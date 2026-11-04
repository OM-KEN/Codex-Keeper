import Foundation
import Combine
import SQLite3
import CryptoKit
import Darwin

private enum SessionRolloutReadError: Error { case invalidUTF8 }

struct SessionScanDiagnostic: Equatable {
    var stage: String
    var code: Int? = nil
    var domain: String? = nil
    var primaryCode: Int? = nil
    var fileFingerprint: String? = nil

    var logValue: [String: Any] {
        var value: [String: Any] = ["stage": stage]
        if let code { value["code"] = code }
        if let domain { value["domain"] = domain }
        if let primaryCode { value["sqlite_primary_code"] = primaryCode }
        if let fileFingerprint { value["file_fingerprint"] = fileFingerprint }
        return value
    }
}

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
    var currentRolloutVerified = false
}

/// 监听 ~/.codex/sessions 的 rollout 变化（方案 §27）。
/// 启动扫一次最近 session，之后只重读 mtime 变化的文件（增量）。
@MainActor
final class SessionWatcher: ObservableObject {
    // Consumers must see the matching sessions, authentication and scan result together.
    var onRefreshCompleted: (() -> Void)?
    @Published private(set) var hasScanned = false
    @Published private(set) var sessions: [SessionActivity] = []

    @Published private(set) var detectionError: String?
    private(set) var scanFailures: [SessionScanDiagnostic] = []
    @Published private(set) var authentication: AuthenticationObservation = .unreadable
    private let worker: SessionScanWorker
    private var timer: Timer?
    private var refreshing = false
    private var suspended = false
    private var generation = 0
    var watchedIDs: Set<String> = []
    var watchedPaths: [URL] = []
    var ignoredPauses: [String: BlockedSession] = [:]
    @Published private(set) var scannedAt: Date?

    init(codexHome: URL = CodexEnvironment.home, worker: SessionScanWorker? = nil) {
        self.worker = worker ?? SessionScanWorker(codexHome: codexHome)
    }
    func start(interval: TimeInterval = 20) {
        worker.invalidateDirectories(paths: [], fullRescan: true)
        suspended = false
        hasScanned = false
        scannedAt = nil
        refresh()
        timer?.invalidate()
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func stop() {
        suspended = true; generation += 1; refreshing = false
        timer?.invalidate(); timer = nil
    }
    func filesChanged(paths: [String], fullRescan: Bool) { worker.invalidateDirectories(paths: paths, fullRescan: fullRescan) }
    func refresh() {
        guard !suspended, !refreshing else { return }
        refreshing = true
        let worker = worker
        let ids = watchedIDs
        let paths = watchedPaths
        let ignored = ignoredPauses
        let generation = self.generation
        Task {
            guard !suspended, self.generation == generation else { return }
            let result = await Task.detached { () -> ([SessionActivity], String?, AuthenticationObservation, [SessionScanDiagnostic]) in
                let sessions = worker.read(watchedIDs: ids, watchedPaths: paths, ignoredPauses: ignored, protectedIDs: ids, forceDirectoryScan: false)
                let auth: AuthenticationObservation
                do { auth = .known(try AppServerUsageProvider.authenticationIdentity(home: worker.codexHome)) }
                catch { auth = .unreadable }
                return (sessions.0, sessions.1, auth, sessions.2)
            }.value
            guard !suspended, self.generation == generation else { return }
            authentication = result.2
            scannedAt = Date()
            hasScanned = true
            scanFailures = result.3
            detectionError = result.1
            sessions = result.0
            refreshing = false
            onRefreshCompleted?()
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
        for case let url as URL in enumerator where url.pathExtension == "jsonl" || (url.pathExtension == "zst" && url.deletingPathExtension().pathExtension == "jsonl") {
            guard RolloutFile.resolvedURL(url) == url else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate else { continue }
            files.append((url, mtime))
        }
        files.sort { $0.mtime > $1.mtime }
        return Array(files.prefix(limit))
    }

    // MARK: - rollout 解析

    nonisolated static func rolloutThreadID(_ url: URL) -> String? {
        let name = RolloutFile.plainURL(url).deletingPathExtension().lastPathComponent
        guard let range = name.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?=_[0-9a-fA-F-]{36}$|$)"#, options: .regularExpression) else { return nil }
        return String(name[range])
    }

    nonisolated static func parse(url: URL, mtime: Date) -> SessionActivity? {
        try? readRollout(url: url, mtime: mtime)
    }

    nonisolated fileprivate static func readRollout(url: URL, mtime: Date) throws -> SessionActivity? {
        try SessionRolloutReader().read(url: url, mtime: mtime)
    }

}

private struct SessionFileStamp: Equatable {
    let inode: UInt64
    let size: UInt64
    let modified: Date
    let changedSeconds: Int
    let changedNanoseconds: Int
    let isDirectory: Bool
    let isRegularFile: Bool

