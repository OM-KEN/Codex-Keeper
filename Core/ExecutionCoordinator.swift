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
        if FileManager.default.fileExists(atPath: self.ledgerURL.path) {
            if let data = try? Data(contentsOf: self.ledgerURL), let saved = try? JSONDecoder().decode([String].self, from: data) { attempts = Set(saved) }
            else { attempts = []; ledgerHealthy = false; status = L10n.text("执行记录无法读取，已暂停自动操作") }
        } else { attempts = [] }
        try? FileManager.default.createDirectory(at: self.ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        executionLock = Darwin.open(self.ledgerURL.deletingLastPathComponent().appendingPathComponent("execution.lock").path, O_CREAT | O_RDWR, 0o600)
        if executionLock < 0 || flock(executionLock, LOCK_EX | LOCK_NB) != 0 {
            ledgerHealthy = false
            status = L10n.text("另一个 Keeper 实例正在管理执行")
        }
        if !ledgerHealthy { lastFailure = status }
    }

    deinit { if executionLock >= 0 { Darwin.close(executionLock) } }

    func cancelCurrent() {
        guard running else { return }
        warning = nil
        generation += 1
        for transport in activeTransports.values { transport.cancel() }
        pingTransport.cancel()
        status = L10n.text("执行已停止，请在 Codex 检查原任务")
    }


    func ping(schedule: ScheduleEngine, accountID: String?, ignoredEpisodes: Set<String> = [], hasPending: @escaping () -> Bool) {
        guard ledgerHealthy, defaults.bool(forKey: "enabled"),
              !running, let node = schedule.currentNode(at: now()), let accountID else { return }
        let key = "ping:\(accountID):\(node.timeIntervalSince1970)"
        guard !attempts.contains(key) else { return }
        let operation = generation
        warning = nil
        lastFailure = nil
        activeMode = .keepAlive
        running = true
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
                guard case .ping = decision else { status = decision.text; running = false; return }
                let blocked = try await Task.detached { try SessionWatcher.freshBlockedSessions(codexHome: self.codexHome) }.value
                guard blocked.allSatisfy({ ignoredEpisodes.contains($0.episodeKey) }), !hasPending(), operation == generation,
                      defaults.bool(forKey: "enabled"), before.isFresh(at: now()),
                      schedule.currentNode(at: now()) == node else { throw CodexConnectionError.server("保活条件已改变，等待重新确认") }
                attempts.insert(key)
                try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Array(attempts)).write(to: ledgerURL, options: .atomic)
                status = L10n.text("正在建立 5 小时窗口…")
                try events.record("started", kind: "ping", node: node, before: before)
                let events = events
                let after = try await Task.detached {
                    try pingTransport.ping(before: before, model: model, provider: provider) { diagnostic in
                        try? events.record("diagnostic", kind: "ping", node: node, diagnostic: diagnostic)
                        Task { @MainActor in
                            guard self.running, self.generation == operation else { return }
                            self.warning = diagnostic.outcome == "waiting" ? diagnostic.warning : nil
                        }
                    }
                }.value
                try events.record("confirmed", kind: "ping", node: node, before: before, after: after)
                status = L10n.text("已确认新的 5 小时窗口")
            } catch {
                status = error.localizedDescription; lastFailure = status
                try? events.record("failed", kind: "ping", node: node, error: status)
            }
            warning = nil
            running = false
        }
    }

    var confirmations: [ExecutionConfirmation] { events.confirmations() }

    func hasAttempted(_ target: BlockedSession) -> Bool { attempts.contains(target.episodeKey) }

    /// Freeze the selected recovery batch, then start each task independently. A long first
    /// task must not keep the other selected tasks waiting for its completion.
    func resume(_ requests: [ResumeRequest], schedule: ScheduleEngine, manual: Bool = false,
                observedRecovery: Bool = false, keepPlan: Bool = false,
                isSelected: @escaping (String) -> Bool = { _ in true }) {
        let requests = requests.filter { !attempts.contains($0.target.episodeKey) }
        guard ledgerHealthy, !running, !requests.isEmpty,
              defaults.bool(forKey: "enabled") else { return }
        let operation = generation
        warning = nil
        lastFailure = nil
        activeMode = .resume
        running = true
        status = L10n.format("正在继续 %d 个任务", requests.count)
        Task {
            do {
                let provider = provider
                let quota = try await Task.detached { try provider.read() }.value
                let decision = DecisionEngine(schedule: schedule).plan(enabled: true,
                    autoResume: manual || defaults.bool(forKey: "autoResume"),
                    earlyRecoveryPolicy: manual ? "immediately" : keepPlan ? "keepPlan" : defaults.string(forKey: "earlyRecoveryPolicy") ?? "ask",
                    usage: quota, blocked: requests.map(\.target), observedRecovery: observedRecovery, heldForPlan: !manual && keepPlan).decision
                guard case .resume = decision else { throw CodexConnectionError.localizedMessage(decision.text) }
                let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                    for request in requests {
                        group.addTask { await self.resumeOne(request, schedule: schedule, operation: operation, manual: manual, isSelected: isSelected) }
                    }
                    var failures: [String] = []
                    for await error in group { if let error { failures.append(error) } }
                    return failures
                }
                status = failures.isEmpty ? L10n.text("所选任务已继续完成") : failures.joined(separator: L10n.text("；"))
                lastFailure = failures.isEmpty ? nil : status
            } catch { status = error.localizedDescription; lastFailure = status }
            running = false
        }
    }

    private func resumeOne(_ request: ResumeRequest, schedule: ScheduleEngine, operation: Int, manual: Bool,
                           isSelected: (String) -> Bool) async -> String? {
        let target = request.target
        let key = target.episodeKey
        let provider = provider
        let codexHome = codexHome
        do {
            let reminderEnabled = defaults.object(forKey: "resumeWorkspaceReminder") as? Bool ?? true
            let currentWorkspace = reminderEnabled ? await Task.detached { WorkspaceGuard.fingerprint(cwd: target.cwd) }.value : nil
            let body = try await Task.detached { try request.resolvedPrompt(reader: ComposerDraftReader(url: codexHome.appendingPathComponent(".codex-global-state.json"))) }.value
            let prompt = WorkspaceGuard.resumePrompt(body, before: request.workspace, after: currentWorkspace, reminderEnabled: reminderEnabled)
            let preflight = try await Task.detached { try ResumePreflight.read(target: target, provider: provider, codexHome: codexHome) }.value
            guard let account = request.accountID, preflight.usage.accountID == account,
                  preflight.usage.isFresh(at: Date()),
                  (preflight.usage.fiveHour?.usedPercent ?? 0) < 100,
                  (preflight.usage.weekly?.usedPercent ?? 0) < 100 else {
                throw CodexConnectionError.server("额度或账户已变化，等待下次恢复")
            }
            let refreshed = await Task.detached { SessionWatcher.parse(url: target.fileURL, mtime: Date()) }.value
            guard let current = refreshed, current.id == target.id, current.cwd == target.cwd,
                  operation == generation, preflight.usage.isFresh(at: Date()), !attempts.contains(key), isSelected(key),
                  (defaults.object(forKey: "dailyAnchorMinutes") as? Int ?? 480) == schedule.anchorMinutes,
                  (manual || defaults.bool(forKey: "autoResume")),
                  (current.lastUserMessageAt ?? .distantPast) <= target.blockedAt,
                  (current.lastTaskStartedAt ?? .distantPast) <= target.blockedAt,
                  (current.lastAbortedAt ?? .distantPast) <= target.blockedAt,
                  (current.lastAssistantMessageAt ?? .distantPast) <= target.blockedAt,
                  !current.taskRunning, defaults.bool(forKey: "enabled") else {
                throw CodexConnectionError.server("任务状态或选择已改变")
            }
            attempts.insert(key)
            try JSONEncoder().encode(Array(attempts)).write(to: ledgerURL, options: .atomic)
            let transport = makeResumeTransport()
            activeTransports[key] = transport
            defer { activeTransports.removeValue(forKey: key) }
            try events.record("started", kind: "resume", node: nil, threadID: target.id)
            let receipt = try await Task.detached { try transport.resume(target, prompt: prompt) }.value
            try events.record("confirmed", kind: "resume", node: nil, threadID: target.id, turnID: receipt.turnID)
            return nil
        } catch {
            try? events.record("failed", kind: "resume", node: nil, error: error.localizedDescription, threadID: target.id)
            return L10n.format("%@：%@", target.project, error.localizedDescription)
        }
    }
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
