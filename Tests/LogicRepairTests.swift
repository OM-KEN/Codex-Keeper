import Foundation
import SQLite3

@MainActor func checkLogicRepairRegression(_ check: (Bool, String) -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-logic-repair-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Calendar.current.date(bySettingHour: 13, minute: 30, second: 30, of: Date())!
    let suite = "keeper.logic-repair." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.register(defaults: ["enabled": true, "autoResume": true, "dailyAnchorMinutes": 480,
        "earlyRecoveryPolicy": "ask", "resumeWorkspaceReminder": false])
    defer { defaults.removePersistentDomain(forName: suite) }

    for mode in ["missing", "legacy-held", "valid-cancel", "valid-ignore", "valid-held", "broken-cancel", "broken-ignore", "broken-held"] {
        let home = root.appendingPathComponent(mode)
        let target = try logicRepairTask(home: home, clock: clock, reset: clock.addingTimeInterval(-60))
        let runtime = home.appendingPathComponent("support/pending-runtime.json")
        var choices = ResumeChoices()
        if mode.hasSuffix("cancel") { choices.useKeepAlive(for: [target]) }
        if mode.hasSuffix("ignore") { choices.ignoredEpisodes = [target.episodeKey] }
        if mode != "missing" {
            try logicRepairRuntime(runtime, tasks: [target], choices: mode == "legacy-held" ? nil : choices,
                held: mode.hasSuffix("held") ? [target.episodeKey] : [])
        }
        let damaged = Data("{ incomplete saved choices".utf8)
        if mode.hasPrefix("broken") { try damaged.write(to: runtime) }
        let usage = LogicRepairUsage(clock)
        let sends = LogicRepairSends()
        let execution = ExecutionCoordinator(provider: usage, makeResumeTransport: { LogicRepairTransport(sends) }, defaults: defaults,
            ledgerURL: home.appendingPathComponent("support/resume-attempts.json"), codexHome: home, now: { usage.clock })
        let state = AppState(provider: usage, defaults: defaults, runtimeURL: runtime, codexHome: home,
            execution: execution, startMonitoring: false, now: { usage.clock })
        if mode.hasPrefix("broken") {
            check((try? Data(contentsOf: runtime)) == damaged, "unreadable saved choices are not overwritten during initialization: \(mode)")
            check(state.keepAliveBlockers(ignoring: []).contains(.runtimeUnhealthy), "unreadable saved choices stop new automatic actions: \(mode)")
            check(state.pendingStateFailure != nil, "unreadable state has a visible persistent error instead of appearing to synchronize: \(mode)")
        }
        state.refresh(manual: true)
        try await logicRepairSettle { state.sessions.hasScanned && !state.usage.refreshing }
        state.recompute()
        try await Task.sleep(nanoseconds: 150_000_000)
        check(sends.total == (mode == "missing" ? 1 : 0), "saved user choices survive startup without authorizing another send: \(mode)")
        if mode.hasPrefix("broken") {
            check((try? Data(contentsOf: runtime)) == damaged, "refresh preserves unreadable original records: \(mode)")
            try logicRepairRuntime(runtime, tasks: [target], choices: choices, held: mode.hasSuffix("held") ? [target.episodeKey] : [])
            state.refresh(manual: true)
            try await logicRepairSettle { !state.usage.refreshing }
            state.recompute()
            try await Task.sleep(nanoseconds: 100_000_000)
            check(!state.keepAliveBlockers(ignoring: []).contains(.runtimeUnhealthy) && sends.total == 0,
                "manual reread recovers repaired records and keeps their original choice: \(mode)")
        }
        state.usage.stop(); state.sessions.stop(); execution.stopOwnedTasks()
    }

    let home = root.appendingPathComponent("now-write-failure")
    let target = try logicRepairTask(home: home, clock: clock, reset: clock.addingTimeInterval(1800))
    let runtime = home.appendingPathComponent("support/pending-runtime.json")
    var choices = ResumeChoices(); choices.requestRecoveryDecision(for: target, now: clock)
    try logicRepairRuntime(runtime, tasks: [target], choices: choices)
    let usage = LogicRepairUsage(clock)
    let sends = LogicRepairSends()
    let execution = ExecutionCoordinator(provider: usage, makeResumeTransport: { LogicRepairTransport(sends) }, defaults: defaults,
        ledgerURL: home.appendingPathComponent("ledger/resume-attempts.json"), codexHome: home, now: { usage.clock })
    let state = AppState(provider: usage, defaults: defaults, runtimeURL: runtime, codexHome: home,
        execution: execution, startMonitoring: false, now: { usage.clock })
    state.refresh(manual: true)
    try await logicRepairSettle { state.sessions.hasScanned && !state.usage.refreshing }
    let saved = try Data(contentsOf: runtime)
    try FileManager.default.removeItem(at: runtime)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
    state.resolveRecoveryDecision(.now, for: [target])
    try await Task.sleep(nanoseconds: 50_000_000)
    check(state.choices.recoveryDecisions?[target.episodeKey]?.phase != .responded && sends.total == 0,
        "failed choice persistence keeps now available and does not submit")
    check(sends.preparations == 0, "failed choice persistence does not launch background channel preparation")
    try FileManager.default.removeItem(at: runtime)
    try saved.write(to: runtime)
    usage.setClock(clock.addingTimeInterval(1))
    state.recompute(allowExecution: false)
    let previousOperations = Set(execution.operations.keys)
    state.resolveRecoveryDecision(.now, for: [target])
    if !Set(execution.operations.keys).subtracting(previousOperations).isEmpty {
        try await logicRepairSettle { sends.total > 0 || execution.operations.values.contains { !previousOperations.contains($0.id) && $0.phase == .notSubmitted } }
    }
    let retryDetails = execution.operations.values.map { "\($0.phase):\($0.preflight?.reasons.map(\.rawValue) ?? []):\($0.failure ?? "")" }
    check(sends.total == 1, "now can be selected again after storage recovers; choice=\(String(describing: state.choices.recoveryDecisions?[target.episodeKey]?.phase)), selected=\(state.selectedTasks.count), state=\(state.pendingStateFailure ?? "healthy"), operation=\(retryDetails)")
    state.usage.stop(); state.sessions.stop(); execution.stopOwnedTasks()

    for savedPhase in ["orphan", "preparing", "preparing-known-error", "preparing-auto", "checking"] {
        let possibleSubmission = savedPhase == "checking"
        let knownError = savedPhase == "preparing-known-error"
        let automatic = savedPhase == "preparing-auto"
        let orphanHome = root.appendingPathComponent("responded-" + savedPhase)
        let task = try logicRepairTask(home: orphanHome, clock: clock, reset: clock.addingTimeInterval(automatic ? -60 : 1800))
        let runtime = orphanHome.appendingPathComponent("support/pending-runtime.json")
        var choice = ResumeChoices()
        if !automatic {
            choice.requestRecoveryDecision(for: task, now: clock)
            _ = choice.resolveRecoveryDecision(.now, for: task)
        }
        try logicRepairRuntime(runtime, tasks: [task], choices: choice)
        if savedPhase != "orphan" {
            var operation = ResumeOperation(id: "old-operation", batchID: "old-batch", accountID: "logic-repair-account", target: task,
                actionAt: clock.addingTimeInterval(-10), phase: possibleSubmission ? .checking : .preparing, protectsThread: possibleSubmission, manual: !automatic)
            if knownError {
                operation.preflight = ResumePreflightDiagnostic(stage: .usageRead, reasons: [.preparationFailed], target: task, checkedAt: clock,
                    failure: UsageReadDiagnostic(requestStage: "account/rateLimits/read", rpcAttempted: true, cooldown: false,
                        elapsedMilliseconds: 1, reason: "connection_failed"))
            }
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(operation))
            try JSONSerialization.data(withJSONObject: ["version": 1, "keys": [], "operations": [encoded]])
                .write(to: orphanHome.appendingPathComponent("support/resume-attempts.json"))
        }
        let usage = LogicRepairUsage(clock)
        let sends = LogicRepairSends()
        let execution = ExecutionCoordinator(provider: usage, makeResumeTransport: { LogicRepairTransport(sends) }, defaults: defaults,
            ledgerURL: orphanHome.appendingPathComponent("support/resume-attempts.json"), codexHome: orphanHome, now: { usage.clock })
        let state = AppState(provider: usage, defaults: defaults, runtimeURL: runtime, codexHome: orphanHome,
            execution: execution, startMonitoring: false, now: { usage.clock })
        if savedPhase == "orphan" {
            check(execution.operations.isEmpty, "orphan choice recovery waits for current task and account evidence")
        }
        state.refresh(manual: true)
        try await logicRepairSettle { state.sessions.hasScanned && !state.usage.refreshing }
        state.recompute()
        try await Task.sleep(nanoseconds: 100_000_000)
        if possibleSubmission {
            check(sends.total == 0 && execution.latestOperation(for: task, accountID: "logic-repair-account")?.phase == .checking &&
                execution.latestOperation(for: task, accountID: "logic-repair-account")?.canRetrySubmission == false,
                "orphan recovery never resets a possibly submitted operation")
        } else {
            let operation = execution.latestOperation(for: task, accountID: "logic-repair-account")
            if automatic {
                check(sends.total == 0 && operation?.waitsForAutomaticRetry == true && operation?.canRetrySubmission == false,
                    "an interrupted automatic preparation keeps its automatic-wait presentation instead of asking for manual retry")
            } else {
                check(sends.total == 0 && operation?.canRetrySubmission == true,
                    "persisted now without an operation gets an explicit unsent retry record")
            }
            if knownError {
                check(operation?.preflight?.failure?.reason == "connection_failed" &&
                    operation?.notSubmittedMessage == CodexConnectionError.userMessage(reason: "connection_failed"),
                    "startup recovery preserves a known error's own cause and action instead of replacing it with an interruption")
            } else {
                check(operation?.preflight?.stage == .channelPrepare && operation?.preflight?.reasons.map(\.rawValue) == ["preparation_interrupted"],
                    "restored unsent preparation records its actual interruption cause rather than only a generic result: \(savedPhase)")
            }
        }
        usage.setClock(clock.addingTimeInterval(60))
        state.refresh(manual: true)
        try await logicRepairSettle { !state.usage.refreshing }
        state.recompute()
        if automatic { try await logicRepairSettle { sends.total == 1 } }
        else { try await Task.sleep(nanoseconds: 100_000_000) }
        check(sends.total == (automatic ? 1 : 0),
            "passing the retry interval preserves automatic recovery while a consumed manual choice still waits for the user: \(savedPhase)")
        state.usage.stop(); state.sessions.stop(); execution.stopOwnedTasks()
    }

    for held in [false, true] {
        let home = root.appendingPathComponent(held ? "mixed-held" : "both-natural")
        let node = Calendar.current.date(bySettingHour: 13, minute: 0, second: 30, of: clock)!
        let first = try logicRepairTask(home: home, clock: node, reset: node.addingTimeInterval(-60))
        let second = try logicRepairTask(home: home, clock: node, reset: node.addingTimeInterval(-60), makeLogs: false)
        let runtime = home.appendingPathComponent("support/pending-runtime.json")
        try logicRepairRuntime(runtime, tasks: [first, second], choices: ResumeChoices(), held: held ? [second.episodeKey] : [])
        let usage = LogicRepairUsage(node)
        let sends = LogicRepairSends()
        let execution = ExecutionCoordinator(provider: usage, makeResumeTransport: {
            LogicRepairTransport(sends, prepare: { usage.setClock(node.addingTimeInterval(240)) })
        }, defaults: defaults, ledgerURL: home.appendingPathComponent("support/resume-attempts.json"), codexHome: home, now: { usage.clock })
        let state = AppState(provider: usage, defaults: defaults, runtimeURL: runtime, codexHome: home,
            execution: execution, startMonitoring: false, now: { usage.clock })
        state.refresh(manual: true)
        try await logicRepairSettle { state.sessions.hasScanned && !state.usage.refreshing && !execution.operations.isEmpty }
        try await logicRepairSettle { !execution.operations.values.contains { $0.phase == .preparing } }
        try await Task.sleep(nanoseconds: 100_000_000)
        check(sends.count(first.id) == 1, "another task's plan choice cannot delay a normally recovered target after slow preparation: \(held)")
        check(sends.count(second.id) == (held ? 0 : 1), "each task keeps its own time permission after preparation: \(held)")
        state.usage.stop(); state.sessions.stop(); execution.stopOwnedTasks()
    }
    try await checkLogicRepairNetwork(root.appendingPathComponent("network"), defaults, clock, check)
    try await checkLogicRepairScanner(root.appendingPathComponent("scanner"), defaults, clock, check)
}

