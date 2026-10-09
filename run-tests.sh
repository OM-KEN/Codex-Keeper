#!/bin/bash
set -euo pipefail
mkdir -p .build/tests
swiftc -parse-as-library -o .build/tests/regression Core/*.swift Codex/*.swift App/AppState.swift Tests/main.swift Tests/PollingTests.swift
.build/tests/regression
