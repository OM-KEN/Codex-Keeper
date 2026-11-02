#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROBE_DIR=".build/cli-compatibility"
mkdir -p "$PROBE_DIR"
SOURCES=(Core/*.swift Codex/*.swift Probes/CLICompatibility.swift)
BUILD_FILES=(Probes/check-cli-compatibility.sh Codex/ZstdBridge/KeeperZstd.c Codex/ZstdBridge/KeeperZstd.h Codex/ZstdBridge/module.modulemap Vendor/zstd/zstddeclib.c Vendor/zstd/LICENSE)
FINGERPRINT=$({ shasum -a 256 "${SOURCES[@]}" "${BUILD_FILES[@]}"; swiftc --version 2>&1; } | shasum -a 256)
if [[ ! -x "$PROBE_DIR/probe" || "$(cat "$PROBE_DIR/source-fingerprint" 2>/dev/null || true)" != "$FINGERPRINT" ]]; then
    clang -O2 -c Codex/ZstdBridge/KeeperZstd.c -o "$PROBE_DIR/zstd.o"
    swiftc -I Codex/ZstdBridge "$PROBE_DIR/zstd.o" -parse-as-library -o "$PROBE_DIR/probe.new" "${SOURCES[@]}"
    mv "$PROBE_DIR/probe.new" "$PROBE_DIR/probe"
    printf '%s\n' "$FINGERPRINT" > "$PROBE_DIR/source-fingerprint"
fi
exec "$PROBE_DIR/probe" "$@"
