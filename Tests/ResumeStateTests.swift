import Foundation
import Combine
import SQLite3

@MainActor func checkResumeStateRegression(_ check: (Bool, String) -> Void) async throws {
    func row(_ type: String, _ payload: [String: Any], at: Date = Date()) throws -> Data {
        var body = payload; body["type"] = type
        var data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: at), "payload": body])
        data.append(10)
        return data
    }
    var monitor = ResumeTurnMonitor(turnID: "target")
    check(try !monitor.consume(row("task_started", ["turn_id": "target"])), "start acknowledgement is not model response")
    check(try !monitor.consume(row("user_message", ["turn_id": "target", "message": "Continue"])), "user input is not model response")
    check(try !monitor.consume(row("agent_reasoning", ["turn_id": "target", "text": ""])), "empty reasoning is not model response")
    check(try !monitor.consume(row("agent_message", ["turn_id": "other", "message": "output"])), "another turn cannot confirm startup")
    check(try monitor.consume(row("agent_message", ["turn_id": "target", "message": "output"])), "first real model output confirms startup before task completes")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-resume-state-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString
    let file = root.appendingPathComponent("rollout-\(id).jsonl")
    var trace = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "cwd": root.path]])
    trace.append(10)
    trace.append(try row("task_started", ["turn_id": "target"]))
    trace.append(try row("error", ["turn_id": "target", "message": "usage_limit_reached", "will_retry": true]))
    try trace.write(to: file)
    let activity = SessionWatcher.parse(url: file, mtime: Date())!
    check(activity.taskRunning && BlockedSessionDetector.detect(in: [activity]).isEmpty,
        "retrying quota error retains running state and cannot create a pause")
    let target = BlockedSession(id: id, project: "Test", cwd: root.path, blockedAt: Date().addingTimeInterval(-5), fiveHourResetAt: nil, weeklyResetAt: nil, fileURL: file)
    try await checkRolloutReplacement(root.appendingPathComponent("rollout-replacement"), check)
    try await checkResumeEvidenceAudit(root.appendingPathComponent("evidence-audit"), check)
    try await checkResumeEvidenceBoundaries(root.appendingPathComponent("evidence-boundaries"), check)
    try await checkResumePreflightAudit(root.appendingPathComponent("preflight-audit"), check)
    try await checkPreparationFailureStages(root.appendingPathComponent("preparation-stages"), check)
    try await checkResumeAppBlockers(root.appendingPathComponent("resume-app-blockers"), check)
    try checkActionableMessageBoundaries(target, check)
    checkConfirmationPresentation(target, check)
    try await checkResumeTransportLifecycle(target, check)
    try await checkResumeCoordinator(root.appendingPathComponent("coordinator"), check)
    try await checkResumePingAdmission(root.appendingPathComponent("ping-admission"), check)
    try await checkResumeSelectionKeepAlive(root.appendingPathComponent("selection-keepalive"), check)
    try await checkPingPreflightDiagnostics(root.appendingPathComponent("ping-preflight"), check)
    try await checkResumePresentationPreflight(root.appendingPathComponent("presentation-preflight"), check)
    try await checkResumeRecoveryAdmission(root.appendingPathComponent("recovery-admission"), check)
    try await checkResumeIdentitySynchronization(root.appendingPathComponent("identity-sync"), check)
    try await checkResumeCurrentPauseRows(root.appendingPathComponent("current-pause"), check)
    try await checkResumeQuotaTerminalEvidence(root.appendingPathComponent("quota-terminal"), check)
    try await checkResumeIgnoredEpisodes(root.appendingPathComponent("ignored"), check)
    try await checkResumeManualReadAndRestart(root.appendingPathComponent("manual"), check)
}

private final class ResumeTestUsage: UsageProvider {
    private let lock = NSLock()
    var account = "resume-state-account"
    private var readBody: (() -> Void)?
    func read() throws -> UsageSnapshot {
        lock.lock(); let account = account; let body = readBody; lock.unlock()
        body?()
        return UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: Date().addingTimeInterval(3600)), weekly: nil,
            capturedAt: Date(), accountID: account, sourceFile: "app-server", zeroUseWindowActive: true)
    }
    func setAccount(_ value: String) { lock.lock(); account = value; lock.unlock() }
    func onRead(_ body: @escaping () -> Void) { lock.lock(); readBody = body; lock.unlock() }
}

private final class ResumeTestClient: CodexTransport {
    let threadID: String
    let cwd: String
    let turnID: String
    var startError: Error?
    var lastSubmissionRequestID: Int? { 2 }
    var completeOnInterrupt = true
    private let condition = NSCondition()
    private var messages: [[String: Any]] = []
    private var methods: [String] = []
    private var closedValue = false
    private var consumed = 0
    private var readers = 0
    private var peakReaders = 0
    init(_ target: BlockedSession) { threadID = target.id; cwd = target.cwd; turnID = "turn-" + target.id }
    var closed: Bool { condition.lock(); defer { condition.unlock() }; return closedValue }
    var readCount: Int { condition.lock(); defer { condition.unlock() }; return consumed }
    var maxReaders: Int { condition.lock(); defer { condition.unlock() }; return peakReaders }
    func count(_ method: String) -> Int { condition.lock(); defer { condition.unlock() }; return methods.filter { $0 == method }.count }
    func send(_ method: String, turn: String? = nil, thread: String? = nil, extras: [String: Any] = [:], requestID: Int? = nil) {
        var params = extras; params["threadId"] = thread ?? threadID; params["turnId"] = turn ?? turnID
        var message: [String: Any] = ["method": method, "params": params]
        if let requestID { message["id"] = requestID }
        enqueue(message)
    }
    func enqueue(_ message: [String: Any]) { condition.lock(); messages.append(message); condition.broadcast(); condition.unlock() }
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        condition.lock(); methods.append(method); condition.unlock()
        if method == "thread/resume" { return ["thread": ["id": threadID, "status": ["type": "idle"]], "cwd": cwd] }
        if method == "turn/start", let startError { throw startError }
        if method == "turn/interrupt", completeOnInterrupt { send("turn/completed", extras: ["turn": ["id": turnID, "status": "interrupted"]]) }
        return ["turn": ["id": turnID]]
    }
    func nextMessage(timeout: TimeInterval) throws -> [String: Any] {
        condition.lock(); readers += 1; peakReaders = max(peakReaders, readers)
        defer { readers -= 1; condition.unlock() }
        let until = Date().addingTimeInterval(timeout)
        while messages.isEmpty && !closedValue {
            if !condition.wait(until: until) { throw CodexConnectionError.timeout }
        }
        guard !closedValue else { throw CodexConnectionError.ended }
        consumed += 1
        return messages.removeFirst()
    }
    func close() { condition.lock(); closedValue = true; condition.broadcast(); condition.unlock() }
}

private final class ResumeTestEvents {
    private let lock = NSLock()
    private var receivedValue = 0
    private var respondedValue = 0
    private var awaitingValue = 0
    private var terminalValue: ResumeTerminal?
    func consume(_ event: ResumeTransportEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .received: receivedValue += 1
        case .responded: respondedValue += 1
        case .awaiting, .unknown: awaitingValue += 1
        case .ended(_, let terminal, _, _): terminalValue = terminal
        default: break
        }
    }
    var received: Int { lock.lock(); defer { lock.unlock() }; return receivedValue }
    var responded: Int { lock.lock(); defer { lock.unlock() }; return respondedValue }
    var awaiting: Int { lock.lock(); defer { lock.unlock() }; return awaitingValue }
    var terminal: ResumeTerminal? { lock.lock(); defer { lock.unlock() }; return terminalValue }
}

private final class ResumeTestTransport: ResumeTransport {
    var prepareBody: (BlockedSession) throws -> Void = { _ in }
    var submitBody: (BlockedSession) throws -> Void = { _ in }
    private let lock = NSLock()
    private var callback: ((ResumeTransportEvent) -> Void)?
    private var target: BlockedSession?
    private var owns = false
    private var stoppedValue = false
    private var preparedValue = false
    private var submittedValue = false
    private var promptValue: String?
    var ownsSubmittedTask: Bool { lock.lock(); defer { lock.unlock() }; return owns }
    var prepared: Bool { lock.lock(); defer { lock.unlock() }; return preparedValue }
    var submitted: Bool { lock.lock(); defer { lock.unlock() }; return submittedValue }
    var prompt: String? { lock.lock(); defer { lock.unlock() }; return promptValue }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stoppedValue }
    func prepare(_ target: BlockedSession) throws {
        lock.lock(); preparedValue = true; self.target = target; lock.unlock()
        try prepareBody(target)
    }
    func submit(_ target: BlockedSession, prompt: String, update: @escaping (ResumeTransportEvent) -> Void) throws {
        try submitBody(target)
        lock.lock(); callback = update; self.target = target; owns = true; submittedValue = true; promptValue = prompt; lock.unlock()
        update(.received(ResumeReceipt(threadID: target.id, turnID: "turn-" + target.id, message: "received"), Date()))
    }
    func event(_ event: ResumeTransportEvent) { lock.lock(); let callback = callback; lock.unlock(); callback?(event) }
    func respond() { lock.lock(); let target = target; lock.unlock(); if let target { event(.responded("turn-" + target.id, Date())) } }
    func finish(_ terminal: ResumeTerminal = .completed) {
        lock.lock(); let target = target; owns = false; lock.unlock()
        if let target { event(.ended("turn-" + target.id, terminal, nil, Date())) }
    }
    func cancel() { lock.lock(); stoppedValue = true; owns = false; lock.unlock() }
}

@MainActor private func resumeWait(_ predicate: () -> Bool) async throws {
    for _ in 0..<300 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
}

@MainActor private func checkResumeTransportLifecycle(_ target: BlockedSession, _ check: (Bool, String) -> Void) async throws {
    let client = ResumeTestClient(target)
    let transport = AppServerResumeTransport(makeTransport: { client }, observationSeconds: 0.05)
    let events = ResumeTestEvents()
    try transport.prepare(target)
    check(client.count("turn/start") == 0, "preparation restores metadata without submitting content")
    try transport.submit(target, prompt: "fake input only", update: events.consume)
    check(events.received == 1 && transport.ownsSubmittedTask && !client.closed, "receipt persists while independent task carrier remains alive")
    client.send("item/agentMessage/delta", turn: "other", extras: ["delta": "other output"])
    client.send("item/reasoning/summaryTextDelta", extras: ["delta": ""])
    client.send("item/started", extras: ["item": ["type": "commandExecution", "status": "inProgress"]])
    try await resumeWait { events.awaiting > 0 }
    check(events.responded == 0 && !client.closed && transport.ownsSubmittedTask,
        "startup deadline releases observation without confirming placeholders or closing carrier")
    client.send("item/agentMessage/delta", extras: ["delta": "real output"])
    try await resumeWait { events.responded == 1 }
    check(events.responded == 1 && !client.closed, "late first response confirms startup while long task continues")
    for _ in 0..<600 { client.send("item/agentMessage/delta", extras: ["delta": "more output"]) }
    client.send("error", extras: ["willRetry": true, "error": ["message": "usage_limit_reached"]])
    try await resumeWait { client.readCount >= 605 }
    check(!client.closed && events.terminal == nil && events.responded == 1 && client.maxReaders == 1,
        "one continuous consumer drains large output and keeps willRetry carrier running")
    client.send("turn/completed", extras: ["turn": ["id": client.turnID, "status": "completed"]])
    try await resumeWait { events.terminal != nil }
    check(client.closed && !transport.ownsSubmittedTask && events.terminal == .completed, "real terminal releases independent writer")

    let unknownClient = ResumeTestClient(target)
    unknownClient.startError = ResumeSubmissionError(mayHaveSubmitted: true, underlying: CodexConnectionError.timeout)
    let unknown = AppServerResumeTransport(makeTransport: { unknownClient }, observationSeconds: 0.05)
    let unknownEvents = ResumeTestEvents(); try unknown.prepare(target)
    try unknown.submit(target, prompt: "fake input only", update: unknownEvents.consume)
    check(unknown.ownsSubmittedTask && !unknownClient.closed && unknownEvents.awaiting > 0,
        "unknown content submission keeps carrier instead of defer-close or fallback")
    unknownClient.enqueue(["id": 90, "result": ["turn": ["id": "another-rpc-turn"]]])
    unknownClient.send("turn/started", turn: "manual-new-turn", extras: ["turn": ["id": "manual-new-turn"]])
    unknownClient.send("item/agentMessage/delta", turn: "manual-new-turn", extras: ["delta": "manual output"])
    try await resumeWait { unknownClient.readCount >= 3 }
    check(unknownEvents.received == 0 && unknownEvents.responded == 0 && !unknownClient.closed,
        "unknown start cannot claim another RPC receipt or a manually started same-thread turn")
    unknownClient.enqueue(["id": 2, "result": ["turn": ["id": unknownClient.turnID]]])
    unknownClient.send("item/reasoning/textDelta", extras: ["delta": "nonempty"])
    try await resumeWait { unknownEvents.responded == 1 }
    check(unknownEvents.received == 1 && unknownEvents.responded == 1, "late content receipt and real reasoning recover unknown submission once")
    unknownClient.send("turn/completed", extras: ["turn": ["id": unknownClient.turnID, "status": "completed"]])
    try await resumeWait { unknownClient.closed }

    let reorderedClient = ResumeTestClient(target)
    reorderedClient.startError = ResumeSubmissionError(mayHaveSubmitted: true, underlying: CodexConnectionError.timeout)
    let reordered = AppServerResumeTransport(makeTransport: { reorderedClient }, observationSeconds: 0.05)
    let reorderedEvents = ResumeTestEvents(); try reordered.prepare(target)
    try reordered.submit(target, prompt: "fake input only", update: reorderedEvents.consume)
    reorderedClient.send("item/agentMessage/delta", turn: "manual-turn", extras: ["delta": "unrelated"])
    reorderedClient.send("turn/completed", turn: "manual-turn", extras: ["turn": ["id": "manual-turn", "status": "completed"]])
    reorderedClient.send("item/agentMessage/delta", extras: ["delta": "actual target output"])
    reorderedClient.send("turn/completed", extras: ["turn": ["id": reorderedClient.turnID, "status": "completed"]])
    try await resumeWait { reorderedClient.readCount == 4 }
    check(reorderedEvents.received == 0 && reorderedEvents.responded == 0 && !reorderedClient.closed,
        "queued target response and terminal remain unclaimed until the original start RPC receipt arrives")
    reorderedClient.enqueue(["id": 2, "result": ["turn": ["id": reorderedClient.turnID]]])
    try await resumeWait { reorderedClient.closed }
    check(reorderedEvents.received == 1 && reorderedEvents.responded == 1 && reorderedEvents.terminal == .completed,
        "matching late receipt replays only its buffered target response and terminal without losing early events")

    let elicitationClient = ResumeTestClient(target)
    let elicitation = AppServerResumeTransport(makeTransport: { elicitationClient })
    let elicitationEvents = ResumeTestEvents(); try elicitation.prepare(target)
    try elicitation.submit(target, prompt: "test only", update: elicitationEvents.consume)
    elicitationClient.send("mcpServer/elicitation/request", turn: "other", requestID: 10)
    elicitationClient.send("mcpServer/elicitation/request", requestID: 11)
    try await resumeWait { elicitationEvents.terminal != nil }
    check(elicitationEvents.terminal == .manualRequired && elicitationClient.count("turn/interrupt") == 1 && elicitationEvents.responded == 0,
        "MCP elicitation handles only its exact target turn and waits for real stopped evidence")

    let rejectedClient = ResumeTestClient(target)
    rejectedClient.startError = ResumeSubmissionError(mayHaveSubmitted: false, underlying: CodexConnectionError.ended)
    let rejected = AppServerResumeTransport(makeTransport: { rejectedClient })
    try rejected.prepare(target)
    do { try rejected.submit(target, prompt: "fake input only", update: { _ in }); check(false, "unwritten content request reports retryable refusal") }
    catch { check((error as? ResumeSubmissionError)?.mayHaveSubmitted == false && rejectedClient.closed, "zero-write refusal releases unsent carrier") }

    let manualClient = ResumeTestClient(target)
    let manual = AppServerResumeTransport(makeTransport: { manualClient }, observationSeconds: 0.05)
    let manualEvents = ResumeTestEvents(); try manual.prepare(target)
    try manual.submit(target, prompt: "fake input only", update: manualEvents.consume)
    manualClient.send("item/commandExecution/requestApproval", thread: "other-thread", requestID: 1)
    manualClient.send("item/tool/call", requestID: 2)
    manualClient.send("serverRequest/resolved", extras: ["requestId": 2])
    manualClient.send("item/started", extras: ["item": ["type": "commandExecution", "status": "inProgress"]])
    try await resumeWait { manualClient.readCount >= 4 }
    check(manualClient.count("turn/interrupt") == 0 && manualEvents.responded == 0,
        "unrelated request, dynamic tool call, resolution and command placeholder cannot prove response or approval")
    manualClient.send("item/commandExecution/requestApproval", requestID: 3)
    try await resumeWait { manualEvents.terminal != nil }
    check(manualEvents.terminal == .manualRequired && manualEvents.responded == 0 && manualClient.count("turn/interrupt") == 1,
        "target manual request requires real interruption terminal and never falsely confirms startup")
    check(!ResumeModelActivity.appServer(method: "item/started", params: ["item": ["type": "fileChange"]]) &&
        ResumeModelActivity.appServer(method: "item/completed", params: ["item": ["type": "commandExecution", "status": "completed"]]),
        "tool first response requires real execution evidence instead of approval placeholder")
}

private func resumeFixture(root: URL, id: String = UUID().uuidString, stop: Date = Date().addingTimeInterval(-5), reset: Date? = nil, turn: String = "original") throws -> BlockedSession {
    let directory = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("rollout-\(id).jsonl")
    let meta: [String: Any] = ["type": "session_meta", "timestamp": ISO8601DateFormatter().string(from: stop.addingTimeInterval(-20)), "payload": ["id": id, "cwd": root.path]]
    var trace = try JSONSerialization.data(withJSONObject: meta); trace.append(10)
    trace.append(try resumeEvent("task_started", turn: turn, at: stop.addingTimeInterval(-10)))
    if let reset {
        trace.append(try resumeEvent("token_count", turn: turn, at: stop.addingTimeInterval(-1), extras: ["rate_limits": ["limit_id": "codex", "primary": ["used_percent": 100, "window_minutes": 300, "resets_at": reset.timeIntervalSince1970]]]))
    }
    trace.append(try resumeEvent("error", turn: turn, at: stop, extras: ["message": "usage_limit_reached"]))
    try trace.write(to: file)
    return BlockedSessionDetector.detect(in: [SessionWatcher.parse(url: file, mtime: Date())!]).first!.stabilized(from: nil)
}
private func resumeEvent(_ type: String, turn: String, at: Date, extras: [String: Any] = [:]) throws -> Data {
    var payload = extras; payload["type"] = type; payload["turn_id"] = turn
    var data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: at), "payload": payload])
    data.append(10); return data
}
private func resumeDatabase(_ root: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(root.appendingPathComponent("logs_1.sqlite").path, &db) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
}

