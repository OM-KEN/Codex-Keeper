import Foundation
import Combine

/// 单个限额窗口快照
struct QuotaWindow: Equatable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date
}

/// 账户额度快照。相等性只比较窗口数据，与采集时间/来源无关。
struct UsageSnapshot: Equatable {
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    var capturedAt: Date
    var accountID: String? = nil
    var sourceFile: String
    var zeroUseWindowActive: Bool? = nil

    func isFresh(at now: Date) -> Bool {
        sourceFile == "app-server" && now.timeIntervalSince(capturedAt) >= -5 && now.timeIntervalSince(capturedAt) <= 60
    }

    var activeFiveHourWindow: Bool? {
        guard let fiveHour else { return false }
        if fiveHour.resetsAt <= capturedAt { return false }
        if fiveHour.usedPercent > 0 { return true }
        return zeroUseWindowActive
    }

    func nextResetDate(at now: Date) -> Date? {
        guard isFresh(at: now) else { return nil }
        let blocked = [fiveHour, weekly].compactMap { $0 }.filter { $0.usedPercent >= 100 }
        if !blocked.isEmpty { return blocked.map(\.resetsAt).max().flatMap { $0 > now ? $0 : nil } }
        let reset = fiveHour?.resetsAt ?? weekly?.resetsAt
        return reset.flatMap { $0 > now ? $0 : nil }
    }

    static func == (lhs: UsageSnapshot, rhs: UsageSnapshot) -> Bool {
        lhs.fiveHour == rhs.fiveHour && lhs.weekly == rhs.weekly && lhs.accountID == rhs.accountID && lhs.zeroUseWindowActive == rhs.zeroUseWindowActive
    }
}

