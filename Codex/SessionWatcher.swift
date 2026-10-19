import Foundation
import Combine

struct UserUsageEvidence: Equatable {
    let promptAt: Date
    let usageAt: Date
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?

    func matches(_ usage: UsageSnapshot) -> Bool {
        (fiveHourResetAt != nil || weeklyResetAt != nil) &&
        fiveHourResetAt == usage.fiveHour?.resetsAt && weeklyResetAt == usage.weekly?.resetsAt
    }
}

enum AuthenticationObservation: Equatable {
    case known(Data?)
    case unreadable
}

/// 单个 Codex session 的活动概况
struct SessionActivity: Equatable {
    let id: String
    let project: String
    let cwd: String
    let fileURL: URL
    var lastActivityAt: Date
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    var sawErrorEvent: Bool
    var taskRunning: Bool
    var lastUserMessageAt: Date?
    var quotaBlockedAt: Date? = nil
    var lastCompletedAt: Date? = nil
    var blockingFiveReset: Date? = nil
    var blockingWeeklyReset: Date? = nil
    var lastAssistantMessageAt: Date? = nil
    var lastTaskStartedAt: Date? = nil
    var lastAbortedAt: Date? = nil
    var title: String? = nil
    var isSubagent = false
    var createdAt: Date? = nil
    // Time of a real desktop user request whose subsequent token usage demonstrably increased.
    var userUsage: UserUsageEvidence? = nil
    var currentTurnID: String? = nil
    var quotaTurnID: String? = nil
    var turns: [String: SessionTurnEvidence] = [:]
    var lastRetryingErrorAt: Date? = nil
}

/// 监听 ~/.codex/sessions 的 rollout 变化（方案 §27）。
/// 启动扫一次最近 session，之后只重读 mtime 变化的文件（增量）。
@MainActor
final class SessionWatcher: ObservableObject {
    @Published private(set) var hasScanned = false
    @Published private(set) var sessions: [SessionActivity] = []

    @Published private(set) var detectionError: String?
    @Published private(set) var authentication: AuthenticationObservation = .unreadable
    private let worker: SessionScanWorker
    private var timer: Timer?
    private var refreshing = false
    var watchedIDs: Set<String> = []
    var watchedPaths: [URL] = []
    @Published private(set) var scannedAt: Date?

    init(codexHome: URL = CodexEnvironment.home, worker: SessionScanWorker? = nil) {
        self.worker = worker ?? SessionScanWorker(codexHome: codexHome)
    }
    func start(interval: TimeInterval = 20) {
        refresh()
        timer?.invalidate()
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let worker = worker
        let ids = watchedIDs
        let paths = watchedPaths
        Task {
            let result = await Task.detached { () -> ([SessionActivity], String?, AuthenticationObservation) in
                let sessions = worker.read(watchedIDs: ids, watchedPaths: paths)
                let auth: AuthenticationObservation
                do { auth = .known(try AppServerUsageProvider.authenticationIdentity(home: worker.codexHome)) }
                catch { auth = .unreadable }
                return (sessions.0, sessions.1, auth)
            }.value
            authentication = result.2
            scannedAt = Date()
            hasScanned = true
            detectionError = result.1
            sessions = result.0
            refreshing = false
        }
    }

    nonisolated static func freshBlockedSessions(codexHome: URL = CodexEnvironment.home, watchedIDs: Set<String> = [], worker: SessionScanWorker? = nil) throws -> [BlockedSession] {
        let scanner = worker ?? SessionScanWorker(codexHome: codexHome)
        let result = scanner.read(watchedIDs: watchedIDs)
        if let error = result.1 { throw CodexConnectionError.server(error) }
        return BlockedSessionDetector.detect(in: result.0)
    }

    // MARK: - 文件扫描

    nonisolated static func recentRollouts(codexHome: URL, limit: Int) -> [(url: URL, mtime: Date)] {
        let sessionsDir = codexHome.appending(path: "sessions", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate else { continue }
            files.append((url, mtime))
        }
        files.sort { $0.mtime > $1.mtime }
        return Array(files.prefix(limit))
    }

    // MARK: - rollout 解析