    init?(_ url: URL, followLinks: Bool = true) {
        var info = stat()
        let result = followLinks ? stat(url.path, &info) : lstat(url.path, &info)
        guard result == 0 else { return nil }
        inode = UInt64(info.st_ino); size = UInt64(max(0, info.st_size))
        modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        isDirectory = info.st_mode & S_IFMT == S_IFDIR; isRegularFile = info.st_mode & S_IFMT == S_IFREG
    }
}

/// Cache directory membership, while native invalidations and a one-minute fallback refresh file order.
/// Directory stamps are checked on every background pass, including already-known deep date folders.
private final class SessionRolloutDirectoryIndex {
    private struct Directory {
        var stamp: SessionFileStamp
        var children: [URL]
        var files: Set<URL>
    }
    private let root: URL
    private var directories: [URL: Directory] = [:]
    private var files: [URL: Date] = [:]
    private var ranked: [(url: URL, mtime: Date)] = []
    private var orderChanged = true
    private var dirtyDirectories: Set<URL> = []
    private var dirtyFiles: Set<URL> = []
    private var needsFullScan = true
    private var lastFullScan: Date?
    private(set) var listingCount = 0
    private(set) var fullScanCount = 0

    init(home: URL) { root = home.resolvingSymlinksInPath().appendingPathComponent("sessions").standardizedFileURL }

    func invalidate(paths: [String], fullRescan: Bool) {
        needsFullScan = needsFullScan || fullRescan
        for raw in paths {
            let url = URL(fileURLWithPath: raw).standardizedFileURL
            guard url == root || url.path.hasPrefix(root.path + "/") else { continue }
            if Self.isRollout(url) {
                dirtyFiles.insert(url)
                if files[url] == nil || SessionFileStamp(url) == nil { dirtyDirectories.insert(url.deletingLastPathComponent()) }
            } else { dirtyDirectories.insert(url) }
        }
    }

