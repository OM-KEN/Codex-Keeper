import Foundation
import SQLite3

func checkTimelineResumeHistory(_ check: (Bool, String) -> Void) {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    func at(_ hour: Int, _ minute: Int = 0, _ second: Double = 0) -> Date {
        calendar.date(byAdding: .minute, value: hour * 60 + minute, to: today)!.addingTimeInterval(second)
    }
    let account = "timeline-resume-account"
    let now = at(14)
    let target = BlockedSession(id: "timeline-resume-task", project: "Test", cwd: "/unused",
        blockedAt: at(7), fiveHourResetAt: nil, weeklyResetAt: nil, fileURL: URL(fileURLWithPath: "/unused/rollout.jsonl"))
    let operation = ResumeOperation(id: "confirmed-resume", batchID: "confirmed-batch", accountID: account, target: target,
        actionAt: at(8, 0, 13.829533), phase: .continued, respondedAt: at(8, 0, 28.962), endedAt: at(8, 7, 59), protectsThread: false)
    let confirmation = ExecutionConfirmation(kind: .resume, actionAt: operation.actionAt, confirmedAt: operation.respondedAt!,
        windowStart: nil, accountID: account, operationID: operation.id)
    let skipped = PingNodeResult(node: at(8), accountID: account, at: at(8, 10, 2), outcome: .skipped)
    let sentPing = PingNodeResult(node: at(13), accountID: account, at: at(13, 0, 30), outcome: .windowActive)
    func initial() -> MenuSummary {
        MenuSummary(timeline: [
            MenuTimelinePoint(date: at(8), time: "08:00", day: "", label: "窗口开始", kind: .keepAliveNotNeeded, solidBefore: false),
            MenuTimelinePoint(date: at(13), time: "13:00", day: "", label: "已保活", kind: .completedKeepAlive, solidBefore: false),
            MenuTimelinePoint(date: at(13, 34), time: "13:34", day: "", label: "已重置", kind: .reset, solidBefore: true),
            MenuTimelinePoint(date: at(18), time: "18:00", day: "", label: "保活", kind: .keepAlive, solidBefore: false)
        ])
    }
    func history(_ operations: [ResumeOperation], confirmations: [ExecutionConfirmation] = [confirmation]) -> MenuSummary {
        var summary = initial()
        summary.applyPingHistory([skipped, sentPing], accountID: account, now: now)
        summary.applyResumeHistory(operations, accountID: account, confirmations: confirmations, now: now)
        return summary
    }
    var summary = history([operation])
    check(summary.timeline.first?.kind == .completedResume && summary.timeline.first?.label == "已继续" &&
        summary.timeline.first?.symbol == "checkmark.circle.fill",
        "a confirmed resume takes precedence over a skipped same-node keepalive when all four slots are occupied")
    check(summary.timeline.first?.operationIDs == [operation.id], "the merged resume retains the exact successful operation association")
    check(summary.timeline.first?.pingResult?.outcome == .skipped,
        "a merged resume retains the skipped keepalive as an attached fact")
    check(summary.timeline.map(\.date) == [at(8), at(13), at(13, 34), at(18)] &&
        summary.timeline[1].pingResult?.outcome == .windowActive && summary.timeline[2].kind == .reset && summary.timeline[3].kind == .keepAlive,
        "merging resume history preserves the independent sent keepalive, reset, next action and four-node limit")
    summary.applyResumeHistory([operation], accountID: account, now: now)
    check(summary.timeline.first?.operationIDs == [operation.id] && summary.timeline.count == 4,
        "reapplying resume history without confirmations preserves its explicit operation IDs")
    summary.applyPingHistory([skipped, sentPing], accountID: account, now: now)
    check(summary.timeline.first?.kind == .completedResume && summary.timeline.first?.operationIDs == [operation.id] && summary.timeline.count == 4,
        "applying ping history after resume history cannot overwrite the confirmed resume")
    let peer = ResumeOperation(id: "unsent-batch-peer", batchID: operation.batchID, accountID: account, target: target,
        actionAt: at(8, 0, 14), phase: .notSubmitted, protectsThread: false)
    let other = ResumeOperation(id: "other-batch", batchID: "other-batch", accountID: account, target: target,
        actionAt: at(9), phase: .continued, respondedAt: at(9, 0, 10), protectsThread: false)
    let batch = history([operation, peer, other])
    check(batch.timeline.first?.operationIDs == [operation.id, peer.id],
        "the merged node opens the real batch including its unsent peer and excludes another batch")
    var respondedPeer = peer; respondedPeer.phase = .continued; respondedPeer.respondedAt = at(8, 0, 30)
    var repeatedBatch = history([operation, respondedPeer], confirmations: [])
    repeatedBatch.applyPingHistory([skipped, sentPing], accountID: account, now: now)
    repeatedBatch.applyResumeHistory([operation, respondedPeer], accountID: account, now: now)
    check(repeatedBatch.timeline.count == 4 && repeatedBatch.timeline.first?.kind == .completedResume &&
        repeatedBatch.timeline.first?.operationIDs == [operation.id, peer.id],
        "multiple responded tasks in one batch merge once and remain idempotent without log confirmations")
    for invalid in [ResumeOperation(id: operation.id, batchID: operation.batchID, accountID: "other-account", target: target,
            actionAt: operation.actionAt, phase: .continued, respondedAt: operation.respondedAt, protectsThread: false),
        ResumeOperation(id: operation.id, batchID: operation.batchID, accountID: nil, target: target,
            actionAt: operation.actionAt, phase: .continued, respondedAt: operation.respondedAt, protectsThread: false),
        ResumeOperation(id: operation.id, batchID: operation.batchID, accountID: account, target: target,
            actionAt: operation.actionAt, phase: .checking, receivedAt: at(8, 0, 20), endedAt: at(8, 7, 59), protectsThread: false),
        ResumeOperation(id: operation.id, batchID: operation.batchID, accountID: account, target: target,
            actionAt: operation.actionAt, phase: .continued, respondedAt: now.addingTimeInterval(1), protectsThread: false),
        ResumeOperation(id: operation.id, batchID: operation.batchID, accountID: account, target: target,
            actionAt: operation.actionAt, phase: .continued, respondedAt: operation.actionAt.addingTimeInterval(-1), protectsThread: false)] {
        let unconfirmed = history([invalid])
        check(unconfirmed.timeline.first?.kind == .pingRecord && unconfirmed.timeline.first?.operationIDs.isEmpty == true,
            "another account, missing identity or unconfirmed/invalid response cannot upgrade a skipped node: \(invalid.accountID ?? "nil") \(invalid.respondedAt?.description ?? "no response")")
    }
    var distant = operation; distant.actionAt = at(8).addingTimeInterval(ScheduleEngine.alignmentTolerance + 1)
    distant.respondedAt = distant.actionAt.addingTimeInterval(1)
    check(history([distant], confirmations: []).timeline.first?.kind == .pingRecord,
        "a resume outside alignment tolerance cannot consume a skipped keepalive node")
    var aligned = operation; aligned.actionAt = at(8).addingTimeInterval(ScheduleEngine.alignmentTolerance)
    aligned.respondedAt = aligned.actionAt.addingTimeInterval(1)
    check(history([aligned], confirmations: []).timeline.first?.kind == .completedResume,
        "a real response exactly at alignment tolerance still matches its fixed node")
    var previousDay = operation
    previousDay.actionAt = calendar.date(byAdding: .day, value: -1, to: operation.actionAt)!
    previousDay.respondedAt = calendar.date(byAdding: .day, value: -1, to: operation.respondedAt!)!
    check(history([previousDay], confirmations: []).timeline.first?.kind == .pingRecord,
        "a previous-day resume cannot upgrade today's skipped keepalive")
    var midnight = MenuSummary()
    midnight.applyPingHistory([PingNodeResult(node: today, accountID: account, at: today.addingTimeInterval(60), outcome: .skipped)], accountID: account, now: now)
    var yesterday = operation; yesterday.actionAt = today.addingTimeInterval(-1); yesterday.respondedAt = today.addingTimeInterval(1)
    midnight.applyResumeHistory([yesterday], accountID: account, now: now)
    check(midnight.timeline.count == 1 && midnight.timeline.first?.kind == .pingRecord,
        "alignment tolerance cannot merge a prior-day action across local midnight")
    var futureResponse = operation; futureResponse.respondedAt = now.addingTimeInterval(1)
    var noPlan = MenuSummary()
    noPlan.applyResumeHistory([futureResponse], accountID: account, now: now)
    check(!noPlan.timeline.contains { $0.kind == .completedResume },
        "a future response cannot invent successful history even when a timeline slot is available")
    var anonymous = MenuSummary()
    let anonymousOperation = ResumeOperation(id: operation.id, batchID: operation.batchID, accountID: nil, target: target,
        actionAt: operation.actionAt, phase: .continued, respondedAt: operation.respondedAt, protectsThread: false)
    anonymous.applyResumeHistory([anonymousOperation], accountID: nil, now: now)
    check(anonymous.timeline.isEmpty, "missing current and operation account identity cannot claim successful resume history")
    for outcome: PingOutcome in [.newWindow, .windowActive, .windowPending, .failed, .unknown, .notExecuted, .submitted] {
        var independent = initial()
        let ping = PingNodeResult(node: skipped.node, accountID: account, at: skipped.at, outcome: outcome)
        independent.applyPingHistory([ping], accountID: account, now: now)
        independent.applyResumeHistory([operation], accountID: account, confirmations: [confirmation], now: now)
        check(independent.timeline.first?.kind == .pingRecord && independent.timeline.first?.pingResult?.outcome == outcome &&
            independent.timeline.first?.operationIDs.isEmpty == true,
            "an independent \(outcome.rawValue) keepalive result cannot be absorbed by a nearby resume")
    }
    var reverse = MenuSummary(timeline: [MenuTimelinePoint(date: operation.actionAt, time: "08:00", day: "", label: "已继续",
        kind: .completedResume, solidBefore: false, operationIDs: [operation.id])])
    reverse.applyPingHistory([skipped], accountID: account, now: now)
    check(reverse.timeline.count == 1 && reverse.timeline.first?.kind == .completedResume && reverse.timeline.first?.pingResult?.outcome == .skipped,
        "reverse-order skipped history attaches to an already confirmed aligned resume without adding a duplicate")
    reverse.applyPingHistory([PingNodeResult(node: skipped.node, accountID: account, at: skipped.at, outcome: .windowActive)], accountID: account, now: now)
    check(reverse.timeline.count == 2 && reverse.timeline.contains { $0.kind == .completedResume && $0.operationIDs == [operation.id] } &&
        reverse.timeline.contains { $0.kind == .pingRecord && $0.pingResult?.outcome == .windowActive },
        "a separately sent keepalive remains a separate fact when applied after a confirmed resume")
}

