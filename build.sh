#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="CodexKeeper"
BUILD_DIR="${BUILD_DIR:-.build}"
# --release produces the same unnotarized distribution build used by Copied.
if [[ "$#" != 0 && !( "$#" == 1 && "$1" == "--release" ) ]]; then
    echo "Usage: $0 [--release]" >&2
    exit 1
fi
IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    if security find-identity -v -p codesigning | grep -F '"Apple Development:' >/dev/null; then
        IDENTITY="Apple Development"
    else
        IDENTITY="-"
    fi
fi
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
FINGERPRINT="$BUILD_DIR/.source_fingerprint"
VERSION_FILE="VERSION"
VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ VERSION must use MAJOR.MINOR.PATCH (found: $VERSION)" >&2
    exit 1
fi

SOURCES=(
    App/CodexKeeperApp.swift
    App/AppState.swift
    App/MenuBarController.swift
    Core/OnboardingPreferences.swift
    Core/ScheduleEngine.swift
    Core/DecisionEngine.swift
    Core/NextAction.swift
    Core/MenuPresentation.swift
    Core/PingEngine.swift
    Core/PingDiagnostics.swift
    Core/ResumeEngine.swift
    Core/ExecutionCoordinator.swift
    Core/ExecutionEventLog.swift
    Codex/AppServerClient.swift
    Codex/DesktopIPCClient.swift
    Codex/ComposerDraftReader.swift
    Codex/QuotaErrorLogProvider.swift
    Codex/UsageObserver.swift
    Codex/SessionWatcher.swift
    Codex/BlockedSessionDetector.swift
    UI/MenuSummaryView.swift
    UI/ResumeTasksView.swift
    UI/SettingsView.swift
    UI/OnboardingView.swift
)
RESOURCES=(Info.plist assets/NOTICE.md)
BUILD_FILES=(build.sh VERSION)

echo "🔨 Building CodexKeeper..."

# ── Fingerprint check (skip compilation if nothing changed) ──
NPROC=$(sysctl -n hw.ncpu)
NEW_FP=$({ shasum -a 256 "${SOURCES[@]}" "${RESOURCES[@]}" "${BUILD_FILES[@]}"; printf '%s\n' "$IDENTITY"; swiftc --version 2>&1; } | shasum -a 256)
OLD_FP=$(cat "$FINGERPRINT" 2>/dev/null || echo "")

if [[ "$NEW_FP" == "$OLD_FP" ]] && [[ -f "$MACOS_DIR/$APP_NAME" ]]; then
    echo "   no changes, skipping compilation"
    exit 0
fi

# ── Clean & compile ─────────────────────────────────────────
mkdir -p "$BUILD_DIR"
STAGING=$(mktemp -d "$BUILD_DIR/.keeper-build.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/$APP_NAME.app"
MACOS_DIR="$STAGED_APP/Contents/MacOS"
mkdir -p "$MACOS_DIR" "$STAGED_APP/Contents/Resources"

swiftc -O \
    -num-threads "$NPROC" \
    -o "$MACOS_DIR/$APP_NAME" \
    -target "arm64-apple-macosx$MIN_OS" \
    -framework SwiftUI \
    -framework AppKit \
    -framework ServiceManagement \
    "${SOURCES[@]}"

# Copy Info.plist and stamp version
cp Info.plist "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$STAGED_APP/Contents/Info.plist"

cp assets/NOTICE.md "$STAGED_APP/Contents/Resources/ThirdPartyNotices.md"

# Match Copied: development signing when available, no notarization requirement.
codesign -s "$IDENTITY" -f "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"
if [[ -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]] && lsof -t "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "Keeper is running from $APP_BUNDLE. Check pending operations and quit it, or build with a different BUILD_DIR." >&2
    exit 1
fi
rm -rf "$APP_BUNDLE"
mv "$STAGED_APP" "$APP_BUNDLE"

# Store fingerprint for next build
echo "$NEW_FP" > "$FINGERPRINT"

echo ""
echo "✅ Build complete!"
echo "   App: $APP_BUNDLE"