    nonisolated static func parse(url: URL, mtime: Date) -> SessionActivity? {
        guard let data = try? Data(contentsOf: url), let content = String(data: data, encoding: .utf8) else { return nil }
        var id = ""
        var cwd = ""
        var activity = mtime
        var five: QuotaWindow?
        var weekly: QuotaWindow?
        var running = false
        var sawError = false
        var userAt: Date?
        var assistantAt: Date?
        var startedAt: Date?
        var abortedAt: Date?
        var isSubagent = false
        var createdAt: Date?
        var inheritedThrough: Date?
        var userUsage: UserUsageEvidence?
        var usagePromptAt: Date?
        var tokenTotal: Int?
        var promptTokenBaseline: Int?
        var blockedAt: Date?
        var completedAt: Date?
        var blockedFive: Date?
        var blockedWeekly: Date?
        var currentTurn: String?
        var quotaTurn: String?
        var turns: [String: SessionTurnEvidence] = [:]
        var retryingErrorAt: Date?
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8), let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any] else { continue }
            let timestamp = UsageDecoder.timestamp(entry["timestamp"] as? String) ?? mtime
            if entry["type"] as? String == "session_meta" {
                // A fork embeds its parent's metadata/history after the owner's first record.
                // Never let those records change file identity or subagent eligibility.
                guard id.isEmpty, let owner = payload["id"] as? String, UUID(uuidString: owner) != nil else { continue }
                id = owner
                cwd = payload["cwd"] as? String ?? ""
                isSubagent = (payload["source"] as? [String: Any])?["subagent"] != nil
                createdAt = UsageDecoder.timestamp(payload["timestamp"] as? String) ?? UsageDecoder.timestamp(entry["timestamp"] as? String)
                if payload["forked_from_id"] == nil && !isSubagent { tokenTotal = 0 }
                if payload["forked_from_id"] != nil || isSubagent {
                    // Copied history may be re-stamped at the fork's first-record time.
                    // Only subsequent events belong to the new session's execution.
                    inheritedThrough = timestamp
                }
                continue
            }
            if let inheritedThrough, timestamp <= inheritedThrough { continue }
            if let threadID = (payload["thread_id"] ?? payload["threadId"]) as? String, threadID != id { continue }
            activity = timestamp
            let type = payload["type"] as? String ?? ""
            let explicitTurn = (payload["turn_id"] ?? payload["turnId"]) as? String
            if type == "task_started" { currentTurn = explicitTurn }
            else if entry["type"] as? String == "turn_context", let explicitTurn { currentTurn = explicitTurn }
            let eventTurn = explicitTurn ?? currentTurn
            if let turn = eventTurn, let at = UsageDecoder.timestamp(entry["timestamp"] as? String) {
                var evidence = turns[turn] ?? SessionTurnEvidence()
                if type == "task_started" { evidence.startedAt = at }
                if ResumeModelActivity.rollout(entry), evidence.startedAt != nil, evidence.responseAt == nil { evidence.responseAt = at }
                if type == "task_complete" || type == "turn_aborted" {
                    if type == "turn_aborted" { evidence.endedAt = at; evidence.terminal = .aborted }
                    else { evidence.endedAt = evidence.endedAt ?? at; evidence.terminal = evidence.terminal ?? .completed }
                    if let error = payload["error"], !(error is NSNull) {
                        let text = String(describing: error)
                        evidence.terminal = ResumeModelActivity.quotaError(text) ? .quotaStopped : .failed
                    }
                }
                if (type == "error" || type == "turn_failed"), payload["will_retry"] as? Bool != true {
                    evidence.endedAt = at
                    evidence.terminal = ResumeModelActivity.quotaError(String(describing: payload)) ? .quotaStopped : .failed
                }
                turns[turn] = evidence
            }
            if let limits = payload["rate_limits"] as? [String: Any],
               (limits["limit_id"] as? String ?? limits["limitId"] as? String ?? "codex") == "codex" {
                (five, weekly) = UsageDecoder.windows(limits)
                if let reached = (limits["rate_limit_reached_type"] ?? limits["rateLimitReachedType"]) as? String, !reached.isEmpty {
                    blockedAt = timestamp; quotaTurn = eventTurn; running = false
                    blockedFive = five?.usedPercent ?? 0 >= 100 ? five?.resetsAt : nil
                    blockedWeekly = weekly?.usedPercent ?? 0 >= 100 ? weekly?.resetsAt : nil
                }
            }
            let validTimestamp = UsageDecoder.timestamp(entry["timestamp"] as? String)
            if type == "token_count", let promptAt = usagePromptAt, let at = validTimestamp, at >= promptAt,
               let info = payload["info"] as? [String: Any],
               let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int {
                if let baseline = promptTokenBaseline, total > baseline,
                   ((info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int ?? 0) > 0,
                   let limits = payload["rate_limits"] as? [String: Any],
                   (limits["limit_id"] as? String ?? limits["limitId"] as? String ?? "codex") == "codex",
                   (limits["rate_limit_reached_type"] as? String ?? limits["rateLimitReachedType"] as? String ?? "").isEmpty {
                    let windows = UsageDecoder.windows(limits)
                    if windows.0 != nil || windows.1 != nil,
                       (windows.0?.usedPercent ?? 0) < 100, (windows.1?.usedPercent ?? 0) < 100 {
                        userUsage = UserUsageEvidence(promptAt: promptAt, usageAt: at,
                            fiveHourResetAt: windows.0?.resetsAt, weeklyResetAt: windows.1?.resetsAt)
                    }
                }
                // An initial token snapshot establishes a baseline; replayed usage is not new activity.
                promptTokenBaseline = total
            }
            if type == "token_count", let info = payload["info"] as? [String: Any],
               let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int {
                tokenTotal = total
            }
            if ResumeModelActivity.rollout(entry) { assistantAt = timestamp; blockedAt = nil }
            if (type == "error" || type == "turn_failed"), payload["will_retry"] as? Bool == true { retryingErrorAt = timestamp; running = true; blockedAt = nil; quotaTurn = nil }
            if type == "task_started" { running = true; startedAt = timestamp; blockedAt = nil; quotaTurn = nil }
            if type == "task_complete" || type == "turn_aborted" {
                running = false; completedAt = timestamp
                usagePromptAt = nil
            }
            let texts = (payload["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            if payload["role"] as? String == "user", !isSubagent, let at = validTimestamp,
               let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any],
               (metadata["content_item_kinds"] as? [String])?.contains("user.text") == true,
               !texts.isEmpty, !texts.hasPrefix("<environment_context>"), !texts.hasPrefix("# AGENTS.md") {
                usagePromptAt = at
                promptTokenBaseline = tokenTotal
            }
            if type == "user_message" || (payload["role"] as? String == "user" && !texts.hasPrefix("<environment_context>") && !texts.hasPrefix("# AGENTS.md")) {
                userAt = timestamp; blockedAt = nil; sawError = false
            }
            if payload["role"] as? String == "assistant", !texts.isEmpty {
                assistantAt = timestamp; blockedAt = nil
            }
            if type == "turn_aborted" { blockedAt = nil; abortedAt = timestamp }
            if (type == "error" || type == "turn_failed"), payload["will_retry"] as? Bool != true {
                sawError = true
                running = false
                usagePromptAt = nil
                let text = String(data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(), encoding: .utf8)?.lowercased() ?? ""
                let quota = ["usage_limit_reached", "usage_limit_exceeded", "quota_exhausted", "insufficient_quota", "you’ve hit your usage limit", "you've hit your usage limit"].contains { text.contains($0) }
                if quota {
                    blockedAt = timestamp; quotaTurn = eventTurn
                    blockedFive = five?.usedPercent ?? 0 >= 100 ? five?.resetsAt : nil
                    blockedWeekly = weekly?.usedPercent ?? 0 >= 100 ? weekly?.resetsAt : nil
                }
            }
        }
        if let turn = currentTurn, let evidence = turns[turn], evidence.terminal == .quotaStopped, let at = evidence.endedAt {
            blockedAt = at; quotaTurn = turn; running = false
        }
        if id.isEmpty {
            let name = url.deletingPathExtension().lastPathComponent
            if let range = name.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) { id = String(name[range]) }
        }
        guard UUID(uuidString: id) != nil else { return nil }
        return SessionActivity(id: id, project: cwd.isEmpty ? L10n.text("未知项目") : URL(fileURLWithPath: cwd).lastPathComponent,
            cwd: cwd, fileURL: url, lastActivityAt: activity, fiveHour: five, weekly: weekly,
            sawErrorEvent: sawError, taskRunning: running, lastUserMessageAt: userAt, quotaBlockedAt: blockedAt,
            lastCompletedAt: completedAt, blockingFiveReset: blockedFive, blockingWeeklyReset: blockedWeekly, lastAssistantMessageAt: assistantAt, lastTaskStartedAt: startedAt, lastAbortedAt: abortedAt, isSubagent: isSubagent, createdAt: createdAt, userUsage: userUsage, currentTurnID: currentTurn, quotaTurnID: quotaTurn, turns: turns, lastRetryingErrorAt: retryingErrorAt)
    }
}