@MainActor func checkKeepAliveSimplification(_ check: (Bool, String) -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-keepalive-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let current = sessions.appendingPathComponent("rollout-\(id)_\(UUID().uuidString).jsonl")
    let old = sessions.appendingPathComponent("rollout-\(id).jsonl")
    let metadata: [String: Any] = ["type": "session_meta", "payload": ["id": id, "cwd": root.path]]
    var trace = try JSONSerialization.data(withJSONObject: metadata); trace.append(10)
    try trace.write(to: current)
    try Data([0xff]).write(to: old)

    func database(_ name: String, sql: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
        var persist: Int32 = 0
        sqlite3_file_control(db, nil, SQLITE_FCNTL_PERSIST_WAL, &persist)
        return url
    }
    let path = current.path.replacingOccurrences(of: "'", with: "''")
    let state = try database("state_5.sqlite", sql: "CREATE TABLE threads(id TEXT, rollout_path TEXT); INSERT INTO threads VALUES('\(id)', '\(path)')")
    let logs = try database("logs_1.sqlite", sql: "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)")
    check(!FileManager.default.fileExists(atPath: state.path + "-wal") && !FileManager.default.fileExists(atPath: logs.path + "-wal"),
        "WAL fixtures use normal last-connection cleanup without auxiliary files")
    check((try? SessionScanWorker.currentRolloutPaths(codexHome: root)[id]) == current,
        "session index opens a WAL database after its auxiliary files were reclaimed")
    check((try? QuotaErrorLogProvider(databaseURL: logs).read()) != nil,
        "quota stop reader opens a WAL database after its auxiliary files were reclaimed")
    var parsed: [URL] = []
    let worker = SessionScanWorker(codexHome: root, parseRollout: { url, mtime in
        parsed.append(url)
        return SessionWatcher.parse(url: url, mtime: mtime)
    })
    let read = worker.read(watchedIDs: [id], watchedPaths: [old])
    check(read.1 == nil && read.0.count == 1 && !parsed.contains(old),
        "trusted current index excludes a broken replaced rollout before parsing it")
    var writer: OpaquePointer?
    guard sqlite3_open(state.path, &writer) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    let latest = root.appendingPathComponent("latest.jsonl")
    let replacement = latest.path.replacingOccurrences(of: "'", with: "''")
    guard sqlite3_exec(writer, "UPDATE threads SET rollout_path='\(replacement)'", nil, nil, nil) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    check((try? SessionScanWorker.currentRolloutPaths(codexHome: root)[id]) == latest,
        "production current-path reader observes the latest commit in an active WAL")
    sqlite3_close(writer)
    let restricted = try ReadOnlyDatabase(url: state, kind: "state")
    do { _ = try restricted.prepare("DELETE FROM threads"); check(false, "restricted database rejects modifying SQL") }
    catch let failure as CodexDatabaseError { check(failure.code == SQLITE_READONLY && failure.stage == "prepare", "restricted database rejects modifying SQL") }
    let missing = root.appendingPathComponent("missing.sqlite")
    do { _ = try ReadOnlyDatabase(url: missing, kind: "state"); check(false, "restricted database never creates missing user databases") }
    catch { check(!FileManager.default.fileExists(atPath: missing.path), "restricted database never creates missing user databases") }
    let corrupt = root.appendingPathComponent("corrupt-state")
    try FileManager.default.createDirectory(at: corrupt.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try trace.write(to: corrupt.appendingPathComponent("sessions/rollout-\(id).jsonl"))
    try Data("invalid state database".utf8).write(to: corrupt.appendingPathComponent("state_5.sqlite"))
    let failure = SessionScanWorker(codexHome: corrupt).read(watchedIDs: [id])
    check(failure.1 == L10n.text("无法读取 Codex 本地暂停记录") && failure.2.contains {
        $0.stage == "state_database.prepare" && $0.code == Int(SQLITE_NOTADB) && $0.primaryCode == Int(SQLITE_NOTADB)
    }, "a later missing quota log cannot overwrite the first concrete state database failure and its SQLite codes")

    let schedule = ScheduleEngine(anchorMinutes: 480)
    let node = schedule.nodes()[1]
    let decision = DecisionEngine(schedule: schedule).decide(now: node.addingTimeInterval(5), enabled: true,
        autoResume: false, earlyRecoveryPolicy: "ask", usage: nil, blocked: [])
    if case .ping = decision { check(true, "unknown quota allows the fixed-node isolated attempt") }
    else { check(false, "unknown quota allows the fixed-node isolated attempt") }

    for unknown in [true, false] {
        let home = root.appendingPathComponent(unknown ? "unknown-quota" : "scan-failure")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"account_id\":\"keepalive-tests\",\"access_token\":\"fixture-only\"}}".utf8)
            .write(to: home.appendingPathComponent("auth.json"))
        let support = home.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let runtime = support.appendingPathComponent("pending-runtime.json")
        let damaged = Data("{ unreadable resume choices".utf8)
        try damaged.write(to: runtime)
        let suite = "keeper.keepalive." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.register(defaults: ["enabled": true, "autoResume": true, "dailyAnchorMinutes": 480])
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = schedule.nodes()[1].addingTimeInterval(5)
        let provider = SimplificationUsage(clock: clock, unknown: unknown)
        let transport = SimplificationPing(clock: clock)
        let execution = ExecutionCoordinator(provider: provider, defaults: defaults, ledgerURL: support.appendingPathComponent("resume-attempts.json"),
            pingTransport: transport, codexHome: home, now: { clock })
        let state = AppState(provider: provider, defaults: defaults, runtimeURL: runtime, codexHome: home,
            execution: execution, startMonitoring: false, now: { clock })
        state.refresh()
        for _ in 0..<100 where state.usage.refreshing || !state.sessions.hasScanned { try await Task.sleep(nanoseconds: 10_000_000) }
        state.recompute()
        try await Task.sleep(nanoseconds: 100_000_000)
        check(transport.calls == 1, "closed-menu background completion permits keepalive despite resume runtime/scan or quota failure: \(unknown)")
        check(provider.modelCalls == 0 && state.nextAction?.date == schedule.nodes()[2],
            "a submitted unknown-quota node moves to the next fixed plan without synchronous model discovery: \(unknown)")
        check((try? Data(contentsOf: runtime)) == damaged, "keepalive leaves damaged resume choices intact: \(unknown)")
        state.usage.stop(); state.sessions.stop(); execution.stopOwnedTasks()
    }
    try await checkKeepAliveFacts(root.appendingPathComponent("facts"), check)
    try checkPingNoticeLifecycle(check, root: root.appendingPathComponent("notice-lifecycle"))
    try await checkKeepAliveHardGates(root.appendingPathComponent("hard-gates"), check)
    try await checkCurrentAuthenticationDisplay(root.appendingPathComponent("authentication-display"), check)
    try checkKeepAlivePreparation(root.appendingPathComponent("preparation"), check)
    try await checkIsolatedPingCompletion(root.appendingPathComponent("pty"), check)
}