private final class LogicRepairUsage: UsageProvider {
    private let lock = NSLock()
    private var value: Date
    private var readsValue = 0
    private var readBody: (() -> Void)?
    init(_ clock: Date) { value = clock }
    var clock: Date { lock.lock(); defer { lock.unlock() }; return value }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return readsValue }
    func setClock(_ date: Date) { lock.lock(); value = date; lock.unlock() }
    func onRead(_ body: (() -> Void)?) { lock.lock(); readBody = body; lock.unlock() }
    func read() throws -> UsageSnapshot {
        lock.lock(); readsValue += 1; let body = readBody; lock.unlock()
        body?()
        let date = clock
        return UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: date.addingTimeInterval(3600)),
            weekly: nil, capturedAt: date, accountID: "logic-repair-account", sourceFile: "app-server", zeroUseWindowActive: true)
    }
}

private final class LogicRepairGate {
    private let condition = NSCondition()
    private var enteredValue = false
    private var released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return enteredValue }
    func wait() {
        condition.lock(); enteredValue = true
        let deadline = Date().addingTimeInterval(10)
        while !released { if !condition.wait(until: deadline) { break } }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@MainActor private func checkLogicRepairNetwork(_ root: URL, _ defaults: UserDefaults, _ clock: Date,
                                             _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try logicRepairDatabase(root)
    let usage = LogicRepairUsage(clock)
    let state = AppState(provider: usage, defaults: defaults, runtimeURL: root.appendingPathComponent("support/pending-runtime.json"),
        codexHome: root, startMonitoring: false, now: { usage.clock })
    state.networkChanged(available: true)
    try await logicRepairSettle { state.sessions.hasScanned && !state.usage.refreshing }
    let reads = usage.reads
    for _ in 0..<12 { state.networkChanged(available: true) }
    try await Task.sleep(nanoseconds: 100_000_000)
    check(usage.reads == reads && !state.usage.criticalRefreshPending && state.usage.polling.interval == 300,
        "repeated connected path signals preserve idle quota cadence and do not create a critical barrier")
    let gate = LogicRepairGate(); defer { gate.release() }
    usage.onRead { gate.wait() }
    state.networkChanged(available: false)
    try await logicRepairSettle { gate.entered }
    check(state.usage.criticalRefreshPending && !state.usage.hasReliableReading,
        "a real reachability change requires a new reliable reading")
    gate.release(); usage.onRead(nil)
    try await logicRepairSettle { !state.usage.refreshing }
    let beforeReconnect = usage.reads
    state.networkChanged(available: true)
    try await logicRepairSettle { !state.usage.refreshing }
    check(usage.reads > beforeReconnect && state.usage.hasReliableReading,
        "network recovery actually reads fresh quota before returning to normal")
    let trace = try String(contentsOf: root.appendingPathComponent("support/usage-transitions.jsonl"), encoding: .utf8)
    check(trace.contains("\"trigger\":\"network\"") && trace.contains("usage_refresh_finished"),
        "critical refresh diagnostics retain their real trigger without account or network contents")
    state.usage.stop(); state.sessions.stop(); state.execution.stopOwnedTasks()

    for changedIdentity in [false, true] {
        let home = root.appendingPathComponent(changedIdentity ? "changed-identity" : "stable-preparation")
        let target = try logicRepairTask(home: home, clock: clock, reset: clock.addingTimeInterval(-60))
        let runtime = home.appendingPathComponent("support/pending-runtime.json")
        try logicRepairRuntime(runtime, tasks: [target], choices: ResumeChoices())
        let usage = LogicRepairUsage(clock)
        let gate = LogicRepairGate(); defer { gate.release() }
        let sends = LogicRepairSends()
        let execution = ExecutionCoordinator(provider: usage, makeResumeTransport: { LogicRepairTransport(sends, prepare: { gate.wait() }) },
            defaults: defaults, ledgerURL: home.appendingPathComponent("support/resume-attempts.json"), codexHome: home, now: { usage.clock })
        let state = AppState(provider: usage, defaults: defaults, runtimeURL: runtime, codexHome: home,
            execution: execution, startMonitoring: false, now: { usage.clock })
        state.networkChanged(available: true)
        try await logicRepairSettle { gate.entered && !state.usage.refreshing }
        if changedIdentity {
            let reads = usage.reads
            try Data("{\"tokens\":{\"account_id\":\"logic-repair-account\",\"access_token\":\"fixture-only-new-token\"}}".utf8)
                .write(to: home.appendingPathComponent("auth.json"))
            state.sessions.refresh()
            try await logicRepairSettle { state.sessions.authentication != .known(nil) && usage.reads > reads && !state.usage.refreshing }
        } else {
            for _ in 0..<12 { state.networkChanged(available: true) }
            try await Task.sleep(nanoseconds: 100_000_000)
            check(!state.usage.criticalRefreshPending, "duplicate network signals cannot revoke an already prepared independent preflight")
        }
        gate.release()
        try await logicRepairSettle { !execution.operations.values.contains { $0.phase == .preparing } }
        try await Task.sleep(nanoseconds: 100_000_000)
        check(sends.total == (changedIdentity ? 0 : 1),
            "stable signals allow progress while changed identity revokes old preparation: \(changedIdentity)")
        state.usage.stop(); state.sessions.stop(); execution.stopOwnedTasks()
    }
}

@MainActor private func checkLogicRepairScanner(_ root: URL, _ defaults: UserDefaults, _ clock: Date,
                                             _ check: (Bool, String) -> Void) async throws {
    let target = try logicRepairTask(home: root, clock: clock, reset: clock.addingTimeInterval(-60))
    let original = try Data(contentsOf: target.fileURL)
    let mtime = try target.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
    let parses = LogicRepairSends()
    let worker = SessionScanWorker(codexHome: root, parseRollout: { url, date in
        parses.record(url.path)
        Thread.sleep(forTimeInterval: 0.01)
        return SessionWatcher.parse(url: url, mtime: date)
    })
    DispatchQueue.concurrentPerform(iterations: 4) { _ in _ = worker.read(watchedIDs: [target.id]) }
    check(parses.total == 1, "concurrent preflight reads serialize and parse unchanged history once")
    let watcher = SessionWatcher(codexHome: root, worker: worker)
    watcher.refresh(); try await logicRepairSettle { watcher.hasScanned }
    let usage = LogicRepairUsage(clock)
    let sends = LogicRepairSends()
    let execution = ExecutionCoordinator(provider: usage, makeResumeTransport: { LogicRepairTransport(sends) }, defaults: defaults,
        ledgerURL: root.appendingPathComponent("support/resume-attempts.json"), codexHome: root, scanWorker: worker, now: { usage.clock })
    execution.resume([ResumeRequest(target: target, prompt: "fixture", accountID: "logic-repair-account", workspace: nil)],
        schedule: ScheduleEngine(anchorMinutes: 480), manual: true)
    try await logicRepairSettle { sends.total == 1 }
    check(parses.total == 1, "watcher and actual resume preflight reuse the same parser cache")
    execution.stopOwnedTasks(); watcher.stop()

    var changed = original
    changed.append(try logicRepairEvent("user_message", at: clock))
    try changed.write(to: target.fileURL)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: target.fileURL.path)
    let afterAppend = worker.read(watchedIDs: [target.id]).0.first { $0.id == target.id }
    check(afterAppend?.lastUserMessageAt == clock &&
        ResumePreflight.sessionBlockers(target: target, session: afterAppend, stage: .beforeSend).contains(.userInputAfterPause) && parses.total == 2,
        "append is rechecked even if modification time is unchanged and manual progress cancels the pause")
    try original.write(to: target.fileURL, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: target.fileURL.path)
    check(try SessionWatcher.freshBlockedSessions(codexHome: root, worker: worker).count == 1,
        "replacement restores the actual original pause rather than retaining manual-progress cache")
    let replacement = String(data: original, encoding: .utf8)!.replacingOccurrences(of: "\"type\":\"error\"", with: "\"type\":\"other\"")
    check(replacement.utf8.count == original.count && Data(replacement.utf8) != original,
        "same-size replacement fixture preserves metadata except file identity")
    let beforeReplacement = parses.total
    try Data(replacement.utf8).write(to: target.fileURL, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: target.fileURL.path)
    check(try SessionWatcher.freshBlockedSessions(codexHome: root, worker: worker).isEmpty && parses.total == beforeReplacement + 1,
        "atomic same-size same-time replacement cannot reuse the old pause")

    var db: OpaquePointer?
    guard sqlite3_open(root.appendingPathComponent("logs_1.sqlite").path, &db) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    let sql = "INSERT INTO logs VALUES(1,\(Int(clock.timeIntervalSince1970)),0,'codex_core::session::turn','\(target.id)','session_task.run:run_turn: Turn error: You’ve hit your usage limit.')"
    let inserted = sqlite3_exec(db, sql, nil, nil, nil); sqlite3_close(db)
    check(try inserted == SQLITE_OK && SessionWatcher.freshBlockedSessions(codexHome: root, worker: worker).count == 1,
        "warm scan sees a new quota stop added only to SQLite")
    try FileManager.default.moveItem(at: root.appendingPathComponent("logs_1.sqlite"), to: root.appendingPathComponent("previous.sqlite"))
    try logicRepairDatabase(root, name: "logs_2.sqlite")
    check(try SessionWatcher.freshBlockedSessions(codexHome: root, worker: worker).isEmpty,
        "shared quota log reader handles database rotation without replaying old stop evidence")

    var running = original; running.append(try logicRepairEvent("task_started", at: clock))
    try running.write(to: target.fileURL)
    _ = worker.read(watchedIDs: [target.id])
    for index in 0..<22 {
        let id = UUID().uuidString
        var row = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "cwd": root.path]])
        row.append(10); row.append(try logicRepairEvent("task_complete", at: clock.addingTimeInterval(Double(index + 1))))
        try row.write(to: root.appendingPathComponent("sessions/rollout-\(id).jsonl"))
    }
    check(worker.read(watchedIDs: []).0.contains { $0.id == target.id && $0.taskRunning },
        "shared worker retains a running task pushed out of the twenty recent files")
    try FileManager.default.removeItem(at: target.fileURL)
    let missing = worker.read(watchedIDs: [])
    check(missing.1 != nil && missing.0.contains { $0.id == target.id && $0.taskRunning },
        "missing protected running history remains a blocking fact instead of silently disappearing")
}

