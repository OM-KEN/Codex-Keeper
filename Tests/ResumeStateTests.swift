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
    try await checkResumeTransportLifecycle(target, check)
    try await checkResumeCoordinator(root.appendingPathComponent("coordinator"), check)
    try await checkResumePingAdmission(root.appendingPathComponent("ping-admission"), check)
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
    coordinator.ping(schedule: state.schedule, accountID: state.displayAccountID, ignoredEpisodes: [target.episodeKey], ignoredTargets: [target], hasPending: { false })
    try await resumeWait { usage.modelReadCount > 0 && coordinator.running }
    state.resolveRecoveryDecision(.now, for: [target])
    check(pending != nil && state.choices.recoveryDecisions?[target.episodeKey] == pending && transports.isEmpty,
        "a now choice during keep-alive remains actionable instead of being consumed without submission")
    usage.releaseModel(); try await resumeWait { !coordinator.running }
    state.resolveRecoveryDecision(.now, for: [target]); try await resumeWait { transports.first?.submitted == true }
    check(coordinator.hasAttempted(target) && coordinator.latestOperation(for: target, accountID: state.displayAccountID)?.receivedAt != nil && transports.count == 1,
        "the preserved choice starts exactly once when keep-alive releases admission")
    transports[0].respond(); transports[0].finish(); try await resumeWait { !coordinator.hasBusyTasks }
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
    check(fact.text == L10n.text("发送失败，请到 Codex 手动继续") && operation.respondedAt == nil && coordinator.confirmations.isEmpty,
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
    check(initial.badge == continued.badge && initial.action == "保持活动" && initial.statusSymbol == "waveform.path.ecg",
        "window classification and viable keepalive primary action stay stable across resume confirmation")
}

func resumeTestAttemptKeys(_ url: URL) throws -> [String] {
    let data = try Data(contentsOf: url)
    if let keys = try? JSONDecoder().decode([String].self, from: data) { return keys }
    let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let operations = try JSONDecoder().decode([ResumeOperation].self, from: JSONSerialization.data(withJSONObject: envelope["operations"]!))
    return (envelope["keys"] as? [String] ?? []) + operations.filter { $0.phase != .preparing && $0.phase != .notSubmitted }.map { $0.target.episodeKey }
}
