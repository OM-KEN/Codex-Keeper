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

/// Online readings authorize execution; verified local rollout readings only update presentation.
@MainActor
final class UsageObserver: ObservableObject {
    // Called on the main actor after the reading and critical-refresh gate have both settled.
    var onRefreshCompleted: (() -> Void)?
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var displaySnapshot: UsageSnapshot?
    var onPassiveChange: (() -> Void)?
    private var passiveSnapshot: UsageSnapshot?
    private(set) var passiveRecovery: (before: UsageSnapshot, after: UsageSnapshot)?
    private var passiveMonitor: RolloutUsageMonitor?
    private var authenticationObservation: AuthenticationObservation = .unreadable
    @Published private(set) var lastError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var refreshMessage = ""
    @Published private(set) var hasReliableReading = false
    private(set) var polling = UsagePollingPolicy(interval: UsagePollingPolicy.activeInterval, wakeAt: nil)
    private(set) var criticalRefreshPending = false
    private(set) var lastRefreshStartedAt: Date?
    private let provider: UsageProvider
    private let now: () -> Date

    private let codexHome: URL
    private let logURL: URL
    private var timer: Timer?
    private var pendingManualSource: String?
    private var pendingAutomaticSource: String?
    private var monitoring = false
    private var suspended = false
    private var generation = 0
    private var requestID: String?
    private var lastReadFailure: UsageReadDiagnostic?
    private var lastSchedulingState: Data?
    private var lastSchedulingLogAt: Date?

    var lastErrorIsTransient: Bool { lastReadFailure?.isTransient == true }

