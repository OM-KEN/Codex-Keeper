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
    @Published private(set) var displayAccountID: String?
    private var accountStates: [String: AccountResumeRuntime] = [:]
    private var pauseRegistry: [String: BlockedSession] = [:]
    private var observedStartups = Set<String>()
    @Published private(set) var recoveryReminderTasks: [BlockedSession] = []
    private let defaults: UserDefaults
    private let runtimeURL: URL
    private let now: () -> Date
    private var savedRuntime: Data?
    private var runtimeHealthy = true
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
            displayAccountID = runtime.displayAccountID ?? (Set(runtime.accounts.values).count == 1 ? runtime.accounts.values.first : nil)
            accountStates = runtime.accountStates ?? [:]
            pauseRegistry = runtime.pauseRegistry ?? runtime.confirmed
            savedRuntime = data
        }
        observedStartups = Set(self.execution.operations.values.filter { $0.respondedAt != nil }.map(\.id))
        self.execution.$operations.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] operations in
            guard let self else { return }
            let responded = Set(operations.values.filter { $0.respondedAt != nil }.map(\.id))
            if !responded.subtracting(self.observedStartups).isEmpty {
                self.observedStartups.formUnion(responded)
                self.requestAutomaticRefresh(source: "resume_started")
                self.sessions.refresh()
            }
            self.recompute(allowExecution: false)
        }.store(in: &cancellables)
        usage.$snapshot.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.recompute() }.store(in: &cancellables)
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
        sessions.watchedIDs = Set(confirmed.keys).union(self.execution.busyThreadIDs)
        sessions.watchedPaths = self.execution.protectedPaths
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
        sessions.watchedIDs = Set(confirmed.keys).union(self.execution.busyThreadIDs)
        usage.start()
        sessions.start()
        recompute()
        ticker = Timer(timeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.recompute() } }
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
    }

    var availableTasks: [BlockedSession] { choices.available(blockedSessions).filter { !execution.hasAttempted($0, accountID: displayAccountID) } }
    var selectedTasks: [BlockedSession] { choices.selected(availableTasks) }

    func setSelected(_ task: BlockedSession, _ selected: Bool) {
        guard !execution.isContentLocked(task, accountID: displayAccountID) else { return }
        if selected { choices.deselectedEpisodes.remove(task.episodeKey) }
        else { choices.deselectedEpisodes.insert(task.episodeKey) }
        recompute()
    }
    func setMessageMode(_ task: BlockedSession, _ mode: ResumeMessageMode) {
        guard !execution.isContentLocked(task, accountID: displayAccountID) else { return }
        if choices.messageModes == nil { choices.messageModes = [:] }
        choices.messageModes?[task.episodeKey] = mode
        recompute()
    }
    func setMessage(_ task: BlockedSession, _ message: String) {
        guard !execution.isContentLocked(task, accountID: displayAccountID) else { return }
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
        choices.useKeepAlive(for: tasks.filter { !execution.isContentLocked($0, accountID: displayAccountID) })
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
            usage.invalidate()
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
            usage: usage.snapshot, runningTask: execution.hasBusyTasks || sessions.sessions.contains { $0.taskRunning },
            resumeDemand: defaults.bool(forKey: "enabled") && defaults.bool(forKey: "autoResume") && !availableTasks.isEmpty,
            executing: execution.running, criticalRefresh: usage.criticalRefreshPending)
        usage.setPolling(policy, retryOpportunity: defaults.bool(forKey: "enabled") ? schedule.retryOpportunity(at: now) : nil)
    }

    private func observeRecovery(_ snapshot: UsageSnapshot?) -> Date? {
        defer { previousUsage = snapshot }
        guard let old = previousUsage, let new = snapshot else { return nil }
        if UsageRecovery.isNatural(from: old, to: new, now: now()) {
            naturalRecoveries.formUnion(blockedSessions.filter {
                accountBindings[$0.id] == new.accountID && new.capturedAt > $0.blockedAt
            }.map(\.episodeKey))
        }
        return UsageRecovery.isEarly(from: old, to: new, now: now()) ? old.capturedAt : nil
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
        let intended = Dictionary(uniqueKeysWithValues: requests.map { ($0.target.episodeKey, $0) })
        execution.resume(requests, schedule: schedule, manual: manual,
            observedRecovery: hasConfirmedRecovery(for: chosen),
            keepPlan: chosen.contains { heldForPlan.contains($0.episodeKey) },
            isSelected: { [weak self] key in
                guard let self, keys.contains(key), self.selectedTasks.contains(where: { $0.episodeKey == key }),
                      self.runtimeHealthy, self.sessions.detectionError == nil, self.defaults.bool(forKey: "autoResume"),
                      let expected = intended[key], self.choices.mode(for: expected.target) == expected.messageMode,
                      self.choices.message(for: expected.target, default: ResumeMessagePreferences.current(defaults: self.defaults)) == expected.prompt else { return false }
                return manual ? (self.choices.recoveryDecisions?[key] == nil || self.choices.recoveryDecisions?[key]?.phase == .responded) : self.choices.recoveryDecisions?[key] == nil
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
        if !defaults.bool(forKey: "enabled"), execution.running { execution.cancelCurrent() }
        execution.reconcile(sessions: sessions.sessions, scannedAt: sessions.scannedAt, healthy: sessions.hasScanned && sessions.detectionError == nil)
        if !usage.criticalRefreshPending, usage.hasReliableReading, usage.lastError == nil,
           let snapshot = usage.snapshot, snapshot.isFresh(at: now), let account = snapshot.accountID, !account.isEmpty {
            switchAccount(to: account)
        }
        schedule = ScheduleEngine(anchorMinutes: defaults.object(forKey: "dailyAnchorMinutes") as? Int ?? 480)
        schedule.accountID = displayAccountID
        schedule.confirmedWindows = execution.confirmedWindows
        if sessions.hasScanned && sessions.detectionError == nil { confirmed = confirmed.filter { id, target in
            sessions.sessions.contains { $0.id == id && !$0.taskRunning && ($0.lastUserMessageAt ?? .distantPast) <= target.blockedAt && ($0.lastTaskStartedAt ?? .distantPast) <= target.blockedAt && ($0.lastAbortedAt ?? .distantPast) <= target.blockedAt && ($0.lastAssistantMessageAt ?? .distantPast) <= target.blockedAt }
        }
        }
        let detected = BlockedSessionDetector.detect(in: sessions.sessions).filter { raw in
            !accountStates.contains { account, state in
                guard account != displayAccountID, state.accounts[raw.id] == account,
                      let previous = state.pauses[raw.id] else { return false }
                return raw.stabilized(from: previous).episodeKey == previous.episodeKey
            }
        }.map { raw -> BlockedSession in
            var target = raw.stabilized(from: pauseRegistry[raw.id] ?? confirmed[raw.id])
            if target.retryQuota == nil,
               let attempt = execution.operations.values.filter({ $0.target.id == raw.id && $0.accountID == displayAccountID &&
                   $0.terminal == .quotaStopped && $0.turnID == raw.stoppedTurnID }).max(by: { $0.actionAt < $1.actionAt }),
               target.episodeKey != attempt.target.episodeKey { target.retryQuota = attempt.quotaBefore }
            pauseRegistry[raw.id] = target
            return target
        }
        blockedSessions = (detected + confirmed.values.filter { c in !detected.contains { $0.id == c.id } }).sorted { $0.blockedAt > $1.blockedAt }
        for target in blockedSessions where now.timeIntervalSince(target.blockedAt) < 30 {
            let key = target.episodeKey
            if workspaceAtBlock[key] == nil, workspaceCapturing.insert(key).inserted {
                Task {
                    let fingerprint = await Task.detached { WorkspaceGuard.fingerprint(cwd: target.cwd) }.value
                    workspaceAtBlock[key] = fingerprint
                }
            }
        }
        let trustedBindings = accountBindings
        if !usage.criticalRefreshPending, usage.hasReliableReading, usage.lastError == nil,
           let snapshot = usage.snapshot, snapshot.isFresh(at: now), let account = snapshot.accountID {
            for session in blockedSessions where accountBindings[session.id] == nil { accountBindings[session.id] = account }
        }
        execution.restoreLegacyEvidence(for: blockedSessions, boundAccounts: trustedBindings)
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
        // Recovery evidence and admission must use the same snapshot in this recomputation.
        let earlyRecoveryAt = observeRecovery(usage.snapshot)
        sessions.watchedPaths = execution.protectedPaths
        sessions.watchedIDs = Set(blockedSessions.map { $0.id }).union(confirmed.keys).union(execution.busyThreadIDs)
            .union(sessions.sessions.filter { $0.taskRunning }.map(\.id))
        if sessions.hasScanned && sessions.detectionError == nil {
            let current = Set(blockedSessions.filter { !execution.hasAttempted($0, accountID: displayAccountID) }.map(\.episodeKey))
            choices.recoveryDecisions = choices.recoveryDecisions?.filter { current.contains($0.key) }
        }
        let earlyPolicy = defaults.string(forKey: "earlyRecoveryPolicy") ?? "ask"
        if defaults.bool(forKey: "enabled"), defaults.bool(forKey: "autoResume"), earlyPolicy == "ask",
           sessions.hasScanned, sessions.detectionError == nil {
            for target in selectedTasks where !heldForPlan.contains(target.episodeKey) {
                if UsageRecovery.hasAvailableQuota(for: target, usage: usage.snapshot,
                    boundAccount: accountBindings[target.id], now: now) {
                    if hasConfirmedRecovery(for: [target]) {
                        if choices.recoveryDecisions?[target.episodeKey]?.phase != .responded {
                            choices.recoveryDecisions?.removeValue(forKey: target.episodeKey)
                        }
                    } else if let earlyRecoveryAt, earlyRecoveryAt > target.blockedAt {
                        choices.requestRecoveryDecision(for: target, now: now)
                        confirmed[target.id] = target
                    }
                }
            }
        }
        guard saveRuntime() else { return }
        let reminders = defaults.bool(forKey: "enabled") && defaults.bool(forKey: "autoResume") && sessions.detectionError == nil ? selectedTasks.filter {
            !(choices.ignoredEpisodes?.contains($0.episodeKey) ?? false) && choices.recoveryDecisions?[$0.episodeKey]?.phase != .responded &&
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
                needsRecoveryDecision: targets.contains { choices.recoveryDecisions?[$0.episodeKey]?.phase != .responded && choices.recoveryDecisions?[$0.episodeKey] != nil },
                reserveIdleDate: usage.hasReliableReading && usage.lastError == nil && targets.isEmpty &&
                    sessions.hasScanned && sessions.detectionError == nil && sessions.authentication != .unreadable)
            if defaults.bool(forKey: "enabled"), !targets.isEmpty, targets.allSatisfy({ choices.recoveryDecisions?[$0.episodeKey]?.phase == .responded }) {
                plan = engine.plan(now: now, enabled: true, autoResume: false, earlyRecoveryPolicy: "keepPlan", usage: usage.snapshot, blocked: [], reserveIdleDate: true)
            }
            if defaults.bool(forKey: "enabled"), targets.contains(where: { target in
                guard let snapshot = usage.snapshot, snapshot.isFresh(at: now) else { return false }
                return (target.fiveHourResetAt != nil && snapshot.fiveHour == nil) || (target.weeklyResetAt != nil && snapshot.weekly == nil)
            }) {
                plan = NextAction(mode: .resume, date: nil, decision: .wait(reason: "等待额度恢复确认"), note: "等待额度恢复确认")
            }
            if defaults.bool(forKey: "enabled"), !usage.criticalRefreshPending, usage.hasReliableReading, usage.lastError == nil,
               usage.snapshot?.isFresh(at: now) == true, let account = usage.snapshot?.accountID, !account.isEmpty,
               targets.contains(where: { accountBindings[$0.id].map { $0 != account } == true }) {
                plan = NextAction(mode: .resume, date: nil, decision: .wait(reason: "账户已改变"), note: "账户已改变")
            }
            if defaults.bool(forKey: "enabled"), let error = sessions.detectionError {
                plan = NextAction(mode: plan.mode, date: nil, decision: .wait(reason: error), note: error)
            }
            if targets.contains(where: { $0.identityUncertain == true }) {
                plan = engine.plan(now: now, enabled: true, autoResume: false, earlyRecoveryPolicy: "keepPlan", usage: usage.snapshot, blocked: [], reserveIdleDate: true)
                if case .ping = plan.decision { plan.date = schedule.nextKeepAliveNode(after: now) }
                plan.decision = .wait(reason: "确认中")
            }
            if targets.isEmpty, execution.hasBusyTasks || sessions.sessions.contains(where: { $0.taskRunning }),
               case .ping = plan.decision {
                plan = NextAction(mode: .keepAlive, date: schedule.nextKeepAliveNode(after: now),
                    decision: .wait(reason: "等待下一可行计划节点"), note: "")
            }
            if targets.contains(where: { execution.busyThreadIDs.contains($0.id) }), case .resume = plan.decision {
                plan = NextAction(mode: .keepAlive, date: schedule.nextKeepAliveNode(after: now),
                    decision: .wait(reason: "等待下一可行计划节点"), note: "")
            }
            if !targets.isEmpty, targets.contains(where: { $0.retryQuota?.provesRecovery(usage.snapshot ?? UsageSnapshot(fiveHour: nil, weekly: nil, capturedAt: .distantPast, sourceFile: ""), after: $0.blockedAt) == false }) {
                if case .resume = plan.decision {
                    let reset = [usage.snapshot?.fiveHour?.resetsAt, usage.snapshot?.weekly?.resetsAt].compactMap { $0 }.filter { $0 > now }.max()
                    plan = NextAction(mode: .resume, date: reset, decision: .wait(reason: "等待额度恢复确认"), note: "等待额度恢复确认")
                }
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
            execution.ping(schedule: schedule, accountID: usage.snapshot?.accountID, ignoredEpisodes: ignored, ignoredTargets: blockedSessions.filter { ignored.contains($0.episodeKey) }, historicalTargets: accountStates.values.flatMap { $0.pauses.values },
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
        runtimeHealthy && sessions.hasScanned && sessions.detectionError == nil &&
            !usage.criticalRefreshPending &&
            !execution.hasBusyTasks && !sessions.sessions.contains { $0.taskRunning } &&
            choices.permitsKeepAlive(for: blockedSessions, ignoring: episodes)
    }

    private func saveRuntime() -> Bool {
        let runtime = PendingRuntime(confirmed: confirmed, accounts: accountBindings, workspaces: workspaceAtBlock, held: heldForPlan, selected: nil, choices: choices, displayAccountID: displayAccountID, accountStates: accountStates, pauseRegistry: pauseRegistry)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        do {
            let data = try encoder.encode(runtime)
            if data != savedRuntime || !runtimeHealthy {
                try FileManager.default.createDirectory(at: runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: runtimeURL, options: .atomic)
                savedRuntime = data
            }
            runtimeHealthy = true
            return true
        } catch {
            runtimeHealthy = false
            recoveryReminderTasks = []
            let reason = "待续状态无法保存，暂停自动操作"
            decision = .wait(reason: reason)
            nextAction = NextAction(mode: .resume, date: nil, decision: .wait(reason: reason), note: reason)
            return false
        }
    }

    func resolveRecoveryDecision(_ choice: RecoveryChoice, for tasks: [BlockedSession]) {
        let keys = Set(tasks.filter { !execution.isContentLocked($0, accountID: displayAccountID) }.map(\.episodeKey))
        recompute(allowExecution: false)
        guard defaults.bool(forKey: "enabled"), defaults.bool(forKey: "autoResume"), sessions.detectionError == nil else { return }
        guard choice != .now || execution.canStartResume else { return }
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

    private func switchAccount(to account: String) {
        guard displayAccountID != account else { return }
        if let previous = displayAccountID {
            accountStates[previous] = AccountResumeRuntime(confirmed: confirmed, accounts: accountBindings,
                workspaces: workspaceAtBlock, held: heldForPlan, choices: choices, pauses: pauseRegistry)
            let state = accountStates[account]
            confirmed = state?.confirmed ?? [:]; accountBindings = state?.accounts ?? [:]
            workspaceAtBlock = state?.workspaces ?? [:]; heldForPlan = state?.held ?? []
            choices = state?.choices ?? ResumeChoices(); pauseRegistry = state?.pauses ?? [:]
            naturalRecoveries.removeAll(); recoveryReminderTasks = []
        }
        displayAccountID = account
    }

    var visibleOperations: [ResumeOperation] {
        execution.operations.values.filter { $0.accountID == displayAccountID && !(choices.ignoredEpisodes?.contains($0.target.episodeKey) ?? false) }
            .sorted { $0.actionAt > $1.actionAt }
    }
    var currentOperations: [ResumeOperation] {
        let latest = Dictionary(grouping: visibleOperations, by: { $0.target.episodeKey }).values.compactMap { group in group.max { $0.actionAt < $1.actionAt } }.filter { operation in
            !blockedSessions.contains { $0.id == operation.target.id && $0.episodeKey != operation.target.episodeKey && $0.blockedAt > operation.actionAt }
        }
        let active = latest.filter { operation in
            if operation.needsManualContinuation { return !(choices.readManualEvents?.contains(operation.id) ?? false) }
            if operation.phase == .checking, !operation.protectsThread { return false }
            if operation.phase == .stopped, operation.respondedAt == nil {
                return operation.terminal != .quotaStopped || !blockedSessions.contains { $0.id == operation.target.id && $0.episodeKey != operation.target.episodeKey }
            }
            return [.preparing, .sending, .confirming, .checking, .notSubmitted].contains(operation.phase)
        }
        let batches = Set(active.map(\.batchID))
        return latest.filter { batches.contains($0.batchID) }.sorted { $0.actionAt < $1.actionAt }
    }
    func taskOperations(ids: Set<String>?) -> [ResumeOperation] {
        guard let ids else { return currentOperations }
        return Dictionary(grouping: visibleOperations.filter { ids.contains($0.id) }, by: { $0.target.episodeKey })
            .values.compactMap { $0.max { $0.actionAt < $1.actionAt } }.sorted { $0.actionAt < $1.actionAt }
    }
    func ignoreEpisode(_ task: BlockedSession) -> Bool {
        let previous = choices
        if choices.ignoredEpisodes == nil { choices.ignoredEpisodes = [] }
        choices.ignoredEpisodes?.insert(task.episodeKey)
        choices.recoveryDecisions?.removeValue(forKey: task.episodeKey)
        guard saveRuntime() else { choices = previous; return false }
        recompute()
        return true
    }
    func markManualEventsRead(_ ids: Set<String>) {
        let ended = visibleOperations.filter { ids.contains($0.id) && $0.needsManualContinuation }.map(\.id)
        guard !ended.isEmpty else { return }
        let previous = choices
        if choices.readManualEvents == nil { choices.readManualEvents = [] }
        choices.readManualEvents?.formUnion(ended)
        guard saveRuntime() else { choices = previous; return }
        recompute(allowExecution: false)
    }
    func retry(_ task: BlockedSession) {
        guard execution.canStartResume, defaults.bool(forKey: "autoResume"), !execution.hasAttempted(task, accountID: displayAccountID),
              selectedTasks.contains(where: { $0.episodeKey == task.episodeKey }) else { return }
        startResume(manual: true, tasks: [task])
    }
    func planExplanation(for task: BlockedSession) -> String? {
        guard choices.recoveryDecisions?[task.episodeKey] == nil || choices.recoveryDecisions?[task.episodeKey]?.phase == .responded else { return nil }
        if let operation = execution.latestOperation(for: task, accountID: displayAccountID), operation.phase == .notSubmitted, operation.manual != true {
            return L10n.text("条件恢复后自动重试")
        }
        // The shared main plan already provides its time; no duplicate promise in the task card.
        return nil
    }
    var enabled: Bool { defaults.bool(forKey: "enabled") }
    var automaticResumeEnabled: Bool { defaults.bool(forKey: "autoResume") }
    var defaultResumeMessage: String { ResumeMessagePreferences.current(defaults: defaults) }

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
    var displayAccountID: String? = nil
    var accountStates: [String: AccountResumeRuntime]? = nil
    var pauseRegistry: [String: BlockedSession]? = nil
}

private struct AccountResumeRuntime: Codable {
    var confirmed: [String: BlockedSession]
    var accounts: [String: String]
    var workspaces: [String: String]
    var held: Set<String>
    var choices: ResumeChoices
    var pauses: [String: BlockedSession]
}