func writeKeepAliveAuthentication(home: URL, account: String, token: String = "fixture-only") throws {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["account_id": account, "access_token": token]])
        .write(to: home.appendingPathComponent("auth.json"), options: .atomic)
}

private final class SimplificationUsage: UsageProvider {
    let clock: Date
    var unknown: Bool
    var modelCalls = 0
    var usedPercent: Double = 0
    init(clock: Date, unknown: Bool) { self.clock = clock; self.unknown = unknown }
    func read() throws -> UsageSnapshot {
        if unknown { throw CodexConnectionError.timeout }
        return UsageSnapshot(fiveHour: QuotaWindow(usedPercent: usedPercent, windowMinutes: 300, resetsAt: clock.addingTimeInterval(18000)),
            weekly: nil, capturedAt: clock, accountID: "keepalive-tests", sourceFile: "app-server", zeroUseWindowActive: false)
    }
    func pingModel() throws -> PingModel { modelCalls += 1; throw CodexConnectionError.timeout }
}

@MainActor private func checkCurrentAuthenticationDisplay(_ home: URL, _ check: (Bool, String) -> Void) async throws {
    try writeKeepAliveAuthentication(home: home, account: "keepalive-tests")
    let suite = "keeper.authentication-display." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.register(defaults: ["enabled": true, "dailyAnchorMinutes": 480])
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = ScheduleEngine(anchorMinutes: 480).nodes()[0].addingTimeInterval(3600)
    let provider = SimplificationUsage(clock: clock, unknown: false)
    let support = home.appendingPathComponent("support")
    let execution = ExecutionCoordinator(provider: provider, defaults: defaults, ledgerURL: support.appendingPathComponent("attempts.json"),
        pingTransport: SimplificationPing(clock: clock), codexHome: home, now: { clock })
    let state = AppState(provider: provider, defaults: defaults, runtimeURL: support.appendingPathComponent("pending-runtime.json"),
        codexHome: home, execution: execution, startMonitoring: false, now: { clock })
    defer { state.usage.stop(); state.sessions.stop(); execution.stopOwnedTasks() }
    state.refresh()
    for _ in 0..<100 where state.usage.refreshing || !state.sessions.hasScanned { try await Task.sleep(nanoseconds: 10_000_000) }
    state.recompute(allowExecution: false)
    var presenter = MenuPresentation()
    func render() -> MenuSummary {
        presenter.build(plan: state.nextAction, usage: state.usage.snapshot, schedule: state.schedule,
            tasks: [], availableTasks: [], choices: state.choices, usageError: state.usage.lastError,
            accountContext: state.authenticatedAccountID, now: clock)
    }
    let original = render()
    provider.unknown = true
    state.usage.refresh()
    for _ in 0..<100 where state.usage.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
    let offline = render()
    check(!original.quotas.isEmpty && offline.quotas.map(\.remaining) == original.quotas.map(\.remaining) && offline.refreshMessage == original.refreshMessage,
        "same-account RPC failure retains the last real quota and its original capture time through AppState")
    try writeKeepAliveAuthentication(home: home, account: "new-authentication-account")
    state.sessions.refresh()
    for _ in 0..<100 {
        state.recompute(allowExecution: false)
        if state.authenticatedAccountID == "new-authentication-account" && !state.usage.refreshing { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let switched = render()
    check(state.authenticatedAccountID == "new-authentication-account" && state.usage.snapshot == nil && switched.quotas.isEmpty &&
        switched.quotaAccountID != original.quotaAccountID,
        "real local authentication change clears the prior account while the new account RPC continues to fail")
}

@MainActor private func checkKeepAliveHardGates(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    for gate in ["missing-auth", "damaged-ledger", "exhausted"] {
        let home = root.appendingPathComponent(gate)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if gate != "missing-auth" { try writeKeepAliveAuthentication(home: home, account: "keepalive-tests") }
        let support = home.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let ledger = support.appendingPathComponent("resume-attempts.json")
        let damaged = Data("{ unreadable shared attempt ledger".utf8)
        if gate == "damaged-ledger" { try damaged.write(to: ledger) }
        let suite = "keeper.keepalive-gates." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.register(defaults: ["enabled": true, "dailyAnchorMinutes": 480])
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = ScheduleEngine(anchorMinutes: 480).nodes()[1].addingTimeInterval(10)
        let provider = SimplificationUsage(clock: clock, unknown: false)
        provider.usedPercent = gate == "exhausted" ? 100 : 0
        let transport = SimplificationPing(clock: clock)
        let execution = ExecutionCoordinator(provider: provider, defaults: defaults, ledgerURL: ledger,
            pingTransport: transport, codexHome: home, now: { clock })
        let state = AppState(provider: provider, defaults: defaults, runtimeURL: support.appendingPathComponent("pending-runtime.json"), codexHome: home,
            execution: execution, startMonitoring: false, now: { clock })
        state.usage.refresh()
        for _ in 0..<100 where state.usage.refreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        state.recompute(); try await Task.sleep(nanoseconds: 30_000_000)
        check(transport.calls == 0, "missing current authentication, unsafe sending ledger and fresh exhaustion remain hard gates: \(gate)")
        if gate == "damaged-ledger" { check((try? Data(contentsOf: ledger)) == damaged, "unsafe shared attempt ledger remains byte-for-byte intact") }
        if gate == "exhausted" {
            provider.usedPercent = 0; state.usage.refresh()
            for _ in 0..<100 where state.usage.refreshing || execution.running { try await Task.sleep(nanoseconds: 10_000_000) }
            check(transport.calls == 1, "fresh quota recovery inside the original opportunity permits exactly one attempt")
        }
        state.usage.stop(); state.sessions.stop(); execution.stopOwnedTasks()
    }
}

private final class SimplificationPing: PingTransport {
    var calls = 0
    let clock: Date
    init(clock: Date) { self.clock = clock }
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider) throws -> UsageSnapshot {
        calls += 1
        return UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 1, windowMinutes: 300, resetsAt: clock.addingTimeInterval(18000)),
            weekly: nil, capturedAt: clock, accountID: before.accountID, sourceFile: "app-server")
    }
    func cancel() {}
}

