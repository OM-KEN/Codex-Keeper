import Foundation
import Combine
import Darwin

/// The persisted attempt is written before sending; uncertain outcomes are never retried automatically.
@MainActor final class ExecutionCoordinator: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var lastFailure: String?
    @Published private(set) var lastFailureNeedsAttention = true
    var visibleFailure: String? { lastFailureNeedsAttention ? lastFailure : nil }
    var visibleNotice: String? { lastFailureNeedsAttention ? nil : lastFailure }
    @Published private(set) var warning: String?
    @Published private(set) var activeMode: NextActionMode?
    @Published private(set) var status = L10n.text("等待计划")
    @Published private(set) var confirmations: [ExecutionConfirmation] = []
    @Published private(set) var operations: [String: ResumeOperation] = [:]
    @Published private(set) var recordingFailure: String?
    @Published private(set) var pingResults: [PingNodeResult] = []
    @Published private(set) var lastPingResult: PingNodeResult?
    private var observedPing: (node: Date, account: String?, reason: String, skipped: Bool)?
    private var preparationRunning = false
    private var pingRunning = false
    private var storageFault = false
    private var pendingEventWrites: [String: (String, ResumeOperation)] = [:]
    private var permanentlyUnhealthy = false
    private var attempts: Set<String>
    private let ledgerURL: URL
    private let events: ExecutionEventLog
    private let provider: UsageProvider
    private let codexHome: URL
    private let scanWorker: SessionScanWorker
    private let makeResumeTransport: () -> ResumeTransport
    private let defaults: UserDefaults
    private let now: () -> Date
    private var activeTransports: [String: ResumeTransport] = [:]
    private let pingTransport: PingTransport
    private var ledgerHealthy = true
    private var generation = 0
    private var pingGeneration = 0
    private var executionLock: Int32 = -1

    init(provider: UsageProvider = AppServerUsageProvider(), makeResumeTransport: @escaping () -> ResumeTransport = { OwnedSessionResumeTransport() }, defaults: UserDefaults = .standard, ledgerURL: URL? = nil, pingTransport: PingTransport? = nil, codexHome: URL = CodexEnvironment.home, scanWorker: SessionScanWorker? = nil, now: @escaping () -> Date = Date.init) {
        self.codexHome = codexHome
        self.scanWorker = scanWorker ?? SessionScanWorker(codexHome: codexHome)
        self.now = now
        self.provider = provider
        self.makeResumeTransport = makeResumeTransport
        self.defaults = defaults
        self.ledgerURL = ledgerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexKeeper/resume-attempts.json")
        self.pingTransport = pingTransport ?? PTYPingTransport(codexHome: codexHome, supportRoot: self.ledgerURL.deletingLastPathComponent().appendingPathComponent("ping"))
        self.events = ExecutionEventLog(url: self.ledgerURL.deletingLastPathComponent().appendingPathComponent("execution-events.jsonl"))
        confirmations = events.confirmations()
        if FileManager.default.fileExists(atPath: self.ledgerURL.path) {
            if let data = try? Data(contentsOf: self.ledgerURL), let saved = try? JSONDecoder().decode(ResumeLedger.self, from: data), saved.version == 1 {
                attempts = saved.keys; operations = Dictionary(uniqueKeysWithValues: saved.operations.map { ($0.id, $0) })
                // A short startup observation cannot survive a restart. Its submission constraint does.
                for key in operations.keys where operations[key]?.observesStartup == true {
                    guard var operation = operations[key] else { continue }
                    if operation.phase == .preparing {
                        operation.phase = .notSubmitted
                        if operation.manual != nil, operation.preflight == nil, operation.failure == nil {
                            operation.preflight = ResumePreflightDiagnostic(stage: .channelPrepare, reasons: [.preparationInterrupted],
                                target: operation.target, checkedAt: now())
                        }
                    } else { operation.phase = .checking }
                    operations[key] = operation
                }
            } else if let data = try? Data(contentsOf: self.ledgerURL), let saved = try? JSONDecoder().decode([String].self, from: data) { attempts = Set(saved) }
            else { attempts = []; ledgerHealthy = false; status = L10n.text("记录无法读取，请到关于页反馈问题。") }
        } else { attempts = [] }
        pingResults = events.pingResults()
        lastPingResult = pingResults.last
        if let result = lastPingResult, result.needsAttention {
            lastFailure = result.message; lastFailureNeedsAttention = result.outcome == .failed
            activeMode = .keepAlive
        }
        reloadConfirmations()
        try? FileManager.default.createDirectory(at: self.ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        executionLock = Darwin.open(self.ledgerURL.deletingLastPathComponent().appendingPathComponent("execution.lock").path, O_CREAT | O_RDWR, 0o600)
        if executionLock < 0 || flock(executionLock, LOCK_EX | LOCK_NB) != 0 {
            ledgerHealthy = false
            status = L10n.text(executionLock < 0 ? "记录无法读取，请到关于页反馈问题。" : "Keeper 已在运行，请使用已打开的 Keeper。")
        }
        if !ledgerHealthy { permanentlyUnhealthy = true; lastFailure = status; recordingFailure = status }
        else {
            for result in pingResults where result.outcome == .submitted {
                let interrupted = PingNodeResult(node: result.node, accountID: result.accountID, at: now(), outcome: .unknown)
                try? recordPing(interrupted, event: "interrupted")
            }
        }
    }

    deinit { if executionLock >= 0 { Darwin.close(executionLock) } }

    /// Identity, plan or clock changes revoke preparation, without interrupting submitted work.
    func invalidatePreparations(keepAlive: Bool = true) {
        generation += 1
        if keepAlive { pingGeneration += 1 }
        for (id, transport) in activeTransports where operations[id]?.phase == .preparing { transport.cancel() }
    }

    /// Switching future execution off also cancels Keeper's isolated ping.
    func cancelCurrent() {
        invalidatePreparations()
        warning = nil
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
            recordingFailure = L10n.text("记录不可用，请检查磁盘空间后刷新。")
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
                turnID: operation.turnID, resumePreflight: operation.preflight, accountID: operation.accountID, operationID: operation.id, episodeKey: operation.target.episodeKey,
                at: name == "startup_confirmed" ? operation.respondedAt : name == "started" ? operation.actionAt : nil)
        } catch {
            pendingEventWrites[operation.id + ":" + name] = (name, operation)
            storageFault = true; ledgerHealthy = false; recordingFailure = L10n.text("记录不可用，请检查磁盘空间后刷新。")
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

    /// Older versions could persist the user's choice before creating its operation.
    /// Only an intact ledger with no attempt or protected writer can prove it was unsent.
    func restoreUnsubmittedChoice(for target: BlockedSession, accountID: String?) {
        guard canStartResume, let accountID, !accountID.isEmpty,
              !hasAttempted(target), !busyThreadIDs.contains(target.id),
              latestOperation(for: target, accountID: accountID) == nil else { return }
        let id = UUID().uuidString
        let operation = ResumeOperation(id: id, batchID: id, accountID: accountID, target: target,
            actionAt: now(), phase: .notSubmitted, endedAt: now(), protectsThread: false, manual: true,
            preflight: ResumePreflightDiagnostic(stage: .channelPrepare, reasons: [.preparationInterrupted], target: target, checkedAt: now()))
        try? save(operation)
    }
    private func updateRunning() {
        let observing = operations.values.contains(where: \.observesStartup)
        running = pingRunning || observing
        if observing { activeMode = .resume; status = L10n.text("正在继续") }
        else if pingRunning { activeMode = .keepAlive }
    }

    func acknowledgePingResult() {
        guard !pingRunning, var result = lastPingResult, result.needsAttention else { return }
        result.acknowledgedAt = now()
        try? recordPing(result, event: "viewed")
    }

    func relocateKeepAlive() {
        pingTransport.relocatePreparation()
        maintainKeepAlive(forceCheck: true)
    }

    func maintainKeepAlive(forceCheck: Bool = false) {
        guard defaults.bool(forKey: "enabled"), !preparationRunning else { return }
        preparationRunning = true
        let transport = pingTransport; let provider = provider
        Task {
            guard defaults.bool(forKey: "enabled") else { preparationRunning = false; return }
            await Task.detached { transport.maintainPreparation(provider: provider, forceCheck: forceCheck) }.value
            preparationRunning = false
        }
    }

    /// Remember why an observed opportunity was not used; later read recovery cannot erase it.
    func observeKeepAlive(schedule: ScheduleEngine, accountID: String?, usage: UsageSnapshot?, reason: String?) {
        let clock = now()
        if let previous = observedPing, clock > previous.node.addingTimeInterval(ScheduleEngine.keepAliveTolerance) {
            if !pingResults.contains(where: { $0.node == previous.node && $0.accountID == previous.account &&
                [.submitted, .newWindow, .windowActive, .windowPending, .unknown, .skipped, .notExecuted].contains($0.outcome) }) {
                let prior = pingResults.last { $0.node == previous.node && $0.accountID == previous.account }
                let result = PingNodeResult(node: previous.node, accountID: previous.account, at: clock,
                    outcome: previous.skipped ? .skipped : .notExecuted, diagnostic: prior?.diagnostic,
                    preflight: prior?.preflight, detail: prior?.preflight?.errorDescription ?? prior?.detail ?? previous.reason)
                try? recordPing(result, event: previous.skipped ? "skipped" : "not_executed")
            }
            observedPing = nil
        }
        guard defaults.bool(forKey: "enabled"), let node = schedule.currentKeepAliveNode(at: clock) else { return }
        let skipped = usage?.isFresh(at: clock) == true && usage?.activeFiveHourWindow == true &&
            (usage?.fiveHour?.usedPercent ?? 100) < 100 && (usage?.weekly?.usedPercent ?? 0) < 100
        observedPing = (node, accountID, reason ?? (skipped ? L10n.text("已有有效 5 小时窗口") : L10n.text("正在确认中")), skipped)
    }

    private func recordPing(_ result: PingNodeResult, event: String, before: UsageSnapshot? = nil, after: UsageSnapshot? = nil, error: String? = nil) throws {
        do {
            try events.record(event, kind: "ping", node: result.node, before: before, after: after, error: error,
                diagnostic: result.diagnostic, preflight: result.preflight, accountID: result.accountID, at: result.at, pingResult: result)
        } catch {
            storageFault = true; ledgerHealthy = false
            recordingFailure = L10n.text("记录不可用，请检查磁盘空间后刷新。")
            throw error
        }
        pingResults.removeAll { $0.node == result.node && $0.accountID == result.accountID }
        pingResults.append(result); pingResults.sort { $0.at < $1.at }; lastPingResult = result
        status = result.message
        if result.succeeded || result.acknowledgedAt != nil { lastFailure = nil }
        else if result.needsAttention {
            lastFailure = result.message; lastFailureNeedsAttention = result.outcome == .failed && (result.preflight?.needsAttention ?? true)
        }
    }

    func ping(schedule: ScheduleEngine, usage: UsageSnapshot? = nil,
              blockers: @escaping () -> [PingPreflightReason]) {
        guard ledgerHealthy, defaults.bool(forKey: "enabled"), !running, !hasBusyTasks,
              let node = schedule.currentKeepAliveNode(at: now()) else { return }
        let startedAt = now(); let startedUptime = ProcessInfo.processInfo.systemUptime
        let opportunity = schedule.keepAliveOpportunities(at: startedAt).first { $0.node == node }
        let authentication = try? PingAuthentication.read(home: codexHome)
        let boundAccount = authentication?.accountID
        let before = usage.flatMap { $0.isFresh(at: startedAt) && $0.accountID == boundAccount ? $0 : nil } ??
            UsageSnapshot(fiveHour: nil, weekly: nil, capturedAt: .distantPast, accountID: boundAccount, sourceFile: "")
        guard let boundAccount else {
            let diagnostic = PingPreflightDiagnostic(stage: .beforeSend, reasons: [.accountUnconfirmed], startedAt: startedAt, checkedAt: now(),
                elapsedSeconds: 0, usageCapturedAt: nil, usageAgeSeconds: nil, opportunityStartsAt: opportunity?.date,
                opportunityDeadline: opportunity?.deadline, newPauseCount: nil)
            if lastPingResult?.node != node || lastPingResult?.preflight?.reasons != diagnostic.reasons {
                try? recordPing(PingNodeResult(node: node, accountID: nil, at: now(), outcome: .failed, preflight: diagnostic), event: "failed")
            }
            return
        }
        let key = "ping:\(boundAccount):\(node.timeIntervalSince1970)"
        guard !attempts.contains(key) else { return }
        let operation = pingGeneration
        warning = nil; activeMode = .keepAlive
        pingRunning = true; running = true
        status = L10n.text("正在确认保活条件…")
        let provider = provider; let transport = pingTransport
        Task {
            var submitted = false
            do {
                try await Task.detached { try transport.prepareForSend() }.value
                let appBlockers = blockers()
                let checkedAt = now()
                let currentAccount = (try? PingAuthentication.read(home: codexHome))?.accountID
                var reasons = appBlockers
                if operation != pingGeneration { reasons.append(.generationChanged) }
                if !defaults.bool(forKey: "enabled") { reasons.append(.disabled) }
                if (defaults.object(forKey: "dailyAnchorMinutes") as? Int ?? 480) != schedule.anchorMinutes { reasons.append(.anchorChanged) }
                if Calendar.current.timeZone.identifier != schedule.timeZoneID { reasons.append(.timeZoneChanged) }
                if currentAccount == nil { reasons.append(.accountUnconfirmed) }
                else if currentAccount != boundAccount { reasons.append(.accountChanged) }
                if !ledgerHealthy { reasons.append(.runtimeUnhealthy) }
                if schedule.currentKeepAliveNode(at: checkedAt) != node {
                    reasons.append(opportunity.map { checkedAt > $0.deadline } == true ? .opportunityExpired : .nodeChanged)
                }
                if !reasons.isEmpty {
                    throw PingPreflightDiagnostic(stage: .beforeSend, reasons: reasons, startedAt: startedAt, checkedAt: checkedAt,
                        elapsedSeconds: max(0, ProcessInfo.processInfo.systemUptime - startedUptime),
                        usageCapturedAt: usage?.capturedAt, usageAgeSeconds: usage.map { checkedAt.timeIntervalSince($0.capturedAt) },
                        opportunityStartsAt: opportunity?.date, opportunityDeadline: opportunity?.deadline, newPauseCount: nil)
                }
                // A previously good read can age during local preparation; unknown quota still permits one attempt.
                let currentBefore = before.isFresh(at: checkedAt) ? before : UsageSnapshot(fiveHour: nil, weekly: nil,
                    capturedAt: .distantPast, accountID: boundAccount, sourceFile: "")
                let decision = DecisionEngine(schedule: schedule).decide(now: checkedAt, enabled: true, autoResume: false,
                    earlyRecoveryPolicy: "ask", usage: currentBefore, blocked: [])
                guard case .ping = decision else { pingRunning = false; updateRunning(); return }
                do { try saveLedger(keys: attempts.union([key])) }
                catch { storageFault = true; ledgerHealthy = false; recordingFailure = L10n.text("记录不可用，请检查磁盘空间后刷新。"); throw error }
                try recordPing(PingNodeResult(node: node, accountID: boundAccount, at: checkedAt, outcome: .submitted), event: "started", before: currentBefore)
                submitted = true
                status = L10n.text("正在建立 5 小时窗口…")
                let events = events
                let result = try await Task.detached {
                    try transport.perform(before: currentBefore, model: transport.preparedModel, provider: provider) { diagnostic in
                        try? events.record("diagnostic", kind: "ping", node: node, diagnostic: diagnostic)
                        Task { @MainActor in
                            guard self.pingRunning else { return }
                            self.warning = diagnostic.outcome == "waiting" && diagnostic.elapsedSeconds >= diagnostic.warningSeconds ? diagnostic.warning : nil
                        }
                    }
                }.value
                guard result.diagnostic.taskCompleted else { throw PingFailure(diagnostic: result.diagnostic) }
                let outcome: PingOutcome
                if let after = result.after, PingConfirmation.accepts(before: currentBefore, after: after, now: now()) {
                    outcome = PingConfirmation.newWindow(before: currentBefore, after: after, now: now(), submittedAt: checkedAt) ? .newWindow : .windowActive
                } else { outcome = .windowPending }
                try recordPing(PingNodeResult(node: node, accountID: boundAccount, at: now(), outcome: outcome, diagnostic: result.diagnostic),
                    event: outcome == .windowPending ? "completed_pending" : "confirmed", before: currentBefore, after: result.after)
                reloadConfirmations()
            } catch {
                if error is PingSubmissionError {
                    do { try saveLedger(keys: attempts.subtracting([key])); submitted = false }
                    catch { storageFault = true; ledgerHealthy = false; recordingFailure = L10n.text("记录不可用，请检查磁盘空间后刷新。") }
                }
                let underlying = (error as? PingSubmissionError)?.underlying ?? error
                var diagnostic = (underlying as? PingFailure)?.diagnostic
                if diagnostic == nil, let local = error as? PingSubmissionError {
                    let failure = underlying as NSError
                    diagnostic = PingDiagnostic(elapsedSeconds: max(0, ProcessInfo.processInfo.systemUptime - startedUptime), warningSeconds: 90, timeoutSeconds: 180,
                        reason: local.stage == "process_launch" ? .launch : local.stage == "authentication" ? .accountChanged : .configuration,
                        outcome: "not_submitted", errorCode: "\(failure.domain):\(failure.code)", stage: local.stage)
                }
                let preflight = underlying as? PingPreflightDiagnostic
                let outcome: PingOutcome = submitted ? (diagnostic?.reason == .model || diagnostic?.reason == .request || diagnostic?.reason == .configuration ? .failed : .unknown) : .failed
                let result = PingNodeResult(node: node, accountID: boundAccount, at: now(), outcome: outcome, diagnostic: diagnostic,
                    preflight: preflight, detail: preflight?.errorDescription ?? diagnostic?.failureMessage ?? CodexConnectionError.capabilityMessage(for: error))
                let unchanged = lastPingResult?.node == node && lastPingResult?.outcome == outcome &&
                    lastPingResult?.preflight?.reasons == preflight?.reasons && lastPingResult?.diagnostic?.reason == diagnostic?.reason
                if !unchanged { try? recordPing(result, event: "failed", error: CodexConnectionError.diagnosticDescription(for: error)) }
                if error is PingSubmissionError || diagnostic?.reason == .model || diagnostic?.reason == .configuration { transport.invalidatePreparation(); maintainKeepAlive(forceCheck: true) }
            }
            warning = nil; pingRunning = false; updateRunning()
        }
    }

    private func reloadConfirmations() {
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

    func hasAttemptedKeepAlive(node: Date, accountID: String?) -> Bool {
        guard let accountID else { return false }
        return attempts.contains("ping:\(accountID):\(node.timeIntervalSince1970)")
    }

    func hasAttempted(_ target: BlockedSession, accountID: String? = nil) -> Bool {
        if attempts.contains(target.episodeKey) { return true }
        return operations.values.contains { (accountID == nil || $0.accountID == accountID) && $0.target.episodeKey == target.episodeKey &&
            $0.phase != .notSubmitted && $0.phase != .preparing }
    }

    /// Each target owns its admission and observation. A long task never freezes another target.
    @discardableResult func resume(_ requests: [ResumeRequest], schedule: ScheduleEngine, manual: Bool = false,
                commit: (Set<String>) -> Bool = { _ in true },
                blockers: @escaping (String) -> [ResumePreflightReason] = { _ in [] }) -> Set<String> {
        guard canStartResume else { return [] }
        var prepared: [(request: ResumeRequest, id: String)] = []
        let batch = UUID().uuidString
        let operationGeneration = generation
        let policy = defaults.string(forKey: "earlyRecoveryPolicy") ?? "ask"
        for request in requests {
            let target = request.target
            guard !hasAttempted(target), !busyThreadIDs.contains(target.id),
                  manual || latestOperation(for: target, accountID: request.accountID).map({ now().timeIntervalSince($0.actionAt) >= 20 }) ?? true else { continue }
            let id = UUID().uuidString
            let operation = ResumeOperation(id: id, batchID: latestOperation(for: target, accountID: request.accountID)?.batchID ?? batch, accountID: request.accountID, target: target,
                actionAt: now(), phase: .preparing, protectsThread: false, manual: manual)
            do { try save(operation) }
            catch { lastFailure = recordingFailure; lastFailureNeedsAttention = true; break }
            prepared.append((request, id))
        }
        guard !prepared.isEmpty else { return [] }
        let admitted = Set(prepared.map { $0.request.target.episodeKey })
        // Saving user choices may fail independently of the ledger. No channel work starts
        // until both are durable; an interrupted preparation remains a safe retry record.
        guard ledgerHealthy, commit(admitted) else {
            let reason: ResumePreflightReason = ledgerHealthy ? .runtimeUnhealthy : .ledgerUnhealthy
            for item in prepared {
                guard var operation = operations[item.id] else { continue }
                operation.phase = .notSubmitted; operation.endedAt = now()
                operation.preflight = ResumePreflightDiagnostic(stage: .channelPrepare, reasons: [reason], target: operation.target, checkedAt: now())
                do { try save(operation); try recordEvent("not_submitted", operation: operation) }
                catch { operations[item.id] = operation }
            }
            lastFailure = recordingFailure ?? prepared.first.flatMap { operations[$0.id]?.notSubmittedMessage }
            lastFailureNeedsAttention = true
            updateRunning()
            return []
        }
        for item in prepared {
            let transport = makeResumeTransport(); activeTransports[item.id] = transport
            Task { await resumeOne(item.request, id: item.id, transport: transport, schedule: schedule, generation: operationGeneration,
                manual: manual, policy: policy, blockers: blockers) }
        }
        updateRunning()
        return admitted
    }

    private func resumeOne(_ request: ResumeRequest, id: String, transport: ResumeTransport, schedule: ScheduleEngine,
                           generation operationGeneration: Int, manual: Bool,
                           policy: String, blockers: (String) -> [ResumePreflightReason]) async {
        let target = request.target
        let provider = provider; let codexHome = codexHome; let clock = now; let scanWorker = scanWorker
        let startedAt = now(); let startedUptime = ProcessInfo.processInfo.systemUptime
        var stage = ResumePreflightDiagnostic.Stage.channelPrepare
        var checkedUsage: UsageSnapshot?
        var committed = false
        do {
            // All slow channel preparation is outside the content commitment boundary.
            try await Task.detached { try transport.prepare(target) }.value
            let reminderEnabled = defaults.object(forKey: "resumeWorkspaceReminder") as? Bool ?? true
            let currentWorkspace = reminderEnabled ? await Task.detached { WorkspaceGuard.fingerprint(cwd: target.cwd) }.value : nil
            stage = .sessionCheck
            let preflight = try await Task.detached { try ResumePreflight.read(target: target, provider: provider, codexHome: codexHome, worker: scanWorker, now: clock) }.value
            checkedUsage = preflight.usage
            stage = .quotaCheck
            let quotaReasons = ResumePreflight.quotaBlockers(target: target, usage: preflight.usage, accountID: request.accountID, now: now(), manual: manual)
            if !quotaReasons.isEmpty { throw ResumePreflightDiagnostic(stage: .quotaCheck, reasons: quotaReasons, target: target, checkedAt: now(), usage: preflight.usage) }
            stage = .promptRead
            let body = try await Task.detached { try request.resolvedPrompt(reader: ComposerDraftReader(url: codexHome.appendingPathComponent(".codex-global-state.json"))) }.value
            let prompt = WorkspaceGuard.resumePrompt(body, before: request.workspace, after: currentWorkspace, reminderEnabled: reminderEnabled)
            stage = .planCheck
            let decision = DecisionEngine(schedule: schedule).plan(now: now(), enabled: true,
                autoResume: manual || defaults.bool(forKey: "autoResume"),
                earlyRecoveryPolicy: manual ? "immediately" : request.heldForPlan ? "keepPlan" : policy,
                usage: preflight.usage, blocked: [target], observedRecovery: request.observedRecovery, heldForPlan: !manual && request.heldForPlan).decision
            guard case .resume = decision else { throw CodexConnectionError.localizedMessage(decision.text) }
            stage = .beforeSend
            let current = SessionWatcher.parse(url: target.fileURL, mtime: now())
            let appBlockers = blockers(target.episodeKey)
            let checkedAt = now()
            var reasons = ResumePreflight.sessionBlockers(target: target, session: current, stage: .beforeSend)
            do {
                if let path = try SessionScanWorker.currentRolloutPaths(codexHome: codexHome)[target.id],
                   path.resolvingSymlinksInPath() != target.fileURL.resolvingSymlinksInPath() { reasons.append(.pauseChanged) }
            } catch { reasons.append(.sessionScanFailed) }
            if operationGeneration != generation { reasons.append(.generationChanged) }
            if !ledgerHealthy { reasons.append(.ledgerUnhealthy) }
            if !preflight.usage.isFresh(at: checkedAt) { reasons.append(.usageNotFresh) }
            if hasAttempted(target) { reasons.append(.alreadyAttempted) }
            reasons.append(contentsOf: appBlockers)
            if Calendar.current.timeZone.identifier != schedule.timeZoneID { reasons.append(.timeZoneChanged) }
            if (defaults.string(forKey: "earlyRecoveryPolicy") ?? "ask") != policy { reasons.append(.policyChanged) }
            if (defaults.object(forKey: "dailyAnchorMinutes") as? Int ?? 480) != schedule.anchorMinutes { reasons.append(.anchorChanged) }
            if !manual && !defaults.bool(forKey: "autoResume") && !reasons.contains(.autoResumeDisabled) { reasons.append(.autoResumeDisabled) }
            if !defaults.bool(forKey: "enabled") { reasons.append(.disabled) }
            if !reasons.isEmpty { throw ResumePreflightDiagnostic(stage: .beforeSend, reasons: reasons, target: target, checkedAt: checkedAt, usage: preflight.usage) }
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
                operation.failure = CodexConnectionError.diagnosticDescription(for: error); operation.protectsThread = !definitelyUnsent
                if !committed {
                    var diagnostic = (error as? ResumePreflightDiagnostic) ?? ResumePreflightDiagnostic(stage: stage, reasons: [.preparationFailed], target: target,
                        checkedAt: now(), usage: checkedUsage, failure: UsageReadFailure.describe(error, elapsed: ProcessInfo.processInfo.systemUptime - startedUptime))
                    diagnostic.startedAt = startedAt; diagnostic.elapsedSeconds = max(0, ProcessInfo.processInfo.systemUptime - startedUptime)
                    operation.preflight = diagnostic
                }
                if definitelyUnsent { operation.endedAt = now() }
                do { try save(operation, afterSubmission: !definitelyUnsent) }
                catch { operations[id] = operation }
                try? recordEvent(definitelyUnsent ? "not_submitted" : "submission_unknown", operation: operation)
                status = definitelyUnsent ? operation.notSubmittedMessage : L10n.text("正在确认中")
                lastFailureNeedsAttention = definitelyUnsent && operation.notSubmittedNeedsAttention
                lastFailure = status
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
                  let session = sessions.first(where: { $0.id == operation.target.id && $0.cwd == operation.target.cwd &&
                      ($0.fileURL.resolvingSymlinksInPath() == operation.target.fileURL.resolvingSymlinksInPath() || $0.currentRolloutVerified) }) else { continue }
            if let turn = operation.turnID, let evidence = session.turns[turn],
               (evidence.startedAt ?? .distantPast) >= operation.target.blockedAt {
                if operation.respondedAt == nil, let at = evidence.responseAt {
                    consume(.responded(turn, at), operationID: operation.id)
                }
                if let terminal = evidence.terminal, let at = evidence.endedAt {
                    let resolved = operation.manualRequested == true ? .manualRequired : terminal
                    if operation.terminal != resolved || operation.endedAt != at || operation.protectsThread {
                        consume(.ended(turn, resolved, nil, at), operationID: operation.id)
                    }
                }
            }
            if let start = session.lastTaskStartedAt, start > operation.actionAt,
               session.currentTurnID != operation.turnID, session.currentTurnID != nil,
               operation.turnID != nil || (!session.taskRunning && ((session.lastCompletedAt ?? .distantPast) >= start || (session.quotaBlockedAt ?? .distantPast) >= start)) {
                var resolved = operations[operation.id] ?? operation
                if resolved.protectsThread {
                    resolved.protectsThread = false
                    try? save(resolved, afterSubmission: true)
                }
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
    var observedRecovery = false
    var heldForPlan = false

    func resolvedPrompt(reader: ComposerDraftReader = ComposerDraftReader()) throws -> String {
        switch messageMode {
        case .localizedDefault: return L10n.text("继续")
        case .fixed: return prompt
        case .composerDraft: return try reader.read(threadID: target.id) ?? L10n.text("继续")
        }
    }
}
