import Foundation
import Combine
import AppKit
import Network

@MainActor final class AppState: ObservableObject {
    let usage: UsageObserver
    let sessions = SessionWatcher()
    let execution: ExecutionCoordinator
    @Published private(set) var schedule: ScheduleEngine
    @Published private(set) var nextNodeText = "–"
    @Published private(set) var blockedSessions: [BlockedSession] = []
    @Published private(set) var decision: KeeperDecision?
    @Published private(set) var choices = ResumeChoices()
    @Published private(set) var nextAction: NextAction?
    private let runtimeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexKeeper/pending-runtime.json")
    private var savedRuntime: Data?
    private var previousUsage: UsageSnapshot?
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

    init() {
        let provider = AppServerUsageProvider()
        usage = UsageObserver(provider: provider)
        execution = ExecutionCoordinator(provider: provider)
        schedule = ScheduleEngine(anchorMinutes: UserDefaults.standard.object(forKey: "dailyAnchorMinutes") as? Int ?? 480)
        if let data = try? Data(contentsOf: runtimeURL), let runtime = try? JSONDecoder().decode(PendingRuntime.self, from: data) {
            confirmed = runtime.confirmed
            accountBindings = runtime.accounts
            workspaceAtBlock = runtime.workspaces
            heldForPlan = runtime.held
            choices = runtime.choices ?? ResumeChoices()
            savedRuntime = data
        }
        usage.$snapshot.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] snapshot in self?.observeRecovery(snapshot); self?.recompute() }.store(in: &cancellables)
        sessions.$sessions.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.recompute() }.store(in: &cancellables)
        execution.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        usage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
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
        let now = Date()
        guard !execution.running, UserDefaults.standard.bool(forKey: "enabled"),
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

    private func environmentChanged() {
        previousUsage = nil
        naturalRecoveries.removeAll()
        usage.invalidate()
        refresh()
    }

    private func observeRecovery(_ snapshot: UsageSnapshot?) {
        defer { previousUsage = snapshot }
        guard let old = previousUsage, let new = snapshot,
              UsageRecovery.isNatural(from: old, to: new, now: Date()) else { return }
        naturalRecoveries.formUnion(blockedSessions.map(\.episodeKey))
    }

    private func hasConfirmedRecovery(for tasks: [BlockedSession]) -> Bool {
        let now = Date()
        let keepPlan = UserDefaults.standard.string(forKey: "earlyRecoveryPolicy") == "keepPlan"
        return !tasks.isEmpty && tasks.allSatisfy { target in
            naturalRecoveries.contains(target.episodeKey) || (!keepPlan &&
                UsageRecovery.canResumeAfterScheduledReset(target, usage: usage.snapshot,
                    boundAccount: accountBindings[target.id], now: now))
        }
    }

    private func startResume(manual: Bool = false) {
        let chosen = selectedTasks
        let requests = chosen.map { target in
            ResumeRequest(target: target,
                prompt: choices.message(for: target, default: UserDefaults.standard.string(forKey: "resumeMessage") ?? L10n.text("继续")),
                accountID: accountBindings[target.id], workspace: workspaceAtBlock[target.episodeKey], messageMode: choices.mode(for: target))
        }
        execution.resume(requests, schedule: schedule, manual: manual,
            observedRecovery: hasConfirmedRecovery(for: chosen),
            keepPlan: chosen.contains { heldForPlan.contains($0.episodeKey) },
            isSelected: { [weak self] key in self?.selectedTasks.contains { $0.episodeKey == key } == true })
    }

    func recompute() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "enabled") { execution.cancelCurrent() }
        schedule = ScheduleEngine(anchorMinutes: defaults.object(forKey: "dailyAnchorMinutes") as? Int ?? 480)
        if sessions.hasScanned { confirmed = confirmed.filter { id, target in
            sessions.sessions.contains { $0.id == id && !$0.taskRunning && ($0.lastUserMessageAt ?? .distantPast) <= target.blockedAt && ($0.lastTaskStartedAt ?? .distantPast) <= target.blockedAt && ($0.lastAbortedAt ?? .distantPast) <= target.blockedAt && ($0.lastAssistantMessageAt ?? .distantPast) <= target.blockedAt }
        }
        }
        let detected = BlockedSessionDetector.detect(in: sessions.sessions)
        blockedSessions = (detected + confirmed.values.filter { c in !detected.contains { $0.id == c.id } }).sorted { $0.blockedAt > $1.blockedAt }
        for target in blockedSessions where Date().timeIntervalSince(target.blockedAt) < 30 {
            let key = target.id + ":" + String(target.blockedAt.timeIntervalSince1970)
            if workspaceAtBlock[key] == nil, workspaceCapturing.insert(key).inserted {
                Task {
                    let fingerprint = await Task.detached { WorkspaceGuard.fingerprint(cwd: target.cwd) }.value
                    workspaceAtBlock[key] = fingerprint
                }
            }
        }
        if let account = usage.snapshot?.accountID {
            for session in blockedSessions where accountBindings[session.id] == nil { accountBindings[session.id] = account }
        }
        blockedSessions = blockedSessions.map { target in
            let supported = target.withRecoveryEvidence(from: confirmed[target.id], usage: usage.snapshot,
                boundAccount: accountBindings[target.id], now: Date())
            if supported.fiveHourResetAt != nil || supported.weeklyResetAt != nil {
                confirmed[target.id] = supported
            } else if confirmed[target.id]?.episodeKey != target.episodeKey {
                confirmed.removeValue(forKey: target.id)
            }
            return supported
        }
        sessions.watchedIDs = Set(blockedSessions.map { $0.id }).union(confirmed.keys)
        let runtime = PendingRuntime(confirmed: confirmed, accounts: accountBindings, workspaces: workspaceAtBlock, held: heldForPlan, selected: nil, choices: choices)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(runtime), data != savedRuntime {
            do {
                try FileManager.default.createDirectory(at: runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: runtimeURL, options: .atomic)
                savedRuntime = data
            } catch { decision = .wait(reason: "待续状态无法保存，暂停自动操作"); return }
        }
        let chosen = selectedTasks
        let engine = DecisionEngine(schedule: schedule)
        var plan = engine.plan(enabled: defaults.bool(forKey: "enabled"), autoResume: defaults.bool(forKey: "autoResume"),
            earlyRecoveryPolicy: defaults.string(forKey: "earlyRecoveryPolicy") ?? "ask", usage: usage.snapshot,
            blocked: chosen, observedRecovery: hasConfirmedRecovery(for: chosen),
            heldForPlan: chosen.contains { heldForPlan.contains($0.episodeKey) })
        if defaults.bool(forKey: "enabled"), !availableTasks.isEmpty && chosen.isEmpty {
            plan = NextAction(mode: .resume, date: nil, decision: .wait(reason: "请选择要继续的任务"), note: "请选择要继续的任务")
        }
        if defaults.bool(forKey: "enabled"), chosen.contains(where: { accountBindings[$0.id] != usage.snapshot?.accountID }) {
            plan = NextAction(mode: .resume, date: nil, decision: .wait(reason: "账户已改变"), note: "账户已改变")
        }
        if defaults.bool(forKey: "enabled"), let error = sessions.detectionError {
            plan = NextAction(mode: plan.mode, date: nil, decision: .wait(reason: error), note: error)
        }
        nextAction = plan
        decision = plan.decision
        nextNodeText = MenuSummary.build(plan: plan, usage: usage.snapshot, schedule: schedule, tasks: chosen).statusText
        if case .ping = decision {
            execution.ping(schedule: schedule, accountID: usage.snapshot?.accountID, ignoredEpisodes: choices.keepAliveEpisodes,
                hasPending: { [weak self] in self?.choices.available(self?.blockedSessions ?? []).isEmpty != true })
        }
        if case .resume = decision { startResume() }
    }

    var resetDate: Date? { usage.snapshot?.nextResetDate(at: Date()) }

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