@MainActor private func checkRolloutReplacement(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try resumeDatabase(root)
    let now = Date()
    let id = UUID().uuidString
    let old = try resumeFixture(root: root, id: id, stop: now.addingTimeInterval(-120), turn: "old-turn")
    var oldTrace = try Data(contentsOf: old.fileURL)
    oldTrace.append(try resumeEvent("task_started", turn: "aborted-turn", at: now.addingTimeInterval(-90)))
    oldTrace.append(try resumeEvent("turn_aborted", turn: "aborted-turn", at: now.addingTimeInterval(-89)))
    try oldTrace.write(to: old.fileURL)
    let current = old.fileURL.deletingLastPathComponent().appendingPathComponent("rollout-\(id)_\(UUID().uuidString).jsonl")
    var trace = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
        "payload": ["id": id, "cwd": root.path, "history_mode": "paginated", "history_base": ["thread_id": id, "end_ordinal_exclusive": 4, "end_byte_offset": 100]]])
    trace.append(10)
    trace.append(try resumeEvent("task_started", turn: "inherited-turn", at: now.addingTimeInterval(-100)))
    trace.append(try resumeEvent("error", turn: "inherited-turn", at: now.addingTimeInterval(-90), extras: ["message": "usage_limit_reached"]))
    trace.append(try resumeEvent("task_started", turn: "current-turn", at: now.addingTimeInterval(-59)))
    trace.append(try resumeEvent("task_complete", turn: "current-turn", at: now.addingTimeInterval(-30), extras: ["error": ["codex_error_info": "usage_limit_exceeded"]]))
    try trace.write(to: current)
    let log = "session_loop{thread_id=\(id)}:turn{turn.id=\"current-turn\"}:session_task.run:run_turn: Turn error: You've hit your usage limit."
    check(QuotaErrorLogProvider.turnID(in: log) == "current-turn", "current dotted turn.id log field is recognized")
    check(QuotaErrorLogProvider.turnID(in: log.replacingOccurrences(of: "turn.id", with: "turn_id")) == "current-turn", "legacy turn_id log field remains supported")
    let conflicting = log.replacingOccurrences(of: "turn{", with: "turn{turn_id=other ")
    check(QuotaErrorLogProvider.turnID(in: conflicting) == nil, "conflicting log turn identifiers are not guessed")
    var db: OpaquePointer?
    sqlite3_open(root.appendingPathComponent("logs_1.sqlite").path, &db)
    let escapedLog = log.replacingOccurrences(of: "'", with: "''")
    let escapedConflict = conflicting.replacingOccurrences(of: "'", with: "''")
    sqlite3_exec(db, "INSERT INTO logs VALUES(1, \(Int(now.addingTimeInterval(-30).timeIntervalSince1970)), 0, 'codex_core::session::turn', '\(id)', '\(escapedConflict)')", nil, nil, nil)
    check(try QuotaErrorLogProvider(codexHome: root).read()[id] == nil, "conflicting log turns cannot become an unqualified quota stop")
    sqlite3_exec(db, "UPDATE logs SET feedback_log_body = '\(escapedLog)'", nil, nil, nil)
    sqlite3_close(db)
    let stateDB = root.appendingPathComponent("state_5.sqlite")
    sqlite3_open(stateDB.path, &db)
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL)", nil, nil, nil)
    func pointTo(_ file: URL) {
        let path = file.path.replacingOccurrences(of: "'", with: "''")
        sqlite3_exec(db, "INSERT OR REPLACE INTO threads VALUES('\(id)', '\(path)')", nil, nil, nil)
    }
    pointTo(current)
    let worker = SessionScanWorker(codexHome: root)
    let first = worker.read(watchedIDs: [id])
    let targets = BlockedSessionDetector.detect(in: first.0)
    check(first.1 == nil && first.0.count == 1 && targets.count == 1 && targets.first?.stoppedTurnID == "current-turn" &&
        targets.first?.fileURL.resolvingSymlinksInPath() == current.resolvingSymlinksInPath(), "a reverted thread exposes only the registered current rollout and its own quota stop")
    check(first.0.first?.turns["inherited-turn"] == nil, "history_base without forked_from_id cannot attribute copied ancestor execution to the current segment")
    if let raw = targets.first {
        var uncertain = raw.stabilized(from: nil); uncertain.identityUncertain = true
        let recovered = raw.stabilized(from: uncertain)
        check(recovered.identityUncertain != true && recovered.episodeKey == uncertain.episodeKey,
            "canonical same-turn evidence repairs persisted uncertainty without changing the attempt key")
        let schedule = ScheduleEngine(anchorMinutes: 480)
        let clock = schedule.nodes()[0].addingTimeInterval(1)
        let idle = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: clock.addingTimeInterval(18000)), weekly: nil,
            capturedAt: clock, accountID: "ignored-rollout-account", sourceFile: "app-server", zeroUseWindowActive: false)
        let suite = "keeper.ignored-rollout." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.register(defaults: ["enabled": true, "dailyAnchorMinutes": 480])
        let pings = ReminderTestPing()
        let keeper = ExecutionCoordinator(provider: RecoveryTestUsage(snapshot: idle), defaults: prefs,
            ledgerURL: root.appendingPathComponent("ignored-support/attempts.json"), pingTransport: pings, codexHome: root, now: { clock })
        keeper.ping(schedule: schedule, accountID: idle.accountID, ignoredEpisodes: [uncertain.episodeKey], ignoredTargets: [recovered], blockers: { [] })
        try await resumeWait { !keeper.running }
        check(pings.count == 1 && keeper.lastFailure == nil,
            "an ignored pause recovered from duplicate rollouts cannot block keepalive as a new pause")
        var wrongTurn = old; wrongTurn.identityUncertain = true
        check(raw.stabilized(from: wrongTurn).stoppedTurnID == "current-turn" && raw.stabilized(from: wrongTurn).identityUncertain == false,
            "authoritative current evidence can replace an uncertain stop inherited from the obsolete file")
    }
    for _ in 0..<21 { _ = try resumeFixture(root: root) }
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-300)], ofItemAtPath: current.path)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-200)], ofItemAtPath: old.fileURL.path)
    let watched = worker.read(watchedIDs: [id], watchedPaths: [current])
    check(watched.1 == nil && watched.0.filter { $0.id == id }.map { $0.fileURL.resolvingSymlinksInPath() } == [current.resolvingSymlinksInPath()],
        "segmented watched rollout remains discoverable outside the newest twenty files regardless of old-file mtime")
    pointTo(old.fileURL)
    let changed = worker.read(watchedIDs: [id])
    check(changed.0.first(where: { $0.id == id })?.fileURL.resolvingSymlinksInPath() == old.fileURL.resolvingSymlinksInPath() &&
        !BlockedSessionDetector.detect(in: changed.0).contains(where: { $0.id == id }),
        "current-path changes invalidate selection without attributing another turn's stop to the old file")
    pointTo(root.appendingPathComponent("missing.jsonl"))
    check(worker.read(watchedIDs: [id]).1 != nil, "missing registered rollout cannot silently fall back to an obsolete file")
    sqlite3_exec(db, "DELETE FROM threads", nil, nil, nil)
    check(worker.read(watchedIDs: [id]).1 != nil, "duplicate thread files without authoritative identity pause scanning")
    pointTo(current)
    let target = BlockedSessionDetector.detect(in: worker.read(watchedIDs: [id]).0).first { $0.id == id }!.stabilized(from: nil)
    let suite = "keeper.rollout-replacement." + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": true, "resumeWorkspaceReminder": false])
    let usage = ResumeTestUsage(); let client = ResumeTestClient(target)
    let movedTransport = ResumeTestTransport()
    movedTransport.prepareBody = { _ in pointTo(old.fileURL) }
    let moved = ExecutionCoordinator(provider: usage, makeResumeTransport: { movedTransport }, defaults: prefs,
        ledgerURL: root.appendingPathComponent("moved-support/attempts.json"), codexHome: root)
    moved.resume([ResumeRequest(target: target, prompt: "synthetic test", accountID: usage.account, workspace: nil)], schedule: ScheduleEngine(anchorMinutes: 480), manual: true)
    try await resumeWait { !moved.running }
    check(!movedTransport.submitted && !moved.hasAttempted(target) && moved.operations.values.first?.preflight?.reasons.contains(.pauseChanged) == true,
        "a rollout switch during channel preparation blocks submission without consuming the pause attempt")
    pointTo(current)
    let ledger = root.appendingPathComponent("support/attempts.json")
    let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { AppServerResumeTransport(makeTransport: { client }) },
        defaults: prefs, ledgerURL: ledger, codexHome: root)
    coordinator.resume([ResumeRequest(target: target, prompt: "synthetic test", accountID: usage.account, workspace: nil)], schedule: ScheduleEngine(anchorMinutes: 480), manual: true)
    try await resumeWait { coordinator.operations.values.first?.receivedAt != nil }
    let replacement = current.deletingLastPathComponent().appendingPathComponent("rollout-\(id)_\(UUID().uuidString).jsonl")
    var response = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "cwd": root.path]])
    response.append(10)
    response.append(try resumeEvent("task_started", turn: client.turnID, at: Date()))
    response.append(try resumeEvent("agent_message", turn: client.turnID, at: Date(), extras: ["message": "real synthetic response"]))
    response.append(try resumeEvent("task_complete", turn: client.turnID, at: Date()))
    try response.write(to: replacement)
    let unverified = SessionWatcher.parse(url: replacement, mtime: Date())!
    coordinator.reconcile(sessions: [unverified], scannedAt: Date(), healthy: true)
    check(coordinator.confirmations.isEmpty, "an unverified alternate path cannot confirm an operation")
    pointTo(replacement)
    let verified = worker.read(watchedIDs: [id], watchedPaths: [current])
    coordinator.reconcile(sessions: verified.0, scannedAt: Date(), healthy: verified.1 == nil)
    check(coordinator.confirmations.count == 1 && !coordinator.running && coordinator.hasAttempted(target),
        "registered replacement can confirm the exact submitted turn while preserving duplicate-send protection")
    coordinator.cancelCurrent()
    pointTo(current)
    let stopped = worker.read(watchedIDs: [id])
    for turn in ["current-turn", "earlier-unknown-turn"] {
        let operation = ResumeOperation(id: turn, batchID: turn, accountID: usage.account, target: old,
            actionAt: old.blockedAt, phase: .checking, turnID: turn, protectsThread: true)
        let repeatedLedger = root.appendingPathComponent("repeated-\(turn)/attempts.json")
        try FileManager.default.createDirectory(at: repeatedLedger.deletingLastPathComponent(), withIntermediateDirectories: true)
        let records = try JSONSerialization.jsonObject(with: JSONEncoder().encode([operation]))
        try JSONSerialization.data(withJSONObject: ["version": 1, "keys": [], "operations": records]).write(to: repeatedLedger)
        let restored = ExecutionCoordinator(provider: usage, defaults: prefs, ledgerURL: repeatedLedger, codexHome: root)
        var changes = 0
        let observation = restored.$operations.dropFirst().sink { _ in changes += 1 }
        restored.reconcile(sessions: stopped.0, scannedAt: Date(), healthy: stopped.1 == nil)
        let firstChanges = changes
        restored.reconcile(sessions: stopped.0, scannedAt: Date(), healthy: stopped.1 == nil)
        check(firstChanges > 0 && changes == firstChanges && !restored.hasBusyTasks && restored.operations[turn]?.respondedAt == nil,
            "repeated canonical terminal or later-lifecycle scans cannot publish endlessly or invent a response: \(turn)")
        observation.cancel()
    }
}

private func resumePendingChoice(_ target: BlockedSession, account: String, runtime: URL) throws {
    var choices = ResumeChoices(); choices.requestRecoveryDecision(for: target, now: Date())
    let encoder = JSONEncoder()
    let saved = try JSONSerialization.jsonObject(with: encoder.encode([target.id: target]))
    try FileManager.default.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["confirmed": saved, "pauseRegistry": saved, "accounts": [target.id: account],
        "workspaces": [:], "held": [], "choices": JSONSerialization.jsonObject(with: encoder.encode(choices)), "displayAccountID": account]).write(to: runtime, options: .atomic)
}

@MainActor private func checkResumeRecoveryAdmission(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    let iso = ISO8601DateFormatter()
    func at(_ value: String) -> Date { iso.date(from: "2026-10-14T" + value + "Z")! }
    let storedReset = at("10:05:14"); let liveReset = at("10:04:11")
    let recoveredAt = at("10:04:19"); let liveBefore = at("10:04:02")
    let account = "recovery-admission-account"
    let raw = BlockedSession(id: UUID().uuidString, project: "Recovery", cwd: root.path, blockedAt: at("09:45:20"),
        fiveHourResetAt: storedReset, weeklyResetAt: nil, fileURL: root.appendingPathComponent("raw.jsonl"))
    let before = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 100, windowMinutes: 300, resetsAt: liveReset), weekly: nil,
        capturedAt: liveBefore, accountID: account, sourceFile: "app-server", zeroUseWindowActive: true)
    let after = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: recoveredAt.addingTimeInterval(18000)), weekly: nil,
        capturedAt: recoveredAt, accountID: account, sourceFile: "app-server", zeroUseWindowActive: false)
    let corrected = raw.withRecoveryEvidence(from: nil, usage: before, boundAccount: account, now: liveBefore)
    check(corrected.fiveHourResetAt == liveReset, "same-account exhausted live quota corrects an existing rollout deadline rather than only filling a missing date")
    let restored = try JSONDecoder().decode(BlockedSession.self, from: JSONEncoder().encode(corrected))
    check(raw.withRecoveryEvidence(from: restored, usage: after, boundAccount: account, now: recoveredAt).fiveHourResetAt == liveReset &&
        UsageRecovery.canResumeAfterScheduledReset(restored, usage: after, boundAccount: account, now: recoveredAt),
        "rescan, restart and a new zero-percent window preserve the corrected pause deadline and allow its normal recovery")
    var invalid = before; invalid.accountID = "different-account"
    check(raw.withRecoveryEvidence(from: nil, usage: invalid, boundAccount: account, now: liveBefore).fiveHourResetAt == storedReset,
        "another account cannot overwrite an existing recovery deadline")
    invalid = before; invalid.capturedAt = raw.blockedAt.addingTimeInterval(-1)
    check(raw.withRecoveryEvidence(from: nil, usage: invalid, boundAccount: account, now: invalid.capturedAt).fiveHourResetAt == storedReset,
        "an exhausted reading before the pause cannot correct its deadline")
    check(!UsageRecovery.isEarly(from: before, to: after, now: recoveredAt), "normal scheduled recovery is not classified as an early reset")
    var earlyBefore = before; earlyBefore.fiveHour?.resetsAt = recoveredAt.addingTimeInterval(3600)
    check(UsageRecovery.isEarly(from: earlyBefore, to: after, now: recoveredAt), "a recent exhausted-to-available pair well before its actual deadline positively proves early recovery")
    earlyBefore.capturedAt = recoveredAt.addingTimeInterval(-61)
    check(!UsageRecovery.isEarly(from: earlyBefore, to: after, now: recoveredAt), "missing recent samples cannot be treated as proof of early recovery")
    earlyBefore = before; earlyBefore.fiveHour?.resetsAt = storedReset
    check(!UsageRecovery.isEarly(from: earlyBefore, to: after, now: recoveredAt), "a 63-second forecast disagreement alone does not prove an early reset")
    var anonymousBefore = before; var anonymousAfter = after
    anonymousBefore.accountID = ""; anonymousAfter.accountID = ""
    check(!UsageRecovery.isNatural(from: anonymousBefore, to: anonymousAfter, now: recoveredAt), "empty identities cannot establish natural recovery")
    anonymousBefore.fiveHour?.resetsAt = recoveredAt.addingTimeInterval(3600)
    check(!UsageRecovery.isEarly(from: anonymousBefore, to: anonymousAfter, now: recoveredAt), "empty identities cannot establish early recovery")

    for (name, warm, intercept, legacy) in [("normal", true, false, false), ("reordered", true, true, false), ("missed-samples", false, false, false), ("saved-reminder", true, false, true)] {
        let directory = root.appendingPathComponent(name).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try resumeDatabase(directory)
        let stop = intercept ? at("10:04:05") : at("09:45:20")
        let original = try resumeFixture(root: directory, stop: stop, reset: storedReset)
        var clock = warm ? liveBefore : at("09:45:30")
        var quota = before; quota.capturedAt = clock; quota.fiveHour?.resetsAt = warm ? liveReset : storedReset
        let usage = RecoveryTestUsage(snapshot: quota)
        let suite = "keeper.recovery-admission." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.register(defaults: ["enabled": true, "autoResume": true, "earlyRecoveryPolicy": "ask", "dailyAnchorMinutes": 780, "resumeWorkspaceReminder": false])
        var transports: [ResumeTestTransport] = []; let pings = ReminderTestPing()
        let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: {
            let transport = ResumeTestTransport(); transports.append(transport); return transport
        }, defaults: prefs, ledgerURL: directory.appendingPathComponent("support/resume-attempts.json"), pingTransport: pings, codexHome: directory, now: { clock })
        let runtime = directory.appendingPathComponent("support/runtime.json")
        if legacy { try resumePendingChoice(original, account: account, runtime: runtime) }
        var state = AppState(provider: usage, defaults: prefs, runtimeURL: runtime, codexHome: directory, execution: coordinator, startMonitoring: false, now: { clock })
        state.refresh(); try await resumeWait { state.availableTasks.count == 1 && !state.usage.refreshing }
        try await Task.sleep(nanoseconds: 50_000_000)
        let target = state.availableTasks.first!
        var caughtDecision = false
        var subscription: AnyCancellable?
        if intercept {
            subscription = state.usage.$refreshing.dropFirst().sink { refreshing in
                if !refreshing && state.usage.snapshot?.capturedAt == recoveredAt {
                    state.recompute(allowExecution: false)
                    caughtDecision = caughtDecision || state.choices.recoveryDecisions?[target.episodeKey] != nil
                }
            }
        }
        defer { subscription?.cancel() }
        clock = recoveredAt; usage.set(after); state.usage.refresh()
        try await resumeWait { !state.usage.refreshing }
        if warm { try await resumeWait { transports.first?.submitted == true } }
        else { try await Task.sleep(nanoseconds: 50_000_000) }
        check(!caughtDecision && state.choices.recoveryDecisions?[target.episodeKey] == nil && pings.count == 0 &&
            (warm ? transports.filter(\.submitted).count == 1 : transports.isEmpty && state.nextAction?.mode == .resume && state.nextAction?.date == storedReset),
            "successful quota reads retain automatic continuation without asking or pinging: \(name)")
        if warm { transports[0].respond(); transports[0].finish(); try await resumeWait { !coordinator.hasBusyTasks } }
        clock = storedReset.addingTimeInterval(1); var later = after; later.capturedAt = clock; later.fiveHour?.resetsAt = clock.addingTimeInterval(18000)
        usage.set(later); state.usage.refresh(); try await resumeWait { !state.usage.refreshing }
        if !warm { try await resumeWait { transports.first?.submitted == true }; transports[0].respond(); transports[0].finish(); try await resumeWait { !coordinator.hasBusyTasks } }
        for _ in 0..<3 { state.recompute(allowExecution: true) }
        check(transports.filter(\.submitted).count == 1 && state.choices.recoveryDecisions?[target.episodeKey] == nil && pings.count == 0,
            "later confirmed recovery and repeated recomputation continue once without reviving a saved decision: \(name)")
        subscription?.cancel()
        state = AppState(provider: usage, defaults: prefs, runtimeURL: runtime, codexHome: directory, execution: coordinator, startMonitoring: false, now: { clock })
        state.refresh(); try await resumeWait { state.sessions.hasScanned && !state.usage.refreshing }
        state.recompute(allowExecution: false)
        check(state.choices.recoveryDecisions?[target.episodeKey] == nil && transports.filter(\.submitted).count == 1,
            "restart keeps the automatic recovery result and does not restore an old ask latch: \(name)")
    }
    let plan = DecisionEngine(schedule: ScheduleEngine(anchorMinutes: 780)).plan(now: recoveredAt, enabled: true, autoResume: true,
        earlyRecoveryPolicy: "ask", usage: after, blocked: [BlockedSession(id: raw.id, project: raw.project, cwd: raw.cwd, blockedAt: raw.blockedAt,
            fiveHourResetAt: nil, weeklyResetAt: nil, fileURL: raw.fileURL)])
    check(!plan.needsRecoveryDecision && plan.mode == .resume && plan.date != nil,
        "no recovery deadline or continuous pair keeps the normal schedule instead of inventing a user decision")

    let directory = root.appendingPathComponent("later-pause").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try resumeDatabase(directory)
    let nextReset = at("11:30:00")
    let newerPause = try resumeFixture(root: directory, stop: at("10:30:04"), reset: nextReset)
    var clock = at("10:30:05")
    var quota = before; quota.capturedAt = at("10:29:55"); quota.fiveHour?.resetsAt = at("10:30:00")
    let provider = RecoveryTestUsage(snapshot: quota)
    let suite = "keeper.later-pause." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": true, "earlyRecoveryPolicy": "ask", "dailyAnchorMinutes": 780, "resumeWorkspaceReminder": false])
    var transports: [ResumeTestTransport] = []; let pings = ReminderTestPing()
    let coordinator = ExecutionCoordinator(provider: provider, makeResumeTransport: {
        let transport = ResumeTestTransport(); transports.append(transport); return transport
    }, defaults: prefs, ledgerURL: directory.appendingPathComponent("support/resume-attempts.json"), pingTransport: pings, codexHome: directory, now: { clock })
    let runtime = directory.appendingPathComponent("support/runtime.json")
    try resumePendingChoice(newerPause, account: account, runtime: runtime)
    let state = AppState(provider: provider, defaults: prefs, runtimeURL: runtime, codexHome: directory, execution: coordinator, startMonitoring: false, now: { clock })
    state.refresh(); try await resumeWait { state.availableTasks.count == 1 && !state.usage.refreshing }
    quota = after; quota.capturedAt = at("10:30:03"); provider.set(quota); state.usage.refresh()
    try await resumeWait { !state.usage.refreshing }; state.recompute(allowExecution: false)
    clock = at("10:30:06"); quota.capturedAt = clock; provider.set(quota); state.usage.refresh()
    try await resumeWait { !state.usage.refreshing }; state.recompute()
    check(state.choices.recoveryDecisions?[newerPause.episodeKey] != nil && !coordinator.running && transports.isEmpty && pings.count == 0,
        "a recovery observed before a newer pause cannot clear its decision or authorize that pause's early continuation")
}