    func read(now: Date, force: Bool) -> [(url: URL, mtime: Date)] {
        let full = force || needsFullScan || (lastFullScan.map { now < $0 || now.timeIntervalSince($0) >= 60 } ?? true)
        if full {
            directories.removeAll(); files.removeAll(); orderChanged = true
            lastFullScan = now; fullScanCount += 1; needsFullScan = false
        }
        var visited = Set<URL>()
        func visit(_ url: URL) {
            guard let stamp = SessionFileStamp(url, followLinks: false), stamp.isDirectory else { return }
            visited.insert(url)
            if directories[url]?.stamp != stamp || dirtyDirectories.contains(url) {
                let old = directories[url]?.files ?? []
                let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                listingCount += 1
                var children: [URL] = [], current = Set<URL>()
                for entry in entries {
                    guard let info = SessionFileStamp(entry, followLinks: false) else { continue }
                    if info.isDirectory { children.append(entry) }
                    else if info.isRegularFile && Self.isRollout(entry) && RolloutFile.resolvedURL(entry) == entry {
                        current.insert(entry)
                        if files[entry] != info.modified { files[entry] = info.modified; orderChanged = true }
                    }
                }
                for removed in old.subtracting(current) { files.removeValue(forKey: removed); orderChanged = true }
                directories[url] = Directory(stamp: stamp, children: children, files: current)
            }
            for child in directories[url]?.children ?? [] { visit(child) }
        }
        visit(root)
        for obsolete in directories.keys.filter({ !visited.contains($0) }) {
            for file in directories[obsolete]?.files ?? [] { files.removeValue(forKey: file); orderChanged = true }
            directories.removeValue(forKey: obsolete)
        }
        // The hot files remain current even when a native write notification is still queued.
        let recent = ranked.prefix(20).map(\.url)
        for url in dirtyFiles.union(recent) where files[url] != nil {
            if let info = SessionFileStamp(url), info.isRegularFile, RolloutFile.resolvedURL(url) == url {
                if files[url] != info.modified { files[url] = info.modified; orderChanged = true }
            } else if files.removeValue(forKey: url) != nil { orderChanged = true }
        }
        dirtyDirectories.removeAll(); dirtyFiles.removeAll()
        if orderChanged {
            ranked = files.map { (url: $0.key, mtime: $0.value) }.sorted { $0.mtime == $1.mtime ? $0.url.path < $1.url.path : $0.mtime > $1.mtime }
            orderChanged = false
        }
        return ranked
    }

    private static func isRollout(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" || (url.pathExtension == "zst" && url.deletingPathExtension().pathExtension == "jsonl")
    }
}

/// Carries only parsed session facts across appends; no historical message text is retained.
private struct SessionRolloutState {
    var id = ""
    var cwd = ""
    var activity = Date.distantPast
    var sawActivity = false
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
    var needsMtimeReplay = false

