import Foundation
import Combine

/// 单个限额窗口快照
struct QuotaWindow: Codable, Equatable {
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

/// Independent read-only account polling. A failure preserves the last real interface reading and its time.
@MainActor
final class UsageObserver: ObservableObject {
    // Called on the main actor after the reading and critical-refresh gate have both settled.
    var onRefreshCompleted: (() -> Void)?
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var refreshMessage = ""
    @Published private(set) var hasReliableReading = false
    private(set) var polling = UsagePollingPolicy(interval: UsagePollingPolicy.activeInterval, wakeAt: nil)
    private(set) var criticalRefreshPending = false
    private(set) var lastRefreshStartedAt: Date?
    private let provider: UsageProvider
    private let now: () -> Date

    private let logURL: URL
    private var timer: Timer?
    private var pendingManualSource: String?
    private var pendingAutomaticSource: String?
    private var monitoring = false
    private var requestID: String?
    private var lastReadFailure: UsageReadDiagnostic?
    private var lastSchedulingState: Data?
    private var lastSchedulingLogAt: Date?

    var lastErrorIsTransient: Bool { lastReadFailure?.isTransient == true }

    init(provider: UsageProvider = AppServerUsageProvider(), logURL: URL? = nil,
         now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CodexKeeper", directoryHint: .isDirectory)
        self.logURL = logURL ?? support.appending(path: "usage-transitions.jsonl")
        try? FileManager.default.createDirectory(at: self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func start(interval: TimeInterval = 20) {
        monitoring = true
        polling = UsagePollingPolicy(interval: interval, wakeAt: nil)
        refresh()
    }

    func stop() {
        monitoring = false
        timer?.invalidate()
        timer = nil
    }

    func invalidate(clearAccount: Bool = false) {
        hasReliableReading = false
        if clearAccount { snapshot = nil }
        // Keep the original reading and its capture time as facts. Critical refresh gates execution.
        // Only a reliable new account response may change the display account.

    }

    func setPolling(_ policy: UsagePollingPolicy, retryOpportunity: UsageRetryOpportunity?) {
        provider.setRetryOpportunity(retryOpportunity, now: now())
        guard polling != policy else { return }
        polling = policy
        scheduleRefresh()
    }

    var nextAutomaticRefreshAt: Date? {
        guard let lastRefreshStartedAt else { return nil }
        let periodic = lastRefreshStartedAt.addingTimeInterval(polling.interval)
        return polling.wakeAt.map { min(periodic, $0) } ?? periodic
    }

    private func scheduleRefresh() {
        timer?.invalidate(); timer = nil
        guard monitoring, !refreshing, let deadline = nextAutomaticRefreshAt else { return }
        // A slow completed request must not create an immediate timer loop.
        timer = Timer(timeInterval: max(1, deadline.timeIntervalSince(now())), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func refresh(manual: Bool = false, source: String = "manual", critical: Bool = false) {
        let trigger = manual || critical || source != "manual" ? source : "automatic"
        if critical { criticalRefreshPending = true }
        guard !refreshing else {
            if manual || critical {
                if manual {
                    pendingManualSource = source
                    refreshMessage = L10n.text("正在同步，完成后重新读取…")
                }
                appendLogEntry(["event": "usage_refresh_queued", "trigger": trigger,
                    "request_id": requestID ?? "", "logged_at": ISO8601DateFormatter().string(from: Date())])
            }
            if critical { pendingAutomaticSource = source }
            return
        }
        timer?.invalidate(); timer = nil
        lastRefreshStartedAt = now()
        let id = UUID().uuidString
        requestID = id
        let started = ProcessInfo.processInfo.systemUptime
        if manual || critical {
            if manual { refreshMessage = L10n.text("正在刷新额度…") }
            appendLogEntry(["event": "usage_refresh_started", "trigger": trigger,
                "request_id": id, "logged_at": ISO8601DateFormatter().string(from: Date())])
        }
        refreshing = true
        let provider = provider
        Task {
            let result = await Task.detached { () -> (UsageSnapshot?, String?, UsageReadDiagnostic?) in
                do { return (try (manual ? provider.readForUserRefresh() : provider.read()), nil, nil) }
                catch {
                    return (nil, error.localizedDescription,
                        UsageReadFailure.describe(error, elapsed: ProcessInfo.processInfo.systemUptime - started))
                }
            }.value
            if let failure = result.2, manual || !failure.sameFailure(as: lastReadFailure) {
                var entry: [String: Any] = ["event": "usage_read_failed", "logged_at": ISO8601DateFormatter().string(from: Date()),
                    "reason": failure.reason, "trigger": trigger,
                    "request_stage": failure.requestStage, "cooldown": failure.cooldown, "elapsed_ms": failure.elapsedMilliseconds]
                if let attempted = failure.rpcAttempted { entry["rpc_attempted"] = attempted }
                appendLogEntry(entry)
            }
            hasReliableReading = result.1 == nil && result.0?.isFresh(at: now()) == true && result.0?.accountID?.isEmpty == false
            if let new = result.0 {
                if snapshot != new { appendTransitionLog(new) }
                snapshot = new // Equal values still carry a new freshness timestamp.
            }
            lastError = result.1
            lastReadFailure = result.2
            if manual || !refreshMessage.isEmpty {
                let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
                refreshMessage = result.1 == nil ? L10n.format("已更新 · %@", clock.string(from: Date())) : L10n.text("刷新失败，请点击刷新按钮重试。")
            }
            if manual || critical {
                appendLogEntry(["event": "usage_refresh_finished", "trigger": trigger,
                    "request_id": id, "logged_at": ISO8601DateFormatter().string(from: Date()),
                    "elapsed_ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                    "result": result.1 == nil ? "success" : "failed", "reason": result.2?.reason ?? "none"])
            }
            refreshing = false
            requestID = nil
            let pendingSource = pendingManualSource
            let pendingAutomatic = pendingAutomaticSource
            pendingManualSource = nil
            pendingAutomaticSource = nil
            criticalRefreshPending = pendingAutomatic != nil
            if let pendingSource { refresh(manual: true, source: pendingSource, critical: pendingAutomatic != nil) }
            else if let pendingAutomatic { refresh(source: pendingAutomatic, critical: true) }
            else { scheduleRefresh() }
            onRefreshCompleted?()
        }
    }

    // MARK: - Transition 日志（P0-6 埋点）

    /// Optional scheduling diagnostics contain only classifications, counts and timing.
    func recordSchedulingState(_ state: [String: Any], source: String) {
        guard let encoded = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys) else { return }
        let date = now()
        guard encoded != lastSchedulingState || source == "menu_open" ||
            lastSchedulingLogAt.map({ date.timeIntervalSince($0) >= 60 }) != false else { return }
        lastSchedulingState = encoded; lastSchedulingLogAt = date
        var entry = state
        entry["event"] = "schedule_evaluated"
        entry["trigger"] = source
        entry["logged_at"] = ISO8601DateFormatter().string(from: Date())
        appendLogEntry(entry)
    }

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

    /// Preserve complete generations: one 1 MB current log and three bounded backups.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int, size > 1024 * 1024 else { return }
        do {
            let oldest = logURL.appendingPathExtension("3")
            if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
            for index in stride(from: 2, through: 1, by: -1) {
                let source = logURL.appendingPathExtension(String(index))
                if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: logURL.appendingPathExtension(String(index + 1))) }
            }
            try fm.moveItem(at: logURL, to: logURL.appendingPathExtension("1"))
        } catch {
            // Keep the current history when rotation cannot finish; never truncate it as fallback.
        }
    }
}