/// The watcher and preflight share one serialized parser cache, never a cached permission to send.
final class SessionScanWorker: @unchecked Sendable {
    let codexHome: URL
    private let quotaLogs: QuotaErrorLogProvider
    private let lock = NSLock()
    private let parseRollout: (URL, Date) -> SessionActivity?
    private var cache: [URL: (mtime: Date, size: UInt64, inode: UInt64, activity: SessionActivity)] = [:]
    init(codexHome: URL, parseRollout: @escaping (URL, Date) -> SessionActivity? = { SessionWatcher.parse(url: $0, mtime: $1) }) {
        self.codexHome = codexHome
        self.parseRollout = parseRollout
        quotaLogs = QuotaErrorLogProvider(codexHome: codexHome)
    }
    func read(watchedIDs: Set<String>, watchedPaths: [URL] = []) -> ([SessionActivity], String?) {
        lock.lock(); defer { lock.unlock() }
        var stops: [String: QuotaStop] = [:]
        var errorMessage: String?
        var all = SessionWatcher.recentRollouts(codexHome: codexHome, limit: Int.max)
        for path in watchedPaths where !all.contains(where: { $0.url == path }) {
            if let values = try? path.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true,
               let mtime = values.contentModificationDate { all.append((path, mtime)) }
        }
        do { stops = try quotaLogs.read() }
        catch {
            // A new installation with no sessions has no candidates to resume.
            if !all.isEmpty || !watchedIDs.isEmpty { errorMessage = error.localizedDescription }
        }
        let runningIDs = Set(cache.values.filter { $0.activity.taskRunning }.map { $0.activity.id })
        let ids = watchedIDs.union(stops.keys).union(runningIDs)
        let recent = Set(all.prefix(20).map { $0.url })
        let files = all.filter { file in recent.contains(file.url) || ids.contains { file.url.deletingPathExtension().lastPathComponent.hasSuffix($0) } }
        var titles: [String: String] = [:]
        if let index = try? String(contentsOf: codexHome.appendingPathComponent("session_index.jsonl"), encoding: .utf8) {
            for line in index.split(separator: "\n") {
                if let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let id = entry["id"] as? String, let title = entry["thread_name"] as? String, !title.isEmpty {
                    titles[id] = title
                }
            }
        }
        var activities: [SessionActivity] = []
        for file in files {
            var activity: SessionActivity?
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path)
            let size = (attributes?[.size] as? NSNumber)?.uint64Value
            let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
            if let cached = cache[file.url], let size, let inode,
               cached.mtime == file.mtime, cached.size == size, cached.inode == inode { activity = cached.activity }
            else if let parsed = parseRollout(file.url, file.mtime) {
                cache[file.url] = (file.mtime, size ?? 0, inode ?? 0, parsed); activity = parsed
            } else {
                let name = file.url.deletingPathExtension().lastPathComponent
                if cache[file.url] != nil || name.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil {
                    errorMessage = L10n.text("无法读取 Codex 本地暂停记录")
                }
                activity = cache[file.url]?.activity
            }
            guard var activity else { continue }
            activity.title = titles[activity.id]
            if let stop = stops[activity.id], !activity.isSubagent,
               (activity.createdAt ?? .distantPast) <= stop.at,
               (activity.lastUserMessageAt ?? .distantPast) <= stop.at,
               (activity.lastAssistantMessageAt ?? .distantPast) <= stop.at,
               (activity.lastTaskStartedAt ?? .distantPast) <= stop.at,
               (activity.lastAbortedAt ?? .distantPast) <= stop.at,
               (stop.turnID == nil || activity.currentTurnID == nil || stop.turnID == activity.currentTurnID),
               activity.quotaBlockedAt == nil,
               (activity.lastRetryingErrorAt ?? .distantPast) < stop.at {
                activity.quotaBlockedAt = stop.at; activity.quotaTurnID = stop.turnID ?? activity.currentTurnID; activity.taskRunning = false
                if let turn = activity.quotaTurnID {
                    var evidence = activity.turns[turn] ?? SessionTurnEvidence()
                    evidence.endedAt = stop.at; evidence.terminal = .quotaStopped
                    activity.turns[turn] = evidence
                }
                activity.blockingFiveReset = activity.fiveHour?.usedPercent ?? 0 >= 100 ? activity.fiveHour?.resetsAt : nil
                activity.blockingWeeklyReset = activity.weekly?.usedPercent ?? 0 >= 100 ? activity.weekly?.resetsAt : nil
            }
            activities.append(activity)
        }
        let existing = Set(all.map { $0.url })
        if cache.contains(where: { !existing.contains($0.key) && $0.value.activity.taskRunning }) {
            errorMessage = L10n.text("无法读取 Codex 本地暂停记录")
            activities += cache.filter { !existing.contains($0.key) && $0.value.activity.taskRunning }.map { $0.value.activity }
        }
        cache = cache.filter { existing.contains($0.key) || $0.value.activity.taskRunning }
        return (activities.sorted { $0.lastActivityAt > $1.lastActivityAt }, errorMessage)
    }
}