    init(codexHome: URL = CodexEnvironment.home, provider: UsageProvider = AppServerUsageProvider(), logURL: URL? = nil,
         now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
        self.codexHome = codexHome
        do { authenticationObservation = .known(try AppServerUsageProvider.authenticationIdentity(home: codexHome)) }
        catch { authenticationObservation = .unreadable }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CodexKeeper", directoryHint: .isDirectory)
        self.logURL = logURL ?? support.appending(path: "usage-transitions.jsonl")
        try? FileManager.default.createDirectory(at: self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func start(interval: TimeInterval = UsagePollingPolicy.idleInterval) {
        suspended = false
        provider.setSuspended(false)
        hasReliableReading = false
        criticalRefreshPending = true
        monitoring = true
        startPassiveMonitoring()
        polling = UsagePollingPolicy(interval: interval, wakeAt: nil)
        refresh()
    }

    func stop() {
        suspended = true
        generation += 1
        monitoring = false
        timer?.invalidate()
        timer = nil
        passiveMonitor?.stop(); passiveMonitor = nil
        pendingManualSource = nil; pendingAutomaticSource = nil
        refreshing = false; requestID = nil; criticalRefreshPending = false
        hasReliableReading = false
        provider.setRetryOpportunity(nil, now: now())
        provider.setSuspended(true)
    }

    func startPassiveMonitoring() {
        guard !suspended, passiveMonitor == nil else { return }
        let generation = self.generation
        passiveMonitor = RolloutUsageMonitor(home: codexHome, now: now) { [weak self] readings, changed in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.receivePassive(readings, authenticationChanged: changed)
            }
        }
        passiveMonitor?.start()
    }

    func rescanPassive() { passiveMonitor?.rescan() }

    func invalidate(clearAccount: Bool = false) {
        hasReliableReading = false
        // Keep the original reading and its capture time as facts. Critical refresh gates execution.
        // Only a reliable new account response may change the display account.
        if clearAccount { passiveSnapshot = nil; passiveRecovery = nil; displaySnapshot = nil }
        rescanPassive()
    }

    func authenticationDidChange() {
        guard !suspended else { return }
        let current: AuthenticationObservation
        do { current = .known(try AppServerUsageProvider.authenticationIdentity(home: codexHome)) }
        catch { current = .unreadable }
        guard current != authenticationObservation else { return }
        authenticationObservation = current
        invalidate(clearAccount: true)
        refresh(source: "authentication", critical: true)
    }

    private func receivePassive(_ readings: [PassiveUsageReading], authenticationChanged: Bool) {
        guard passiveMonitor != nil else { return }
        if authenticationChanged { authenticationDidChange() }
        for reading in readings {
            let next = reading.snapshot
            guard (try? AppServerUsageProvider.authenticationIdentity(home: codexHome)) == reading.authentication,
                  (try? AppServerUsageProvider.authenticationAccountID(home: codexHome)) == next.accountID,
                  next.capturedAt <= now(), now().timeIntervalSince(next.capturedAt) <= RolloutUsageReader.maximumAge else { continue }
            let old = [passiveSnapshot, snapshot].compactMap { $0 }.filter { $0.accountID == next.accountID }
                .max { $0.capturedAt < $1.capturedAt }
            if let old, old.accountID == next.accountID, old.capturedAt > next.capturedAt || (old.capturedAt == next.capturedAt && old == next) { continue }
            passiveSnapshot = next
            if let old, old.accountID == next.accountID,
               [old.fiveHour, old.weekly].compactMap({ $0 }).contains(where: { $0.usedPercent >= 100 }),
               [next.fiveHour, next.weekly].compactMap({ $0 }).allSatisfy({ $0.usedPercent < 100 }),
               (old.fiveHour == nil || next.fiveHour != nil), (old.weekly == nil || next.weekly != nil) {
                passiveRecovery = (old, next)
            } else if [next.fiveHour, next.weekly].compactMap({ $0 }).contains(where: { $0.usedPercent >= 100 }) {
                passiveRecovery = nil
            }
            updateDisplaySnapshot()
            onPassiveChange?()
            if let old, old.accountID == next.accountID, Self.needsOnlineVerification(from: old, to: next),
               lastRefreshStartedAt.map({ $0 < next.capturedAt }) ?? true {
                refresh(source: "passive_boundary", critical: true)
            }
        }
    }

    private static func needsOnlineVerification(from old: UsageSnapshot, to new: UsageSnapshot) -> Bool {
        for (before, after) in [(old.fiveHour, new.fiveHour), (old.weekly, new.weekly)] {
            if (before?.usedPercent ?? 0 >= 100) != (after?.usedPercent ?? 0 >= 100) { return true }
            if let before, let after {
                if abs(before.resetsAt.timeIntervalSince(after.resetsAt)) > ScheduleEngine.alignmentTolerance { return true }
                if (before.usedPercent == 0) != (after.usedPercent == 0) { return true }
            } else if before != after { return true }
        }
        return false
    }

    private func updateDisplaySnapshot() {
        if let passiveSnapshot, now().timeIntervalSince(passiveSnapshot.capturedAt) <= RolloutUsageReader.maximumAge,
           snapshot == nil || (snapshot?.accountID == passiveSnapshot.accountID && snapshot!.capturedAt < passiveSnapshot.capturedAt) {
            displaySnapshot = passiveSnapshot
        } else { displaySnapshot = snapshot }
    }

    func verifiedPassiveRecovery(at date: Date) -> (before: UsageSnapshot, after: UsageSnapshot)? {
        guard let evidence = passiveRecovery, let live = snapshot, live.isFresh(at: date), hasReliableReading, lastError == nil,
              evidence.before.accountID == evidence.after.accountID, live.accountID == evidence.after.accountID,
              live.capturedAt >= evidence.after.capturedAt, date.timeIntervalSince(evidence.after.capturedAt) <= RolloutUsageReader.maximumAge,
              [live.fiveHour, live.weekly].compactMap({ $0 }).allSatisfy({ $0.usedPercent < 100 }),
              (evidence.before.fiveHour == nil || live.fiveHour != nil), (evidence.before.weekly == nil || live.weekly != nil) else { return nil }
        return evidence
    }

    func setPolling(_ policy: UsagePollingPolicy, retryOpportunity: UsageRetryOpportunity?) {
        guard !suspended else { return }
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
        guard !suspended else { return }
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
        let generation = self.generation
        Task {
            guard !suspended, self.generation == generation else { return }
            let result = await Task.detached { () -> (UsageSnapshot?, String?, UsageReadDiagnostic?) in
                do { return (try (manual ? provider.readForUserRefresh() : provider.read()), nil, nil) }
                catch {
                    return (nil, error.localizedDescription,
                        UsageReadFailure.describe(error, elapsed: ProcessInfo.processInfo.systemUptime - started))
                }
            }.value
            guard !suspended, self.generation == generation else { return }
            if let failure = result.2, manual || !failure.sameFailure(as: lastReadFailure) {
                var entry: [String: Any] = ["event": "usage_read_failed", "logged_at": ISO8601DateFormatter().string(from: Date()),
                    "reason": failure.reason, "trigger": trigger,
                    "request_stage": failure.requestStage, "cooldown": failure.cooldown, "elapsed_ms": failure.elapsedMilliseconds]
                if let attempted = failure.rpcAttempted { entry["rpc_attempted"] = attempted }
                appendLogEntry(entry)
            }
            hasReliableReading = result.1 == nil && result.0?.isFresh(at: now()) == true && result.0?.accountID?.isEmpty == false
            if result.2?.isTransient == true, snapshot?.isFresh(at: now()) == true {
                // Keep the recent live reading during a transient refresh failure.
            } else if let new = result.0 {
                if snapshot != new { appendTransitionLog(new) }
                snapshot = new // Equal values still carry a new freshness timestamp.
            } else if result.1 != nil {
                snapshot = nil
            }
            if let live = snapshot, passiveSnapshot?.accountID != live.accountID { passiveSnapshot = nil; passiveRecovery = nil }
            if result.2 != nil, result.2?.isTransient != true { passiveSnapshot = nil; passiveRecovery = nil }
            updateDisplaySnapshot()
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