@MainActor private func checkResumeIdentitySynchronization(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try resumeDatabase(root)
    var clock = Date(timeIntervalSince1970: 1791962400)
    let account = "identity-sync-account"
    var live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: clock.addingTimeInterval(3600)), weekly: nil,
        capturedAt: clock, accountID: account, sourceFile: "app-server", zeroUseWindowActive: true)
    let provider = RecoveryTestUsage(snapshot: live)
    let suite = "keeper.identity-sync." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": true, "earlyRecoveryPolicy": "ask", "dailyAnchorMinutes": 780, "resumeWorkspaceReminder": false])
    var transports: [ResumeTestTransport] = []; let pings = ReminderTestPing()
    let coordinator = ExecutionCoordinator(provider: provider, makeResumeTransport: {
        let transport = ResumeTestTransport(); transports.append(transport); return transport
    }, defaults: prefs, ledgerURL: root.appendingPathComponent("support/resume-attempts.json"), pingTransport: pings, codexHome: root, now: { clock })
    let state = AppState(provider: provider, defaults: prefs, runtimeURL: root.appendingPathComponent("support/runtime.json"), codexHome: root,
        execution: coordinator, startMonitoring: false, now: { clock })
    state.refresh(); try await resumeWait { state.sessions.hasScanned && !state.usage.refreshing && state.displayAccountID == account }
    let target = try resumeFixture(root: root, stop: clock.addingTimeInterval(-5), reset: live.fiveHour!.resetsAt)
    provider.pause(); defer { provider.release() }
    state.usage.refresh(source: "identity-fixture", critical: true); state.sessions.refresh()
    try await resumeWait { state.availableTasks.count == 1 }
    state.recompute(allowExecution: false)
    check(state.usage.criticalRefreshPending && state.nextAction?.note != "账户已改变" && state.displayAccountID == account && transports.isEmpty,
        "a new pause awaiting its critical account check is synchronization rather than an account change")
    provider.set(live, failing: true); provider.release()
    try await resumeWait { !state.usage.refreshing && state.usage.lastError != nil }
    clock = clock.addingTimeInterval(71); state.usage.refresh()
    try await resumeWait { !state.usage.refreshing }
    state.recompute(allowExecution: false)
    check(state.usage.snapshot?.accountID == nil && state.usage.snapshot?.sourceFile != "app-server" &&
        state.displayAccountID == account && state.nextAction?.note != "账户已改变" && transports.isEmpty && pings.count == 0,
        "an expired live reading replaced by an anonymous rollout cannot declare an account change or authorize sending")
    live.capturedAt = clock; provider.set(live); state.usage.refresh()
    try await resumeWait { !state.usage.refreshing && state.usage.lastError == nil && state.usage.hasReliableReading }
    state.recompute(allowExecution: false)
    check(state.displayAccountID == account && state.nextAction?.mode == .resume && state.nextAction?.date == live.fiveHour?.resetsAt &&
        state.nextAction?.note != "账户已改变" && state.choices.recoveryDecisions?[target.episodeKey] == nil && transports.isEmpty && pings.count == 0,
        "a successful background read clears the failure and restores the same account's automatic plan without menu interaction")
}

@MainActor private func checkResumeQuotaTerminalEvidence(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try resumeDatabase(root)
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let start = now.addingTimeInterval(-20); let stop = now.addingTimeInterval(-10)
    let id = UUID().uuidString; let turn = "quota-before-response"
    let file = root.appendingPathComponent("sessions/rollout-\(id).jsonl")
    var trace = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(-10)), "payload": ["id": id, "cwd": root.path]])
    trace.append(10); trace.append(try resumeEvent("task_started", turn: turn, at: start))
    let prefix = trace
    trace.append(try resumeEvent("error", turn: turn, at: stop, extras: ["message": "usage_limit_reached"]))
    let completed = try resumeEvent("task_complete", turn: turn, at: stop.addingTimeInterval(1))
    trace.append(completed); try trace.write(to: file)
    check(SessionWatcher.parse(url: file, mtime: now)?.turns[turn]?.terminal == .quotaStopped,
        "generic task completion after a quota error preserves the failed terminal instead of proving startup")

    var db: OpaquePointer?
    guard sqlite3_open(root.appendingPathComponent("logs_1.sqlite").path, &db) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    defer { sqlite3_close(db) }
    let body = "turn_id=\(turn) session_task.run:run_turn: Turn error: You’ve hit your usage limit."
    guard sqlite3_exec(db, "INSERT INTO logs VALUES(1, \(Int(stop.timeIntervalSince1970)), 0, 'codex_core::session::turn', '\(id)', '\(body)')", nil, nil, nil) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    var dbOnly = prefix; dbOnly.append(completed); try dbOnly.write(to: file)
    let watcher = SessionWatcher(codexHome: root); watcher.refresh()
    try await resumeWait { watcher.hasScanned }
    let activity = watcher.sessions.first!
    check(activity.quotaBlockedAt == stop && activity.turns[turn]?.terminal == .quotaStopped,
        "exact database quota stop overrides an unqualified rollout completion for the same turn")
    let target = BlockedSession(id: id, project: "Quota terminal", cwd: root.path, blockedAt: start.addingTimeInterval(-10), fiveHourResetAt: nil, weeklyResetAt: nil, fileURL: activity.fileURL)
    let operation = ResumeOperation(id: "quota-terminal-operation", batchID: "quota-terminal", accountID: "test-account", target: target,
        actionAt: start, phase: .checking, turnID: turn, receivedAt: start, protectsThread: true)
    let ledger = root.appendingPathComponent("support/resume-attempts.json")
    try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([operation]))
    try JSONSerialization.data(withJSONObject: ["version": 1, "keys": [], "operations": encoded]).write(to: ledger)
    let suite = "keeper.quota-terminal." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    let coordinator = ExecutionCoordinator(provider: ResumeTestUsage(), defaults: prefs, ledgerURL: ledger, codexHome: root)
    coordinator.reconcile(sessions: [activity], scannedAt: now, healthy: true)
    check(coordinator.operations[operation.id]?.target.fileURL == activity.fileURL && activity.fileURL.resolvingSymlinksInPath() == file.resolvingSymlinksInPath(),
        "exact quota terminal scan matches the restored operation and rollout path")
    check(coordinator.operations[operation.id]?.respondedAt == nil && coordinator.operations[operation.id]?.terminal == .quotaStopped && coordinator.confirmations.isEmpty,
        "quota stop before first response never becomes continued during scan reconciliation")

    guard sqlite3_exec(db, "INSERT INTO logs VALUES(2, \(Int(now.timeIntervalSince1970 - 1)), 0, 'codex_core::session::turn', '\(id)', '\(body)')", nil, nil, nil) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    dbOnly.append(try resumeEvent("task_started", turn: "later-running-turn", at: now.addingTimeInterval(-5))); try dbOnly.write(to: file)
    let scanned = watcher.scannedAt; watcher.refresh(); try await resumeWait { watcher.scannedAt != scanned }
    check(watcher.sessions.first?.taskRunning == true && watcher.sessions.first?.quotaBlockedAt == nil,
        "a delayed database stop for an older turn cannot stop the known newer running turn")
}

@MainActor private func checkResumePingAdmission(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try resumeDatabase(root)
    let pendingTarget = try resumeFixture(root: root)
    let now = Date()
    let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
    let anchor = parts.hour! * 60 + parts.minute!
    let suite = "keeper.resume.ping-admission." + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": false, "autoResume": true, "earlyRecoveryPolicy": "ask", "dailyAnchorMinutes": anchor, "resumeWorkspaceReminder": false])
    let usage = RecoveryTestUsage(snapshot: UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: now.addingTimeInterval(18000)), weekly: nil,
        capturedAt: now, accountID: "ping-admission-account", sourceFile: "app-server"))
    var transports: [ResumeTestTransport] = []
    let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: {
        let transport = ResumeTestTransport(); transports.append(transport); return transport
    }, defaults: prefs, ledgerURL: root.appendingPathComponent("support/resume-attempts.json"), pingTransport: ReminderTestPing(), codexHome: root)
    try resumePendingChoice(pendingTarget, account: "ping-admission-account", runtime: root.appendingPathComponent("support/runtime.json"))
    let state = AppState(provider: usage, defaults: prefs, runtimeURL: root.appendingPathComponent("support/runtime.json"), codexHome: root, execution: coordinator, startMonitoring: false)
    state.refresh(manual: true); try await resumeWait { state.availableTasks.count == 1 && !state.usage.refreshing }
    usage.pauseModel(); prefs.set(true, forKey: "enabled"); state.recompute(allowExecution: false)
    let target = state.availableTasks.first!
    let pending = state.choices.recoveryDecisions?[target.episodeKey]
    coordinator.ping(schedule: state.schedule, accountID: state.displayAccountID, ignoredEpisodes: [target.episodeKey], ignoredTargets: [target], blockers: { [] })
    try await resumeWait { usage.modelReadCount > 0 && coordinator.running }
    state.resolveRecoveryDecision(.now, for: [target])
    check(pending != nil && state.choices.recoveryDecisions?[target.episodeKey] == pending && transports.isEmpty,
        "a now choice during keep-alive remains actionable instead of being consumed without submission")
    usage.releaseModel(); try await resumeWait { !coordinator.running }
    state.resolveRecoveryDecision(.now, for: [target]); try await resumeWait { transports.first?.submitted == true && coordinator.latestOperation(for: target, accountID: state.displayAccountID)?.receivedAt != nil }
    check(coordinator.hasAttempted(target) && coordinator.latestOperation(for: target, accountID: state.displayAccountID)?.receivedAt != nil && transports.count == 1,
        "the preserved choice starts exactly once when keep-alive releases admission")
    transports[0].respond(); transports[0].finish(); try await resumeWait { !coordinator.hasBusyTasks }
}

@MainActor func checkResumeSelectionKeepAlive(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    let calendar = Calendar.current
    let node = calendar.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!
    for scenario in ["deselected", "reselected", "new-pause", "auto-off", "auto-on", "auto-off-new-pause"] {
        let directory = root.appendingPathComponent(scenario).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try resumeDatabase(directory)
        var clock = node.addingTimeInterval(-300)
        let first = try resumeFixture(root: directory, stop: clock.addingTimeInterval(-60), turn: "first-stop")
        _ = try resumeFixture(root: directory, stop: clock.addingTimeInterval(-60), turn: "second-stop")
        let suite = "keeper.selection-keepalive." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.register(defaults: ["enabled": true, "autoResume": true, "earlyRecoveryPolicy": "ask", "dailyAnchorMinutes": 780, "resumeWorkspaceReminder": false])
        var quota = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: clock.addingTimeInterval(18000)), weekly: nil,
            capturedAt: clock, accountID: "selection-account", sourceFile: "app-server", zeroUseWindowActive: false)
        let usage = RecoveryTestUsage(snapshot: quota); let pings = ReminderTestPing()
        var transports: [ResumeTestTransport] = []
        let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: {
            let transport = ResumeTestTransport(); transports.append(transport); return transport
        }, defaults: prefs, ledgerURL: directory.appendingPathComponent("support/resume-attempts.json"), pingTransport: pings, codexHome: directory, now: { clock })
        let runtime = directory.appendingPathComponent("support/runtime.json")
        try resumePendingChoice(first, account: "selection-account", runtime: runtime)
        let state = AppState(provider: usage, defaults: prefs, runtimeURL: runtime, codexHome: directory, execution: coordinator, startMonitoring: false, now: { clock })
        state.refresh(manual: true); try await resumeWait { state.availableTasks.count == 2 && !state.usage.refreshing }
        let tasks = [state.availableTasks.first { $0.id == first.id }!, state.availableTasks.first { $0.id != first.id }!]
        if scenario.hasPrefix("auto-") {
            prefs.set(false, forKey: "autoResume"); state.recompute(allowExecution: false)
            try await resumeWait { !state.usage.refreshing }; state.recompute(allowExecution: false)
            check(state.selectedTasks.count == 2 && state.choices.recoveryDecisions?[first.episodeKey] != nil,
                "global auto-resume off preserves task selection and recovery choice: \(scenario)")
            prefs.set(true, forKey: "autoResume"); state.recompute(allowExecution: false)
            try await resumeWait { !state.usage.refreshing }; state.recompute(allowExecution: false)
            check(state.nextAction?.mode == .resume && state.selectedTasks.count == 2 && state.choices.recoveryDecisions?[first.episodeKey] != nil,
                "re-enabling auto-resume restores the original continuation plan and pending choice: \(scenario)")
            prefs.set(false, forKey: "autoResume"); state.recompute(allowExecution: false)
            try await resumeWait { !state.usage.refreshing }; state.recompute(allowExecution: false)
        } else {
            state.setSelected(tasks[0], false)
            check(state.nextAction?.mode == .resume && state.selectedTasks.count == 1,
                "one deselected task leaves the other continuation plan intact: \(scenario)")
            state.setSelected(tasks[1], false)
            check(state.availableTasks.count == 2 && state.selectedTasks.isEmpty && state.choices.keepAliveEpisodes.isEmpty,
                "task switches retain both tasks for later reselection: \(scenario)")
            state.setSelected(tasks[1], true)
            check(state.nextAction?.mode == .resume && state.selectedTasks.map(\.episodeKey) == [tasks[1].episodeKey],
                "reselection restores only that task's continuation: \(scenario)")
            state.setSelected(tasks[1], false)
        }
        check(state.nextAction?.mode == .keepAlive && state.nextAction?.date == node,
            "no enabled continuation retains the next scheduled keep-alive: \(scenario)")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime)) as! [String: Any]
        let choices = try JSONDecoder().decode(ResumeChoices.self, from: JSONSerialization.data(withJSONObject: saved["choices"]!))
        check(choices == state.choices, "keep-alive plan persists existing task choices without cancelling them: \(scenario)")

        usage.pauseModel(); clock = node; quota.capturedAt = clock; quota.fiveHour?.resetsAt = node.addingTimeInterval(18000)
        usage.set(quota); state.usage.refresh()
        try await resumeWait { usage.modelReadCount > 0 && coordinator.running }
        check(coordinator.running, "real coordinator prepares scheduled keep-alive: \(scenario)")
        if scenario == "reselected" { state.setSelected(tasks[1], true) }
        if scenario == "auto-on" { prefs.set(true, forKey: "autoResume"); state.recompute(allowExecution: false) }
        if scenario.hasSuffix("new-pause") { _ = try resumeFixture(root: directory, stop: clock.addingTimeInterval(-1), turn: "new-stop") }
        usage.releaseModel(); try await resumeWait { !coordinator.running }
        let shouldPing = scenario == "deselected" || scenario == "auto-off"
        check(pings.count == (shouldPing ? 1 : 0) && coordinator.confirmations.filter { $0.kind == .keepAlive }.count == (shouldPing ? 1 : 0),
            "send-time task protection permits only the unchanged keep-alive snapshot: \(scenario)")
        if scenario == "auto-on" {
            try await resumeWait { !state.usage.refreshing }; state.recompute()
            try await resumeWait { transports.first?.submitted == true }
            check(transports.count == 1 && !coordinator.hasAttempted(tasks[0]) && coordinator.hasAttempted(tasks[1]),
                "re-enabling auto-resume continues only the selected task without a pending recovery choice")
        } else {
            check(transports.isEmpty && tasks.allSatisfy { !coordinator.hasAttempted($0) },
                "keep-alive never resumes a task or creates a continuation attempt: \(scenario)")
        }
        for transport in transports { transport.respond(); transport.finish() }
        try await resumeWait { !coordinator.hasBusyTasks }
    }

    let task = BlockedSession(id: "fact", project: "Fact", cwd: root.path, blockedAt: node.addingTimeInterval(-60),
        fiveHourResetAt: nil, weeklyResetAt: nil, fileURL: root.appendingPathComponent("fact.jsonl"))
    check(ResumeTaskFact.make(task: task, operation: nil).text == L10n.text("等待自动继续"),
        "normal task waiting status omits paused wording")
    check(ResumeTaskFact.make(task: task, operation: nil, selected: false).text == L10n.text("已暂停，自动续跑已关闭") &&
        ResumeTaskFact.make(task: task, operation: nil, cancelled: true).text == L10n.text("已取消本次自动继续"),
        "deselected and cancelled tasks do not promise automatic continuation")
    let stopped = ResumeOperation(id: "stopped", batchID: "batch", accountID: "selection-account", target: task,
        actionAt: node, phase: .stopped, terminal: .quotaStopped, protectsThread: false)
    check(ResumeTaskFact.make(task: task, operation: stopped, enabled: false).text == L10n.text("已暂停，Keeper 已停用") &&
        ResumeTaskFact.make(task: task, operation: stopped, autoResume: false).text == L10n.text("已暂停，自动续跑已关闭"),
        "a quota-stopped operation cannot claim automatic waiting while Keeper or auto-resume is off")
    var active = stopped; active.phase = .sending
    check(ResumeTaskFact.make(task: task, operation: active, enabled: false, autoResume: false, selected: false).text == L10n.text("正在确认中"),
        "real sending facts retain priority over future automatic switches")
    active.phase = .confirming
    check(ResumeTaskFact.make(task: task, operation: active, enabled: false, autoResume: false, selected: false).text == L10n.text("正在确认中"),
        "real confirmation facts retain priority over future automatic switches")
    active.respondedAt = node
    check(ResumeTaskFact.make(task: task, operation: active, enabled: false, autoResume: false, selected: false).text.contains(L10n.text("已继续")),
        "confirmed continuation facts retain priority over future automatic switches")
    var choices = ResumeChoices(); choices.requestRecoveryDecision(for: task, now: node); choices.deselectedEpisodes.insert(task.episodeKey)
    var summary = MenuSummary()
    summary.applyResumeTasks(operations: [], pending: [task], choices: choices)
    check(summary.tasks == [L10n.format("%d 个任务已关闭自动继续", 1)] && !summary.tasksNeedAttention,
        "deselected tasks remain accessible without claiming waiting or requiring a choice")
    summary.applyRecoveryReminder(tasks: [task], choices: choices)
    check(summary.reminderTitle.isEmpty, "deselected recovery choices do not request user action")
    choices.deselectedEpisodes.remove(task.episodeKey)
    summary.applyRecoveryReminder(tasks: [task], choices: choices)
    check(!summary.reminderTitle.isEmpty, "reselecting restores a saved recovery choice")
    for (enabled, autoResume) in [(false, true), (true, false)] {
        var presentation = MenuPresentation()
        let menu = presentation.build(plan: nil, usage: nil, schedule: ScheduleEngine(anchorMinutes: 780), tasks: [task],
            availableTasks: [task], choices: choices, enabled: enabled, autoResume: autoResume, now: node)
        check(menu.reminderTitle.isEmpty, "disabled Keeper or auto-resume suppresses recovery reminders: \(enabled), \(autoResume)")
        summary.applyResumeTasks(operations: [], pending: [task], choices: choices, enabled: enabled, autoResume: autoResume)
        check(summary.tasks == [L10n.format(enabled ? "%d 个任务已关闭自动继续" : "%d 个任务已暂停自动继续", 1)] && !summary.tasksNeedAttention,
            "task summary reflects disabled Keeper or auto-resume instead of waiting: \(enabled), \(autoResume)")
    }
    var manual = stopped; manual.phase = .manualRequired; manual.terminal = .manualRequired; manual.endedAt = node
    var disabled = MenuSummary(headline: "已停用")
    disabled.applyResumeTasks(operations: [manual], pending: [], choices: ResumeChoices(), enabled: false)
    check(disabled.headline == "已停用" && disabled.statusSymbol == "pause.circle" && disabled.taskCount == 1,
        "a manual continuation record remains accessible without replacing the disabled primary state")

    let retryRoot = root.appendingPathComponent("retry-explanation").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: retryRoot, withIntermediateDirectories: true); try resumeDatabase(retryRoot)
    let clock = node.addingTimeInterval(-300)
    let retryTask = try resumeFixture(root: retryRoot, stop: clock.addingTimeInterval(-60))
    let retry = ResumeOperation(id: "retry", batchID: "retry", accountID: "selection-account", target: retryTask,
        actionAt: clock, phase: .notSubmitted, failure: "preflight failed", protectsThread: false, manual: false)
    let ledger = retryRoot.appendingPathComponent("support/resume-attempts.json")
    try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([retry]))
    try JSONSerialization.data(withJSONObject: ["version": 1, "keys": [], "operations": encoded]).write(to: ledger)
    let suite = "keeper.retry-explanation." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": true, "dailyAnchorMinutes": 780])
    let usage = RecoveryTestUsage(snapshot: UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: node.addingTimeInterval(18000)),
        weekly: nil, capturedAt: clock, accountID: "selection-account", sourceFile: "app-server", zeroUseWindowActive: false))
    let coordinator = ExecutionCoordinator(provider: usage, defaults: prefs, ledgerURL: ledger, codexHome: retryRoot, now: { clock })
    let state = AppState(provider: usage, defaults: prefs, runtimeURL: retryRoot.appendingPathComponent("support/runtime.json"), codexHome: retryRoot,
        execution: coordinator, startMonitoring: false, now: { clock })
    state.refresh(); try await resumeWait { state.availableTasks.count == 1 && !state.usage.refreshing }
    let current = state.availableTasks.first!
    check(state.planExplanation(for: current) == L10n.text("条件恢复后自动重试"), "enabled automatic preflight failure retains its retry explanation")
    state.setSelected(current, false)
    check(state.planExplanation(for: current) == nil, "deselected task cannot promise automatic retry")
    state.setSelected(current, true)
    for key in ["autoResume", "enabled"] {
        prefs.set(false, forKey: key)
        check(state.planExplanation(for: current) == nil, "disabled \(key) cannot promise automatic retry")
        prefs.set(true, forKey: key)
        check(state.planExplanation(for: current) == L10n.text("条件恢复后自动重试"), "restoring \(key) restores the saved retry explanation")
    }
}