/// Independent read-only account polling. Rollout data is bounded, explicitly stale fallback evidence.
@MainActor
final class UsageObserver: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var refreshMessage = ""
    private let provider: UsageProvider

    private let codexHome: URL
    private let logURL: URL
    private var timer: Timer?
    private var pendingManualSource: String?
    private var requestID: String?
    private var lastErrorReason: String?

    init(codexHome: URL = CodexEnvironment.home, provider: UsageProvider = AppServerUsageProvider(), logURL: URL? = nil) {
        self.provider = provider
        self.codexHome = codexHome
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CodexKeeper", directoryHint: .isDirectory)
        self.logURL = logURL ?? support.appending(path: "usage-transitions.jsonl")
        try? FileManager.default.createDirectory(at: self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func start(interval: TimeInterval = 20) {
        refresh()
        timer?.invalidate()
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func invalidate() {
        if var previous = snapshot { previous.capturedAt = .distantPast; snapshot = previous }
    }

    func refresh(manual: Bool = false, source: String = "manual") {
        let trigger = manual ? source : "automatic"
        guard !refreshing else {
            if manual {
                pendingManualSource = source
                refreshMessage = "正在同步，完成后重新读取…"
                appendLogEntry(["event": "usage_refresh_queued", "trigger": trigger,
                    "request_id": requestID ?? "", "logged_at": ISO8601DateFormatter().string(from: Date())])
            }
            return
        }
        let id = UUID().uuidString
        requestID = id
        let started = ProcessInfo.processInfo.systemUptime
        if manual {
            refreshMessage = "正在刷新额度…"
            appendLogEntry(["event": "usage_refresh_started", "trigger": trigger,
                "request_id": id, "logged_at": ISO8601DateFormatter().string(from: Date())])
        }
        refreshing = true
        let provider = provider
        let home = codexHome
        Task {
            let result = await Task.detached { () -> (UsageSnapshot?, String?, String?) in
                do { return (try (manual ? provider.readForUserRefresh() : provider.read()), nil, nil) }
                catch {
                    let reason: String
                    switch error {
                    case CodexConnectionError.timeout: reason = "request_timeout"
                    case CodexConnectionError.ended: reason = "connection_ended"
                    case CodexConnectionError.unavailable: reason = "cli_unavailable"
                    case CodexConnectionError.invalidResponse: reason = "invalid_response"
                    case CodexConnectionError.server(let message): reason = CodexConnectionError.serverFailureReason(message)
                    default: reason = "read_failed"
                    }
                    return (Self.readLatestSnapshot(codexHome: home), error.localizedDescription, reason)
                }
            }.value
            if let reason = result.2, manual || lastErrorReason != reason || lastError != result.1 {
                appendLogEntry(["event": "usage_read_failed", "logged_at": ISO8601DateFormatter().string(from: Date()),
                    "reason": reason, "trigger": manual ? "manual" : "automatic"])
            }
            if result.1 != nil, snapshot?.isFresh(at: Date()) == true {
                // Keep the recent live reading during a transient refresh failure.
            } else if let new = result.0 {
                if snapshot != new { appendTransitionLog(new) }
                snapshot = new // Equal values still carry a new freshness timestamp.
            } else if result.1 != nil {
                snapshot = nil
            }
            lastError = result.1
            lastErrorReason = result.2
            if manual || !refreshMessage.isEmpty {
                let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
                refreshMessage = result.1 == nil ? "已更新 · " + clock.string(from: Date()) : "刷新失败，请点击刷新按钮重试。"
            }
            if manual {
                appendLogEntry(["event": "usage_refresh_finished", "trigger": trigger,
                    "request_id": id, "logged_at": ISO8601DateFormatter().string(from: Date()),
                    "elapsed_ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                    "result": result.1 == nil ? "success" : "failed", "reason": result.2 ?? "none"])
            }
            refreshing = false
            requestID = nil
            let pendingSource = pendingManualSource
            pendingManualSource = nil
            if let pendingSource { refresh(manual: true, source: pendingSource) }
        }
    }

    // MARK: - 快照读取

    /// 扫描最近修改的 rollout 文件，取最后一条带窗口数据的 rate_limits
    nonisolated static func readLatestSnapshot(codexHome: URL) -> UsageSnapshot? {
        let sessionsDir = codexHome.appending(path: "sessions", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate else { continue }
            files.append((url, mtime))
        }
        files.sort { $0.mtime > $1.mtime }

        return files.prefix(12).compactMap { readSnapshot(from: $0) }.max { $0.capturedAt < $1.capturedAt }
    }

    /// 从单个 rollout 尾部找最新 rate_limits（从后往前扫，命中即停）
    nonisolated private static func readSnapshot(from file: (url: URL, mtime: Date)) -> UsageSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        guard let data = try? handle.readToEnd(), let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        var capturedAt: Date?

        for rawLine in lines.reversed() {
            guard rawLine.contains("rate_limits"),
                  let lineData = rawLine.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any]
            else { continue }

            (fiveHour, weekly) = UsageDecoder.windows(rateLimits)

            if fiveHour != nil || weekly != nil {
                if let ts = entry["timestamp"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    capturedAt = formatter.date(from: ts)
                }
                break
            }
        }

        guard fiveHour != nil || weekly != nil else { return nil }
        return UsageSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            capturedAt: capturedAt ?? file.mtime,
            sourceFile: file.url.lastPathComponent
        )
    }

    // MARK: - Transition 日志（P0-6 埋点）

    private func appendTransitionLog(_ snapshot: UsageSnapshot) {
        var entry: [String: Any] = [
            "logged_at": ISO8601DateFormatter().string(from: Date()),
            "captured_at": ISO8601DateFormatter().string(from: snapshot.capturedAt),
            "source": snapshot.sourceFile,
        ]
        if let five = snapshot.fiveHour {
            entry["five_hour_used"] = five.usedPercent
            entry["five_hour_active"] = snapshot.activeFiveHourWindow
            entry["five_hour_reset"] = ISO8601DateFormatter().string(from: five.resetsAt)
        }
        if let weekly = snapshot.weekly {
            entry["weekly_used"] = weekly.usedPercent
            entry["weekly_reset"] = ISO8601DateFormatter().string(from: weekly.resetsAt)
        }
        appendLogEntry(entry)
    }

    private func appendLogEntry(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")

        rotateIfNeeded()
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logURL)
        }
    }

    /// 简单轮转：超过 512KB 只留后半（§55 限量精神）
    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int, size > 512 * 1024,
              let data = try? Data(contentsOf: logURL) else { return }
        let half = data.suffix(data.count / 2)
        try? half.write(to: logURL)
    }
}
