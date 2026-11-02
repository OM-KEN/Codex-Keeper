#!/bin/bash
set -euo pipefail
mkdir -p .build/tests
clang -O2 -c Codex/ZstdBridge/KeeperZstd.c -o .build/tests/zstd.o
swiftc -I Codex/ZstdBridge .build/tests/zstd.o -parse-as-library -o .build/tests/regression Core/*.swift Codex/*.swift App/AppState.swift Tests/main.swift Tests/PollingTests.swift Tests/ResumeStateTests.swift Tests/LogicRepairTests.swift Tests/PassiveUsageTests.swift Tests/SessionIncrementalTests.swift Tests/MenuLiveUpdateTests.swift Tests/MenuDisabledTests.swift Tests/KeepAliveSimplificationTests.swift Tests/TokenUsageHistoryTests.swift UI/MenuSummaryView.swift UI/MenuBarQuotaView.swift UI/TokenUsageHistoryView.swift
.build/tests/regression "$@"