final class PreparationGatePing: PingTransport {
    private let condition = NSCondition()
    private var held = false
    private var preparations = 0
    private var sends = 0
    private let clock: () -> Date
    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }
    var preparationCount: Int { condition.lock(); defer { condition.unlock() }; return preparations }
    var count: Int { condition.lock(); defer { condition.unlock() }; return sends }
    func holdPreparation() { condition.lock(); held = true; condition.unlock() }
    func releasePreparation() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }
    func prepareForSend() {
        condition.lock(); defer { condition.unlock() }
        preparations += 1
        while held { condition.wait() }
    }
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider) throws -> UsageSnapshot {
        condition.lock(); sends += 1; condition.unlock()
        let now = clock()
        return UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 1, windowMinutes: 300, resetsAt: now.addingTimeInterval(18000)),
            weekly: nil, capturedAt: now, accountID: before.accountID, sourceFile: "app-server")
    }
    func cancel() { releasePreparation() }
}

@MainActor func checkPingNoticeLifecycle(_ check: (Bool, String) -> Void, root: URL) throws {
    let suite = "keeper.ping-notice." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.register(defaults: ["enabled": true, "dailyAnchorMinutes": 480])
    defer { defaults.removePersistentDomain(forName: suite) }
    let schedule = ScheduleEngine(anchorMinutes: 480)
    let node = schedule.nodes()[2]
    let missed = PingNodeResult(node: node, accountID: "notice-account", at: node.addingTimeInterval(601),
        outcome: .notExecuted, detail: "额度恢复后按计划保活")
    var clock = node.addingTimeInterval(7200)
    for (name, account, confirmedAt, suppress) in [
        ("later-resume", "notice-account", missed.at.addingTimeInterval(3600), true),
        ("older-resume", "notice-account", missed.at.addingTimeInterval(-60), false),
        ("other-account", "other-account", missed.at.addingTimeInterval(3600), false),
        ("future-resume", "notice-account", clock.addingTimeInterval(60), false)
    ] {
        let support = root.appendingPathComponent(name)
        let events = ExecutionEventLog(url: support.appendingPathComponent("execution-events.jsonl"))
        try events.record("not_executed", kind: "ping", node: node, at: missed.at, pingResult: missed)
        try events.record("startup_confirmed", kind: "resume", node: nil, accountID: account,
            operationID: name, at: confirmedAt)
        let coordinator = ExecutionCoordinator(defaults: defaults, ledgerURL: support.appendingPathComponent("attempts.json"),
            codexHome: root, now: { clock })
        check((coordinator.visibleNotice == nil) == suppress,
            "only a later real same-account response supersedes a missed ping notice: \(name)")
        check(events.pingResults().contains { $0.node == missed.node && $0.outcome == .notExecuted },
            "superseding a current notice preserves the missed opportunity in history: \(name)")
    }
    let support = root.appendingPathComponent("skipped")
    let events = ExecutionEventLog(url: support.appendingPathComponent("execution-events.jsonl"))
    try events.record("not_executed", kind: "ping", node: node, at: missed.at, pingResult: missed)
    let coordinator = ExecutionCoordinator(defaults: defaults, ledgerURL: support.appendingPathComponent("attempts.json"),
        codexHome: root, now: { clock })
    check(coordinator.visibleNotice != nil, "an unresolved missed opportunity initially retains its notice")
    clock = schedule.nodes()[3].addingTimeInterval(10)
    let active = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 26, windowMinutes: 300, resetsAt: clock.addingTimeInterval(5400)),
        weekly: nil, capturedAt: clock, accountID: "notice-account", sourceFile: "app-server")
    coordinator.observeKeepAlive(schedule: schedule, accountID: active.accountID, usage: active, reason: nil)
    clock = clock.addingTimeInterval(601)
    coordinator.observeKeepAlive(schedule: schedule, accountID: active.accountID, usage: nil, reason: nil)
    check(coordinator.lastPingResult?.outcome == .skipped && coordinator.lastFailure == nil &&
        coordinator.visibleNotice == nil && coordinator.visibleFailure == nil,
        "a normal skipped opportunity clears the previous notice before any menu acknowledgement")
    coordinator.acknowledgePingResult()
    check(coordinator.visibleNotice == nil && events.pingResults().contains { $0.outcome == .notExecuted },
        "closing the menu cannot revive an old notice and never deletes its history")
}