@MainActor private func checkResumeCurrentPauseRows(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try resumeDatabase(root)
    let now = Date(); let before = now.addingTimeInterval(-30)
    let first = try resumeFixture(root: root, stop: before, turn: "first-original")
    let second = try resumeFixture(root: root, stop: before, turn: "second-original")
    let turn = "first-resumed"
    let file = try FileHandle(forWritingTo: first.fileURL); try file.seekToEnd()
    try file.write(contentsOf: resumeEvent("task_started", turn: turn, at: now.addingTimeInterval(-10)))
    try file.write(contentsOf: resumeEvent("error", turn: turn, at: now.addingTimeInterval(-5), extras: ["message": "usage_limit_reached"]))
    try file.close()
    let operations = [
        ResumeOperation(id: "earlier-pause", batchID: "same-batch", accountID: "resume-state-account", target: first,
            actionAt: now.addingTimeInterval(-12), phase: .stopped, turnID: turn, receivedAt: now.addingTimeInterval(-10),
            endedAt: now.addingTimeInterval(-5), terminal: .quotaStopped, protectsThread: false),
        ResumeOperation(id: "other-confirming", batchID: "same-batch", accountID: "resume-state-account", target: second,
            actionAt: now.addingTimeInterval(-12), phase: .checking, turnID: "second-resumed", receivedAt: now.addingTimeInterval(-10), protectsThread: true)
    ]
    let ledger = root.appendingPathComponent("support/resume-attempts.json")
    try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(operations))
    try JSONSerialization.data(withJSONObject: ["version": 1, "keys": [], "operations": encoded]).write(to: ledger)
    let suite = "keeper.resume.current-pause." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": false, "dailyAnchorMinutes": 480])
    let usage = ResumeTestUsage()
    let coordinator = ExecutionCoordinator(provider: usage, defaults: prefs, ledgerURL: ledger, codexHome: root)
    let state = AppState(provider: usage, defaults: prefs, runtimeURL: root.appendingPathComponent("support/runtime.json"), codexHome: root, execution: coordinator, startMonitoring: false)
    state.refresh(manual: true); try await resumeWait { state.availableTasks.count == 1 && !state.usage.refreshing }
    check(state.availableTasks.first?.id == first.id && state.currentOperations.map(\.id) == ["other-confirming"] && state.visibleOperations.count == 2,
        "a new quota pause replaces its earlier current row even while another task in the same batch is confirming, preserving history")
}

@MainActor private func checkResumeCoordinator(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try resumeDatabase(root)
    let first = try resumeFixture(root: root, turn: "first-original")
    let second = try resumeFixture(root: root, turn: "second-original")
    let suite = "keeper.resume.states." + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": true, "dailyAnchorMinutes": 480, "resumeWorkspaceReminder": false])
    let usage = ResumeTestUsage()
    var transports: [ResumeTestTransport] = []
    var shouldFail = true
    let failureLock = NSLock()
    let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: {
        let transport = ResumeTestTransport()
        transport.prepareBody = { target in
            failureLock.lock(); let fail = target.id == first.id && shouldFail
            if fail { shouldFail = false }; failureLock.unlock()
            if fail { throw CodexConnectionError.server("工作目录检查失败") }
        }
        transports.append(transport); return transport
    }, defaults: prefs, ledgerURL: root.appendingPathComponent("support/resume-attempts.json"), codexHome: root)
    let schedule = ScheduleEngine(anchorMinutes: 480)
    let requests = [first, second].map { ResumeRequest(target: $0, prompt: "test only", accountID: usage.account, workspace: nil) }
    coordinator.resume(requests, schedule: schedule, manual: true)
    try await resumeWait { coordinator.operations.values.contains { $0.phase == .notSubmitted } && coordinator.operations.values.contains { $0.phase == .confirming } }
    check(coordinator.running && !coordinator.hasAttempted(first) && coordinator.hasAttempted(second),
        "one preflight failure is visible and retryable while another task still observes startup")
    coordinator.resume([requests[0]], schedule: schedule, manual: true)
    try await resumeWait { transports.count == 3 && transports[2].submitted }
    check(transports.count == 3 && transports[2].submitted && !transports[1].cancelled,
        "failed task can independently retry while another long task is active")
    transports[1].respond(); transports[2].respond()
    try await resumeWait { !coordinator.running }
    check(coordinator.operations.values.filter { $0.respondedAt != nil }.count == 2 && coordinator.independentTaskNames.count == 2,
        "startup responses release foreground batch while both independent tasks keep running")
    check(coordinator.confirmations.filter { $0.kind == .resume }.count == 2 && coordinator.confirmations.allSatisfy { $0.operationID != nil && $0.episodeKey != nil && $0.threadID != nil && $0.turnID != nil },
        "per-task startup history preserves operation, pause, thread and target turn")
    coordinator.resume(requests, schedule: schedule, manual: true)
    var changed = first; changed.pauseID = first.episodeKey + ":new-key"
    coordinator.resume([ResumeRequest(target: changed, prompt: "test only", accountID: usage.account, workspace: nil)], schedule: schedule, manual: true)
    check(transports.count == 3 && coordinator.hasBusyTasks, "in-flight thread constraint cannot be bypassed with another episode key")
    coordinator.reconcile(sessions: [], scannedAt: Date(), healthy: false)
    coordinator.reconcile(sessions: [SessionWatcher.parse(url: second.fileURL, mtime: Date())!], scannedAt: Date(), healthy: true)
    check(coordinator.busyThreadIDs.contains(first.id) && coordinator.busyThreadIDs.contains(second.id), "old or failed scans cannot clear target-turn handoff guards")
    prefs.set(false, forKey: "enabled"); coordinator.cancelCurrent()
    check(!transports[1].cancelled && !transports[2].cancelled && coordinator.independentTaskNames.count == 2,
        "disabling future automatic actions does not cancel submitted independent tasks")
    prefs.set(true, forKey: "enabled")
    transports[1].finish(); transports[2].finish()
    try await resumeWait { !coordinator.hasBusyTasks }
    check(coordinator.independentTaskNames.isEmpty && !coordinator.hasBusyTasks, "true task terminal releases carrier and busy protection")
    let projectionRuntime = root.appendingPathComponent("support/history-projection.json")
    try JSONSerialization.data(withJSONObject: ["confirmed": [:], "accounts": [first.id: usage.account, second.id: usage.account],
        "workspaces": [:], "held": []]).write(to: projectionRuntime)
    let projection = AppState(provider: usage, defaults: prefs, runtimeURL: projectionRuntime, codexHome: root,
        execution: coordinator, startMonitoring: false)
    let historyRows = projection.taskOperations(ids: Set(coordinator.operations.keys))
    check(historyRows.count == 2 && historyRows.allSatisfy { $0.respondedAt != nil } && coordinator.operations.count == 3,
        "retry updates one row per pause while retaining the prior failed attempt underneath")

    let slowRoot = root.appendingPathComponent("slow")
    try FileManager.default.createDirectory(at: slowRoot, withIntermediateDirectories: true); try resumeDatabase(slowRoot)
    let slowTarget = try resumeFixture(root: slowRoot)
    let prepared = DispatchSemaphore(value: 0)
    let slowTransport = ResumeTestTransport(); slowTransport.prepareBody = { _ in prepared.wait() }
    let slowCoordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { slowTransport }, defaults: prefs,
        ledgerURL: slowRoot.appendingPathComponent("support/resume-attempts.json"), codexHome: slowRoot)
    slowCoordinator.resume([ResumeRequest(target: slowTarget, prompt: "test only", accountID: usage.account, workspace: nil)], schedule: schedule, manual: true)
    try await resumeWait { slowTransport.prepared }
    prefs.set("keepPlan", forKey: "earlyRecoveryPolicy"); prepared.signal()
    try await resumeWait { !slowCoordinator.running }
    check(!slowTransport.submitted && !slowCoordinator.hasAttempted(slowTarget), "policy changes during slow preparation are checked before atomic intent and start")
    prefs.removeObject(forKey: "earlyRecoveryPolicy")

    let draftRoot = root.appendingPathComponent("draft-preflight")
    try FileManager.default.createDirectory(at: draftRoot, withIntermediateDirectories: true); try resumeDatabase(draftRoot)
    let draftTarget = try resumeFixture(root: draftRoot)
    let draftFile = draftRoot.appendingPathComponent(".codex-global-state.json")
    func writeDraft(_ text: String) throws {
        try JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": ["composer-prompt-drafts-v2": ["local:" + draftTarget.id: ["prompt": text]]]])
            .write(to: draftFile, options: .atomic)
    }
    try writeDraft("old draft")
    let draftUsage = ResumeTestUsage(); let readEntered = DispatchSemaphore(value: 0); let readRelease = DispatchSemaphore(value: 0)
    draftUsage.onRead { readEntered.signal(); readRelease.wait() }
    let draftTransport = ResumeTestTransport()
    let draftCoordinator = ExecutionCoordinator(provider: draftUsage, makeResumeTransport: { draftTransport }, defaults: prefs,
        ledgerURL: draftRoot.appendingPathComponent("support/resume-attempts.json"), codexHome: draftRoot)
    draftCoordinator.resume([ResumeRequest(target: draftTarget, prompt: "fixed", accountID: usage.account, workspace: nil, messageMode: .composerDraft)], schedule: schedule, manual: true)
    try await resumeWait { readEntered.wait(timeout: .now()) == .success }
    try writeDraft("latest draft after quota read began"); let latestDraft = try Data(contentsOf: draftFile); readRelease.signal()
    try await resumeWait { draftTransport.submitted }
    check(draftTransport.prompt == "latest draft after quota read began" && (try? Data(contentsOf: draftFile)) == latestDraft,
        "composer draft is read after slow final quota preflight near submission and retained unchanged")
    draftTransport.respond(); draftTransport.finish(); try await resumeWait { !draftCoordinator.hasBusyTasks }

    let editRoot = root.appendingPathComponent("editing-preparation")
    try FileManager.default.createDirectory(at: editRoot, withIntermediateDirectories: true); try resumeDatabase(editRoot)
    let editTarget = try resumeFixture(root: editRoot)
    try resumePendingChoice(editTarget, account: usage.account, runtime: editRoot.appendingPathComponent("support/runtime.json"))
    let editRelease = DispatchSemaphore(value: 0); let editTransport = ResumeTestTransport()
    editTransport.prepareBody = { _ in editRelease.wait() }
    let editCoordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { editTransport }, defaults: prefs,
        ledgerURL: editRoot.appendingPathComponent("support/resume-attempts.json"), codexHome: editRoot)
    let editState = AppState(provider: usage, defaults: prefs, runtimeURL: editRoot.appendingPathComponent("support/runtime.json"), codexHome: editRoot, execution: editCoordinator, startMonitoring: false)
    editState.refresh(manual: true); try await resumeWait { editState.availableTasks.count == 1 && !editState.usage.refreshing }
    let editable = editState.availableTasks.first!
    editState.resolveRecoveryDecision(.now, for: [editable]); try await resumeWait { editTransport.prepared }
    editState.setMessage(editable, "changed while preparing"); editRelease.signal()
    try await resumeWait { !editCoordinator.running }
    check(!editTransport.submitted && !editCoordinator.hasAttempted(editable) && editState.choices.message(for: editable, default: "") == "changed while preparing",
        "editing one preparing task cancels its stale queued content before commitment while preserving the new text")

    let runtimeRoot = root.appendingPathComponent("runtime-storage")
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true); try resumeDatabase(runtimeRoot)
    let storagePending = try resumeFixture(root: runtimeRoot)
    let runtimeURL = runtimeRoot.appendingPathComponent("support/runtime.json")
    try resumePendingChoice(storagePending, account: usage.account, runtime: runtimeURL)
    let runtimeRelease = DispatchSemaphore(value: 0); var runtimeTransports: [ResumeTestTransport] = []
    let runtimeCoordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: {
        let transport = ResumeTestTransport()
        if runtimeTransports.isEmpty { transport.prepareBody = { _ in runtimeRelease.wait() } }
        runtimeTransports.append(transport); return transport
    }, defaults: prefs, ledgerURL: runtimeRoot.appendingPathComponent("support/resume-attempts.json"), codexHome: runtimeRoot)
    let runtimeState = AppState(provider: usage, defaults: prefs, runtimeURL: runtimeURL, codexHome: runtimeRoot, execution: runtimeCoordinator, startMonitoring: false)
    runtimeState.refresh(manual: true); try await resumeWait { runtimeState.availableTasks.count == 1 && !runtimeState.usage.refreshing }
    let runtimeTarget = runtimeState.availableTasks.first!
    runtimeState.resolveRecoveryDecision(.now, for: [runtimeTarget]); try await resumeWait { runtimeTransports.first?.prepared == true }
    try FileManager.default.removeItem(at: runtimeURL); try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: false)
    let ignored = runtimeState.ignoreEpisode(runtimeTarget); runtimeRelease.signal()
    try await resumeWait { runtimeTransports.first?.submitted == true || !runtimeCoordinator.running }
    check(!ignored && runtimeTransports.first?.submitted == false && !runtimeCoordinator.hasAttempted(runtimeTarget) && runtimeState.availableTasks.count == 1,
        "failed ignore persistence preserves the row and stops an already prepared request before submission")
    if runtimeTransports.first?.submitted == true { runtimeTransports.first?.finish(); try await resumeWait { !runtimeCoordinator.hasBusyTasks } }
    try FileManager.default.removeItem(at: runtimeURL); runtimeState.recompute(allowExecution: false)
    runtimeState.retry(runtimeTarget)
    if runtimeTransports.first?.submitted == false {
        try await resumeWait { runtimeTransports.count == 2 && runtimeTransports[1].submitted }
        check(runtimeTransports.filter(\.submitted).count == 1, "restored pause storage permits a fresh single explicit retry")
        runtimeTransports[1].respond(); runtimeTransports[1].finish(); try await resumeWait { !runtimeCoordinator.hasBusyTasks }
    }

    let storageRoot = root.appendingPathComponent("storage")
    try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true); try resumeDatabase(storageRoot)
    let storageTarget = try resumeFixture(root: storageRoot)
    let ledger = storageRoot.appendingPathComponent("support/resume-attempts.json")
    let storageTransport = ResumeTestTransport()
    let storageCoordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { storageTransport }, defaults: prefs, ledgerURL: ledger, codexHome: storageRoot)
    try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
    storageCoordinator.resume([ResumeRequest(target: storageTarget, prompt: "test only", accountID: usage.account, workspace: nil)], schedule: schedule, manual: true)
    try await resumeWait { !storageCoordinator.running }
    check(!storageTransport.submitted && !storageCoordinator.hasAttempted(storageTarget) && storageCoordinator.recordingFailure != nil,
        "atomic intent save failure sends nothing and does not claim the episode")
    try FileManager.default.removeItem(at: ledger); storageCoordinator.retryPersistence()

    let postRoot = root.appendingPathComponent("post-storage")
    try FileManager.default.createDirectory(at: postRoot, withIntermediateDirectories: true); try resumeDatabase(postRoot)
    let postTarget = try resumeFixture(root: postRoot)
    let postLedger = postRoot.appendingPathComponent("support/resume-attempts.json")
    let postTransport = ResumeTestTransport()
    let postCoordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { postTransport }, defaults: prefs, ledgerURL: postLedger, codexHome: postRoot)
    postCoordinator.resume([ResumeRequest(target: postTarget, prompt: "test only", accountID: usage.account, workspace: nil)], schedule: schedule, manual: true)
    try await resumeWait { postCoordinator.operations.values.first?.phase == .confirming }
    try FileManager.default.removeItem(at: postLedger); try FileManager.default.createDirectory(at: postLedger, withIntermediateDirectories: false)
    postTransport.respond(); try await resumeWait { postCoordinator.recordingFailure != nil }
    check(postCoordinator.hasAttempted(postTarget) && postCoordinator.hasBusyTasks && !postTransport.cancelled && postCoordinator.operations.values.first?.respondedAt != nil,
        "post-submission recording failure preserves startup fact and live carrier while blocking new content")
    try FileManager.default.removeItem(at: postLedger); postCoordinator.retryPersistence()
    check(postCoordinator.recordingFailure == nil && (try? Data(contentsOf: postLedger)) != nil,
        "restored storage durably repairs pending submission evidence")
    postTransport.finish(); try await resumeWait { !postCoordinator.hasBusyTasks }

    let eventRoot = root.appendingPathComponent("event-storage")
    try FileManager.default.createDirectory(at: eventRoot, withIntermediateDirectories: true); try resumeDatabase(eventRoot)
    let eventTarget = try resumeFixture(root: eventRoot)
    let eventLedger = eventRoot.appendingPathComponent("support/resume-attempts.json")
    let eventTransport = ResumeTestTransport()
    let eventCoordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { eventTransport }, defaults: prefs, ledgerURL: eventLedger, codexHome: eventRoot)
    eventCoordinator.resume([ResumeRequest(target: eventTarget, prompt: "test only", accountID: usage.account, workspace: nil)], schedule: schedule, manual: true)
    try await resumeWait { eventCoordinator.operations.values.first?.receivedAt != nil }
    let eventFile = eventLedger.deletingLastPathComponent().appendingPathComponent("execution-events.jsonl")
    try FileManager.default.removeItem(at: eventFile); try FileManager.default.createDirectory(at: eventFile, withIntermediateDirectories: false)
    eventTransport.respond(); try await resumeWait { eventCoordinator.recordingFailure != nil }
    let eventRestarted = ExecutionCoordinator(provider: usage, defaults: prefs, ledgerURL: eventLedger, codexHome: eventRoot)
    check(eventRestarted.confirmations.count == 1 && eventRestarted.confirmations.first?.operationID == eventCoordinator.operations.values.first?.id,
        "durable first-response fact rebuilds associated history after startup event logging fails and the app restarts")
    try FileManager.default.removeItem(at: eventFile); eventCoordinator.retryPersistence()
    check(eventCoordinator.recordingFailure == nil && eventCoordinator.confirmations.count == 1,
        "successful event repair removes recording issue and keeps one startup history entry")
    eventTransport.finish(); try await resumeWait { !eventCoordinator.hasBusyTasks }
}

