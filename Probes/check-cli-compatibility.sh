#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROBE_DIR=".build/cli-compatibility"
mkdir -p "$PROBE_DIR"
SOURCES=(Core/*.swift Codex/*.swift Probes/CLICompatibility.swift)
FINGERPRINT=$({ shasum -a 256 "${SOURCES[@]}"; swiftc --version 2>&1; } | shasum -a 256)
if [[ ! -x "$PROBE_DIR/probe" || "$(cat "$PROBE_DIR/source-fingerprint" 2>/dev/null || true)" != "$FINGERPRINT" ]]; then
    swiftc -parse-as-library -o "$PROBE_DIR/probe.new" "${SOURCES[@]}"
    mv "$PROBE_DIR/probe.new" "$PROBE_DIR/probe"
    printf '%s\n' "$FINGERPRINT" > "$PROBE_DIR/source-fingerprint"
fi
exec "$PROBE_DIR/probe" "$@"