@MainActor private func checkKeepAliveFacts(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try writeKeepAliveAuthentication(home: root, account: "facts-account")
    let suite = "keeper.keepalive-facts." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.register(defaults: ["enabled": true, "dailyAnchorMinutes": 480])
    defer { defaults.removePersistentDomain(forName: suite) }
    let schedule = ScheduleEngine(anchorMinutes: 480)
    var clock = schedule.nodes()[1].addingTimeInterval(10)
    var before = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: clock.addingTimeInterval(18000)),
        weekly: nil, capturedAt: clock, accountID: "facts-account", sourceFile: "app-server", zeroUseWindowActive: false)
    var after = before; after.fiveHour?.usedPercent = 1
    check(PingConfirmation.newWindow(before: before, after: after, now: clock, submittedAt: clock), "fresh known inactive before plus a completed valid window can prove a new window")
    var stale = before; stale.capturedAt = clock.addingTimeInterval(-61)
    check(PingConfirmation.accepts(before: stale, after: after, now: clock) && !PingConfirmation.newWindow(before: stale, after: after, now: clock, submittedAt: clock),
        "old before evidence can confirm an effective window without claiming it was newly opened")
    before.zeroUseWindowActive = true
    check(PingConfirmation.accepts(before: before, after: after, now: clock) && !PingConfirmation.newWindow(before: before, after: after, now: clock),
        "completion with an already effective window is valid without a new-window claim")
    before.fiveHour?.usedPercent = 100
    let exhausted = DecisionEngine(schedule: schedule).decide(now: clock, enabled: true, autoResume: false, earlyRecoveryPolicy: "ask", usage: before, blocked: [])
    if case .wait = exhausted { check(true, "fresh known exhaustion waits inside the fixed opportunity") }
    else { check(false, "fresh known exhaustion waits inside the fixed opportunity") }
    let transport = PreparationGatePing(clock: { clock })
    let ledger = root.appendingPathComponent("support/resume-attempts.json")
    var coordinator: ExecutionCoordinator? = ExecutionCoordinator(provider: SimplificationUsage(clock: clock, unknown: true), defaults: defaults,
        ledgerURL: ledger, pingTransport: transport, codexHome: root, now: { clock })
    var wrongAccount = before; wrongAccount.accountID = "old-failed-reading-account"
    coordinator!.ping(schedule: schedule, usage: wrongAccount, blockers: { [] })
    for _ in 0..<100 where coordinator!.running { try await Task.sleep(nanoseconds: 10_000_000) }
    check(transport.count == 1 && coordinator!.lastPingResult?.outcome == .windowActive && coordinator!.lastFailure == nil,
        "unknown quota binds current authentication and records completed effective window rather than newly opened")
    coordinator = nil
    coordinator = ExecutionCoordinator(provider: SimplificationUsage(clock: clock, unknown: true), defaults: defaults,
        ledgerURL: ledger, pingTransport: transport, codexHome: root, now: { clock })
    coordinator!.ping(schedule: schedule, blockers: { [] })
    check(transport.count == 1 && coordinator!.hasAttemptedKeepAlive(node: schedule.nodes()[1], accountID: "facts-account"),
        "restart preserves account/original-node deduplication despite unavailable quota")
    try writeKeepAliveAuthentication(home: root, account: "second-account")
    coordinator!.ping(schedule: schedule, blockers: { [] })
    for _ in 0..<100 where coordinator!.running { try await Task.sleep(nanoseconds: 10_000_000) }
    check(transport.count == 2 && coordinator!.lastPingResult?.accountID == "second-account", "a real current account switch has its own protected original-node intent")
    coordinator = nil

    let interruptedRoot = root.appendingPathComponent("interrupted")
    try FileManager.default.createDirectory(at: interruptedRoot, withIntermediateDirectories: true)
    let key = "ping:second-account:\(schedule.nodes()[1].timeIntervalSince1970)"
    try JSONEncoder().encode([key]).write(to: interruptedRoot.appendingPathComponent("attempts.json"))
    let result = PingNodeResult(node: schedule.nodes()[1], accountID: "second-account", at: clock, outcome: .submitted)
    try ExecutionEventLog(url: interruptedRoot.appendingPathComponent("execution-events.jsonl")).record("started", kind: "ping", node: result.node, pingResult: result)
    let restored = ExecutionCoordinator(provider: SimplificationUsage(clock: clock, unknown: true), defaults: defaults,
        ledgerURL: interruptedRoot.appendingPathComponent("attempts.json"), pingTransport: transport, codexHome: root, now: { clock })
    restored.ping(schedule: schedule, blockers: { [] })
    check(restored.lastPingResult?.outcome == .unknown && restored.visibleNotice != nil && restored.visibleFailure == nil && transport.count == 2,
        "restart after submitted without a terminal result shows unknown and never resends")
    clock = schedule.nodes()[2]
    restored.observeKeepAlive(schedule: schedule, accountID: "second-account", usage: nil, reason: "fixture scan failure")
    clock = clock.addingTimeInterval(601)
    restored.observeKeepAlive(schedule: schedule, accountID: "second-account", usage: after, reason: nil)
    check(restored.lastPingResult?.outcome == .notExecuted && restored.lastPingResult?.detail == "fixture scan failure" && restored.visibleNotice != nil,
        "read recovery after a missed fixed opportunity retains the actual nonexecution reason")
    let log = root.appendingPathComponent("display-events.jsonl")
    let fact = PingNodeResult(node: schedule.nodes()[1], accountID: "facts-account", at: after.capturedAt, outcome: .windowActive)
    try ExecutionEventLog(url: log).record("confirmed", kind: "ping", node: fact.node, before: before, after: after, pingResult: fact)
    check(ExecutionEventLog(url: log).confirmations().first?.windowStart == nil, "an already effective window history never fabricates a new start")
    var menu = MenuSummary()
    menu.applyPingHistory([fact], accountID: "facts-account", now: after.capturedAt)
    check(menu.timeline.first?.pingResult?.outcome == .windowActive && menu.timeline.first?.label == fact.historyLabel,
        "menu history uses the same canonical result fact as execution events and notification text")
    for outcome: PingOutcome in [.newWindow, .windowActive, .windowPending] {
        let result = PingNodeResult(node: fact.node, accountID: fact.accountID, at: fact.at, outcome: outcome)
        var history = MenuSummary()
        history.applyPingHistory([result], accountID: fact.accountID, now: fact.at)
        check(history.timeline.first?.label == "已保活" && history.timeline.first?.isHistory == true &&
            history.timeline.first?.pingResult?.message == result.message && result.message != L10n.text("已保活"),
            "keepalive history has a compact label and retains the distinct \(outcome.rawValue) result for details")
    }
    let skippedHistory = PingNodeResult(node: fact.node, accountID: fact.accountID, at: fact.at, outcome: .skipped)
    var skippedMenu = MenuSummary()
    skippedMenu.applyPingHistory([skippedHistory], accountID: fact.accountID, now: fact.at)
    check(skippedMenu.timeline.first?.label == "无需保活" && skippedMenu.timeline.first?.pingResult?.message == L10n.text("已有有效 5 小时窗口"),
        "an existing active window skips sending and displays no keepalive needed with its reason in details")
    for kind: MenuTimelinePoint.Kind in [.completedKeepAlive, .completedResume] {
        let point = MenuTimelinePoint(date: fact.at, time: "13:00", day: "", label: "", kind: kind, solidBefore: false)
        check(point.symbol == "checkmark.circle.fill" && !point.isAction,
            "completed \(kind) history uses the same secondary-colored checkmark")
    }
    for outcome: PingOutcome in [.submitted, .failed, .unknown, .notExecuted] {
        let result = PingNodeResult(node: fact.node, accountID: fact.accountID, at: fact.at, outcome: outcome)
        check(result.historyLabel != "已保活" && !result.succeeded,
            "unconfirmed or unsuccessful \(outcome.rawValue) keeps its actual status")
    }
    let future = schedule.nodes()[3]
    menu.timeline = [MenuTimelinePoint(date: schedule.nodes()[0], time: "08:00", day: "", label: "已保活", kind: .completedKeepAlive, solidBefore: false),
        MenuTimelinePoint(date: schedule.nodes()[1], time: "13:00", day: "", label: "已保活", kind: .completedKeepAlive, solidBefore: false),
        MenuTimelinePoint(date: schedule.nodes()[2], time: "18:00", day: "", label: "重置", kind: .reset, solidBefore: false),
        MenuTimelinePoint(date: future, time: "23:00", day: "", label: "保活", kind: .keepAlive, solidBefore: false)]
    let many = schedule.nodes().prefix(3).map { PingNodeResult(node: $0, accountID: "facts-account", at: $0, outcome: .windowActive) }
    menu.applyPingHistory(many, accountID: "facts-account", now: schedule.nodes()[2].addingTimeInterval(30))
    check(menu.timeline.count == 4 && menu.timeline.contains { $0.date == future && $0.kind == .keepAlive } &&
        menu.timeline.filter { $0.pingResult != nil }.count == 2,
        "canonical ping facts replace represented history without exceeding four timeline nodes or removing the next action")
    let observedAt = schedule.nodes()[2].addingTimeInterval(30)
    let observed = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 2, windowMinutes: 300, resetsAt: schedule.nodes()[2].addingTimeInterval(18000)),
        weekly: nil, capturedAt: observedAt, accountID: "facts-account", sourceFile: "app-server")
    let pendingFact = PingNodeResult(node: schedule.nodes()[2], accountID: "facts-account", at: observedAt, outcome: .windowPending)
    var observedPresenter = MenuPresentation()
    var observedMenu = observedPresenter.build(plan: NextAction(mode: .keepAlive, date: future, decision: .wait(reason: "等待下一可行计划节点"), note: ""),
        usage: observed, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(), now: observedAt)
    observedMenu.applyPingHistory([pendingFact], accountID: observed.accountID, now: observedAt)
    check(observedMenu.timeline.filter { abs($0.date.timeIntervalSince(pendingFact.node)) <= ScheduleEngine.alignmentTolerance }.count == 1 &&
        observedMenu.timeline.first?.pingResult?.outcome == .windowPending && observedMenu.timeline.count <= 4 &&
        observedMenu.timeline.contains { $0.date == future && $0.kind == .keepAlive },
        "a canonical pending result merges the same-node neutral window origin without a confirmation or an invented new window")
    let pendingLedger = root.appendingPathComponent("neutral/attempts.json")
    let pendingTransport = PendingResultPing()
    let pendingCoordinator = ExecutionCoordinator(provider: SimplificationUsage(clock: clock, unknown: true), defaults: defaults,
        ledgerURL: pendingLedger, pingTransport: pendingTransport, codexHome: root, now: { clock })
    // Return to a live opportunity after checking the prior missed result.
    clock = schedule.nodes()[3].addingTimeInterval(10)
    pendingCoordinator.ping(schedule: schedule, blockers: { [] })
    for _ in 0..<100 where pendingCoordinator.running { try await Task.sleep(nanoseconds: 10_000_000) }
    var presenter = MenuPresentation()
    let plan = DecisionEngine(schedule: schedule).plan(now: clock, enabled: true, autoResume: false, earlyRecoveryPolicy: "ask", usage: nil, blocked: [])
    let neutral = presenter.build(plan: plan, usage: nil, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(),
        executionFailure: pendingCoordinator.visibleFailure, executionNotice: pendingCoordinator.visibleNotice, now: clock)
    check(pendingCoordinator.lastPingResult?.outcome == .windowPending && pendingCoordinator.visibleFailure == nil &&
        neutral.note.contains(L10n.text("保活请求已完成，窗口待确认。")) && !neutral.note.contains("失败"),
        "production coordinator and presenter retain completed-pending as a neutral result without a failure prefix")
    pendingCoordinator.acknowledgePingResult()
    check(pendingCoordinator.visibleNotice == nil && pendingCoordinator.lastPingResult?.acknowledgedAt != nil &&
        ExecutionEventLog(url: pendingLedger.deletingLastPathComponent().appendingPathComponent("execution-events.jsonl")).pingResults().last?.outcome == .windowPending,
        "viewing a result clears its current alert while its execution fact remains in durable history")
    var quotaPresenter = MenuPresentation()
    var live = after; live.capturedAt = clock; live.fiveHour?.resetsAt = clock.addingTimeInterval(3600)
    let livePlan = DecisionEngine(schedule: schedule).plan(now: clock, enabled: true, autoResume: false, earlyRecoveryPolicy: "ask", usage: live, blocked: [])
    let shown = quotaPresenter.build(plan: livePlan, usage: live, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(), now: clock)
    let differentPlan = NextAction(mode: .keepAlive, date: clock.addingTimeInterval(7200), decision: .wait(reason: "等待下一可行计划节点"), note: "")
    let retained = quotaPresenter.build(plan: differentPlan, usage: nil, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(),
        usageError: "fixture offline", usageErrorIsTransient: true, now: clock.addingTimeInterval(61))
    check(retained.quotas.map(\.remaining) == shown.quotas.map(\.remaining) && retained.refreshMessage == shown.refreshMessage && retained.isTime,
        "fixed plan changes preserve the last real quota facts and their original sampling time independently")
    let changed = quotaPresenter.build(plan: differentPlan, usage: nil, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(),
        accountContext: "different-current-authentication", now: clock.addingTimeInterval(62))
    check(changed.isTime && changed.quotas.isEmpty && changed.quotaAccountID != live.accountID,
        "current local authentication changes clear old quota display before a new RPC reading exists")
}