@MainActor private func checkResumeIgnoredEpisodes(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try resumeDatabase(root)
    let stop = Date().addingTimeInterval(-15)
    let first = try resumeFixture(root: root, stop: stop, turn: "pause-A")
    let suite = "keeper.resume.ignore." + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": false, "dailyAnchorMinutes": 480, "resumeWorkspaceReminder": false])
    let usage = ResumeTestUsage()
    let execution = ExecutionCoordinator(provider: usage, defaults: prefs, ledgerURL: root.appendingPathComponent("support/resume-attempts.json"), codexHome: root)
    let runtime = root.appendingPathComponent("support/pending-runtime.json")
    var state = AppState(provider: usage, defaults: prefs, runtimeURL: runtime, codexHome: root, execution: execution, startMonitoring: false)
    state.refresh(manual: true)
    try await resumeWait { state.availableTasks.count == 1 && state.displayAccountID == usage.account }
    let original = state.availableTasks.first!
    let beforeIgnore = state.choices
    check(state.availableTasks.count == 1 && state.choices == beforeIgnore, "opening or cancelling ignore confirmation does not change the pause")
    check(state.ignoreEpisode(original) && state.availableTasks.isEmpty && execution.operations.isEmpty,
        "confirmed ignore removes only this pause after saving without submitting or deleting task")
    state = AppState(provider: usage, defaults: prefs, runtimeURL: runtime, codexHome: root, execution: execution, startMonitoring: false)
    state.refresh(manual: true); try await resumeWait { state.sessions.hasScanned && !state.usage.refreshing }
    state.recompute(allowExecution: false)
    check(state.availableTasks.isEmpty && state.choices.ignoredEpisodes?.contains(original.episodeKey) == true,
        "ignored pause survives restart without a thread blacklist")
    let drift = try resumeFixture(root: root, id: first.id, stop: stop.addingTimeInterval(1), turn: "pause-A")
    state.sessions.refresh(); try await resumeWait { state.sessions.sessions.first?.quotaBlockedAt == drift.blockedAt }
    state.recompute(allowExecution: false)
    check(state.blockedSessions.first?.episodeKey == original.episodeKey && state.blockedSessions.first?.blockedAt == original.blockedAt && state.availableTasks.isEmpty,
        "timestamp drift and repeated same-turn errors retain stable ignored identity")
    let manualStart = Date().addingTimeInterval(-5)
    let newStop = Date().addingTimeInterval(-2)
    let handle = try FileHandle(forWritingTo: first.fileURL); try handle.seekToEnd()
    try handle.write(contentsOf: resumeEvent("task_started", turn: "pause-B", at: manualStart))
    try handle.write(contentsOf: resumeEvent("error", turn: "pause-B", at: newStop, extras: ["message": "usage_limit_reached"]))
    try handle.close()
    state.sessions.refresh(); try await resumeWait { state.sessions.sessions.first?.currentTurnID == "pause-B" }
    state.recompute(allowExecution: false)
    let next = state.availableTasks.first
    check(next?.episodeKey != original.episodeKey && next?.stoppedTurnID == "pause-B" && state.selectedTasks.count == 1,
        "manual continuation followed by true new quota stop re-enters normal selected recovery flow")
    check(next.map { state.choices.ignoredEpisodes?.contains($0.episodeKey) == false && state.choices.recoveryDecisions?[$0.episodeKey] == nil && state.choices.messageModes?[$0.episodeKey] == nil } == true,
        "new pause inherits neither ignore nor old choice or authorization")
    var db: OpaquePointer?
    sqlite3_open(root.appendingPathComponent("logs_1.sqlite").path, &db)
    let driftedStop = newStop.addingTimeInterval(5)
    let body = "turn_id=pause-B session_task.run:run_turn: Turn error: You've hit your usage limit."
    let escapedBody = body.replacingOccurrences(of: "'", with: "''")
    sqlite3_exec(db, "INSERT INTO logs VALUES(1, \(Int(driftedStop.timeIntervalSince1970)), 0, 'codex_core::session::turn', '\(first.id)', '\(escapedBody)')", nil, nil, nil)
    sqlite3_close(db)
    let combined = try SessionWatcher.freshBlockedSessions(codexHome: root)
    check(combined.first?.stoppedTurnID == "pause-B" && combined.first?.blockedAt == next?.blockedAt,
        "database stop time cannot override matching rollout quota stop")
    let lines = try String(contentsOf: first.fileURL, encoding: .utf8).split(separator: "\n").filter { line in
        let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        return (entry?["payload"] as? [String: Any])?["type"] as? String != "error"
    }
    try (lines.joined(separator: "\n") + "\n").write(to: first.fileURL, atomically: true, encoding: .utf8)
    state.sessions.refresh(); try await resumeWait { state.sessions.sessions.first?.quotaBlockedAt == Date(timeIntervalSince1970: floor(driftedStop.timeIntervalSince1970)) }
    state.recompute(allowExecution: false)
    check(state.availableTasks.first?.episodeKey == next?.episodeKey && state.availableTasks.first?.blockedAt == next?.blockedAt,
        "switching to database-only evidence preserves the existing stable pause and time")

    usage.setAccount("other-account"); state.usage.refresh(manual: true)
    try await resumeWait { state.displayAccountID == "other-account" }
    check(state.availableTasks.isEmpty && state.visibleOperations.isEmpty, "reliable account switch isolates prior account task facts")
    usage.setAccount("resume-state-account"); state.usage.refresh(manual: true)
    try await resumeWait { state.displayAccountID == "resume-state-account" }
    state.recompute(allowExecution: false)
    check(state.availableTasks.first?.episodeKey == next?.episodeKey && state.choices.ignoredEpisodes?.contains(original.episodeKey) == true,
        "switching back restores original account pause decisions and ignored history")
    let quota = try usage.read(); let baseline = ResumeQuotaEvidence(quota)!
    var same = quota; same.capturedAt = quota.capturedAt.addingTimeInterval(2)
    check(!baseline.provesRecovery(same, after: quota.capturedAt.addingTimeInterval(1)),
        "recapturing identical available quota cannot authorize an immediate quota retry loop")
    var fluctuating = same; fluctuating.fiveHour?.usedPercent = max(0, (quota.fiveHour?.usedPercent ?? 0) - 1)
    check(!baseline.provesRecovery(fluctuating, after: quota.capturedAt.addingTimeInterval(1)),
        "a lower non-exhausted reading in the same window cannot prove a new quota pause recovered")
    let nextReset = same.fiveHour!.resetsAt.addingTimeInterval(300)
    same.fiveHour?.resetsAt = nextReset
    check(baseline.provesRecovery(same, after: quota.capturedAt.addingTimeInterval(1)), "new reliable quota window can prove a later pause recovered")
}

@MainActor private func checkResumeManualReadAndRestart(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try resumeDatabase(root)
    let target = try resumeFixture(root: root, turn: "manual-stop")
    let suite = "keeper.resume.manual." + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": false, "dailyAnchorMinutes": 480, "resumeWorkspaceReminder": false])
    let usage = ResumeTestUsage()
    let transport = ResumeTestTransport()
    let ledger = root.appendingPathComponent("support/resume-attempts.json")
    let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { transport }, defaults: prefs, ledgerURL: ledger, codexHome: root)
    let runtime = root.appendingPathComponent("support/pending-runtime.json")
    var state = AppState(provider: usage, defaults: prefs, runtimeURL: runtime, codexHome: root, execution: coordinator, startMonitoring: false)
    state.refresh(manual: true)
    try await resumeWait { state.displayAccountID == usage.account && state.availableTasks.count == 1 }
    coordinator.resume([ResumeRequest(target: target, prompt: "test only", accountID: usage.account, workspace: nil)], schedule: ScheduleEngine(anchorMinutes: 480), manual: true)
    try await resumeWait { coordinator.operations.values.first?.receivedAt != nil }
    transport.finish(.manualRequired)
    try await resumeWait { state.currentOperations.first?.needsManualContinuation == true }
    let operation = state.currentOperations.first!
    let fact = ResumeTaskFact.make(task: target, operation: operation)
    check(fact.text == L10n.text("需要手动继续，请到 Codex 查看原任务。") && operation.respondedAt == nil && coordinator.confirmations.isEmpty,
        "manual stop before actual startup shows failed sending without inventing continued time")
    var menu = MenuSummary(headline: "23:06", action: "保持活动", isTime: true)
    menu.applyResumeTasks(operations: state.currentOperations, pending: state.availableTasks, choices: state.choices)
    check(menu.headline == "需要手动继续" && menu.tasks.first == L10n.format("%d 个任务需到 Codex 手动继续", 1) &&
        !menu.tasks.joined().contains("发送失败"), "manual reminder main area and task bubble contain only required action and count")
    state.markManualEventsRead(["unrelated-event"])
    check(!state.currentOperations.isEmpty, "viewing unrelated history cannot consume another manual reminder")
    state.markManualEventsRead([operation.id])
    check(state.currentOperations.isEmpty && state.visibleOperations.count == 1 && coordinator.hasAttempted(target) && coordinator.confirmations.isEmpty,
        "viewing actual ended record consumes only its reminder, preserves history and does not approve or resume")
    state = AppState(provider: usage, defaults: prefs, runtimeURL: runtime, codexHome: root, execution: coordinator, startMonitoring: false)
    state.refresh(manual: true); try await resumeWait { state.displayAccountID == usage.account && state.sessions.hasScanned }
    check(state.currentOperations.isEmpty && state.taskOperations(ids: [operation.id]).count == 1,
        "manual reminder read state survives restart and historical detail stays readable")
    check(state.ignoreEpisode(target) && state.visibleOperations.isEmpty && state.taskOperations(ids: [operation.id]).isEmpty && coordinator.operations.count == 1,
        "ignore hides current and historical detail rows while retaining underlying execution record")

    let restartRoot = root.appendingPathComponent("restart-observation")
    try FileManager.default.createDirectory(at: restartRoot, withIntermediateDirectories: true); try resumeDatabase(restartRoot)
    let restartTarget = try resumeFixture(root: restartRoot, turn: "old-stop")
    let activeTransport = ResumeTestTransport()
    let sourceLedger = restartRoot.appendingPathComponent("support/resume-attempts.json")
    let active = ExecutionCoordinator(provider: usage, makeResumeTransport: { activeTransport }, defaults: prefs, ledgerURL: sourceLedger, codexHome: restartRoot)
    active.resume([ResumeRequest(target: restartTarget, prompt: "test only", accountID: usage.account, workspace: nil)], schedule: ScheduleEngine(anchorMinutes: 480), manual: true)
    try await resumeWait { active.operations.values.first?.phase == .confirming }
    activeTransport.event(.awaiting); try await resumeWait { !active.running }
    let copiedLedger = restartRoot.appendingPathComponent("restarted/resume-attempts.json")
    try FileManager.default.createDirectory(at: copiedLedger.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contentsOf: sourceLedger).write(to: copiedLedger)
    try Data(contentsOf: sourceLedger.deletingLastPathComponent().appendingPathComponent("execution-events.jsonl")).write(to: copiedLedger.deletingLastPathComponent().appendingPathComponent("execution-events.jsonl"))
    let restarted = ExecutionCoordinator(provider: usage, defaults: prefs, ledgerURL: copiedLedger, codexHome: restartRoot)
    check(!restarted.running && restarted.operations.values.first?.phase == .checking && restarted.hasAttempted(restartTarget) && restarted.protectedPaths.contains(restartTarget.fileURL),
        "restart restores unconfirmed turn guard and monitoring path without waiting for entire project completion")
    let targetTurn = "turn-" + restartTarget.id
    let file = try FileHandle(forWritingTo: restartTarget.fileURL); try file.seekToEnd()
    try file.write(contentsOf: resumeEvent("task_started", turn: targetTurn, at: Date()))
    try file.write(contentsOf: resumeEvent("agent_message", turn: targetTurn, at: Date(), extras: ["message": "real response"]))
    try file.close()
    restarted.reconcile(sessions: [SessionWatcher.parse(url: restartTarget.fileURL, mtime: Date())!], scannedAt: Date(), healthy: true)
    check(restarted.operations.values.first?.respondedAt != nil && restarted.confirmations.count == 1 && restarted.hasBusyTasks,
        "healthy exact-turn scan supplements late startup once and retains running handoff protection")
    let finish = try FileHandle(forWritingTo: restartTarget.fileURL); try finish.seekToEnd()
    try finish.write(contentsOf: resumeEvent("task_complete", turn: targetTurn, at: Date()))
    try finish.close()
    restarted.reconcile(sessions: [SessionWatcher.parse(url: restartTarget.fileURL, mtime: Date())!], scannedAt: Date(), healthy: true)
    check(!restarted.hasBusyTasks && restarted.confirmations.count == 1, "exact terminal scan releases restarted protection without duplicating startup history")
    activeTransport.finish(); try await resumeWait { !active.hasBusyTasks }

    let pastRoot = root.appendingPathComponent("past-unknown")
    try FileManager.default.createDirectory(at: pastRoot, withIntermediateDirectories: true); try resumeDatabase(pastRoot)
    let pastTarget = try resumeFixture(root: pastRoot)
    let past = ResumeOperation(id: "past-unknown", batchID: "past-unknown", accountID: usage.account, target: pastTarget,
        actionAt: pastTarget.blockedAt.addingTimeInterval(1), phase: .checking, protectsThread: true)
    let pastLedger = pastRoot.appendingPathComponent("support/resume-attempts.json")
    try FileManager.default.createDirectory(at: pastLedger.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([past]))
    try JSONSerialization.data(withJSONObject: ["version": 1, "keys": [], "operations": encoded]).write(to: pastLedger)
    let later = try FileHandle(forWritingTo: pastTarget.fileURL); try later.seekToEnd()
    try later.write(contentsOf: resumeEvent("task_started", turn: "later-manual-turn", at: Date()))
    try later.write(contentsOf: resumeEvent("task_complete", turn: "later-manual-turn", at: Date()))
    try later.close()
    let pastCoordinator = ExecutionCoordinator(provider: usage, defaults: prefs, ledgerURL: pastLedger, codexHome: pastRoot)
    let pastState = AppState(provider: usage, defaults: prefs, runtimeURL: pastRoot.appendingPathComponent("support/runtime.json"), codexHome: pastRoot, execution: pastCoordinator, startMonitoring: false)
    pastState.refresh(manual: true); try await resumeWait { pastState.displayAccountID == usage.account && pastState.sessions.hasScanned }
    pastState.recompute(allowExecution: false)
    check(!pastCoordinator.hasBusyTasks && pastState.currentOperations.isEmpty && pastState.visibleOperations.count == 1 && pastCoordinator.confirmations.isEmpty,
        "verified later lifecycle releases old unknown active reminder while preserving unconfirmed history without claiming success")

    let first = ResumeOperation(id: "one", batchID: "batch", accountID: usage.account, target: target,
        actionAt: Date().addingTimeInterval(-20), phase: .continued, turnID: "one-turn", respondedAt: Date().addingTimeInterval(-10), protectsThread: true)
    var second = first; second = ResumeOperation(id: "two", batchID: "batch", accountID: usage.account,
        target: BlockedSession(id: UUID().uuidString, project: "Secret reason", cwd: root.path, blockedAt: target.blockedAt,
            fiveHourResetAt: nil, weeklyResetAt: nil, fileURL: target.fileURL), actionAt: Date(), phase: .notSubmitted,
        failure: "Secret reason", protectsThread: false)
    var summary = MenuSummary(headline: "正在继续")
    summary.applyResumeTasks(operations: [first, second], pending: [], choices: ResumeChoices())
    check(summary.taskProgress == L10n.format("已继续 %d/%d", 1, 2) && summary.tasksNeedAttention && summary.headline == "正在继续" && !summary.tasks.joined().contains("Secret"),
        "progress stays in task bubble while headline omits score and failure details")
    var sending = second; sending.phase = .sending; sending.failure = nil
    var confirming = first; confirming.phase = .confirming; confirming.respondedAt = nil
    summary.applyResumeTasks(operations: [sending, confirming], pending: [], choices: ResumeChoices())
    check(summary.taskProgress == L10n.format("已继续 %d/%d", 0, 2) && !summary.tasksNeedAttention,
        "normal sending and confirmation keep their normal tone with the continued count")
    var needsChoice = ResumeChoices(); needsChoice.requestRecoveryDecision(for: target, now: Date())
    summary.applyResumeTasks(operations: [], pending: [target], choices: needsChoice)
    check(summary.tasksNeedAttention && summary.taskProgress.isEmpty,
        "a recovery choice needs attention without inventing a started batch")
    summary.applyResumeTasks(operations: [], pending: [], choices: ResumeChoices())
    check(summary.tasks.isEmpty && summary.taskProgress.isEmpty && !summary.tasksNeedAttention, "all confirmed startup tasks remove current record bubble")
    let fixed = Date().addingTimeInterval(-1800)
    let snapshot = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: fixed.addingTimeInterval(18000)), weekly: nil,
        capturedAt: Date(), accountID: usage.account, sourceFile: "app-server", zeroUseWindowActive: true)
    let schedule = ScheduleEngine(anchorMinutes: 480)
    let plan = DecisionEngine(schedule: schedule).plan(now: snapshot.capturedAt, enabled: true, autoResume: false, earlyRecoveryPolicy: "ask", usage: snapshot, blocked: [])
    let initial = MenuSummary.build(plan: plan, usage: snapshot, schedule: schedule, tasks: [], now: snapshot.capturedAt)
    let continued = MenuSummary.build(plan: plan, usage: snapshot, schedule: schedule, tasks: [], confirmations: [ExecutionConfirmation(kind: .resume,
        actionAt: fixed, confirmedAt: fixed.addingTimeInterval(1), windowStart: nil, accountID: usage.account)], now: snapshot.capturedAt)
    let unscoped = MenuSummary.build(plan: plan, usage: snapshot, schedule: schedule, tasks: [], confirmations: [ExecutionConfirmation(kind: .resume,
        actionAt: fixed, confirmedAt: fixed.addingTimeInterval(1), windowStart: nil)], now: snapshot.capturedAt)
    check(unscoped.timeline.first?.kind != .completedResume,
        "legacy nil-account confirmation is preserved on disk but cannot claim a new account's window")
    let sameTime = first.actionAt
    var history = MenuSummary(timeline: [MenuTimelinePoint(date: sameTime, time: "18:05", day: "", label: "已保活", kind: .completedKeepAlive, solidBefore: false),
        MenuTimelinePoint(date: sameTime, time: "18:05", day: "", label: "已继续", kind: .completedResume, solidBefore: false)])
    history.applyResumeHistory([first], accountID: usage.account, confirmations: [ExecutionConfirmation(kind: .resume,
        actionAt: sameTime, confirmedAt: first.respondedAt!, windowStart: nil, accountID: usage.account,
        operationID: first.id, episodeKey: first.target.episodeKey, threadID: first.target.id, turnID: first.turnID)])
    check(history.timeline[0].operationIDs.isEmpty && history.timeline[1].operationIDs == [first.id],
        "keepalive history cannot absorb nearby resume rows and resume history uses exact operation association")
    history.applyResumeHistory([first, second], accountID: usage.account, confirmations: [ExecutionConfirmation(kind: .resume,
        actionAt: sameTime, confirmedAt: first.respondedAt!, windowStart: nil, accountID: usage.account,
        operationID: first.id, episodeKey: first.target.episodeKey, threadID: first.target.id, turnID: first.turnID)])
    check(history.timeline[1].operationIDs == [first.id, second.id] && second.respondedAt == nil,
        "a continuation history entry opens its real batch including an unsent peer without claiming that peer continued")
    var stopped = operation; stopped.phase = .stopped; stopped.terminal = .failed
    var stoppedSummary = MenuSummary(headline: "23:06", isTime: true)
    stoppedSummary.applyResumeTasks(operations: [stopped], pending: [], choices: ResumeChoices())
    stoppedSummary.timeline = [MenuTimelinePoint(date: Date().addingTimeInterval(3600), time: "23:06", day: "", label: "保活", kind: .keepAlive, solidBefore: false)]
    stoppedSummary.applyResumeHistory([stopped], accountID: usage.account)
    check(stoppedSummary.tasks.first == L10n.format("%d 个任务续跑已停止", 1) && stoppedSummary.timeline.contains { $0.kind == .resumeRecord && $0.operationIDs.contains(stopped.id) },
        "received then failed task remains reviewable without implying automatic resend or confirmed startup")
    var noPlanHistory = MenuSummary(headline: "正在同步", isSyncing: true)
    noPlanHistory.applyResumeHistory([operation], accountID: usage.account)
    check(noPlanHistory.timeline.contains { $0.isHistory && $0.operationIDs.contains(operation.id) },
        "ended manual record remains reachable while quota and a future plan are unavailable")
    var continuedWithoutPlan = MenuSummary(headline: "正在同步", isSyncing: true)
    continuedWithoutPlan.applyResumeHistory([first], accountID: usage.account)
    check(continuedWithoutPlan.timeline.contains { $0.kind == .completedResume && $0.operationIDs.contains(first.id) },
        "persisted real startup retains a history entry without relying on a fresh quota window")
    var retainedPresentation = MenuPresentation()
    let beforeReading = retainedPresentation.build(plan: plan, usage: snapshot, schedule: schedule, tasks: [], availableTasks: [],
        choices: ResumeChoices(), now: snapshot.capturedAt)
    var readChoices = ResumeChoices(); readChoices.readManualEvents = [operation.id]
    let synchronizingPlan = NextAction(mode: .keepAlive, date: nil, decision: .wait(reason: "等待额度同步"), note: "等待额度同步")
    let afterReading = retainedPresentation.build(plan: synchronizingPlan, usage: nil, schedule: schedule, tasks: [], availableTasks: [],
        choices: readChoices, usageError: "temporary connection failure", usageErrorIsTransient: true,
        now: snapshot.capturedAt.addingTimeInterval(61))
    check(!afterReading.quotas.isEmpty && afterReading.headline == beforeReading.headline && afterReading.refreshMessage == beforeReading.refreshMessage,
        "reading a manual reminder never discards retained quota, its capture time or a valid future plan")
    check(initial.badge == continued.badge && initial.action == continued.action && initial.statusText == continued.statusText && initial.statusSymbol == continued.statusSymbol,
        "window classification and primary reset or keepalive display stay stable across resume confirmation")
}

