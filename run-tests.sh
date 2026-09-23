#!/bin/bash
set -euo pipefail
mkdir -p .build/tests
swiftc -parse-as-library -o .build/tests/regression Core/*.swift Codex/*.swift Tests/main.swift
.build/tests/regression