private final class PreparationUsage: UsageProvider {
    var models = 0
    var invalidations = 0
    func read() throws -> UsageSnapshot { throw CodexConnectionError.timeout }
    func pingModel() throws -> PingModel { models += 1; return PingModel(model: "gpt-6-luna", reasoningEffort: "low") }
    func invalidatePingModel() { invalidations += 1 }
}

private func checkKeepAlivePreparation(_ root: URL, _ check: (Bool, String) -> Void) throws {
    let auth = root.appendingPathComponent("auth")
    try writeKeepAliveAuthentication(home: auth, account: "cache-account")
    let binary = root.appendingPathComponent("fake-codex")
    let alternate = root.appendingPathComponent("alternate-codex")
    for file in [binary, alternate] {
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    var clock: TimeInterval = 0
    var locations = 0
    var preferred = binary
    let provider = PreparationUsage()
    let cache = PingPreparation(mainHome: auth, root: root.appendingPathComponent("isolated"), locate: { locations += 1; return preferred }, uptime: { clock })
    cache.maintain(provider: provider)
    let config = cache.home.appendingPathComponent("config.toml")
    let initial = try config.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    clock = 299; cache.maintain(provider: provider)
    clock = 300; cache.maintain(provider: provider)
    check(locations == 1 && provider.models == 1 && provider.invalidations == 1,
        "five-minute unchanged metadata checks launch no CLI, network discovery or new locator scan")
    check(try config.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == initial,
        "unchanged preparation does not rewrite the isolated configuration")
    try writeKeepAliveAuthentication(home: auth, account: "cache-account", token: "rotated-token")
    clock = 600; cache.maintain(provider: provider)
    check(provider.models == 1 && locations == 1, "ordinary token refresh preserves capabilities for the same stable account")
    try writeKeepAliveAuthentication(home: auth, account: "new-cache-account")
    clock = 900; cache.maintain(provider: provider)
    check(provider.models == 2, "real account change invalidates and discovers model capabilities in the background")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: binary.path)
    clock = 1200; cache.maintain(provider: provider)
    check(provider.models == 3 && locations == 2, "CLI file/version metadata change relocates and refreshes capability evidence")
    cache.invalidate(); cache.maintain(provider: provider)
    check(provider.models == 4, "an actual model error can invalidate and requery background capabilities")
    preferred = alternate; cache.invalidate(relocate: true); cache.maintain(provider: provider, forceCheck: true)
    check(try cache.prepareForSend() == alternate, "explicit fallback-path changes relocate even while the previous executable still exists")
    try FileManager.default.removeItem(at: config)
    _ = try cache.prepareForSend()
    check(FileManager.default.fileExists(atPath: config.path), "missing isolated config is rebuilt before submission without querying a model")
    let client = CapabilityCacheTransport()
    var identity = Data("token-a".utf8)
    var account = "account-a"
    var uptime: TimeInterval = 0
    let shared = AppServerUsageProvider(makeTransport: { client }, contextIdentity: { identity }, accountIdentity: { account }, uptime: { uptime })
    _ = try shared.pingModel()
    identity = Data("refreshed-token-a".utf8)
    _ = try shared.read(); _ = try shared.pingModel()
    check(client.models == 1, "quota connection renewal for the same stable account preserves its discovered model capability")
    client.readFailure = .ended
    _ = try? shared.read()
    uptime = 21; identity = Data("token-b".utf8); account = "account-b"
    client.account = account; client.readFailure = nil; client.effort = "medium"
    _ = try shared.read()
    let newModel = try shared.pingModel()
    check(client.models == 2 && newModel.reasoningEffort == "medium",
        "new quota transport identity cannot make old-account model capabilities look current after a fatal connection error")
}