func resumeTestAttemptKeys(_ url: URL) throws -> [String] {
    let data = try Data(contentsOf: url)
    if let keys = try? JSONDecoder().decode([String].self, from: data) { return keys }
    let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let operations = try JSONDecoder().decode([ResumeOperation].self, from: JSONSerialization.data(withJSONObject: envelope["operations"]!))
    return (envelope["keys"] as? [String] ?? []) + operations.filter { $0.phase != .preparing && $0.phase != .notSubmitted }.map { $0.target.episodeKey }
}

@MainActor private func checkPingPreflightDiagnostics(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    let scenarios: [(String, Int, [String])] = [
        ("generation", 1, ["generation_changed"]), ("disabled", 1, ["disabled"]), ("anchor", 1, ["anchor_changed"]),
        ("account", 1, ["account_changed"]), ("missing-account", 1, ["account_unconfirmed"]), ("empty-account", 1, ["account_unconfirmed"]), ("stale-account", 1, ["account_unconfirmed"]),
        ("generation", 2, ["generation_changed"]), ("disabled", 2, ["disabled"]), ("anchor", 2, ["anchor_changed"]),
        ("pause", 2, ["new_pause"]), ("stale", 2, ["usage_not_fresh"]), ("future", 2, ["usage_not_fresh"]),
        ("timezone", 2, ["timezone_changed"]), ("expired", 2, ["opportunity_expired"]),
        ("drift-expired", 2, ["opportunity_expired"]), ("node", 2, ["node_changed"]),
        ("expired", 1, ["opportunity_expired"]), ("drift-expired", 1, ["opportunity_expired"]),
        ("mixed-hard", 1, ["critical_refresh", "account_changed"]),
        ("multiple", 2, ["critical_refresh", "codex_task_running", "generation_changed", "disabled", "anchor_changed", "usage_not_fresh"])
    ] + ["runtime_unhealthy", "sessions_unscanned", "session_scan_failed", "critical_refresh", "keeper_busy", "codex_task_running", "task_selection_changed", "app_state_unavailable"].flatMap { reason in
        [(reason, 1, [reason]), (reason, 2, [reason])]
    }
    for (name, stage, expected) in scenarios {
        let directory = root.appendingPathComponent("\(name)-\(stage)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try resumeDatabase(directory)
        let suite = "keeper.preflight." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.register(defaults: ["enabled": true, "dailyAnchorMinutes": 480])
        var schedule = ScheduleEngine(anchorMinutes: 480)
        let nodes = schedule.nodes(on: Date())
        let node = name == "drift-expired" ? nodes[1] : nodes[0]
        if name == "drift-expired" {
            schedule.accountID = "preflight-secret-account"
            schedule.confirmedWindows = [KeepAliveWindowEvidence(accountID: "preflight-secret-account", node: nodes[0], windowReset: node.addingTimeInterval(90),
                confirmedAt: nodes[0].addingTimeInterval(90), anchorMinutes: 480, timeZoneID: schedule.timeZoneID)]
        }
        let opportunity = schedule.keepAliveOpportunities(at: node).first { $0.node == node }!
        var clock = name.hasSuffix("expired") ? opportunity.deadline.addingTimeInterval(-0.5) : node.addingTimeInterval(name == "node" ? 1 : 10)
        let started = clock
        func idle() -> UsageSnapshot {
            UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: clock.addingTimeInterval(18000)), weekly: nil,
                capturedAt: clock, accountID: "preflight-secret-account", sourceFile: "app-server", zeroUseWindowActive: false)
        }
        var before = idle()
        if name == "account" || name == "stale-account" { before.accountID = "other-secret-account" }
        if name == "stale-account" { before.capturedAt = clock.addingTimeInterval(-61) }
        if name == "missing-account" { before.accountID = nil }
        if name == "empty-account" { before.accountID = " " }
        let usage = RecoveryTestUsage(snapshot: before)
        let pings = ReminderTestPing()
        let ledger = directory.appendingPathComponent("support/attempts.json")
        let coordinator = ExecutionCoordinator(provider: usage, defaults: prefs, ledgerURL: ledger, pingTransport: pings, codexHome: directory, now: { clock })
        let state = name == "critical_refresh" && stage == 1 ? AppState(provider: usage, defaults: prefs,
            runtimeURL: directory.appendingPathComponent("support/runtime.json"), codexHome: directory, execution: coordinator, startMonitoring: false, now: { clock }) : nil
        if name == "pause" { _ = try resumeFixture(root: directory, stop: started.addingTimeInterval(-1)) }
        if name == "timezone" { schedule.timeZoneID = "fixture-other-timezone" }
        var calls = 0
        var recovered = false
        let blockers: () -> [PingPreflightReason] = {
            calls += 1
            guard !recovered, calls == stage else { return [] }
            switch name {
            case "generation": coordinator.cancelCurrent()
            case "disabled": prefs.set(false, forKey: "enabled"); return []
            case "anchor": prefs.set(481, forKey: "dailyAnchorMinutes")
            case "stale": clock = before.capturedAt.addingTimeInterval(60.001)
            case "future": clock = before.capturedAt.addingTimeInterval(-5.001)
            case "expired", "drift-expired": clock = opportunity.deadline.addingTimeInterval(0.001)
            case "node": clock = node.addingTimeInterval(-0.001)
            case "mixed-hard": return [.criticalRefresh, .accountChanged]
            case "multiple":
                coordinator.cancelCurrent(); prefs.set(false, forKey: "enabled"); prefs.set(481, forKey: "dailyAnchorMinutes")
                clock = before.capturedAt.addingTimeInterval(61)
                return [.criticalRefresh, .codexTaskRunning]
            default: break
            }
            return PingPreflightReason(rawValue: name).map { [$0] } ?? []
        }
        coordinator.ping(schedule: schedule, accountID: "preflight-secret-account", blockers: blockers)
        try await resumeWait { !coordinator.running }
        if name.hasSuffix("expired"), stage == 1 {
            check(coordinator.visibleNotice == PingPreflightReason.opportunityExpired.userMessage,
                "quota preparation crossing the opportunity deadline leaves a visible missed-keepalive result: \(name)")
        }
        if let state {
            try await Task.sleep(nanoseconds: 50_000_000)
            check(usage.readCount == 1 && !state.usage.refreshing && !state.usage.criticalRefreshPending,
                "ordinary ping preflight does not trigger AppState's successful-execution critical refresh")
            state.usage.stop(); state.sessions.stop()
        }
        let events = directory.appendingPathComponent("support/execution-events.jsonl")
        let log = try String(contentsOf: events, encoding: .utf8)
        let rows = try log.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let diagnostic = rows.last?["preflight"] as? [String: Any]
        check(diagnostic?["stage"] as? String == (stage == 1 ? "after_usage" : "before_send") && diagnostic?["reasons"] as? [String] == expected,
            "production ping preflight retains every specific reason at checkpoint \(stage): \(name)")
        check(pings.count == 0 && !rows.contains { $0["event"] as? String == "started" } && ((try? resumeTestAttemptKeys(ledger)) ?? []).isEmpty,
            "preflight failure has no transport send, started event or attempt commitment: \(name)-\(stage)")
        let deadline = (diagnostic?["opportunityDeadline"] as? String).flatMap(UsageDecoder.timestamp)
        let opportunityStart = (diagnostic?["opportunityStartsAt"] as? String).flatMap(UsageDecoder.timestamp)
        let checkedAt = (diagnostic?["checkedAt"] as? String).flatMap(UsageDecoder.timestamp)
        let age = diagnostic?["usageAgeSeconds"] as? Double
        let elapsed = diagnostic?["elapsedSeconds"] as? Double
        check(deadline == opportunity.deadline && opportunityStart == opportunity.date && checkedAt.map { abs($0.timeIntervalSince(clock)) < 0.001 } == true &&
            age.map { abs($0 - clock.timeIntervalSince(before.capturedAt)) < 0.00001 } == true && elapsed.map { $0 >= 0 } == true,
            "preflight evidence preserves quota age and the original node's actual opportunity including drift: \(name)-\(stage)")
        if name == "pause" { check(diagnostic?["newPauseCount"] as? Int == 1, "new pause diagnostics store only the blocking pause count") }
        check(!log.contains("secret-account") && !log.contains(directory.path) && !log.contains("usage_limit_reached"),
            "preflight diagnostics omit account identity, task content and workspace paths: \(name)-\(stage)")
        check(coordinator.lastFailure != "状态已改变，取消本次保活" && coordinator.lastFailure != "保活条件已改变，等待重新确认",
            "preflight UI uses a concrete reason: \(name)-\(stage)")

        let attention = ["account", "missing-account", "empty-account", "stale-account", "runtime_unhealthy", "session_scan_failed", "app_state_unavailable", "mixed-hard"].contains(name)
        check(coordinator.lastFailure != nil && (coordinator.visibleFailure != nil) == attention && (coordinator.visibleNotice != nil) != attention,
            "ping waits preserve the internal outcome signal while only hard blockers appear as failures: \(name)-\(stage)")
        if !attention {
            var presentation = MenuPresentation()
            let menu = presentation.build(plan: nil, usage: nil, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(),
                executionFailure: coordinator.visibleFailure, executionNotice: coordinator.visibleNotice, now: clock)
            check(menu.note.contains(coordinator.status) && !menu.note.contains("失败") && menu.warning.isEmpty && menu.statusSymbol != "exclamationmark.circle",
                "normal ping wait and missed opportunity remain visible as an ordinary note: \(name)-\(stage)")
        }
        if name == "mixed-hard" {
            check(coordinator.lastFailure == CodexConnectionError.userMessage(reason: "account_changed"),
                "a normal ping refresh cannot hide a simultaneous account blocker")
        }
        recovered = true; clock = started; prefs.set(true, forKey: "enabled"); prefs.set(480, forKey: "dailyAnchorMinutes")
        schedule.timeZoneID = Calendar.current.timeZone.identifier; usage.set(idle())
        if name == "pause" {
            for file in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sessions"), includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: file)
            }
        }
        coordinator.ping(schedule: schedule, accountID: "preflight-secret-account", blockers: blockers)
        try await resumeWait { !coordinator.running }
        coordinator.ping(schedule: schedule, accountID: "preflight-secret-account", blockers: blockers)
        try await resumeWait { !coordinator.running }
        check(pings.count == 1 && coordinator.confirmations.filter { $0.kind == .keepAlive }.count == 1 && (try? resumeTestAttemptKeys(ledger))?.count == 1,
            "recovered preflight can retry once and successful original-node commitment prevents a duplicate: \(name)-\(stage)")
    }
    try await checkAppKeepAliveBlockers(root.appendingPathComponent("app-blockers"), check)
}

@MainActor private func checkAppKeepAliveBlockers(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try resumeDatabase(root)
    let clock = Date()
    let usage = RecoveryTestUsage(snapshot: UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: clock.addingTimeInterval(18000)), weekly: nil,
        capturedAt: clock, accountID: "blocker-account", sourceFile: "app-server", zeroUseWindowActive: false))
    let suite = "keeper.app-blockers." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": false, "autoResume": true, "dailyAnchorMinutes": 480])
    let state = AppState(provider: usage, defaults: prefs, runtimeURL: root.appendingPathComponent("support/runtime.json"), codexHome: root, startMonitoring: false, now: { clock })
    check(state.keepAliveBlockers(ignoring: []).contains(.sessionsUnscanned), "AppState reports an incomplete first session scan explicitly")
    state.sessions.refresh(); try await resumeWait { state.sessions.hasScanned && !state.usage.refreshing }
    usage.pause(); state.usage.refresh(critical: true)
    try await resumeWait { state.usage.refreshing }
    check(state.keepAliveBlockers(ignoring: []).contains(.criticalRefresh) && !state.keepAliveBlockers(ignoring: []).contains(.codexTaskRunning),
        "real AppState distinguishes a required quota refresh from a running Codex task")
    usage.release(); try await resumeWait { !state.usage.refreshing }
    let target = try resumeFixture(root: root, stop: clock.addingTimeInterval(-1))
    state.sessions.refresh(); try await resumeWait { !state.blockedSessions.isEmpty && !state.usage.refreshing }
    check(state.keepAliveBlockers(ignoring: []).contains(.taskSelectionChanged), "real AppState identifies a pending pause outside the admitted task choices")
    var trace = try Data(contentsOf: target.fileURL)
    trace.append(try resumeEvent("task_started", turn: "running", at: clock)); try trace.write(to: target.fileURL)
    let scanned = state.sessions.scannedAt; state.sessions.refresh()
    try await resumeWait { state.sessions.scannedAt != scanned && !state.usage.refreshing }
    check(state.keepAliveBlockers(ignoring: []).contains(.codexTaskRunning) && !state.keepAliveBlockers(ignoring: []).contains(.criticalRefresh),
        "real AppState reports running Codex work after its quota refresh finishes")
    usage.pause(); state.usage.refresh(critical: true)
    check(Set(state.keepAliveBlockers(ignoring: [])).isSuperset(of: [.criticalRefresh, .codexTaskRunning]),
        "AppState preserves simultaneous task-running and quota-refresh blockers")
    usage.release(); try await resumeWait { !state.usage.refreshing }
    let invalid = root.appendingPathComponent("sessions/rollout-\(UUID().uuidString).jsonl")
    try Data([0xff]).write(to: invalid)
    let prior = state.sessions.scannedAt; state.sessions.refresh(); try await resumeWait { state.sessions.scannedAt != prior }
    check(state.keepAliveBlockers(ignoring: []).contains(.sessionScanFailed), "real AppState identifies a failed session scan independently")
    let invalidParent = root.appendingPathComponent("invalid-runtime-parent")
    try Data().write(to: invalidParent)
    let unhealthy = AppState(provider: usage, defaults: prefs, runtimeURL: invalidParent.appendingPathComponent("runtime.json"), codexHome: root,
        execution: state.execution, startMonitoring: false, now: { clock })
    check(unhealthy.keepAliveBlockers(ignoring: []).contains(.runtimeUnhealthy), "real AppState preserves persistence-health admission as its own reason")
    let busyRoot = root.appendingPathComponent("busy")
    try FileManager.default.createDirectory(at: busyRoot, withIntermediateDirectories: true)
    let busyLedger = busyRoot.appendingPathComponent("attempts.json")
    try JSONEncoder().encode([target.episodeKey]).write(to: busyLedger)
    let busyExecution = ExecutionCoordinator(provider: usage, defaults: prefs, ledgerURL: busyLedger, codexHome: root)
    let busyState = AppState(provider: usage, defaults: prefs, runtimeURL: busyRoot.appendingPathComponent("runtime.json"), codexHome: root,
        execution: busyExecution, startMonitoring: false, now: { clock })
    check(busyState.keepAliveBlockers(ignoring: []).contains(.keeperBusy), "real AppState identifies existing Keeper continuation ownership")
    state.usage.stop(); state.sessions.stop(); unhealthy.usage.stop(); unhealthy.sessions.stop(); busyState.usage.stop(); busyState.sessions.stop()
}

