#!/bin/bash
set -euo pipefail
mkdir -p .build/tests
swiftc -parse-as-library -o .build/tests/regression Core/*.swift Codex/*.swift App/AppState.swift Tests/main.swift Tests/PollingTests.swift Tests/ResumeStateTests.swift Tests/LogicRepairTests.swift Tests/PassiveUsageTests.swift Tests/SessionIncrementalTests.swift Tests/MenuLiveUpdateTests.swift Tests/MenuDisabledTests.swift UI/MenuSummaryView.swift UI/MenuBarQuotaView.swift
.build/tests/regression "$@"
