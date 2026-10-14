import Foundation
import Combine
import Darwin

/// The persisted attempt is written before sending; uncertain outcomes are never retried automatically.
@MainActor final class ExecutionCoordinator: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var lastFailure: String?
    @Published private(set) var warning: String?
    @Published private(set) var activeMode: NextActionMode?
    @Published private(set) var status = L10n.text("等待计划")
    @Published private(set) var confirmations: [ExecutionConfirmation] = []
    private(set) var confirmedWindows: [KeepAliveWindowEvidence] = []
    @Published private(set) var operations: [String: ResumeOperation] = [:]
    @Published private(set) var recordingFailure: String?
    private var pingRunning = false
    private var storageFault = false
    private var pendingEventWrites: [String: (String, ResumeOperation)] = [:]
    private var permanentlyUnhealthy = false
    private var attempts: Set<String>
    private let ledgerURL: URL
    private let events: ExecutionEventLog
    private let provider: UsageProvider
    private let codexHome: URL
    private let makeResumeTransport: () -> ResumeTransport
    private let defaults: UserDefaults
    private let now: () -> Date
    private var activeTransports: [String: ResumeTransport] = [:]
    private let pingTransport: PingTransport
    private var ledgerHealthy = true
    private var generation = 0
    private var executionLock: Int32 = -1

    init(provider: UsageProvider = AppServerUsageProvider(), makeResumeTransport: @escaping () -> ResumeTransport = { OwnedSessionResumeTransport() }, defaults: UserDefaults = .standard, ledgerURL: URL? = nil, pingTransport: PingTransport = PTYPingTransport(), codexHome: URL = CodexEnvironment.home, now: @escaping () -> Date = Date.init) {
        self.codexHome = codexHome
        self.now = now
        self.pingTransport = pingTransport
        self.provider = provider
        self.makeResumeTransport = makeResumeTransport
        self.defaults = defaults
        self.ledgerURL = ledgerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexKeeper/resume-attempts.json")
        self.events = ExecutionEventLog(url: self.ledgerURL.deletingLastPathComponent().appendingPathComponent("execution-events.jsonl"))
        confirmations = events.confirmations()
        confirmedWindows = events.keepAliveWindows()
        if FileManager.default.fileExists(atPath: self.ledgerURL.path) {
            if let data = try? Data(contentsOf: self.ledgerURL), let saved = try? JSONDecoder().decode(ResumeLedger.self, from: data), saved.version == 1 {
                attempts = saved.keys; operations = Dictionary(uniqueKeysWithValues: saved.operations.map { ($0.id, $0) })
                // A short startup observation cannot survive a restart. Its submission constraint does.
                for key in operations.keys where operations[key]?.observesStartup == true {
                    operations[key]?.phase = operations[key]?.phase == .preparing ? .notSubmitted : .checking
                }
            } else if let data = try? Data(contentsOf: self.ledgerURL), let saved = try? JSONDecoder().decode([String].self, from: data) { attempts = Set(saved) }
            else { attempts = []; ledgerHealthy = false; status = L10n.text("执行记录无法读取，已暂停自动操作") }
        } else { attempts = [] }
        reloadConfirmations()
        try? FileManager.default.createDirectory(at: self.ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        executionLock = Darwin.open(self.ledgerURL.deletingLastPathComponent().appendingPathComponent("execution.lock").path, O_CREAT | O_RDWR, 0o600)
        if executionLock < 0 || flock(executionLock, LOCK_EX | LOCK_NB) != 0 {
            ledgerHealthy = false
            status = L10n.text("另一个 Keeper 实例正在管理执行")
        }
        if !ledgerHealthy { permanentlyUnhealthy = true; lastFailure = status; recordingFailure = status }
    }

    deinit { if executionLock >= 0 { Darwin.close(executionLock) } }

    /// Switching future execution off cancels only preparations and Keeper's isolated ping.
    func cancelCurrent() {
        generation += 1
        warning = nil
        for (id, transport) in activeTransports where operations[id]?.phase == .preparing { transport.cancel() }
        if pingRunning { pingTransport.cancel() }
    }

    func stopOwnedTasks() {
        cancelCurrent()
        for transport in activeTransports.values { transport.cancel() }
    }

    var independentTaskNames: [String] {
        activeTransports.compactMap { id, transport in transport.ownsSubmittedTask ? operations[id]?.target.displayName : nil }.sorted()
    }
    var protectedPaths: [URL] { Array(Set(operations.values.filter(\.protectsThread).map { $0.target.fileURL })) }
    var busyThreadIDs: Set<String> {
        let legacy = attempts.filter { !$0.hasPrefix("ping:") }.compactMap { key -> String? in
            let id = String(key.split(separator: ":").first ?? "")
            let stop = Double(key.split(separator: ":").last ?? "").map { Date(timeIntervalSince1970: $0) } ?? .distantFuture
            return UUID(uuidString: id) != nil && !confirmations.contains(where: { $0.threadID == id && $0.confirmedAt >= stop }) ? id : nil
        }
        return Set(operations.values.filter { $0.protectsThread || $0.phase == .preparing }.map { $0.target.id }).union(legacy)
    }
    var hasBusyTasks: Bool { !busyThreadIDs.isEmpty || !independentTaskNames.isEmpty }
    var isKeepingAlive: Bool { pingRunning }
    var canStartResume: Bool { ledgerHealthy && !pingRunning && defaults.bool(forKey: "enabled") }

    private func saveLedger(operations proposed: [String: ResumeOperation]? = nil, keys: Set<String>? = nil) throws {
        let proposed = proposed ?? operations
        let keys = keys ?? attempts
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(ResumeLedger(version: 1, keys: keys, operations: proposed.values.sorted { $0.id < $1.id })).write(to: ledgerURL, options: .atomic)
        operations = proposed; attempts = keys
    }
    private func save(_ operation: ResumeOperation, afterSubmission: Bool = false) throws {
        var proposed = operations; proposed[operation.id] = operation
        do { try saveLedger(operations: proposed) }
        catch {
            if afterSubmission { operations = proposed }
            storageFault = true; ledgerHealthy = false
            recordingFailure = L10n.text("执行记录无法保存，暂停新的自动操作")
            throw error
        }
    }
    func retryPersistence() {
        guard storageFault, !permanentlyUnhealthy else { return }
        do {
            try saveLedger()
            for (key, pending) in pendingEventWrites {
                try recordEvent(pending.0, operation: pending.1)
                pendingEventWrites.removeValue(forKey: key)
            }
            storageFault = false; ledgerHealthy = true; recordingFailure = nil; reloadConfirmations()
        }
        catch { }
    }
    private func recordEvent(_ name: String, operation: ResumeOperation) throws {
        do {
            try events.record(name, kind: "resume", node: nil, error: operation.failure, threadID: operation.target.id,
                turnID: operation.turnID, accountID: operation.accountID, operationID: operation.id, episodeKey: operation.target.episodeKey,
                at: name == "startup_confirmed" ? operation.respondedAt : name == "started" ? operation.actionAt : nil)
        } catch {
            pendingEventWrites[operation.id + ":" + name] = (name, operation)
            storageFault = true; ledgerHealthy = false; recordingFailure = L10n.text("执行记录无法保存，暂停新的自动操作")
            throw error
        }
    }
    func restoreLegacyEvidence(for targets: [BlockedSession], boundAccounts: [String: String]) {
        let metadata = events.legacyResumeAttempts()
        for target in targets where attempts.contains(target.episodeKey) {
            let id = "legacy:" + target.episodeKey
            guard operations[id] == nil else { continue }
            let evidence = metadata[target.id]
            let record = ResumeOperation(id: id, batchID: id, accountID: evidence?.accountID ?? boundAccounts[target.id], target: target,
                actionAt: evidence?.startedAt ?? target.blockedAt, phase: evidence?.confirmedAt == nil ? .checking : .continued,
                turnID: evidence?.turnID, respondedAt: evidence?.confirmedAt, endedAt: evidence?.confirmedAt,
                terminal: evidence?.confirmedAt == nil ? nil : .completed, protectsThread: evidence?.confirmedAt == nil)
            do { try save(record, afterSubmission: true) } catch { }
        }
    }

    func latestOperation(for target: BlockedSession, accountID: String?) -> ResumeOperation? {
        operations.values.filter { $0.target.episodeKey == target.episodeKey && $0.accountID == accountID }.max { $0.actionAt < $1.actionAt }
    }
    func isContentLocked(_ target: BlockedSession, accountID: String?) -> Bool {
        latestOperation(for: target, accountID: accountID)?.locksContent == true
    }
    private func updateRunning() {
        let observing = operations.values.contains(where: \.observesStartup)
        running = pingRunning || observing
        if observing { activeMode = .resume; status = L10n.text("正在继续") }
        else if pingRunning { activeMode = .keepAlive }
    }

    func ping(schedule: ScheduleEngine, accountID: String?, ignoredEpisodes: Set<String> = [], ignoredTargets: [BlockedSession] = [], historicalTargets: [BlockedSession] = [], hasPending: @escaping () -> Bool) {
        guard ledgerHealthy, defaults.bool(forKey: "enabled"),
              !running, !hasBusyTasks, let node = schedule.currentKeepAliveNode(at: now()), let accountID else { return }
        let key = "ping:\(accountID):\(node.timeIntervalSince1970)"
        guard !attempts.contains(key) else { return }
        let operation = generation
        warning = nil
        lastFailure = nil
        activeMode = .keepAlive
        pingRunning = true; running = true
        status = L10n.text("正在确认保活条件…")
        let provider = provider
        let pingTransport = pingTransport
        Task {
            do {
                // Resolve capabilities before taking the final account/quota snapshot.
                let model = try await Task.detached { try provider.pingModel() }.value
                let before = try await Task.detached { try provider.read() }.value
                guard operation == generation, defaults.bool(forKey: "enabled"),
                      (defaults.object(forKey: "dailyAnchorMinutes") as? Int ?? 480) == schedule.anchorMinutes,
                      accountID == before.accountID, !hasPending() else { throw CodexConnectionError.server("状态已改变，取消本次保活") }
                let decision = DecisionEngine(schedule: schedule).decide(now: now(), enabled: true, autoResume: false, earlyRecoveryPolicy: "ask", usage: before, blocked: [])
                guard case .ping = decision else { status = decision.text; pingRunning = false; updateRunning(); return }
                let blocked = try await Task.detached { try SessionWatcher.freshBlockedSessions(codexHome: self.codexHome) }.value
                guard blocked.allSatisfy({ raw in ignoredEpisodes.contains(raw.episodeKey) || ignoredTargets.contains { ignoredEpisodes.contains($0.episodeKey) && $0.matchesPause(raw) } || historicalTargets.contains { $0.matchesPause(raw) } }), !hasPending(), operation == generation,
                      defaults.bool(forKey: "enabled"), before.isFresh(at: now()),
                      Calendar.current.timeZone.identifier == schedule.timeZoneID,
                      (defaults.object(forKey: "dailyAnchorMinutes") as? Int ?? 480) == schedule.anchorMinutes,
                      schedule.currentKeepAliveNode(at: now()) == node else { throw CodexConnectionError.server("保活条件已改变，等待重新确认") }
                try saveLedger(keys: attempts.union([key]))
                status = L10n.text("正在建立 5 小时窗口…")
                try events.record("started", kind: "ping", node: node, before: before)
                let events = events
                let after = try await Task.detached {
                    try pingTransport.ping(before: before, model: model, provider: provider) { diagnostic in
                        try? events.record("diagnostic", kind: "ping", node: node, diagnostic: diagnostic)
                        Task { @MainActor in
                            guard self.running, self.generation == operation else { return }
                            self.warning = diagnostic.outcome == "waiting" && diagnostic.elapsedSeconds >= diagnostic.warningSeconds ? diagnostic.warning : nil
                        }
                    }
                }.value
                guard PingConfirmation.accepts(before: before, after: after, now: now()) else {
                    throw CodexConnectionError.server("保活已发送，但未确认新窗口；本轮不再重试")
                }
                try events.record("confirmed", kind: "ping", node: node, before: before, after: after, schedule: schedule)
                reloadConfirmations()
                status = L10n.text("已确认新的 5 小时窗口")
            } catch {
                status = error.localizedDescription; lastFailure = status
                try? events.record("failed", kind: "ping", node: node, error: status)
            }
            warning = nil
            pingRunning = false; updateRunning()
        }
    }

    private func reloadConfirmations() {
        confirmedWindows = events.keepAliveWindows()
        let logged = events.confirmations()
        let ids = Set(logged.compactMap(\.operationID))
        let saved = operations.values.compactMap { operation -> ExecutionConfirmation? in
            guard let response = operation.respondedAt, !ids.contains(operation.id) else { return nil }
            return ExecutionConfirmation(kind: .resume, actionAt: operation.actionAt, confirmedAt: response, windowStart: nil,
                accountID: operation.accountID, operationID: operation.id, episodeKey: operation.target.episodeKey,
                threadID: operation.target.id, turnID: operation.turnID)
        }
        confirmations = (logged + saved).sorted { $0.confirmedAt < $1.confirmedAt }
    }

    func hasAttempted(_ target: BlockedSession, accountID: String? = nil) -> Bool {
        if attempts.contains(target.episodeKey) { return true }
        return operations.values.contains { (accountID == nil || $0.accountID == accountID) && $0.target.episodeKey == target.episodeKey &&
            $0.phase != .notSubmitted && $0.phase != .preparing }
    }

    /// Each target owns its admission and observation. A long task never freezes another target.
    func resume(_ requests: [ResumeRequest], schedule: ScheduleEngine, manual: Bool = false,
                observedRecovery: Bool = false, keepPlan: Bool = false,
                isSelected: @escaping (String) -> Bool = { _ in true }) {
        guard canStartResume else { return }
        let batch = UUID().uuidString
        let operationGeneration = generation
        let policy = defaults.string(forKey: "earlyRecoveryPolicy") ?? "ask"
        for request in requests {
            let target = request.target
            guard !hasAttempted(target), !busyThreadIDs.contains(target.id),
                  manual || latestOperation(for: target, accountID: request.accountID).map({ now().timeIntervalSince($0.actionAt) >= 20 }) ?? true else { continue }
            let id = UUID().uuidString
            operations[id] = ResumeOperation(id: id, batchID: latestOperation(for: target, accountID: request.accountID)?.batchID ?? batch, accountID: request.accountID, target: target,
                actionAt: now(), phase: .preparing, protectsThread: false, manual: manual)
            let transport = makeResumeTransport(); activeTransports[id] = transport
            updateRunning()
            Task { await resumeOne(request, id: id, transport: transport, schedule: schedule, generation: operationGeneration,
                manual: manual, observedRecovery: observedRecovery, keepPlan: keepPlan, policy: policy, isSelected: isSelected) }
        }
    }

    private func resumeOne(_ request: ResumeRequest, id: String, transport: ResumeTransport, schedule: ScheduleEngine,
                           generation operationGeneration: Int, manual: Bool, observedRecovery: Bool, keepPlan: Bool,
                           policy: String, isSelected: (String) -> Bool) async {
        let target = request.target
        let provider = provider; let codexHome = codexHome
        var committed = false
        do {
            // All slow channel preparation is outside the content commitment boundary.
            try await Task.detached { try transport.prepare(target) }.value
            let reminderEnabled = defaults.object(forKey: "resumeWorkspaceReminder") as? Bool ?? true
            let currentWorkspace = reminderEnabled ? await Task.detached { WorkspaceGuard.fingerprint(cwd: target.cwd) }.value : nil
            let preflight = try await Task.detached { try ResumePreflight.read(target: target, provider: provider, codexHome: codexHome) }.value
            guard let account = request.accountID, UsageRecovery.hasAvailableQuota(for: target, usage: preflight.usage, boundAccount: account, now: now()),
                  manual || target.retryQuota?.provesRecovery(preflight.usage, after: target.blockedAt) != false else {
                throw CodexConnectionError.server("额度或账户已变化，等待下次恢复")
            }
            let body = try await Task.detached { try request.resolvedPrompt(reader: ComposerDraftReader(url: codexHome.appendingPathComponent(".codex-global-state.json"))) }.value
            let prompt = WorkspaceGuard.resumePrompt(body, before: request.workspace, after: currentWorkspace, reminderEnabled: reminderEnabled)
            let decision = DecisionEngine(schedule: schedule).plan(now: now(), enabled: true,
                autoResume: manual || defaults.bool(forKey: "autoResume"),
                earlyRecoveryPolicy: manual ? "immediately" : keepPlan ? "keepPlan" : policy,
                usage: preflight.usage, blocked: [target], observedRecovery: observedRecovery, heldForPlan: !manual && keepPlan).decision
            guard case .resume = decision else { throw CodexConnectionError.localizedMessage(decision.text) }
            guard let current = SessionWatcher.parse(url: target.fileURL, mtime: now()), current.id == target.id, current.cwd == target.cwd,
                  operationGeneration == generation, ledgerHealthy, preflight.usage.isFresh(at: now()), !hasAttempted(target), isSelected(target.episodeKey),
                  Calendar.current.timeZone.identifier == schedule.timeZoneID,
                  (defaults.string(forKey: "earlyRecoveryPolicy") ?? "ask") == policy,
                  (defaults.object(forKey: "dailyAnchorMinutes") as? Int ?? 480) == schedule.anchorMinutes,
                  (manual || defaults.bool(forKey: "autoResume")), defaults.bool(forKey: "enabled"),
                  (current.lastUserMessageAt ?? .distantPast) <= target.blockedAt,
                  (current.lastTaskStartedAt ?? .distantPast) <= target.blockedAt,
                  (current.lastAbortedAt ?? .distantPast) <= target.blockedAt,
                  (current.lastAssistantMessageAt ?? .distantPast) <= target.blockedAt, !current.taskRunning else {
                throw CodexConnectionError.server("任务状态或选择已改变")
            }
            guard var operation = operations[id] else { return }
            operation.actionAt = now(); operation.phase = .sending; operation.protectsThread = true; operation.quotaBefore = ResumeQuotaEvidence(preflight.usage)
            // Deduplication and metadata become durable in the same atomic save, immediately before start.
            try save(operation)
            try recordEvent("started", operation: operation)
            committed = true
            try await Task.detached { try transport.submit(target, prompt: prompt) { [weak self] event in
                Task { @MainActor [weak self] in self?.consume(event, operationID: id) }
            } }.value
        } catch {
            let definitelyUnsent = !committed || (error as? ResumeSubmissionError)?.mayHaveSubmitted == false
            if var operation = operations[id] {
                operation.phase = definitelyUnsent ? .notSubmitted : .checking
                operation.failure = error.localizedDescription; operation.protectsThread = !definitelyUnsent
                if definitelyUnsent { operation.endedAt = now() }
                do { try save(operation, afterSubmission: !definitelyUnsent) }
                catch { operations[id] = operation }
                try? recordEvent(definitelyUnsent ? "not_submitted" : "submission_unknown", operation: operation)
                lastFailure = operation.failure; status = operation.failure ?? ""
            }
            if definitelyUnsent { transport.cancel(); activeTransports.removeValue(forKey: id) }
            updateRunning()
        }
    }

    private func consume(_ event: ResumeTransportEvent, operationID id: String) {
        guard var operation = operations[id] else { return }
        var name: String?
        switch event {
        case .received(let receipt, let at):
            guard receipt.threadID == operation.target.id, operation.turnID == nil || operation.turnID == receipt.turnID else { return }
            operation.turnID = receipt.turnID; operation.receivedAt = operation.receivedAt ?? at
            if operation.respondedAt == nil && operation.terminal == nil { operation.phase = .confirming }
            name = "received"
        case .responded(let turnID, let at):
            guard operation.turnID == nil || operation.turnID == turnID, operation.respondedAt == nil else { return }
            operation.turnID = turnID; operation.respondedAt = at; operation.failure = nil
            if operation.terminal == nil { operation.phase = .continued }
            name = "startup_confirmed"
        case .awaiting:
            guard operation.respondedAt == nil, operation.terminal == nil else { return }
            operation.phase = .checking; name = "startup_pending"
        case .manualRequested:
            operation.manualRequested = true
            if operation.respondedAt == nil { operation.phase = .checking }
            name = "manual_requested"
        case .notSubmitted(let reason):
            operation.phase = .notSubmitted; operation.failure = reason; operation.protectsThread = false; operation.endedAt = now()
            activeTransports.removeValue(forKey: id)?.cancel(); name = "not_submitted"
        case .unknown(let reason):
            if operation.respondedAt == nil && operation.terminal == nil { operation.phase = .checking }
            operation.failure = reason; name = "submission_unknown"
        case .ended(let turn, let terminal, let reason, let at):
            if let known = operation.turnID, let turn, known != turn { return }
            operation.turnID = operation.turnID ?? turn; operation.terminal = terminal
            if terminal == .disconnected {
                if operation.respondedAt == nil { operation.phase = .checking }
            } else {
                operation.endedAt = at; operation.protectsThread = false
                operation.phase = terminal == .manualRequired ? .manualRequired : operation.respondedAt != nil && terminal == .completed ? .continued : .stopped
            }
            if operation.respondedAt == nil { operation.failure = reason }
            activeTransports.removeValue(forKey: id)?.cancel(); name = terminal.rawValue
        case .observationEnded:
            if activeTransports[id]?.ownsSubmittedTask != true { activeTransports.removeValue(forKey: id) }
        }
        do { try save(operation, afterSubmission: true) } catch { }
        if let name {
            try? recordEvent(name, operation: operation)
        }
        if operation.respondedAt != nil { reloadConfirmations() }
        updateRunning()
    }

    /// Only a healthy fresh scan covering the exact turn or a later lifecycle can release the guard.
    func reconcile(sessions: [SessionActivity], scannedAt: Date?, healthy: Bool) {
        retryPersistence()
        guard healthy, let scannedAt else { return }
        for operation in Array(operations.values) where operation.protectsThread ||
            (operation.respondedAt == nil && operation.turnID != nil && operation.phase != .notSubmitted) {
            guard scannedAt >= operation.actionAt,
                  let session = sessions.first(where: { $0.id == operation.target.id && $0.fileURL == operation.target.fileURL }) else { continue }
            if let turn = operation.turnID, let evidence = session.turns[turn],
               (evidence.startedAt ?? .distantPast) >= operation.target.blockedAt {
                if operation.respondedAt == nil, let at = evidence.responseAt {
                    consume(.responded(turn, at), operationID: operation.id)
                } else if operation.respondedAt == nil, evidence.terminal == .completed, let at = evidence.endedAt {
                    consume(.responded(turn, at), operationID: operation.id)
                }
                if let terminal = evidence.terminal, let at = evidence.endedAt {
                    consume(.ended(turn, operation.manualRequested == true ? .manualRequired : terminal, nil, at), operationID: operation.id)
                }
            }
            if let start = session.lastTaskStartedAt, start > operation.actionAt,
               session.currentTurnID != operation.turnID, session.currentTurnID != nil,
               operation.turnID != nil || (!session.taskRunning && ((session.lastCompletedAt ?? .distantPast) >= start || (session.quotaBlockedAt ?? .distantPast) >= start)) {
                var resolved = operations[operation.id] ?? operation
                resolved.protectsThread = false
                try? save(resolved, afterSubmission: true)
            }
        }
    }

}

private struct ResumeLedger: Codable {
    let version: Int
    let keys: Set<String>
    let operations: [ResumeOperation]
}

struct ResumeRequest {
    let target: BlockedSession
    let prompt: String
    let accountID: String?
    let workspace: String?
    var messageMode: ResumeMessageMode = .fixed

    func resolvedPrompt(reader: ComposerDraftReader = ComposerDraftReader()) throws -> String {
        messageMode == .composerDraft ? try reader.read(threadID: target.id) ?? L10n.text("继续") : prompt
    }
}
