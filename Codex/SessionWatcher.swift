import Foundation
import Combine

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
}

/// 监听 ~/.codex/sessions 的 rollout 变化（方案 §27）。
/// 启动扫一次最近 session，之后只重读 mtime 变化的文件（增量）。
@MainActor
final class SessionWatcher: ObservableObject {
    @Published private(set) var hasScanned = false
    @Published private(set) var sessions: [SessionActivity] = []

    @Published private(set) var detectionError: String?
    private let worker: SessionScanWorker
    private var timer: Timer?
    private var refreshing = false
    var watchedIDs: Set<String> = []

    init(codexHome: URL = CodexEnvironment.home) {
        worker = SessionScanWorker(codexHome: codexHome)
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
        Task {
            let result = await Task.detached { worker.read(watchedIDs: ids) }.value
            hasScanned = true
            sessions = result.0
            detectionError = result.1
            refreshing = false
        }
    }

    nonisolated static func freshBlockedSessions(codexHome: URL = CodexEnvironment.home, watchedIDs: Set<String> = []) throws -> [BlockedSession] {
        let worker = SessionScanWorker(codexHome: codexHome)
        let result = worker.read(watchedIDs: watchedIDs)
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
        var blockedAt: Date?
        var completedAt: Date?
        var blockedFive: Date?
        var blockedWeekly: Date?
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
            if let limits = payload["rate_limits"] as? [String: Any],
               (limits["limit_id"] as? String ?? limits["limitId"] as? String ?? "codex") == "codex" {
                (five, weekly) = UsageDecoder.windows(limits)
                if let reached = (limits["rate_limit_reached_type"] ?? limits["rateLimitReachedType"]) as? String, !reached.isEmpty {
                    blockedAt = timestamp; running = false
                    blockedFive = five?.usedPercent ?? 0 >= 100 ? five?.resetsAt : nil
                    blockedWeekly = weekly?.usedPercent ?? 0 >= 100 ? weekly?.resetsAt : nil
                }
            }
            if type == "task_started" { running = true; startedAt = timestamp; blockedAt = nil }
            if type == "task_complete" || type == "turn_aborted" {
                running = false; completedAt = timestamp
            }
            let texts = (payload["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            if type == "user_message" || (payload["role"] as? String == "user" && !texts.hasPrefix("<environment_context>") && !texts.hasPrefix("# AGENTS.md")) {
                userAt = timestamp; blockedAt = nil; sawError = false
            }
            if payload["role"] as? String == "assistant", !texts.isEmpty {
                assistantAt = timestamp; blockedAt = nil
            }
            if type == "turn_aborted" { blockedAt = nil; abortedAt = timestamp }
            if type == "error" || type == "turn_failed" {
                sawError = true
                running = false
                let text = String(data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(), encoding: .utf8)?.lowercased() ?? ""
                let quota = ["usage_limit_reached", "usage_limit_exceeded", "quota_exhausted", "insufficient_quota", "you’ve hit your usage limit", "you've hit your usage limit"].contains { text.contains($0) }
                if quota {
                    blockedAt = timestamp
                    blockedFive = five?.usedPercent ?? 0 >= 100 ? five?.resetsAt : nil
                    blockedWeekly = weekly?.usedPercent ?? 0 >= 100 ? weekly?.resetsAt : nil
                }
            }
        }
        if id.isEmpty {
            let name = url.deletingPathExtension().lastPathComponent
            if let range = name.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) { id = String(name[range]) }
        }
        guard UUID(uuidString: id) != nil else { return nil }
        return SessionActivity(id: id, project: cwd.isEmpty ? "未知项目" : URL(fileURLWithPath: cwd).lastPathComponent,
            cwd: cwd, fileURL: url, lastActivityAt: activity, fiveHour: five, weekly: weekly,
            sawErrorEvent: sawError, taskRunning: running, lastUserMessageAt: userAt, quotaBlockedAt: blockedAt,
            lastCompletedAt: completedAt, blockingFiveReset: blockedFive, blockingWeeklyReset: blockedWeekly, lastAssistantMessageAt: assistantAt, lastTaskStartedAt: startedAt, lastAbortedAt: abortedAt, isSubagent: isSubagent, createdAt: createdAt)
    }
}

/// Only one read is in flight. Metadata scanning is cheap; JSON parsing stays off the main actor.
private final class SessionScanWorker {
    let codexHome: URL
    let quotaLogs: QuotaErrorLogProvider
    var cache: [URL: (mtime: Date, activity: SessionActivity)] = [:]
    init(codexHome: URL) {
        self.codexHome = codexHome
        quotaLogs = QuotaErrorLogProvider(codexHome: codexHome)
    }
    func read(watchedIDs: Set<String>) -> ([SessionActivity], String?) {
        var stops: [String: QuotaStop] = [:]
        var errorMessage: String?
        let all = SessionWatcher.recentRollouts(codexHome: codexHome, limit: Int.max)
        do { stops = try quotaLogs.read() }
        catch {
            // A new installation with no sessions has no candidates to resume.
            if !all.isEmpty || !watchedIDs.isEmpty { errorMessage = error.localizedDescription }
        }
        let ids = watchedIDs.union(stops.keys)
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
            if let cached = cache[file.url], cached.mtime == file.mtime { activity = cached.activity }
            else if let parsed = SessionWatcher.parse(url: file.url, mtime: file.mtime) {
                cache[file.url] = (file.mtime, parsed); activity = parsed
            }
            guard var activity else { continue }
            activity.title = titles[activity.id]
            if let stop = stops[activity.id], !activity.isSubagent,
               (activity.createdAt ?? .distantPast) <= stop.at,
               (activity.lastUserMessageAt ?? .distantPast) <= stop.at,
               (activity.lastAssistantMessageAt ?? .distantPast) <= stop.at,
               (activity.lastTaskStartedAt ?? .distantPast) <= stop.at,
               (activity.lastAbortedAt ?? .distantPast) <= stop.at {
                activity.quotaBlockedAt = stop.at; activity.taskRunning = false
                activity.blockingFiveReset = activity.fiveHour?.usedPercent ?? 0 >= 100 ? activity.fiveHour?.resetsAt : nil
                activity.blockingWeeklyReset = activity.weekly?.usedPercent ?? 0 >= 100 ? activity.weekly?.resetsAt : nil
            }
            activities.append(activity)
        }
        let existing = Set(all.map { $0.url })
        cache = cache.filter { existing.contains($0.key) }
        return (activities.sorted { $0.lastActivityAt > $1.lastActivityAt }, errorMessage)
    }
}
