import AppKit
import SwiftUI

@MainActor func checkDisabledMenu(_ check: (Bool, String) -> Void, root: URL) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await checkDisabledBackground(check, root: root.appendingPathComponent("background"))
    let now = Date()
    let usage = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 10, windowMinutes: 300,
        resetsAt: now.addingTimeInterval(3600)), weekly: nil, capturedAt: now,
        accountID: "disabled-menu-fixture", sourceFile: "app-server")
    let plan = NextAction(mode: .keepAlive, date: now.addingTimeInterval(7200), decision: .wait(reason: "等待下一可行计划节点"), note: "")
    var presentation = MenuPresentation()
    _ = presentation.build(plan: plan, usage: usage, schedule: ScheduleEngine(anchorMinutes: 480),
        tasks: [], availableTasks: [], choices: ResumeChoices(), now: now)
    presentation.requestRefreshFeedback()
    let disabled = presentation.build(plan: plan, usage: usage, schedule: ScheduleEngine(anchorMinutes: 480),
        tasks: [], availableTasks: [], choices: ResumeChoices(), enabled: false,
        usageError: "fixture quota failure", sessionError: "fixture session failure",
        running: true, executionWarning: "fixture execution warning", refreshing: true,
        refreshMessage: "正在刷新额度…", now: now)
    check(disabled.headline == "已停用" && disabled.statusSymbol == "pause.circle", "disabled menu keeps its single disabled state")
    check(!disabled.isRefreshing && !disabled.isSyncing && disabled.refreshMessage.isEmpty,
        "disabled menu hides in-flight refresh and previous update feedback")
    check([disabled.action, disabled.badge, disabled.eyebrow, disabled.note, disabled.error, disabled.warning,
        disabled.reminderTitle, disabled.reminderBody].allSatisfy(\.isEmpty) && disabled.quotas.isEmpty && disabled.timeline.isEmpty && disabled.tasks.isEmpty,
        "disabled menu removes quota, task, warning and schedule details")

    let suite = "keeper.disabled-menu." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "enabled")
    let provider = DisabledMenuUsageProvider(usage)
    let home = root.appendingPathComponent("codex-home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let state = AppState(provider: provider, defaults: defaults, runtimeURL: root.appendingPathComponent("pending-runtime.json"),
        codexHome: home, startMonitoring: false)
    state.usage.onRefreshCompleted = nil
    state.sessions.onRefreshCompleted = nil
    state.refresh(manual: true, source: "menu_open")
    try await Task.sleep(nanoseconds: 100_000_000)
    check(provider.reads == 0 && state.usage.lastRefreshStartedAt == nil,
        "opening a disabled Keeper menu cannot request or queue a quota refresh")
    check(state.sessions.scannedAt == nil, "opening a disabled Keeper menu does not trigger a task scan")
    defaults.set(true, forKey: "enabled")
    state.refresh(manual: true, source: "menu_open")
    let deadline = Date().addingTimeInterval(2)
    while state.usage.refreshing && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    check(provider.reads > 0 && state.usage.snapshot?.accountID == usage.accountID && state.usage.lastError == nil,
        "opening the menu after re-enabling Keeper restores normal refresh")
    while state.sessions.scannedAt == nil && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let host = NSHostingView(rootView: MenuSummaryView(summary: disabled))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 304, height: 160),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    host.frame.size = size
    check(size.height > 20 && size.height < 64, "disabled menu collapses to a compact single status row without a refresh button")
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: root.appendingPathComponent("disabled-menu.png"))
        }
    }
}

