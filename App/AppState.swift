import Foundation
import Combine
import AppKit
import Network

@MainActor final class AppState: ObservableObject {
    let usage: UsageObserver
    let sessions: SessionWatcher
    let execution: ExecutionCoordinator
    @Published private(set) var schedule: ScheduleEngine
    @Published private(set) var nextNodeText = "–"
    @Published private(set) var blockedSessions: [BlockedSession] = []
    @Published private(set) var decision: KeeperDecision?
    @Published private(set) var choices = ResumeChoices()
    @Published private(set) var nextAction: NextAction?
    @Published private(set) var recoveryReminderTasks: [BlockedSession] = []
    private let defaults: UserDefaults
    private let runtimeURL: URL
    private let now: () -> Date
    private var savedRuntime: Data?
    private var previousUsage: UsageSnapshot?
    private var observedSessions: [SessionActivity] = []
    private var observedAuthentication: AuthenticationObservation?
    private var monitoringSettings: [String] = []
    private var environmentDay: Date?
    private var environmentTimeZone = Calendar.current.timeZone.identifier
    private var naturalRecoveries = Set<String>()
    private var heldForPlan = Set<String>()
    private let network = NWPathMonitor()
    private var confirmed: [String: BlockedSession] = [:]
    private var workspaceAtBlock: [String: String] = [:]
    private var workspaceCapturing = Set<String>()
    private var accountBindings: [String: String] = [:]
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    init(provider: UsageProvider = AppServerUsageProvider(), defaults: UserDefaults = .standard,
         runtimeURL: URL? = nil, codexHome: URL = CodexEnvironment.home,
         execution: ExecutionCoordinator? = nil, startMonitoring: Bool = true, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.runtimeURL = runtimeURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexKeeper/pending-runtime.json")
        usage = UsageObserver(codexHome: codexHome, provider: provider, logURL: self.runtimeURL.deletingLastPathComponent().appendingPathComponent("usage-transitions.jsonl"), now: now)
        sessions = SessionWatcher(codexHome: codexHome)
        self.execution = execution ?? ExecutionCoordinator(provider: provider, defaults: defaults,
            ledgerURL: self.runtimeURL.deletingLastPathComponent().appendingPathComponent("resume-attempts.json"), codexHome: codexHome)
        schedule = ScheduleEngine(anchorMinutes: defaults.object(forKey: "dailyAnchorMinutes") as? Int ?? 480)
        if let data = try? Data(contentsOf: self.runtimeURL), let runtime = try? JSONDecoder().decode(PendingRuntime.self, from: data) {
            confirmed = runtime.confirmed
            accountBindings = runtime.accounts
            workspaceAtBlock = runtime.workspaces
            heldForPlan = runtime.held
            choices = runtime.choices ?? ResumeChoices()
            savedRuntime = data
        }
        usage.$snapshot.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] snapshot in self?.observeRecovery(snapshot); self?.recompute() }.store(in: &cancellables)
        sessions.$sessions.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.recompute() }.store(in: &cancellables)
        sessions.$detectionError.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.recompute() }.store(in: &cancellables)
        usage.$lastError.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.recompute(allowExecution: false) }.store(in: &cancellables)
        usage.$refreshing.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.recompute(allowExecution: false) }.store(in: &cancellables)
        self.execution.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        usage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.execution.$running.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] running in
            if !running, self?.execution.lastFailure == nil { self?.requestAutomaticRefresh(source: "execution_finished") }
            self?.recompute(allowExecution: false)
        }.store(in: &cancellables)
        monitoringSettings = settingsFingerprint()
        environmentDay = Calendar.current.startOfDay(for: now())
        sessions.watchedIDs = Set(confirmed.keys)
        observers.append(NotificationCenter.default.addObserver(forName: CodexLocator.fallbackPathChanged, object: defaults, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.usage.refresh(manual: true, source: "cli_path") }
        })
        guard startMonitoring else { recompute(allowExecution: false); return }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.preferencesChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.environmentChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.environmentChanged() }
        })
        for name in [Notification.Name.NSSystemTimeZoneDidChange, Notification.Name.NSCalendarDayChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.environmentChanged() }
            })
        }
        network.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.environmentChanged() } }
        network.start(queue: DispatchQueue(label: "keeper.network"))
        sessions.watchedIDs = Set(confirmed.keys)
        usage.start()
        sessions.start()
        recompute()
        ticker = Timer(timeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.recompute() } }
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
    }

    var availableTasks: [BlockedSession] { choices.available(blockedSessions).filter { !execution.hasAttempted($0) } }
    var selectedTasks: [BlockedSession] { choices.selected(availableTasks) }

    func setSelected(_ task: BlockedSession, _ selected: Bool) {
        guard !execution.running else { return }
        if selected { choices.deselectedEpisodes.remove(task.episodeKey) }
        else { choices.deselectedEpisodes.insert(task.episodeKey) }
        recompute()
    }
    func setMessageMode(_ task: BlockedSession, _ mode: ResumeMessageMode) {
        guard !execution.running else { return }
        if choices.messageModes == nil { choices.messageModes = [:] }
        choices.messageModes?[task.episodeKey] = mode
        recompute()
    }
    func setMessage(_ task: BlockedSession, _ message: String) {
        guard !execution.running else { return }
        choices.messages[task.episodeKey] = message
        recompute()
    }
    var cancellationPlan: (resume: Date, keepAlive: Date)? {
        let now = now()
        guard !execution.running, defaults.bool(forKey: "enabled"),
              let plan = nextAction, plan.mode == .resume, let resume = plan.date,
              usage.snapshot?.isFresh(at: now) == true else { return nil }
        let alternative = DecisionEngine(schedule: schedule).plan(now: now, enabled: true,
            autoResume: false, earlyRecoveryPolicy: "keepPlan", usage: usage.snapshot, blocked: [])
        guard let keepAlive = alternative.date else { return nil }
        return (resume, keepAlive)
    }

    func useKeepAlive(for tasks: [BlockedSession]) {
        guard !execution.running else { return }
        choices.useKeepAlive(for: tasks)
        recompute()
    }
    func refresh(manual: Bool = false, source: String = "manual") {
        usage.refresh(manual: manual, source: source); sessions.refresh(); recompute()
    }

    func environmentChanged() {
        environmentDay = Calendar.current.startOfDay(for: now())
        environmentTimeZone = Calendar.current.timeZone.identifier
        previousUsage = nil
        naturalRecoveries.removeAll()
        usage.invalidate()
        requestAutomaticRefresh(source: "environment")
        sessions.refresh()
        recompute()
    }

    private func settingsFingerprint() -> [String] {
        ["enabled", "autoResume", "dailyAnchorMinutes", "earlyRecoveryPolicy", "resumeWorkspaceReminder",
         ResumeMessagePreferences.modeKey, "resumeMessage"].map { defaults.object(forKey: $0).map { String(describing: $0) } ?? "" }
    }

    private func preferencesChanged() {
        guard monitoringSettings != settingsFingerprint() else { return }
        monitoringSettings = settingsFingerprint()
        environmentChanged()
    }

    private func requestAutomaticRefresh(source: String, occurredAt: Date? = nil) {
        if let occurredAt, let started = usage.lastRefreshStartedAt, occurredAt <= started { return }
        usage.setPolling(UsagePollingPolicy(interval: UsagePollingPolicy.activeInterval, wakeAt: nil),
            retryOpportunity: defaults.bool(forKey: "enabled") ? schedule.retryOpportunity(at: now()) : nil)
        usage.refresh(source: source, critical: true)
    }

    private func observeSessions() {
        let authentication = sessions.authentication
        if let before = observedAuthentication, before != authentication {
            previousUsage = nil
            naturalRecoveries.removeAll()
            usage.invalidate(clearAccount: true)
            requestAutomaticRefresh(source: "authentication")
        }
        observedAuthentication = authentication
        if let event = SessionUsageActivity.latestRefreshEvent(previous: observedSessions, current: sessions.sessions) {
            requestAutomaticRefresh(source: "session_activity", occurredAt: event)
        }
        observedSessions = sessions.sessions
    }

    private func updateUsagePolling(at now: Date) {
        let reliable = usage.hasReliableReading && usage.lastError == nil && sessions.authentication != .unreadable
        let policy = UsagePollingPolicy.evaluate(now: now, schedule: schedule, enabled: defaults.bool(forKey: "enabled"),
            scanned: sessions.hasScanned, scanError: sessions.detectionError, reliableUsage: reliable,
            usage: usage.snapshot, runningTask: sessions.sessions.contains { $0.taskRunning },
            resumeDemand: defaults.bool(forKey: "enabled") && defaults.bool(forKey: "autoResume") && !availableTasks.isEmpty,
            executing: execution.running, criticalRefresh: usage.criticalRefreshPending)
        usage.setPolling(policy, retryOpportunity: defaults.bool(forKey: "enabled") ? schedule.retryOpportunity(at: now) : nil)
    }

    private func observeRecovery(_ snapshot: UsageSnapshot?) {
        defer { previousUsage = snapshot }
        guard let old = previousUsage, let new = snapshot,
              UsageRecovery.isNatural(from: old, to: new, now: now()) else { return }
        naturalRecoveries.formUnion(blockedSessions.map(\.episodeKey))
    }

    private func hasConfirmedRecovery(for tasks: [BlockedSession]) -> Bool {
        let now = now()
        let keepPlan = defaults.string(forKey: "earlyRecoveryPolicy") == "keepPlan"
        return !tasks.isEmpty && tasks.allSatisfy { target in
            naturalRecoveries.contains(target.episodeKey) || (!keepPlan &&
                UsageRecovery.canResumeAfterScheduledReset(target, usage: usage.snapshot,
                    boundAccount: accountBindings[target.id], now: now))
        }
    }

    private func startResume(manual: Bool = false, tasks: [BlockedSession]? = nil) {
        let chosen = tasks ?? selectedTasks
        let keys = Set(chosen.map(\.episodeKey))
        let requests = chosen.map { target in
            ResumeRequest(target: target,
                prompt: choices.message(for: target, default: ResumeMessagePreferences.current(defaults: defaults)),
                accountID: accountBindings[target.id], workspace: workspaceAtBlock[target.episodeKey], messageMode: choices.mode(for: target))
        }
        execution.resume(requests, schedule: schedule, manual: manual,
            observedRecovery: hasConfirmedRecovery(for: chosen),
            keepPlan: chosen.contains { heldForPlan.contains($0.episodeKey) },
            isSelected: { [weak self] key in
                guard let self, keys.contains(key), self.selectedTasks.contains(where: { $0.episodeKey == key }),
                      self.sessions.detectionError == nil, self.defaults.bool(forKey: "autoResume") else { return false }
                return manual ? self.choices.recoveryDecisions?[key]?.phase == .responded : self.choices.recoveryDecisions?[key] == nil
            })
    }

    func recompute(allowExecution: Bool = true) {
        let now = now()
        if sessions.hasScanned { observeSessions() }
        let settings = settingsFingerprint()
        let day = Calendar.current.startOfDay(for: now)
        if monitoringSettings != settings || environmentDay != day || environmentTimeZone != Calendar.current.timeZone.identifier {
            monitoringSettings = settings
            environmentDay = day
            environmentTimeZone = Calendar.current.timeZone.identifier
            previousUsage = nil
            naturalRecoveries.removeAll()
            usage.invalidate()
            requestAutomaticRefresh(source: "plan_environment")
        }
        if !defaults.bool(forKey: "enabled") { execution.cancelCurrent() }
        schedule = ScheduleEngine(anchorMinutes: defaults.object(forKey: "dailyAnchorMinutes") as? Int ?? 480)
        schedule.accountID = usage.snapshot?.accountID
        schedule.confirmedWindows = execution.confirmedWindows
        if sessions.hasScanned && sessions.detectionError == nil { confirmed = confirmed.filter { id, target in
            sessions.sessions.contains { $0.id == id && !$0.taskRunning && ($0.lastUserMessageAt ?? .distantPast) <= target.blockedAt && ($0.lastTaskStartedAt ?? .distantPast) <= target.blockedAt && ($0.lastAbortedAt ?? .distantPast) <= target.blockedAt && ($0.lastAssistantMessageAt ?? .distantPast) <= target.blockedAt }
        }
        }
        let detected = BlockedSessionDetector.detect(in: sessions.sessions)
        blockedSessions = (detected + confirmed.values.filter { c in !detected.contains { $0.id == c.id } }).sorted { $0.blockedAt > $1.blockedAt }
        for target in blockedSessions where now.timeIntervalSince(target.blockedAt) < 30 {
            let key = target.id + ":" + String(target.blockedAt.timeIntervalSince1970)
            if workspaceAtBlock[key] == nil, workspaceCapturing.insert(key).inserted {
                Task {
                    let fingerprint = await Task.detached { WorkspaceGuard.fingerprint(cwd: target.cwd) }.value
                    workspaceAtBlock[key] = fingerprint
                }
            }
        }
        if !usage.criticalRefreshPending, let snapshot = usage.snapshot, snapshot.isFresh(at: now), let account = snapshot.accountID {
            for session in blockedSessions where accountBindings[session.id] == nil { accountBindings[session.id] = account }
        }
        blockedSessions = blockedSessions.map { target in
            let supported = target.withRecoveryEvidence(from: confirmed[target.id], usage: usage.snapshot,
                boundAccount: accountBindings[target.id], now: now)
            if supported.fiveHourResetAt != nil || supported.weeklyResetAt != nil {
                confirmed[target.id] = supported
            } else if confirmed[target.id]?.episodeKey != target.episodeKey {
                confirmed.removeValue(forKey: target.id)
            }
            return supported
        }
        sessions.watchedIDs = Set(blockedSessions.map { $0.id }).union(confirmed.keys)
            .union(sessions.sessions.filter { $0.taskRunning }.map(\.id))
        if sessions.hasScanned && sessions.detectionError == nil {
            let current = Set(blockedSessions.filter { !execution.hasAttempted($0) }.map(\.episodeKey))
            choices.recoveryDecisions = choices.recoveryDecisions?.filter { current.contains($0.key) }
        }
        let earlyPolicy = defaults.string(forKey: "earlyRecoveryPolicy") ?? "ask"
        if defaults.bool(forKey: "enabled"), defaults.bool(forKey: "autoResume"), earlyPolicy == "ask",
           sessions.hasScanned, sessions.detectionError == nil {
            for target in selectedTasks where !heldForPlan.contains(target.episodeKey) && !hasConfirmedRecovery(for: [target]) {
                if UsageRecovery.hasAvailableQuota(for: target, usage: usage.snapshot,
                    boundAccount: accountBindings[target.id], now: now) {
                    choices.requestRecoveryDecision(for: target, now: now)
                    confirmed[target.id] = target
                }
            }
        }
        guard saveRuntime() else { return }
        let reminders = defaults.bool(forKey: "enabled") && defaults.bool(forKey: "autoResume") && sessions.detectionError == nil ? selectedTasks.filter {
            choices.recoveryDecisions?[$0.episodeKey]?.phase != .responded &&
            choices.recoveryDecisions?[$0.episodeKey]?.notification == .pending &&
            UsageRecovery.hasAvailableQuota(for: $0, usage: usage.snapshot, boundAccount: accountBindings[$0.id], now: now)
        } : []
        if recoveryReminderTasks != reminders { recoveryReminderTasks = reminders }
        let chosen = selectedTasks
        let automatic = chosen.filter { choices.recoveryDecisions?[$0.episodeKey] == nil }
        let engine = DecisionEngine(schedule: schedule)
        func checkedPlan(for targets: [BlockedSession]) -> NextAction {
            var plan = engine.plan(now: now, enabled: defaults.bool(forKey: "enabled"), autoResume: defaults.bool(forKey: "autoResume"),
                earlyRecoveryPolicy: earlyPolicy, usage: usage.snapshot, blocked: targets,
                observedRecovery: hasConfirmedRecovery(for: targets),
                heldForPlan: targets.contains { heldForPlan.contains($0.episodeKey) },
                needsRecoveryDecision: targets.contains { choices.recoveryDecisions?[$0.episodeKey] != nil },
                reserveIdleDate: usage.hasReliableReading && usage.lastError == nil && targets.isEmpty &&
                    sessions.hasScanned && sessions.detectionError == nil && sessions.authentication != .unreadable)
            if defaults.bool(forKey: "enabled"), !targets.isEmpty, targets.allSatisfy({ choices.recoveryDecisions?[$0.episodeKey]?.phase == .responded }) {
                plan = NextAction(mode: .resume, date: nil, decision: .wait(reason: "等待续跑决定"), note: "等待续跑决定", needsRecoveryDecision: true)
            }
            if defaults.bool(forKey: "enabled"), targets.contains(where: { target in
                guard let snapshot = usage.snapshot, snapshot.isFresh(at: now) else { return false }
                return (target.fiveHourResetAt != nil && snapshot.fiveHour == nil) || (target.weeklyResetAt != nil && snapshot.weekly == nil)
            }) {
                plan = NextAction(mode: .resume, date: nil, decision: .wait(reason: "等待额度恢复确认"), note: "等待额度恢复确认")
            }
            if defaults.bool(forKey: "enabled"), targets.contains(where: { accountBindings[$0.id] != usage.snapshot?.accountID }) {
                plan = NextAction(mode: .resume, date: nil, decision: .wait(reason: "账户已改变"), note: "账户已改变")
            }
            if defaults.bool(forKey: "enabled"), let error = sessions.detectionError {
                plan = NextAction(mode: plan.mode, date: nil, decision: .wait(reason: error), note: error)
            }
            return plan
        }
        var plan = automatic.map { checkedPlan(for: [$0]) }.min {
            ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture)
        } ?? checkedPlan(for: chosen)
        if automatic.isEmpty, chosen.contains(where: {
            let recovery = choices.recoveryDecisions?[$0.episodeKey]
            return recovery != nil && recovery?.phase != .responded
        }) {
            plan = checkedPlan(for: [])
            plan.needsRecoveryDecision = true
        }
        if defaults.bool(forKey: "enabled"), sessions.detectionError == nil, !availableTasks.isEmpty && chosen.isEmpty {
            plan = NextAction(mode: .resume, date: nil, decision: .wait(reason: "请选择要继续的任务"), note: "请选择要继续的任务")
        }
        nextAction = plan
        decision = plan.decision
        nextNodeText = MenuSummary.build(plan: plan, usage: usage.snapshot, schedule: schedule, tasks: chosen).statusText
        updateUsagePolling(at: now)
        guard allowExecution, !usage.criticalRefreshPending else { return }
        let ignored = choices.keepAliveIgnoredEpisodes
        if canKeepAlive(ignoring: ignored), case .ping = checkedPlan(for: []).decision {
            execution.ping(schedule: schedule, accountID: usage.snapshot?.accountID, ignoredEpisodes: ignored,
                hasPending: { [weak self] in self?.canKeepAlive(ignoring: ignored) != true })
        }
        // Each eligible task is checked independently of tasks waiting for a choice.
        let ready = automatic.filter { target in
            if case .resume = checkedPlan(for: [target]).decision { return true }
            return false
        }
        if !ready.isEmpty { startResume(tasks: ready) }
    }

    private func canKeepAlive(ignoring episodes: Set<String>) -> Bool {
        sessions.hasScanned && sessions.detectionError == nil &&
            !usage.criticalRefreshPending &&
            !sessions.sessions.contains { $0.taskRunning } &&
            choices.permitsKeepAlive(for: blockedSessions, ignoring: episodes)
    }

    private func saveRuntime() -> Bool {
        let runtime = PendingRuntime(confirmed: confirmed, accounts: accountBindings, workspaces: workspaceAtBlock, held: heldForPlan, selected: nil, choices: choices)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        do {
            let data = try encoder.encode(runtime)
            if data != savedRuntime {
                try FileManager.default.createDirectory(at: runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: runtimeURL, options: .atomic)
                savedRuntime = data
            }
            return true
        } catch {
            recoveryReminderTasks = []
            let reason = "待续状态无法保存，暂停自动操作"
            decision = .wait(reason: reason)
            nextAction = NextAction(mode: .resume, date: nil, decision: .wait(reason: reason), note: reason)
            return false
        }
    }

    func resolveRecoveryDecision(_ choice: RecoveryChoice, for tasks: [BlockedSession]) {
        guard !execution.running else { return }
        let keys = Set(tasks.map(\.episodeKey))
        recompute(allowExecution: false)
        guard defaults.bool(forKey: "enabled"), defaults.bool(forKey: "autoResume"), sessions.detectionError == nil else { return }
        let targets = selectedTasks.filter { keys.contains($0.episodeKey) && choices.recoveryDecisions?[$0.episodeKey] != nil }
        let resolved = targets.filter { choices.resolveRecoveryDecision(choice, for: $0) }
        for target in resolved {
            if choice == .plan { heldForPlan.insert(target.episodeKey) }
        }
        guard saveRuntime() else { return }
        if choice == .now { startResume(manual: true, tasks: resolved) }
        recompute(allowExecution: choice != .now)
    }

    func claimRecoveryReminder(for key: String) -> RecoveryDecision? {
        recompute(allowExecution: false)
        guard recoveryReminderTasks.contains(where: { $0.episodeKey == key }) else { return nil }
        choices.recoveryDecisions?[key]?.notification = .requested
        guard saveRuntime() else { return nil }
        recoveryReminderTasks.removeAll { $0.episodeKey == key }
        return choices.recoveryDecisions?[key]
    }

    func recoveryReminderIsCurrent(for key: String, phase: RecoveryDecision.Phase) -> Bool {
        recompute(allowExecution: false)
        guard defaults.bool(forKey: "enabled"), defaults.bool(forKey: "autoResume"), sessions.detectionError == nil,
              let target = selectedTasks.first(where: { $0.episodeKey == key }),
              UsageRecovery.hasAvailableQuota(for: target, usage: usage.snapshot, boundAccount: accountBindings[target.id], now: now()) else { return false }
        return choices.recoveryDecisions?[key]?.phase == phase && choices.recoveryDecisions?[key]?.notification == .requested
    }

    func finishRecoveryReminder(for key: String, phase: RecoveryDecision.Phase, delivered: Bool) {
        guard choices.recoveryDecisions?[key]?.phase == phase, choices.recoveryDecisions?[key]?.notification == .requested else { return }
        choices.recoveryDecisions?[key]?.notification = delivered ? .delivered : .unavailable
        _ = saveRuntime()
        recompute(allowExecution: false)
    }

    func openRecoveryDecisions(open: () -> Void) {
        recompute(allowExecution: false)
        open()
    }

    var resetDate: Date? { usage.snapshot?.nextResetDate(at: now()) }

    static let dayClockFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f }()

}


private struct PendingRuntime: Codable {
    var confirmed: [String: BlockedSession]
    var accounts: [String: String]
    var workspaces: [String: String]
    var held: Set<String>
    var selected: String?
    var choices: ResumeChoices?
}