private func logicRepairEvent(_ type: String, at: Date) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: at),
        "payload": ["type": type, "turn_id": "next-turn"]])
    data.append(10); return data
}

private final class LogicRepairSends {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    private var preparationsValue = 0
    var total: Int { lock.lock(); defer { lock.unlock() }; return values.values.reduce(0, +) }
    var preparations: Int { lock.lock(); defer { lock.unlock() }; return preparationsValue }
    func prepared() { lock.lock(); preparationsValue += 1; lock.unlock() }
    func count(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[id] ?? 0 }
    func record(_ id: String) { lock.lock(); values[id, default: 0] += 1; lock.unlock() }
}

private struct LogicRepairTransport: ResumeTransport {
    let sends: LogicRepairSends
    var prepareBody: () -> Void
    init(_ sends: LogicRepairSends, prepare: @escaping () -> Void = {}) { self.sends = sends; prepareBody = prepare }
    func prepare(_ target: BlockedSession) throws { sends.prepared(); prepareBody() }
    func submit(_ target: BlockedSession, prompt: String, update: @escaping (ResumeTransportEvent) -> Void) throws {
        sends.record(target.id)
        update(.received(ResumeReceipt(threadID: target.id, turnID: "fixture-turn", message: "fixture"), Date()))
    }
}