@MainActor private func checkDisabledBackground(_ check: (Bool, String) -> Void, root: URL) async throws {
    let suite = "keeper.disabled-background." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "enabled")
    let home = root.appendingPathComponent("codex-home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let usage = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 10, windowMinutes: 300,
        resetsAt: Date().addingTimeInterval(3600)), weekly: nil, capturedAt: Date(),
        accountID: "disabled-background-fixture", sourceFile: "app-server")
    let provider = DisabledMenuUsageProvider(usage)
    let preparation = DisabledPreparationPing()
    let execution = ExecutionCoordinator(provider: provider, defaults: defaults,
        ledgerURL: root.appendingPathComponent("resume-attempts.json"), pingTransport: preparation, codexHome: home)
    let state = AppState(provider: provider, defaults: defaults,
        runtimeURL: root.appendingPathComponent("pending-runtime.json"), codexHome: home, execution: execution)
    defer { state.usage.stop(); state.sessions.stop() }
    try await Task.sleep(nanoseconds: 150_000_000)
    check(provider.reads == 0 && !state.sessions.hasScanned && preparation.checks == 0 && provider.modelReads == 0,
        "disabled startup performs no quota, model preparation or local task scan")
    execution.maintainKeepAlive(forceCheck: true)
    execution.relocateKeepAlive()
    state.environmentChanged(source: "wake")
    state.networkChanged(available: true)
    state.usage.authenticationDidChange()
    state.usage.refresh(manual: true, source: "button")
    state.usage.startPassiveMonitoring()
    state.sessions.refresh()
    state.recompute(source: "timer")
    try await Task.sleep(nanoseconds: 150_000_000)
    check(provider.reads == 0 && !state.sessions.hasScanned && preparation.checks == 0 && provider.modelReads == 0,
        "disabled wake, network, auth, timer and relocation signals cannot restart monitoring or model discovery")

    defaults.set(true, forKey: "enabled")
    state.environmentChanged(source: "enable")
    let deadline = Date().addingTimeInterval(3)
    while (!state.sessions.hasScanned || state.usage.refreshing || provider.reads == 0) && Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    while preparation.checks == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    check(state.sessions.hasScanned && state.usage.hasReliableReading && provider.reads > 0 && preparation.checks > 0 && provider.modelReads > 0,
        "re-enabling restores background model preparation with a new reliable task and quota refresh")
    state.sessions.start(interval: 0.03)
    state.usage.setPolling(UsagePollingPolicy(interval: 0.03, wakeAt: nil), retryOpportunity: nil)
    defaults.set(false, forKey: "enabled")
    state.environmentChanged(source: "disable")
    let reads = provider.reads
    let modelReads = provider.modelReads
    let preparations = preparation.checks
    let scannedAt = state.sessions.scannedAt
    execution.maintainKeepAlive(forceCheck: true)
    execution.relocateKeepAlive()
    state.networkChanged(available: false)
    state.environmentChanged(source: "clock")
    state.usage.refresh(critical: true)
    state.sessions.refresh()
    try await Task.sleep(nanoseconds: 200_000_000)
    check(provider.reads == reads && state.sessions.scannedAt == scannedAt && !state.usage.refreshing &&
        provider.modelReads == modelReads && preparation.checks == preparations,
        "disabling stops short timers and rejects both queued refreshes and new background preparation")

    let previousCapture = state.usage.snapshot?.capturedAt
    provider.hold()
    defer { provider.release() }
    defaults.set(true, forKey: "enabled")
    state.environmentChanged(source: "enable_in_flight")
    let readDeadline = Date().addingTimeInterval(3)
    while provider.reads == reads && Date() < readDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    check(!state.usage.hasReliableReading && state.usage.refreshing,
        "re-enable cannot authorize execution with the previous cached quota")
    state.usage.refresh(manual: true, source: "button")
    state.usage.refresh(source: "boundary", critical: true)
    defaults.set(false, forKey: "enabled")
    state.environmentChanged(source: "disable_in_flight")
    let admittedReads = provider.reads
    provider.release()
    try await Task.sleep(nanoseconds: 150_000_000)
    check(provider.reads == admittedReads && !state.usage.refreshing && !state.usage.hasReliableReading &&
        state.usage.snapshot?.capturedAt == previousCapture,
        "late in-flight results are discarded and queued manual/critical reads stay cancelled")
    defaults.set(true, forKey: "enabled")
    state.environmentChanged(source: "enable_again")
    let freshDeadline = Date().addingTimeInterval(3)
    while (!state.usage.hasReliableReading || state.usage.refreshing || !state.sessions.hasScanned) && Date() < freshDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    check(state.usage.hasReliableReading && state.usage.snapshot?.capturedAt != previousCapture && state.sessions.hasScanned,
        "a new enable cycle recovers fresh quota and task state after an interrupted read")
    defaults.set(false, forKey: "enabled"); state.environmentChanged(source: "cleanup")
    try await checkSuspendedQueryConnection(check)
}