    mutating func append(_ data: Data, mtime: Date) {
        guard let entry = SessionRolloutDecoder.decode(data),
              let payload = entry["payload"] as? [String: Any] else { return }
        let validTimestamp = UsageDecoder.timestamp(entry["timestamp"] as? String)
        if validTimestamp == nil { needsMtimeReplay = true }
        let timestamp = validTimestamp ?? mtime
        if entry["type"] as? String == "session_meta" {
            // A fork embeds its parent's metadata/history after the owner's first record.
            // Never let those records change file identity or subagent eligibility.
            guard id.isEmpty, let owner = payload["id"] as? String, UUID(uuidString: owner) != nil else { return }
            id = owner
            cwd = payload["cwd"] as? String ?? ""
            isSubagent = (payload["source"] as? [String: Any])?["subagent"] != nil
            createdAt = UsageDecoder.timestamp(payload["timestamp"] as? String) ?? validTimestamp
            if payload["forked_from_id"] == nil && payload["history_base"] == nil && !isSubagent { tokenTotal = 0 }
            if payload["forked_from_id"] != nil || payload["history_base"] != nil || isSubagent {
                // Copied history may be re-stamped at the fork's first-record time.
                // Only subsequent events belong to the new session's execution.
                inheritedThrough = timestamp
            }
            return
        }
        if let inheritedThrough, timestamp <= inheritedThrough { return }
        if let threadID = (payload["thread_id"] ?? payload["threadId"]) as? String, threadID != id { return }
        activity = timestamp; sawActivity = true
        let type = payload["type"] as? String ?? ""
        let explicitTurn = (payload["turn_id"] ?? payload["turnId"]) as? String
        if type == "task_started" { currentTurn = explicitTurn }
        else if entry["type"] as? String == "turn_context", let explicitTurn { currentTurn = explicitTurn }
        let eventTurn = explicitTurn ?? currentTurn
        if let turn = eventTurn, let at = validTimestamp {
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

    func snapshot(url: URL, mtime: Date) -> SessionActivity? {
        var copy = self
        return copy.finish(url: url, mtime: mtime)
    }

    private mutating func finish(url: URL, mtime: Date) -> SessionActivity? {
        if let turn = currentTurn, let evidence = turns[turn], evidence.terminal == .quotaStopped, let at = evidence.endedAt {
            blockedAt = at; quotaTurn = turn; running = false
        }
        if id.isEmpty {
            id = SessionWatcher.rolloutThreadID(url) ?? ""
        }
        guard UUID(uuidString: id) != nil else { return nil }
        return SessionActivity(id: id, project: cwd.isEmpty ? L10n.text("未知项目") : URL(fileURLWithPath: cwd).lastPathComponent,
            cwd: cwd, fileURL: url, lastActivityAt: sawActivity ? activity : mtime, fiveHour: five, weekly: weekly,
            sawErrorEvent: sawError, taskRunning: running, lastUserMessageAt: userAt, quotaBlockedAt: blockedAt,
            lastCompletedAt: completedAt, blockingFiveReset: blockedFive, blockingWeeklyReset: blockedWeekly, lastAssistantMessageAt: assistantAt, lastTaskStartedAt: startedAt, lastAbortedAt: abortedAt, isSubagent: isSubagent, createdAt: createdAt, userUsage: userUsage, currentTurnID: currentTurn, quotaTurnID: quotaTurn, turns: turns, lastRetryingErrorAt: retryingErrorAt)
    }
}

/// A file change invalidates permission checks, but an append need not reparse its history.
final class SessionRolloutReader {
    private struct Cursor {
        var inode: UInt64
        var offset: UInt64 = 0
        var mtime: Date
        var stamp: SessionFileStamp?
        var state = SessionRolloutState()
        var pending = Data()
        var header = Data()
        var anchor = Data()
    }
    private var cursors: [URL: Cursor] = [:]

    func retainFiles(_ paths: Set<URL>) { cursors = cursors.filter { paths.contains($0.key) } }

    func read(url: URL, mtime: Date) throws -> SessionActivity? {
        let actual = RolloutFile.resolvedURL(url)
        if actual.pathExtension == "zst" {
            var state = SessionRolloutState()
            try RolloutFile.forEachLine(actual) { line in
                try autoreleasepool {
                    guard String(data: line, encoding: .utf8) != nil else { throw SessionRolloutReadError.invalidUTF8 }
                    state.append(line, mtime: mtime)
                }
            }
            return state.snapshot(url: actual, mtime: mtime)
        }
        let url = actual
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let stamp = SessionFileStamp(url), stamp.isRegularFile else { throw CocoaError(.fileReadUnknown) }
        let inode = stamp.inode, size = stamp.size
        var cursor = cursors[url]
        var restart = cursor == nil || cursor?.inode != inode || size < (cursor?.offset ?? 0)
        if let old = cursor, !restart {
            restart = old.state.needsMtimeReplay && old.mtime != mtime || (size == old.offset && (old.mtime != mtime || old.stamp != stamp))
            if !restart, !old.header.isEmpty {
                restart = try handle.read(upToCount: old.header.count) != old.header
            }
            if !restart, !old.anchor.isEmpty {
                try handle.seek(toOffset: old.offset - UInt64(old.anchor.count))
                restart = try handle.read(upToCount: old.anchor.count) != old.anchor
            }
        }
        if restart { cursor = Cursor(inode: inode, mtime: mtime) }
        guard var next = cursor else { return nil }
        try handle.seek(toOffset: next.offset)
        while next.offset < size {
            guard let data = try handle.read(upToCount: Int(min(64 * 1024, size - next.offset))), !data.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            next.offset += UInt64(data.count)
            var start = data.startIndex
            // Search each new byte once, even when a single record spans many chunks.
            while let end = data[start...].firstIndex(of: 10) {
                next.pending.append(contentsOf: data[start..<end])
                try autoreleasepool {
                    guard String(data: next.pending, encoding: .utf8) != nil else { throw SessionRolloutReadError.invalidUTF8 }
                    if next.header.isEmpty { next.header = next.pending; next.header.append(10) }
                    next.state.append(next.pending, mtime: mtime)
                }
                next.pending = Data()
                start = data.index(after: end)
            }
            next.pending.append(contentsOf: data[start...])
        }
        // A complete final JSON without a newline remains visible, but is not committed
        // twice when the writer later appends its newline or the rest of that record.
        var preview = next.state
        if !next.pending.isEmpty {
            guard String(data: next.pending, encoding: .utf8) != nil else { throw SessionRolloutReadError.invalidUTF8 }
            preview.append(next.pending, mtime: mtime)
        }
        try handle.seek(toOffset: next.offset > 64 ? next.offset - 64 : 0)
        next.anchor = try handle.read(upToCount: Int(min(next.offset, 64))) ?? Data()
        next.mtime = mtime; next.stamp = stamp
        cursors[url] = next
        return preview.snapshot(url: url, mtime: mtime)
    }
}

/// The watcher and preflight share one serialized parser cache, never a cached permission to send.
final class SessionScanWorker: @unchecked Sendable {
    let codexHome: URL
    private let quotaLogs: QuotaErrorLogProvider
    private let lock = NSLock()
    private let invalidationLock = NSLock()
    private var invalidatedPaths = Set<String>()
    private var fullInvalidation = false
    private let parseRollout: (URL, Date) throws -> SessionActivity?
    private let rolloutReader = SessionRolloutReader()
    private var cache: [URL: (stamp: SessionFileStamp, activity: SessionActivity)] = [:]
    private let directoryIndex: SessionRolloutDirectoryIndex
    private let now: () -> Date
    var directoryListingCount: Int { lock.lock(); defer { lock.unlock() }; return directoryIndex.listingCount }
    var directoryFullScanCount: Int { lock.lock(); defer { lock.unlock() }; return directoryIndex.fullScanCount }
    init(codexHome: URL, parseRollout: ((URL, Date) throws -> SessionActivity?)? = nil, now: @escaping () -> Date = Date.init) {
        self.codexHome = codexHome
        self.now = now; directoryIndex = SessionRolloutDirectoryIndex(home: codexHome)
        self.parseRollout = parseRollout ?? rolloutReader.read
        quotaLogs = QuotaErrorLogProvider(codexHome: codexHome)
    }
    // Shared with preflight: an explicitly watched target always overrides this isolation.
    private var ignoredPauses: [String: BlockedSession] = [:]
    private var protectedIDs: Set<String> = []
    private var protectedPaths: [URL] = []
    func invalidateDirectories(paths: [String], fullRescan: Bool = false) {
        // The native callback can arrive on the main actor while a full parser/SQL read is running.
        invalidationLock.lock(); defer { invalidationLock.unlock() }
        invalidatedPaths.formUnion(paths); fullInvalidation = fullInvalidation || fullRescan
    }
    func read(watchedIDs: Set<String>, watchedPaths: [URL]? = nil, ignoredPauses: [String: BlockedSession]? = nil, protectedIDs: Set<String>? = nil, forceDirectoryScan: Bool = true) -> ([SessionActivity], String?, [SessionScanDiagnostic]) {
        lock.lock(); defer { lock.unlock() }
        invalidationLock.lock()
        let invalidations = Array(invalidatedPaths), fullRescan = fullInvalidation
        invalidatedPaths.removeAll(); fullInvalidation = false
        invalidationLock.unlock()
        directoryIndex.invalidate(paths: invalidations, fullRescan: fullRescan)
        if let ignoredPauses { self.ignoredPauses = ignoredPauses }
        if let protectedIDs { self.protectedIDs = protectedIDs }
        if let watchedPaths { self.protectedPaths = watchedPaths }
        let watchedPaths = self.protectedPaths
        var stops: [String: QuotaStop] = [:]
        var errorMessage: String?
        var failures: [SessionScanDiagnostic] = []
        func diagnose(_ stage: String, error: Error? = nil, file: URL? = nil) {
            let fingerprint = file.map { SHA256.hash(data: Data($0.path.utf8)).map { String(format: "%02x", $0) }.joined() }
            var diagnostic = SessionScanDiagnostic(stage: stage, fileFingerprint: fingerprint)
            if let database = error as? CodexDatabaseError {
                diagnostic.stage += "." + database.stage
                diagnostic.code = Int(database.extendedCode); diagnostic.primaryCode = Int(database.code); diagnostic.domain = "SQLite"
            } else if error is SessionRolloutReadError {
                diagnostic.stage += ".decode_utf8"
            } else if let error = error as NSError? {
                diagnostic.code = error.code; diagnostic.domain = error.domain
            }
            if !failures.contains(diagnostic) { failures.append(diagnostic) }
        }
        var currentPaths: [String: URL] = [:]
        do { currentPaths = try Self.currentRolloutPaths(codexHome: codexHome) }
        catch { errorMessage = error.localizedDescription; diagnose("state_database", error: error) }
        var all = directoryIndex.read(now: now(), force: forceDirectoryScan)
        for original in watchedPaths {
            let path = RolloutFile.resolvedURL(original)
            if !all.contains(where: { $0.url.resolvingSymlinksInPath() == path.resolvingSymlinksInPath() }) {
                if let values = try? path.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true,
                   let mtime = values.contentModificationDate { all.append((path, mtime)) }
            }
        }
        do { stops = try quotaLogs.read() }
        catch {
            // A new installation with no sessions has no candidates to resume.
            if !all.isEmpty || !watchedIDs.isEmpty { errorMessage = errorMessage ?? error.localizedDescription; diagnose("quota_log_database", error: error) }
        }
        let runningIDs = Set(cache.values.filter { $0.activity.taskRunning }.map { $0.activity.id })
        func isolated(_ id: String) -> Bool {
            guard let ignored = self.ignoredPauses[id], !watchedIDs.contains(id), !self.protectedIDs.contains(id), !runningIDs.contains(id),
                  !watchedPaths.contains(where: { SessionWatcher.rolloutThreadID($0) == id || RolloutFile.resolvedURL($0) == currentPaths[id] }) else { return false }
            if let stop = stops[id] {
                guard stop.at <= ignored.blockedAt,
                      stop.turnID == nil || stop.turnID == ignored.stoppedTurnID else { return false }
            }
            return true
        }
        let ids = watchedIDs.union(self.protectedIDs).union(stops.keys.filter { !isolated($0) }).union(runningIDs)
        let recent = Set(all.prefix(20).map { $0.url })
        let candidates = ids.union(recent.compactMap(SessionWatcher.rolloutThreadID))
        let registered = Set(currentPaths.filter { candidates.contains($0.key) }.map { $0.value.resolvingSymlinksInPath() })
        let watched = Set(watchedPaths.map { $0.resolvingSymlinksInPath() })
        let files = all.filter { file in
            let path = file.url.resolvingSymlinksInPath()
            if let id = SessionWatcher.rolloutThreadID(file.url), let current = currentPaths[id],
               current.resolvingSymlinksInPath() != path { return false }
            return recent.contains(file.url) || watched.contains(path) ||
                SessionWatcher.rolloutThreadID(file.url).map { candidates.contains($0) } == true || registered.contains(path)
        }
        // Validate registered current files after excluding replaced history, before parsing candidates.
        for (id, path) in currentPaths where candidates.contains(id) && !files.contains(where: { $0.url.resolvingSymlinksInPath() == path.resolvingSymlinksInPath() }) {
            if !isolated(id) { errorMessage = errorMessage ?? L10n.text("无法读取 Codex 本地暂停记录") }
            diagnose(isolated(id) ? "ignored_rollout_missing" : "canonical_rollout_missing", file: path)
        }
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
            let stamp = SessionFileStamp(file.url)
            if let cached = cache[file.url], let stamp, cached.stamp == stamp { activity = cached.activity }
            else {
                var parseError: Error?
                do { activity = try parseRollout(file.url, stamp?.modified ?? file.mtime) }
                catch { parseError = error }
                if let parsed = activity, let stamp {
                    cache[file.url] = (stamp, parsed)
                } else {
                    if let id = SessionWatcher.rolloutThreadID(file.url), isolated(id) {
                        diagnose("ignored_rollout_parse", error: parseError, file: file.url)
                        continue
                    }
                    let name = RolloutFile.plainURL(file.url).deletingPathExtension().lastPathComponent
                    if cache[file.url] != nil || name.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil {
                        errorMessage = errorMessage ?? L10n.text("无法读取 Codex 本地暂停记录")
                        diagnose("rollout_parse", error: parseError, file: file.url)
                    }
                    activity = cache[file.url]?.activity
                }
            }
            guard var activity else { continue }
            activity.title = titles[activity.id]
            activities.append(activity)
        }
        // A revert keeps the thread ID but replaces its writable rollout. Never use mtime to pick a history.
        activities = Dictionary(grouping: activities, by: \.id).values.compactMap { group in
            if let path = currentPaths[group[0].id] {
                guard var current = group.first(where: { $0.fileURL.resolvingSymlinksInPath() == path.resolvingSymlinksInPath() }) else {
                    errorMessage = errorMessage ?? L10n.text("无法读取 Codex 本地暂停记录"); diagnose("canonical_rollout_missing", file: path); return nil
                }
                current.currentRolloutVerified = true
                return current
            }
            guard group.count == 1 else {
                errorMessage = errorMessage ?? L10n.text("无法读取 Codex 本地暂停记录"); diagnose("ambiguous_rollout", file: group[0].fileURL); return nil
            }
            return group[0]
        }
        activities = activities.map { original in
            var activity = original
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
            return activity
        }
        let existing = Set(all.map { $0.url })
        let missing = cache.filter { entry in
            !existing.contains(entry.key) && entry.value.activity.taskRunning &&
            !activities.contains(where: { $0.id == entry.value.activity.id && $0.currentRolloutVerified })
        }
        if !missing.isEmpty {
            errorMessage = errorMessage ?? L10n.text("无法读取 Codex 本地暂停记录")
            for file in missing.keys { diagnose("running_rollout_missing", file: file) }
            activities += missing.map { $0.value.activity }
        }
        let verifiedPaths = Dictionary(uniqueKeysWithValues: activities.filter(\.currentRolloutVerified).map {
            ($0.id, $0.fileURL.resolvingSymlinksInPath())
        })
        cache = cache.filter { entry in
            if let current = verifiedPaths[entry.value.activity.id], entry.key.resolvingSymlinksInPath() != current { return false }
            return existing.contains(entry.key) || entry.value.activity.taskRunning
        }
        rolloutReader.retainFiles(Set(cache.keys))
        if errorMessage != nil { activities = activities.map { var value = $0; value.currentRolloutVerified = false; return value } }
        return (activities.sorted { $0.lastActivityAt > $1.lastActivityAt }, errorMessage,
            failures.sorted { ($0.stage, $0.fileFingerprint ?? "") < ($1.stage, $1.fileFingerprint ?? "") })
    }

    static func currentRolloutPaths(codexHome: URL) throws -> [String: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func modified(_ url: URL) -> Date {
            let main = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let wal = (try? URL(fileURLWithPath: url.path + "-wal").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return max(main, wal)
        }
        guard let database = files.filter({ $0.lastPathComponent.range(of: #"^state(?:_[0-9]+)?\.sqlite$"#, options: .regularExpression) != nil })
            .sorted(by: { modified($0) == modified($1) ? $0.lastPathComponent > $1.lastPathComponent : modified($0) > modified($1) }).first else { return [:] }
        let reader = try ReadOnlyDatabase(url: database, kind: "state")
        let statement = try reader.prepare("SELECT id, rollout_path FROM threads")
        defer { sqlite3_finalize(statement) }
        var result: [String: URL] = [:]
        var step = try reader.step(statement)
        while step == SQLITE_ROW {
            if let id = sqlite3_column_text(statement, 0), let path = sqlite3_column_text(statement, 1) {
                result[String(cString: id)] = RolloutFile.resolvedURL(URL(fileURLWithPath: String(cString: path)))
            }
            step = try reader.step(statement)
        }
        return result
    }
}