@MainActor private func checkIsolatedPingCompletion(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    let auth = root.appendingPathComponent("auth")
    try writeKeepAliveAuthentication(home: auth, account: "pty-account")
    let binary = root.appendingPathComponent("fake-tui")
    let thread = UUID().uuidString; let turn = UUID().uuidString
    let script = """
    #!/usr/bin/python3
    import os,pathlib,json,time
    home=pathlib.Path(os.environ['CODEX_HOME'])
    directory=home/'sessions'; directory.mkdir(exist_ok=True)
    rows=[{'type':'session_meta','payload':{'id':'\(thread)'}},{'payload':{'type':'task_started','turn_id':'\(turn)'}},{'payload':{'role':'assistant','content':[{'text':'OK'}]}},{'payload':{'type':'task_complete','turn_id':'\(turn)'}}]
    (directory/'rollout-test.jsonl').write_text(chr(10).join(json.dumps(x) for x in rows))
    (home/'launch-count').open('a').write('1')
    time.sleep(5)
    """
    try script.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let isolated = root.appendingPathComponent("isolated")
    let home = isolated.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    for name in ["state_5.sqlite", "logs_1.sqlite"] { try Data("invalid sqlite fixture".utf8).write(to: home.appendingPathComponent(name)) }
    let before = UsageSnapshot(fiveHour: nil, weekly: nil, capturedAt: .distantPast, accountID: "pty-account", sourceFile: "")
    var reads = 0
    let provider = IsolatedConfirmationUsage {
        reads += 1
        if reads == 1 {
            try Data([0xff]).write(to: home.appendingPathComponent("sessions/rollout-test.jsonl"))
            throw CodexConnectionError.timeout
        }
        let now = Date()
        return UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 1, windowMinutes: 300, resetsAt: now.addingTimeInterval(18000)),
            weekly: nil, capturedAt: now, accountID: "pty-account", sourceFile: "app-server")
    }
    let timing = PingTiming(warning: 0.1, timeout: 0.8, pollInterval: 0.03)
    let transport = PTYPingTransport(codexHome: auth, supportRoot: isolated, binary: binary, timing: timing)
    try transport.prepareForSend()
    let result = try transport.perform(before: before, model: transport.preparedModel, provider: provider, progress: { _ in })
    check(result.diagnostic.taskCompleted && result.diagnostic.windowConfirmed && reads == 2,
        "isolated completion survives a quota retry without reparsing its now-unreadable completed rollout")
    check(!FileManager.default.fileExists(atPath: home.appendingPathComponent("state_5.sqlite-wal").path) &&
        !FileManager.default.fileExists(atPath: home.appendingPathComponent("logs_1.sqlite-wal").path),
        "invalid diagnostic databases do not affect this ping or acquire auxiliary files")
    let pendingRoot = root.appendingPathComponent("pending")
    let pendingTransport = PTYPingTransport(codexHome: auth, supportRoot: pendingRoot, binary: binary, timing: timing)
    try pendingTransport.prepareForSend()
    var warnings: [PingDiagnostic] = []
    let pending = try pendingTransport.perform(before: before, model: pendingTransport.preparedModel,
        provider: IsolatedConfirmationUsage { throw CodexConnectionError.timeout }, progress: { warnings.append($0) })
    check(pending.after == nil && pending.diagnostic.taskCompleted && pending.diagnostic.outcome == "completed_pending" &&
        pending.diagnostic.elapsedSeconds >= timing.timeout && warnings.contains(where: { $0.elapsedSeconds >= timing.warning && $0.outcome == "waiting" }),
        "completed request with persistent quota failure keeps warning/confirmation deadlines and ends as completed pending")
    let canceledRoot = root.appendingPathComponent("cancelled")
    let canceled = PTYPingTransport(codexHome: auth, supportRoot: canceledRoot, binary: binary, timing: timing)
    try canceled.prepareForSend(); canceled.cancel()
    do {
        _ = try canceled.perform(before: before, model: canceled.preparedModel, provider: provider, progress: { _ in })
        check(false, "cancellation between durable intent and process launch cannot be reset by perform")
    } catch let failure as PingSubmissionError {
        check((failure.underlying as? PingFailure)?.diagnostic.reason == .cancelled &&
            !FileManager.default.fileExists(atPath: canceledRoot.appendingPathComponent("home/launch-count").path),
            "cancellation between durable intent and process launch cannot be reset by perform")
    }
    let invalidTransport = PTYPingTransport(codexHome: auth, supportRoot: root.appendingPathComponent("invalid-read"), binary: binary, timing: timing)
    try invalidTransport.prepareForSend()
    let invalid = try invalidTransport.perform(before: before, model: invalidTransport.preparedModel,
        provider: IsolatedConfirmationUsage { throw CodexConnectionError.invalidResponse }, progress: { _ in })
    check(invalid.after == nil && invalid.diagnostic.taskCompleted && invalid.diagnostic.outcome == "completed_pending" &&
        invalid.diagnostic.reason == .quotaRead && invalid.diagnostic.quotaReadFailure?.reason == "invalid_response" && invalid.diagnostic.elapsedSeconds < timing.timeout,
        "nonretryable quota decoding failure preserves a completed request and reports pending window immediately")
}