@MainActor private func checkResumeEvidenceAudit(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try resumeDatabase(root)
    let target = try resumeFixture(root: root)
    var empty = ResumeTurnMonitor(turnID: "audit-turn")
    check(try !empty.consume(resumeEvent("task_complete", turn: "audit-turn", at: Date())) && empty.responseAt == nil,
        "empty rollout completion cannot fabricate a real model response")
    var nullError = ResumeTurnMonitor(turnID: "audit-turn")
    do {
        let responded = try nullError.consume(resumeEvent("task_complete", turn: "audit-turn", at: Date(), extras: ["error": NSNull(), "last_agent_message": "real output"]))
        check(responded, "rollout completion with real response and error null is a successful model response")
    } catch { check(false, "rollout completion with real response and error null is a successful model response") }
    let client = ResumeTestClient(target)
    let transport = AppServerResumeTransport(makeTransport: { client }, observationSeconds: 0.05)
    let events = ResumeTestEvents(); try transport.prepare(target); try transport.submit(target, prompt: "test only", update: events.consume)
    client.send("turn/completed", extras: ["turn": ["id": client.turnID, "status": "completed", "items": [], "error": NSNull()]])
    try await resumeWait { client.closed }
    check(events.responded == 0 && events.terminal == .completed, "empty app-server completion ends the carrier without fabricating startup")
    let suite = "keeper.resume.audit." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": true, "resumeWorkspaceReminder": false])
    let usage = ResumeTestUsage(); usage.setAccount("other-account")
    let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { ResumeTestTransport() }, defaults: prefs, ledgerURL: root.appendingPathComponent("support/attempts.json"), codexHome: root)
    coordinator.resume([ResumeRequest(target: target, prompt: "test only", accountID: "original-account", workspace: nil)], schedule: ScheduleEngine(anchorMinutes: 480), manual: true)
    try await resumeWait { !coordinator.running }
    let log = try String(contentsOf: root.appendingPathComponent("support/execution-events.jsonl"), encoding: .utf8)
    let rows = try log.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    let preflight = rows.last?["preflight"] as? [String: Any]
    check(preflight?["stage"] as? String == "quota_check" && preflight?["reasons"] as? [String] == ["account_changed"],
        "resume preflight records reliable account mismatch at the quota checkpoint instead of a combined error")
}

@MainActor private func checkResumeEvidenceBoundaries(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try resumeDatabase(root)
    for (name, extras, responds, terminal) in [
        ("empty", [String: Any](), false, ResumeTerminal.completed),
        ("null", ["error": NSNull()], false, .completed),
        ("text", ["error": NSNull(), "last_agent_message": "real response"], true, .completed),
        ("failure", ["error": ["message": "usage_limit_reached"]], false, .quotaStopped)
    ] {
        let target = try resumeFixture(root: root)
        let desktop = FakeDesktopConnection()
        desktop.onStart = {
            let file = try FileHandle(forWritingTo: target.fileURL); defer { try? file.close() }; try file.seekToEnd()
            try file.write(contentsOf: resumeEvent("task_complete", turn: "desktop-turn", at: Date(), extras: extras))
        }
        let fallback = ResumeTestTransport()
        let transport = OwnedSessionResumeTransport(makeDesktop: { desktop }, fallback: fallback, observationSeconds: 0.2)
        let events = ResumeTestEvents(); try transport.prepare(target); try transport.submit(target, prompt: "test only", update: events.consume)
        try await resumeWait { responds ? events.responded == 1 : events.terminal != nil }
        check(events.responded == (responds ? 1 : 0) && (responds || events.terminal == terminal) && !fallback.prepared && events.awaiting == 0,
            "real owned transport handles completion evidence without waiting or changing channels: \(name)")
    }
    let target = try resumeFixture(root: root)
    for (name, items, error, responds, terminal) in [
        ("empty", [[String: Any]](), NSNull() as Any, false, ResumeTerminal.completed),
        ("placeholder", [["type": "agentMessage", "id": "a", "text": " "]], NSNull() as Any, false, .completed),
        ("message", [["type": "agentMessage", "id": "a", "text": "real response"]], NSNull() as Any, true, .completed),
        ("reasoning", [["type": "reasoning", "id": "r", "summary": ["real reasoning"], "content": []]], NSNull() as Any, true, .completed),
        ("tool", [["type": "mcpToolCall", "id": "m", "status": "completed", "error": NSNull()]], NSNull() as Any, true, .completed),
        ("pending-tool", [["type": "dynamicToolCall", "id": "m", "status": "inProgress"]], NSNull() as Any, false, .completed),
        ("missing-status", [["type": "mcpToolCall", "id": "m"]], NSNull() as Any, false, .completed),
        ("failure", [], ["message": "real error"] as Any, false, .failed)
    ] {
        let client = ResumeTestClient(target); let transport = AppServerResumeTransport(makeTransport: { client }, observationSeconds: 0.05)
        let events = ResumeTestEvents(); try transport.prepare(target); try transport.submit(target, prompt: "test only", update: events.consume)
        client.send("turn/completed", extras: ["turn": ["id": client.turnID, "status": "completed", "items": items, "error": error]])
        try await resumeWait { client.closed }
        check(events.responded == (responds ? 1 : 0) && events.terminal == terminal, "real app-server transport requires actual completion content: \(name)")
    }
    let suite = "keeper.resume.evidence." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": true, "resumeWorkspaceReminder": false])
    let usage = ResumeTestUsage(); let client = ResumeTestClient(target); var carriers = 0
    let ledger = root.appendingPathComponent("support/attempts.json")
    let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { carriers += 1; return AppServerResumeTransport(makeTransport: { client }) }, defaults: prefs, ledgerURL: ledger, codexHome: root)
    let request = ResumeRequest(target: target, prompt: "test only", accountID: usage.account, workspace: nil)
    coordinator.resume([request], schedule: ScheduleEngine(anchorMinutes: 480), manual: true)
    try await resumeWait { coordinator.operations.values.first?.receivedAt != nil }
    client.send("turn/completed", extras: ["turn": ["id": client.turnID, "status": "completed", "items": [], "error": NSNull()]])
    try await resumeWait { !coordinator.running }
    coordinator.resume([request], schedule: ScheduleEngine(anchorMinutes: 480), manual: true)
    check(coordinator.operations.values.first?.respondedAt == nil && coordinator.confirmations.isEmpty && carriers == 1 && coordinator.hasAttempted(target),
        "empty real completion never creates startup confirmation and still preserves the submitted attempt guard")
    let file = try FileHandle(forWritingTo: target.fileURL); try file.seekToEnd()
    try file.write(contentsOf: resumeEvent("task_started", turn: client.turnID, at: Date()))
    try file.write(contentsOf: resumeEvent("task_complete", turn: client.turnID, at: Date(), extras: ["error": NSNull()]))
    try file.close()
    let session = SessionWatcher.parse(url: target.fileURL, mtime: Date())!
    check(session.turns[client.turnID]?.terminal == .completed && session.turns[client.turnID]?.responseAt == nil,
        "session scan treats error null as successful termination without inventing model activity")
    coordinator.reconcile(sessions: [session], scannedAt: Date(), healthy: true)
    check(coordinator.confirmations.isEmpty && coordinator.operations.values.first?.respondedAt == nil,
        "healthy restart reconciliation cannot turn an empty completion into startup confirmation")
    let text = try FileHandle(forWritingTo: target.fileURL); try text.seekToEnd()
    try text.write(contentsOf: resumeEvent("task_complete", turn: client.turnID, at: Date(), extras: ["last_agent_message": "real response", "error": NSNull()])); try text.close()
    coordinator.reconcile(sessions: [SessionWatcher.parse(url: target.fileURL, mtime: Date())!], scannedAt: Date(), healthy: true)
    check(coordinator.confirmations.count == 1, "exact-turn scan can recover real completion text without duplicate confirmation")
}

@MainActor private func checkResumePreflightAudit(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    let cases: [(String, String, [String])] = [
        ("workspace", "session_check", ["workspace_unavailable"]), ("archived", "session_check", ["archived"]),
        ("unreadable", "session_check", ["session_unreadable"]), ("thread", "session_check", ["thread_changed"]), ("subagent", "session_check", ["subagent"]),
        ("user", "session_check", ["user_input_after_pause"]), ("started", "session_check", ["task_started_after_pause", "task_running"]),
        ("aborted", "session_check", ["task_aborted_after_pause"]), ("response", "session_check", ["model_response_after_pause"]),
        ("running", "session_check", ["task_running"]), ("pause", "pause_check", ["pause_changed"]),
        ("missing-account", "quota_check", ["account_unconfirmed"]), ("empty-account", "quota_check", ["account_unconfirmed"]),
        ("stale-account", "quota_check", ["account_unconfirmed", "usage_not_fresh", "usage_before_pause"]),
        ("old-usage", "quota_check", ["usage_not_fresh", "usage_before_pause"]), ("future-usage", "quota_check", ["usage_not_fresh"]),
        ("before-pause", "quota_check", ["usage_before_pause"]), ("quota-missing", "quota_check", ["quota_missing"]),
        ("five-missing", "quota_check", ["five_hour_missing"]), ("week-missing", "quota_check", ["weekly_missing"]),
        ("exhausted", "quota_check", ["five_hour_exhausted", "weekly_exhausted"]), ("recovery", "quota_check", ["recovery_unconfirmed"]),
        ("generation", "before_send", ["generation_changed"]), ("slow-final-check", "before_send", ["usage_not_fresh"]),
        ("timezone", "before_send", ["timezone_changed"]), ("policy", "before_send", ["policy_changed"]),
        ("anchor", "before_send", ["anchor_changed"]), ("auto-off", "before_send", ["auto_resume_disabled"]), ("disabled", "before_send", ["disabled"]),
        ("multiple", "before_send", ["generation_changed", "selection_changed", "prompt_changed", "policy_changed", "anchor_changed"])
    ]
    for (name, stage, expected) in cases {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try resumeDatabase(directory)
        var clock = ScheduleEngine(anchorMinutes: 480).nodes(on: Date())[0].addingTimeInterval(10); let started = clock
        let original = try resumeFixture(root: directory, stop: clock.addingTimeInterval(-5))
        var target = original
        let originalTrace = try Data(contentsOf: target.fileURL)
        func copyTarget(cwd: String? = nil, file: URL? = nil, five: Bool = false, week: Bool = false) -> BlockedSession {
            var value = BlockedSession(id: original.id, project: original.project, cwd: cwd ?? original.cwd, blockedAt: original.blockedAt,
                fiveHourResetAt: five ? clock.addingTimeInterval(3600) : nil, weeklyResetAt: week ? clock.addingTimeInterval(3600) : nil, fileURL: file ?? original.fileURL)
            value.stoppedTurnID = original.stoppedTurnID; value.pauseID = original.pauseID; value.startedBarrierAt = original.startedBarrierAt
            return value
        }
        func append(_ type: String, extras: [String: Any] = [:]) throws {
            var trace = try Data(contentsOf: original.fileURL); trace.append(try resumeEvent(type, turn: "new-turn", at: clock, extras: extras)); try trace.write(to: original.fileURL)
        }
        switch name {
        case "workspace": target = copyTarget(cwd: directory.appendingPathComponent("missing").path)
        case "archived":
            let archive = directory.appendingPathComponent("archived_sessions/trace.jsonl"); try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try originalTrace.write(to: archive); target = copyTarget(file: archive)
        case "unreadable": try Data([0xff]).write(to: original.fileURL)
        case "thread", "subagent":
            var lines = String(decoding: originalTrace, as: UTF8.self).split(separator: "\n").map { Data($0.utf8) }
            var row = try JSONSerialization.jsonObject(with: lines[0]) as! [String: Any]; var payload = row["payload"] as! [String: Any]
            if name == "thread" { payload["id"] = UUID().uuidString } else { payload["source"] = ["subagent": "test-only"] }
            row["payload"] = payload; lines[0] = try JSONSerialization.data(withJSONObject: row)
            var trace = Data(); for line in lines { trace.append(line); trace.append(10) }; try trace.write(to: original.fileURL)
        case "user": try append("user_message", extras: ["message": "fixture-only-input"])
        case "started": try append("task_started")
        case "aborted": try append("turn_aborted")
        case "response": try append("agent_message", extras: ["message": "fixture-only-output"])
        case "running":
            let prefix = String(decoding: originalTrace, as: UTF8.self).split(separator: "\n").dropLast().joined(separator: "\n") + "\n"
            var trace = Data(prefix.utf8); trace.append(try resumeEvent("error", turn: "original", at: clock, extras: ["will_retry": true, "message": "service error"])); try trace.write(to: original.fileURL)
        case "pause": _ = try resumeFixture(root: directory, id: original.id, stop: clock.addingTimeInterval(-1), turn: "different-stop")
        case "five-missing": target = copyTarget(five: true)
        case "week-missing": target = copyTarget(week: true)
        default: break
        }
        var live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: clock.addingTimeInterval(3600)),
            weekly: nil, capturedAt: clock, accountID: "audit-account", sourceFile: "app-server", zeroUseWindowActive: true)
        switch name {
        case "missing-account": live.accountID = nil
        case "empty-account": live.accountID = " "
        case "stale-account": live.accountID = "other-account"; live.capturedAt = clock.addingTimeInterval(-60.001)
        case "old-usage": live.capturedAt = clock.addingTimeInterval(-60.001)
        case "future-usage": live.capturedAt = clock.addingTimeInterval(5.001)
        case "before-pause": live.capturedAt = target.blockedAt
        case "quota-missing": live.fiveHour = nil
        case "five-missing": live.weekly = live.fiveHour; live.fiveHour = nil
        case "exhausted": live.fiveHour?.usedPercent = 100; live.weekly = live.fiveHour
        case "recovery": target.retryQuota = ResumeQuotaEvidence(live)
        default: break
        }
        let usage = RecoveryTestUsage(snapshot: live)
        let suite = "keeper.preflight.audit." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.register(defaults: ["enabled": true, "autoResume": true, "dailyAnchorMinutes": 480, "resumeWorkspaceReminder": false])
        var schedule = ScheduleEngine(anchorMinutes: 480); if name == "timezone" { schedule.timeZoneID = "fixture-other-zone" }
        var transports: [ResumeTestTransport] = []
        let ledger = directory.appendingPathComponent("support/attempts.json")
        let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { let transport = ResumeTestTransport(); transports.append(transport); return transport }, defaults: prefs,
            ledgerURL: ledger, codexHome: directory, now: { clock })
        var recovered = false
        let blockers: (String) -> [ResumePreflightReason] = { _ in
            guard !recovered else { return [] }
            switch name {
            case "generation": coordinator.cancelCurrent()
            case "slow-final-check": clock = started.addingTimeInterval(60.001)
            case "policy": prefs.set("keepPlan", forKey: "earlyRecoveryPolicy")
            case "anchor": prefs.set(481, forKey: "dailyAnchorMinutes")
            case "auto-off": prefs.set(false, forKey: "autoResume")
            case "disabled": prefs.set(false, forKey: "enabled")
            case "multiple": coordinator.cancelCurrent(); prefs.set("keepPlan", forKey: "earlyRecoveryPolicy"); prefs.set(481, forKey: "dailyAnchorMinutes"); return [.selectionChanged, .promptChanged]
            default: break
            }
            return []
        }
        let request = ResumeRequest(target: target, prompt: "fixture-only-prompt", accountID: "audit-account", workspace: nil, observedRecovery: true)
        coordinator.resume([request], schedule: schedule, manual: name != "recovery" && name != "auto-off", blockers: blockers)
        try await resumeWait { !coordinator.running }
        let operation = coordinator.operations.values.first
        check(operation?.preflight?.stage.rawValue == stage && operation?.preflight?.reasons.map(\.rawValue) == expected,
            "production resume admission distinguishes every failed condition: \(name)")
        check(transports.count == 1 && !transports[0].submitted && !coordinator.hasAttempted(target) && ((try? resumeTestAttemptKeys(ledger)) ?? []).isEmpty,
            "rejected resume never sends or commits attempt protection: \(name)")
        let log = try String(contentsOf: directory.appendingPathComponent("support/execution-events.jsonl"), encoding: .utf8)
        check(!log.contains("\"event\":\"started\"") && log.contains("\"preflight\""), "unsent resume persists structured diagnostics without started: \(name)")
        let rows = try log.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        guard let diagnostic = rows.first?["preflight"] as? [String: Any] else {
            check(false, "missing preflight record for case: \(name); phase=\(operation?.phase.rawValue ?? "none")")
            coordinator.stopOwnedTasks()
            continue
        }
        let safe = String(decoding: try JSONSerialization.data(withJSONObject: diagnostic), as: UTF8.self)
        check(!safe.contains(directory.path) && !safe.contains("audit-account") && !safe.contains("fixture-only"), "resume preflight fields contain only classification and time evidence: \(name)")
        check(operation?.preflight?.elapsedSeconds.map { $0 >= 0 } == true && operation?.preflight?.pauseAt == target.blockedAt,
            "resume diagnostic retains timing and exact pause provenance: \(name)")
        if name == "slow-final-check" {
            check(operation?.preflight?.usageAgeSeconds.map { abs($0 - 60.001) < 0.0001 } == true && operation?.preflight?.checkedAt == clock,
                "slow final admission cannot borrow an earlier timestamp to pass the 60-second quota boundary")
        }
        recovered = true; clock = started; prefs.set(true, forKey: "enabled"); prefs.set(true, forKey: "autoResume"); prefs.set(480, forKey: "dailyAnchorMinutes"); prefs.removeObject(forKey: "earlyRecoveryPolicy")
        schedule.timeZoneID = Calendar.current.timeZone.identifier
        try originalTrace.write(to: original.fileURL)
        live.fiveHour = QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: clock.addingTimeInterval(3600)); live.weekly = nil; live.accountID = "audit-account"; live.capturedAt = clock; usage.set(live)
        let retry = ResumeRequest(target: original, prompt: "fixture-only-prompt", accountID: "audit-account", workspace: nil)
        coordinator.resume([retry], schedule: schedule, manual: true, blockers: blockers)
        try await resumeWait { transports.count == 2 && transports[1].submitted }
        check(transports.count == 2 && transports[1].submitted, "recovered resume preflight can be retried normally: \(name)")
        transports[1].respond(); transports[1].finish(); try await resumeWait { !coordinator.running }
        coordinator.resume([retry], schedule: schedule, manual: true)
        check(transports.count == 2 && coordinator.confirmations.count == 1, "successful recovered resume is confirmed once and never resent: \(name)")
    }
}

private struct AuditFailureUsage: UsageProvider {
    let snapshot: UsageSnapshot
    let mode: String
    func read() throws -> UsageSnapshot {
        if mode == "usage" { throw UsageReadFailure(underlying: CodexConnectionError.timeout,
            diagnostic: UsageReadDiagnostic(requestStage: "rate_limits", rpcAttempted: true, cooldown: false, elapsedMilliseconds: 10, reason: "request_timeout")) }
        return snapshot
    }
    func pingModel() throws -> PingModel {
        if mode == "model" { throw UsageReadFailure(underlying: CodexConnectionError.server("failed to connect Authorization: Bearer fixture-secret"),
            diagnostic: UsageReadDiagnostic(requestStage: "provider", rpcAttempted: true, cooldown: false, elapsedMilliseconds: 10, reason: "connection_failed")) }
        return PingModel(model: "gpt-6-luna", reasoningEffort: "low")
    }
}