@MainActor private func checkSuspendedQueryConnection(_ check: (Bool, String) -> Void) async throws {
    var transports: [DisabledQueryTransport] = []
    var identityReads = 0
    let provider = AppServerUsageProvider(makeTransport: {
        let transport = DisabledQueryTransport(); transports.append(transport); return transport
    }, contextIdentity: { identityReads += 1; return nil })
    _ = try provider.read(); _ = try provider.read(); _ = try provider.pingModel()
    check(transports.count == 1, "active quota reads and background model preparation reuse their dedicated connection")
    provider.setSuspended(true)
    let deadline = Date().addingTimeInterval(3)
    while transports[0].closes == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    check(transports[0].closes == 1, "suspending releases the idle dedicated query connection")
    let calls = transports[0].calls
    let identities = identityReads
    for operation in [{ _ = try provider.read() }, { _ = try provider.readForUserRefresh() }, { _ = try provider.pingModel() }] {
        do { try operation(); check(false, "suspended provider rejects quota and model discovery") }
        catch { check(true, "suspended provider rejects quota and model discovery") }
    }
    check(transports.count == 1 && transports[0].calls == calls && identityReads == identities,
        "suspended provider performs no RPC, child creation or authentication scan")
    provider.setSuspended(false)
    let live = try provider.read()
    check(transports.count == 2 && live.accountID == "paused-query-fixture",
        "resuming rebuilds the closed query connection and returns a live quota")
    provider.setSuspended(true)

    let transport = DisabledQueryTransport()
    let interrupted = AppServerUsageProvider(makeTransport: { transport }, contextIdentity: { nil })
    transport.onAccountRead = { interrupted.setSuspended(true) }
    defer { transport.onAccountRead = nil }
    do { _ = try interrupted.read(); check(false, "suspension between RPCs interrupts the read batch") }
    catch { check(transport.calls == 1, "suspension between RPCs interrupts the read batch before rate limits") }

    let modelTransport = DisabledQueryTransport()
    let preparing = AppServerUsageProvider(makeTransport: { modelTransport }, contextIdentity: { nil })
    modelTransport.onAccountRead = { preparing.setSuspended(true) }
    defer { modelTransport.onAccountRead = nil }
    do { _ = try preparing.pingModel(); check(false, "suspension interrupts in-flight background model preparation") }
    catch { check(modelTransport.calls == 1, "suspension interrupts in-flight background preparation before model/list") }
    preparing.setSuspended(false)
    modelTransport.onAccountRead = nil
    check(try preparing.pingModel().model == "gpt-6-luna",
        "a later enable permits model preparation to recover after its interrupted RPC batch")
    preparing.setSuspended(true)
}

private final class DisabledQueryTransport: CodexTransport {
    private let lock = NSLock()
    private var requestCount = 0
    private var closeCount = 0
    var onAccountRead: (() -> Void)?
    var calls: Int { lock.lock(); defer { lock.unlock() }; return requestCount }
    var closes: Int { lock.lock(); defer { lock.unlock() }; return closeCount }
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        lock.lock(); requestCount += 1; lock.unlock()
        if method == "account/read" {
            onAccountRead?()
            return ["account": ["type": "chatgpt"]]
        }
        if method == "model/list" { return ["data": [["id": "gpt-6-luna", "model": "gpt-6-luna"]]] }
        return ["accountId": "paused-query-fixture", "rateLimits": ["primary": [
            "usedPercent": 7, "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(3600).timeIntervalSince1970]]]
    }
    func nextMessage(timeout: TimeInterval) throws -> [String: Any] { throw CodexConnectionError.timeout }
    func close() { lock.lock(); closeCount += 1; lock.unlock() }
}

private final class DisabledMenuUsageProvider: UsageProvider, @unchecked Sendable {
    private let lock = NSCondition()
    private var count = 0
    private var discoveries = 0
    private var held = false
    private let snapshot: UsageSnapshot
    init(_ snapshot: UsageSnapshot) { self.snapshot = snapshot }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    var modelReads: Int { lock.lock(); defer { lock.unlock() }; return discoveries }
    func pingModel() throws -> PingModel {
        lock.lock(); discoveries += 1; lock.unlock()
        return PingModel(model: "gpt-6-luna", reasoningEffort: "low")
    }
    func hold() { lock.lock(); held = true; lock.unlock() }
    func release() { lock.lock(); held = false; lock.broadcast(); lock.unlock() }
    func read() throws -> UsageSnapshot {
        lock.lock(); defer { lock.unlock() }; count += 1
        while held { lock.wait() }
        var fresh = snapshot; fresh.capturedAt = Date(); return fresh
    }
}

private final class DisabledPreparationPing: PingTransport {
    private let lock = NSLock()
    private var count = 0
    var checks: Int { lock.lock(); defer { lock.unlock() }; return count }
    func maintainPreparation(provider: UsageProvider, forceCheck: Bool) {
        _ = try? provider.pingModel()
        lock.lock(); count += 1; lock.unlock()
    }
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider) throws -> UsageSnapshot {
        throw CodexConnectionError.unavailable
    }
    func cancel() {}
}