private struct IsolatedConfirmationUsage: UsageProvider {
    let readValue: () throws -> UsageSnapshot
    init(_ read: @escaping () throws -> UsageSnapshot) { readValue = read }
    func read() throws -> UsageSnapshot { try readValue() }
}

private struct PendingResultPing: PingTransport {
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider) throws -> UsageSnapshot { throw CodexConnectionError.invalidResponse }
    func perform(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void) throws -> PingResult {
        PingResult(after: nil, diagnostic: PingDiagnostic(elapsedSeconds: 180, warningSeconds: 90, timeoutSeconds: 180,
            reason: .quotaRead, taskCompleted: true, outcome: "completed_pending"))
    }
    func cancel() {}
}

private final class CapabilityCacheTransport: CodexTransport {
    var account = "account-a"
    var effort = "low"
    var models = 0
    var readFailure: CodexConnectionError?
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        if method == "account/read" { return ["account": ["type": "chatgpt"]] }
        if method == "model/list" {
            models += 1
            return ["data": [["model": "gpt-6-luna", "supportedReasoningEfforts": [["reasoningEffort": effort]], "defaultReasoningEffort": effort]]]
        }
        if let readFailure { throw readFailure }
        return ["accountId": account, "rateLimits": ["primary": ["usedPercent": 1, "windowDurationMins": 300,
            "resetsAt": Date().addingTimeInterval(18000).timeIntervalSince1970]]]
    }
    func nextMessage(timeout: TimeInterval) throws -> [String: Any] { throw CodexConnectionError.timeout }
    func close() {}
}