@MainActor private func checkPreparationFailureStages(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    for (mode, stage, reason) in [("model", "model_discovery", "model_discovery_failed"), ("usage", "usage_read", "usage_read_failed"), ("scan", "session_scan", "session_scan_failed")] {
        let directory = root.appendingPathComponent(mode)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sessions"), withIntermediateDirectories: true); try resumeDatabase(directory)
        let schedule = ScheduleEngine(anchorMinutes: 480); let clock = schedule.nodes(on: Date())[0].addingTimeInterval(10)
        let live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: clock.addingTimeInterval(18000)), weekly: nil,
            capturedAt: clock, accountID: "audit-account", sourceFile: "app-server", zeroUseWindowActive: false)
        let usage = AuditFailureUsage(snapshot: live, mode: mode)
        if mode == "scan" { try Data([0xff]).write(to: directory.appendingPathComponent("sessions/rollout-\(UUID().uuidString).jsonl")) }
        let suite = "keeper.preparation-stage." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.register(defaults: ["enabled": true, "dailyAnchorMinutes": 480])
        let pings = ReminderTestPing(); let ledger = directory.appendingPathComponent("support/attempts.json")
        let coordinator = ExecutionCoordinator(provider: usage, defaults: prefs, ledgerURL: ledger, pingTransport: pings, codexHome: directory, now: { clock })
        coordinator.ping(schedule: schedule, accountID: "audit-account", blockers: { [] }); try await resumeWait { !coordinator.running }
        let log = try String(contentsOf: directory.appendingPathComponent("support/execution-events.jsonl"), encoding: .utf8)
        let row = try JSONSerialization.jsonObject(with: Data(log.split(separator: "\n").last!.utf8)) as! [String: Any]
        let diagnostic = row["preflight"] as? [String: Any]; let failure = diagnostic?["failure"] as? [String: Any]
        check(diagnostic?["stage"] as? String == stage && diagnostic?["reasons"] as? [String] == [reason] && failure?["reason"] != nil,
            "ping preparation errors retain their actual checkpoint and sanitized classification: \(mode)")
        check((mode == "usage" ? coordinator.status == L10n.text("正在确认中") && coordinator.visibleFailure == nil : coordinator.status.contains("，") && coordinator.visibleFailure != nil) &&
            !coordinator.status.contains("\n") && (row["error"] as? String)?.contains("\n") == false,
            "ping preparation separates transient waiting from actionable hints while retaining its original diagnostic: \(mode)")
        check(mode == "usage" ? failure?["rpcAttempted"] as? Bool == true : failure?["rpcAttempted"] == nil,
            "only explicit quota RPC evidence is retained; model discovery does not borrow quota RPC status: \(mode)")
        check(pings.count == 0 && !log.contains("fixture-secret") && !log.contains("Authorization") && !FileManager.default.fileExists(atPath: ledger.path),
            "preparation failures neither send nor persist raw errors or attempt keys: \(mode)")
    }
    let directory = root.appendingPathComponent("resume-read")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try resumeDatabase(directory)
    let target = try resumeFixture(root: directory)
    for error in [CodexConnectionError.unavailable, .invalidResponse, .approvalRequired] {
        let diagnostic = ResumePreflightDiagnostic(stage: .usageRead, reasons: [.preparationFailed], target: target, checkedAt: Date(),
            failure: UsageReadFailure.describe(error, elapsed: 0))
        check(diagnostic.errorDescription == error.errorDescription,
            "resume preparation preserves the precise existing message: \(UsageReadFailure.describe(error, elapsed: 0).reason)")
    }
    let usage = AuditFailureUsage(snapshot: UsageSnapshot(fiveHour: nil, weekly: nil, capturedAt: Date(), accountID: "audit-account", sourceFile: "app-server"), mode: "usage")
    let suite = "keeper.resume-read-stage." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "resumeWorkspaceReminder": false])
    let transport = ResumeTestTransport()
    let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { transport }, defaults: prefs, ledgerURL: directory.appendingPathComponent("support/attempts.json"), codexHome: directory)
    coordinator.resume([ResumeRequest(target: target, prompt: "test only", accountID: "audit-account", workspace: nil)], schedule: ScheduleEngine(anchorMinutes: 480), manual: true)
    try await resumeWait { !coordinator.running }
    check(coordinator.operations.values.first?.preflight?.stage == .usageRead && coordinator.lastFailure?.contains("连接失败") == true && !transport.submitted,
        "resume quota failures preserve a concrete timeout message and their real read checkpoint")
}

@MainActor private func checkResumeAppBlockers(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try resumeDatabase(root)
    let target = try resumeFixture(root: root)
    let suite = "keeper.resume-app-blockers." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": false, "autoResume": true, "resumeWorkspaceReminder": false])
    let runtime = root.appendingPathComponent("support/runtime.json")
    try resumePendingChoice(target, account: "resume-state-account", runtime: runtime)
    let state = AppState(provider: ResumeTestUsage(), defaults: prefs, runtimeURL: runtime, codexHome: root, startMonitoring: false)
    state.sessions.refresh(); try await resumeWait { state.sessions.hasScanned && !state.usage.refreshing }
    let expected = ResumeRequest(target: target, prompt: L10n.text("继续"), accountID: "resume-state-account", workspace: nil, messageMode: .localizedDefault)
    func blockers(_ value: AppState = state) -> [ResumePreflightReason] { value.resumeBlockers(key: target.episodeKey, intended: expected, admitted: true, manual: true) }
    check(blockers().contains(.recoveryChoiceChanged), "AppState distinguishes an unapproved recovery choice from task selection")
    state.setSelected(target, false)
    check(blockers().contains(.selectionChanged), "AppState exposes task selection changes explicitly")
    state.setSelected(target, true); state.setMessageMode(target, .fixed); state.setMessage(target, "fixture-only-new-prompt")
    check(Set(blockers()).isSuperset(of: [.messageModeChanged, .promptChanged]), "AppState retains simultaneous message-option and message-body changes")
    prefs.set(false, forKey: "autoResume")
    check(blockers().contains(.autoResumeDisabled), "AppState exposes the automatic continuation switch independently")
    try Data([0xff]).write(to: root.appendingPathComponent("sessions/rollout-\(UUID().uuidString).jsonl"))
    let scanned = state.sessions.scannedAt; state.sessions.refresh(); try await resumeWait { state.sessions.scannedAt != scanned }
    check(blockers().contains(.sessionScanFailed), "AppState exposes scan health rather than combining it with selection")
    let parent = root.appendingPathComponent("invalid-runtime-parent"); try Data().write(to: parent)
    let unhealthy = AppState(provider: ResumeTestUsage(), defaults: prefs, runtimeURL: parent.appendingPathComponent("runtime.json"), codexHome: root, execution: state.execution, startMonitoring: false)
    check(blockers(unhealthy).contains(.runtimeUnhealthy), "AppState exposes persistence health as a distinct resume blocker")
    state.usage.stop(); state.sessions.stop(); unhealthy.usage.stop(); unhealthy.sessions.stop()
}

@MainActor private func checkActionableMessageBoundaries(_ target: BlockedSession, _ check: (Bool, String) -> Void) throws {
    for corruptLedger in [true, false] {
        let directory = URL(fileURLWithPath: target.cwd).appendingPathComponent("message-storage-" + UUID().uuidString)
        let ledger = directory.appendingPathComponent("resume-attempts.json")
        if corruptLedger {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("invalid ledger".utf8).write(to: ledger)
        } else { try Data().write(to: directory) }
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ExecutionCoordinator(provider: ResumeTestUsage(), ledgerURL: ledger, codexHome: URL(fileURLWithPath: target.cwd))
        check(!coordinator.canStartResume && coordinator.recordingFailure?.contains("反馈") == true &&
            coordinator.recordingFailure?.contains("刷新") == false && coordinator.recordingFailure?.contains("已在运行") == false,
            "unreadable records and unavailable lock files give a real recovery path without inventing another instance")
    }
    let legacy = ResumeOperation(id: "copy", batchID: "copy", accountID: nil, target: target, actionAt: Date(), phase: .notSubmitted,
        failure: "fixture-only technical failure", protectsThread: false)
    check(ResumeTaskFact.make(task: target, operation: legacy).text == L10n.text("发送未完成，请先在 Codex 检查原任务。"),
        "legacy failed operations show a safe action rather than raw diagnostic text")
    var draft = legacy
    draft.preflight = ResumePreflightDiagnostic(stage: .promptRead, reasons: [.preparationFailed], target: target, checkedAt: Date())
    check(ResumeTaskFact.make(task: target, operation: draft).text.contains("默认发送") && draft.failure == legacy.failure,
        "unsent draft failure points to the real message option while retaining diagnostic history")
    var pending = legacy; pending.phase = .checking; pending.protectsThread = true
    let pendingText = ResumeTaskFact.make(task: target, operation: pending).text
    check(pendingText == L10n.text("正在确认中") && pending.protectsThread, "uncertain submitted results wait without recommending a resend or releasing protection")
    let unknown = PingDiagnostic(elapsedSeconds: 180, warningSeconds: 90, timeoutSeconds: 180)
    check(unknown.failureMessage.contains("刷新查看额度") && !unknown.failureMessage.contains("重试") && !unknown.failureMessage.contains("网络") && !unknown.failureMessage.contains("OK"),
        "unknown ping results suggest checking quota without inventing a network cause or a resend action")
    do { try AppServerUsageProvider.requireChatGPT(["account": ["type": "apiKey"]]); check(false, "unsupported login must fail") }
    catch {
        check(error.localizedDescription.contains("ChatGPT") && !error.localizedDescription.contains("API") && CodexConnectionError.diagnosticDescription(for: error).contains("API key"),
            "unsupported sign-in has a simple action while detailed login diagnostics remain available")
    }
    check(CodexConnectionError.server("unknown service problem").localizedDescription.contains("Codex") &&
        !CodexConnectionError.server("unknown service problem").localizedDescription.contains("网络"), "unknown service errors do not guess a network fix")
}

private func checkConfirmationPresentation(_ target: BlockedSession, _ check: (Bool, String) -> Void) {
    for (reason, received) in [(PingFailureReason.requestTimeout, false), (.unknown, false), (.unknown, true)] {
        var diagnostic = PingDiagnostic(elapsedSeconds: 90, warningSeconds: 90, timeoutSeconds: 180)
        diagnostic.reason = reason; diagnostic.okReceived = received
        check(diagnostic.warning == L10n.text("正在确认中"), "every in-progress ping uses the same waiting message: \(reason)-\(received)")
    }
    let start = Date()
    var operation = ResumeOperation(id: "presentation", batchID: "presentation", accountID: nil, target: target,
        actionAt: start, phase: .preparing, protectsThread: false, manual: false)
    for phase in [ResumePhase.preparing, .sending, .confirming, .checking] {
        operation.phase = phase
        let fact = ResumeTaskFact.make(task: target, operation: operation)
        var menu = MenuSummary(); menu.applyResumeTasks(operations: [operation], pending: [], choices: ResumeChoices())
        check(fact.text == L10n.text("正在确认中") && fact.isConfirming && !menu.tasksNeedAttention &&
            menu.tasks == [L10n.format("%d 个任务正在确认中", 1)], "all ongoing resume phases share one neutral confirmation state: \(phase)")
    }
    operation.phase = .notSubmitted
    for reason in [ResumePreflightReason.usageNotFresh, .fiveHourExhausted, .recoveryUnconfirmed, .anchorChanged, .promptChanged, .taskStartedAfterPause, .modelResponseAfterPause, .taskRunning] {
        operation.preflight = ResumePreflightDiagnostic(stage: .beforeSend, reasons: [reason], target: target, checkedAt: start)
        let fact = ResumeTaskFact.make(task: target, operation: operation)
        var menu = MenuSummary(); menu.applyResumeTasks(operations: [operation], pending: [], choices: ResumeChoices())
        check(fact.symbol != "exclamationmark.circle" && !menu.tasksNeedAttention && !menu.tasks.joined().contains("发送失败"),
            "automatic waits, updated settings and existing task progress are ordinary states: \(reason)")
    }
    operation.preflight = ResumePreflightDiagnostic(stage: .quotaCheck, reasons: [.usageNotFresh, .accountChanged], target: target, checkedAt: start)
    check(ResumeTaskFact.make(task: target, operation: operation).text == CodexConnectionError.userMessage(reason: "account_changed"),
        "a normal resume wait never hides a simultaneous account blocker")
    operation.preflight = ResumePreflightDiagnostic(stage: .sessionCheck, reasons: [.taskRunning, .taskAbortedAfterPause], target: target, checkedAt: start)
    var stopped = MenuSummary(); stopped.applyResumeTasks(operations: [operation], pending: [], choices: ResumeChoices())
    check(ResumeTaskFact.make(task: target, operation: operation).text.contains("已中断") && stopped.tasksNeedAttention,
        "explicit task stop remains actionable even when mixed with ordinary progress")
    operation.preflight = ResumePreflightDiagnostic(stage: .beforeSend, reasons: [.promptChanged], target: target, checkedAt: start)
    var choices = ResumeChoices(); choices.deselectedEpisodes.insert(target.episodeKey)
    var paused = MenuSummary(); paused.applyResumeTasks(operations: [operation], pending: [], choices: choices)
    check(!paused.tasksNeedAttention && paused.tasks == [L10n.format("%d 个任务已关闭自动继续", 1)],
        "an explicitly deselected task displays its real pause rather than promising a new plan")
    check(ResumeTaskFact.make(task: target, operation: operation, selected: false, cancelled: true).text == L10n.text("已取消本次自动继续"),
        "ordinary preparation cancellation retains the existing explicit cancel choice")
    var cancelledChoices = ResumeChoices(); cancelledChoices.keepAliveEpisodes.insert(target.episodeKey)
    var cancelledMenu = MenuSummary(); cancelledMenu.applyResumeTasks(operations: [operation], pending: [], choices: cancelledChoices)
    check(!cancelledMenu.tasksNeedAttention && cancelledMenu.tasks == [L10n.format("%d 个任务已取消本次自动继续", 1)],
        "ordinary preparation summary retains the existing explicit cancel choice")
    operation.manual = true
    operation.preflight = ResumePreflightDiagnostic(stage: .quotaCheck, reasons: [.usageNotFresh], target: target, checkedAt: start)
    var manual = MenuSummary(); manual.applyResumeTasks(operations: [operation], pending: [], choices: ResumeChoices())
    check(manual.tasksNeedAttention && ResumeTaskFact.make(task: target, operation: operation).text.contains("刷新后重试"),
        "a stopped manual preparation never promises automatic recovery")
    operation.manual = false
    for reason in [ResumePreflightReason.pauseChanged, .alreadyAttempted, .taskRunning] {
        operation.preflight = ResumePreflightDiagnostic(stage: .beforeSend, reasons: [reason], target: target, checkedAt: start)
        var updated = MenuSummary(); updated.applyResumeTasks(operations: [operation], pending: [], choices: ResumeChoices())
        check(!operation.notSubmittedNeedsAttention && !operation.canRetrySubmission && !updated.tasksNeedAttention &&
            updated.tasks == [L10n.format("%d 个任务状态已更新", 1)] && !ResumeTaskFact.make(task: target, operation: operation).text.contains("已继续"),
            "old-request guards show only an updated state and never offer a resend or claim success: \(reason)")
    }
    operation.manual = nil; operation.preflight = nil
    var legacy = MenuSummary(); legacy.applyResumeTasks(operations: [operation], pending: [], choices: ResumeChoices())
    check(legacy.tasksNeedAttention, "legacy unsent operations retain conservative failure presentation")
    var ended = operation; ended.phase = .stopped; ended.endedAt = start
    let terminals: [ResumeTerminal?] = [.aborted, .failed, .completed, .disconnected, nil]
    let facts = terminals.map { terminal -> ResumeTaskFact in
        ended.terminal = terminal
        return ResumeTaskFact.make(task: target, operation: ended)
    }
    check(facts[0].text.contains("已中断") && facts[1].text.contains("继续失败") && facts[2].text.contains("未确认") &&
        facts[3].text == facts[2].text && facts[4].text == facts[2].text &&
        facts.allSatisfy { !$0.text.contains("手动") && !$0.text.contains("已继续") && !$0.isConfirming },
        "unconfirmed terminal results distinguish interruption and failure without inferring a manual stop or successful startup")
    check(terminals.allSatisfy { terminal in
        ended.terminal = terminal; ended.respondedAt = start
        let fact = ResumeTaskFact.make(task: target, operation: ended)
        return fact.symbol == "checkmark.circle.fill" && fact.text.contains("已继续") && !fact.text.contains("未确认")
    }, "confirmed startup remains visible regardless of the later terminal result")
    ended.respondedAt = nil; ended.terminal = .quotaStopped
    check(ResumeTaskFact.make(task: target, operation: ended).text == L10n.text("等待自动继续"),
        "quota stops retain their existing automatic-wait presentation")
    ended.respondedAt = start; ended.terminal = .manualRequired
    let manualFact = ResumeTaskFact.make(task: target, operation: ended)
    check(manualFact.symbol == "exclamationmark.circle" && manualFact.text.contains("已继续") && manualFact.text.contains("手动继续"),
        "an explicit manual-continuation request keeps priority while preserving confirmed startup")
}

@MainActor private func checkResumePresentationPreflight(_ root: URL, _ check: (Bool, String) -> Void) async throws {
    for (name, manual) in [("stale-auto", false), ("stale-manual", true), ("transient-auto", false), ("transient-manual", true), ("mixed-hard", false), ("plan-auto", false)] {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try resumeDatabase(directory)
        let schedule = ScheduleEngine(anchorMinutes: 480); let clock = schedule.nodes(on: Date())[0].addingTimeInterval(name == "plan-auto" ? 181 : 10)
        let target = try resumeFixture(root: directory, stop: clock.addingTimeInterval(-120))
        let live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: clock.addingTimeInterval(3600)), weekly: nil,
            capturedAt: name.hasPrefix("stale") ? clock.addingTimeInterval(-61) : clock, accountID: "audit-account", sourceFile: "app-server", zeroUseWindowActive: true)
        let usage = AuditFailureUsage(snapshot: live, mode: name.hasPrefix("transient") ? "usage" : "")
        let suite = "keeper.presentation-preflight." + UUID().uuidString; let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.register(defaults: ["enabled": true, "autoResume": true, "earlyRecoveryPolicy": "immediately", "resumeWorkspaceReminder": false])
        let transport = ResumeTestTransport()
        let coordinator = ExecutionCoordinator(provider: usage, makeResumeTransport: { transport }, defaults: prefs,
            ledgerURL: directory.appendingPathComponent("support/attempts.json"), codexHome: directory, now: { clock })
        coordinator.resume([ResumeRequest(target: target, prompt: "test only", accountID: "audit-account", workspace: nil,
            observedRecovery: true, heldForPlan: name == "plan-auto")], schedule: schedule,
            manual: manual, blockers: { _ in name == "mixed-hard" ? [.usageNotFresh, .accountChanged] : [] })
        try await resumeWait { !coordinator.running }
        guard let operation = coordinator.operations.values.first else { check(false, "presentation fixture records an operation: \(name)"); continue }
        let attention = manual || name == "mixed-hard"
        var menu = MenuSummary(); menu.applyResumeTasks(operations: [operation], pending: [], choices: ResumeChoices())
        check(coordinator.lastFailure != nil && (coordinator.visibleFailure != nil) == attention && operation.notSubmittedNeedsAttention == attention &&
            menu.tasksNeedAttention == attention && operation.canRetrySubmission == attention && !transport.submitted && !coordinator.hasAttempted(target),
            "real unsent preparation keeps internal outcome and consistent user presentation without sending: \(name)")
        if name == "plan-auto" {
            check(operation.preflight?.stage == .planCheck && operation.preflight?.reasons == [.preparationFailed] &&
                coordinator.status == L10n.text("等待下次自动继续。") && operation.failure?.contains("按计划自动继续") == true,
                "a real synchronous plan wait remains ordinary information and retains the original decision text")
            var manualPlan = operation; manualPlan.manual = true
            check(!manualPlan.notSubmittedNeedsAttention && manualPlan.canRetrySubmission &&
                manualPlan.notSubmittedMessage == L10n.text("本次未发送，请查看当前计划。"),
                "a stopped manual plan check gives an action without promising an automatic retry")
        }
        if name == "mixed-hard" {
            check(coordinator.visibleFailure == CodexConnectionError.userMessage(reason: "account_changed"), "real automatic preparation prioritizes account blockers over normal freshness waits")
        }
    }
}