@MainActor private func logicRepairSettle(_ ready: () -> Bool, file: StaticString = #fileID, line: UInt = #line) async throws {
    for _ in 0..<300 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    FileHandle.standardError.write(Data("Timed out at \(file):\(line)\n".utf8))
    throw CodexConnectionError.timeout
}

private func logicRepairTask(home: URL, clock: Date, reset: Date, makeLogs: Bool = true) throws -> BlockedSession {
    try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    if makeLogs { try logicRepairDatabase(home) }
    let id = UUID().uuidString
    let stop = clock.addingTimeInterval(-600)
    func line(_ type: String, _ payload: [String: Any], _ at: Date) throws -> Data {
        var row = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": ISO8601DateFormatter().string(from: at), "payload": payload])
        row.append(10); return row
    }
    var data = try line("session_meta", ["id": id, "cwd": home.path], stop.addingTimeInterval(-20))
    data.append(try line("event_msg", ["type": "task_started", "turn_id": "stopped-turn"], stop.addingTimeInterval(-10)))
    data.append(try line("event_msg", ["type": "token_count", "turn_id": "stopped-turn", "rate_limits": ["limit_id": "codex", "primary": ["used_percent": 100, "window_minutes": 300, "resets_at": reset.timeIntervalSince1970]]], stop.addingTimeInterval(-1)))
    data.append(try line("event_msg", ["type": "error", "turn_id": "stopped-turn", "message": "usage_limit_reached"], stop))
    let file = home.appendingPathComponent("sessions/rollout-\(id).jsonl")
    try data.write(to: file)
    guard let session = SessionWatcher.parse(url: file, mtime: clock), let task = BlockedSessionDetector.detect(in: [session]).first else { throw CodexConnectionError.invalidResponse }
    return task.stabilized(from: nil)
}

private func logicRepairDatabase(_ home: URL, name: String = "logs_1.sqlite") throws {
    var db: OpaquePointer?
    guard sqlite3_open(home.appendingPathComponent(name).path, &db) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
}

private func logicRepairRuntime(_ url: URL, tasks: [BlockedSession], choices: ResumeChoices?, held: [String] = []) throws {
    let confirmed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })))
    var value: [String: Any] = ["confirmed": confirmed, "accounts": Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, "logic-repair-account") }),
        "workspaces": [:], "held": held, "displayAccountID": "logic-repair-account"]
    if let choices { value["choices"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(choices)) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value).write(to: url, options: .atomic)
}
