import Foundation
import SQLite3

@MainActor func checkUsagePollingAndDrift(_ check: (Bool, String) -> Void, root: URL) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let calendar = Calendar.current
    let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9))!
    let schedule = ScheduleEngine(anchorMinutes: 480)
    let nodes = schedule.nodes(on: day)
    let reset = nodes[1].addingTimeInterval(397)
    let live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 10, windowMinutes: 300, resetsAt: reset),
        weekly: QuotaWindow(usedPercent: 10, windowMinutes: 10080, resetsAt: day.addingTimeInterval(86400)),
        capturedAt: day, accountID: "polling-account", sourceFile: "app-server")
    func policy(_ usage: UsageSnapshot? = nil, at now: Date? = nil, scanned: Bool = true, error: String? = nil,
                reliable: Bool = true, running: Bool = false, demand: Bool = false,
                executing: Bool = false, critical: Bool = false, plan: ScheduleEngine? = nil) -> UsagePollingPolicy {
        UsagePollingPolicy.evaluate(now: now ?? day, schedule: plan ?? schedule, enabled: true,
            scanned: scanned, scanError: error, reliableUsage: reliable, usage: usage ?? live,
            runningTask: running, resumeDemand: demand, executing: executing, criticalRefresh: critical)
    }
    check(policy().interval == 300, "reliable idle state reduces only quota polling to five minutes")
    check(policy(at: day.addingTimeInterval(180)).interval == 300 && !live.isFresh(at: day.addingTimeInterval(180)),
        "normal snapshot aging does not undo idle polling or extend execution freshness")
    for value in [policy(scanned: false), policy(error: "unreadable log"), policy(reliable: false),
                  policy(running: true), policy(demand: true), policy(executing: true), policy(critical: true)] {
        check(value.interval == 20, "unknown, active, recovery and verification states retain fast quota polling")
    }
    var unknown = live; unknown.fiveHour?.usedPercent = 0; unknown.zeroUseWindowActive = nil
    check(policy(unknown).interval == 20, "unknown zero-percent window cannot be classified as idle")
    check(policy(at: nodes[1].addingTimeInterval(-120)).interval == 20,
        "original plan boundary wakes idle quota polling two minutes early")
    check(schedule.retryOpportunity(at: nodes[1].addingTimeInterval(-120)) == nil &&
        schedule.retryOpportunity(at: nodes[1].addingTimeInterval(599))?.node == nodes[1],
        "two-minute preparation does not consume the last two minutes of the bounded retry opportunity")
    var blocked = live; blocked.fiveHour?.usedPercent = 100
    check(policy(blocked).interval == 300 && policy(blocked, demand: true).interval == 20,
        "far exhaustion can idle only without any pending recovery demand")
    for weekly in [false, true] {
        var close = live
        if weekly { close.weekly?.resetsAt = day.addingTimeInterval(120) }
        else { close.fiveHour?.resetsAt = day.addingTimeInterval(120) }
        check(policy(close).interval == 20, "each quota boundary independently wakes two minutes early: \(weekly)")
    }
    var both = blocked; both.weekly?.usedPercent = 100; both.fiveHour?.resetsAt = day.addingTimeInterval(-1)
    check(policy(both).interval == 20 && policy(both, demand: true).interval == 20,
        "an unverified five-hour boundary stays fast even when weekly quota remains blocked")
    let stalePlan = DecisionEngine(schedule: schedule).plan(now: day.addingTimeInterval(180), enabled: true,
        autoResume: true, earlyRecoveryPolicy: "ask", usage: live, blocked: [], reserveIdleDate: true)
    check(stalePlan.date == reset && stalePlan.decision == .wait(reason: "等待下一可行计划节点"),
        "older idle reading preserves conditional next-action date without an executable decision")

    let evidenceURL = root.appendingPathComponent("evidence.jsonl")
    func evidenceRow(node: Date, drift: TimeInterval, account: String = "polling-account", version: Int? = 1) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var row: [String: Any] = ["event": "confirmed", "kind": "ping", "node": iso.string(from: node),
            "at": iso.string(from: node.addingTimeInterval(drift + 14)),
            "after_reset": iso.string(from: node.addingTimeInterval(18000 + drift)),
            "account_id": account, "before_account_id": account,
            "schedule_anchor_minutes": 480, "schedule_timezone": calendar.timeZone.identifier]
        row["window_evidence_version"] = version
        return row
    }
    var mismatched = evidenceRow(node: nodes[0], drift: 1); mismatched["before_account_id"] = "other-account"
    let rows = [evidenceRow(node: nodes[0], drift: 397), evidenceRow(node: nodes[1], drift: 616),
                evidenceRow(node: nodes[2], drift: 1, version: nil), mismatched]
    var lines = Data()
    for row in rows { lines.append(try JSONSerialization.data(withJSONObject: row)); lines.append(10) }
    try lines.write(to: evidenceURL)
    let windows = ExecutionEventLog(url: evidenceURL).keepAliveWindows()
    check(windows.count == 2, "drift loader rejects legacy and account-mismatched confirmations")
    var drifted = schedule; drifted.accountID = "polling-account"; drifted.confirmedWindows = windows
    let effective = nodes[2].addingTimeInterval(616)
    check(drifted.nextKeepAliveNode(after: nodes[2].addingTimeInterval(-1)) == effective,
        "confirmed preceding Keeper window reserves the compensated actual node")
    check(drifted.currentKeepAliveNode(at: effective.addingTimeInterval(-1)) == nil &&
        drifted.currentKeepAliveNode(at: effective) == nodes[2],
        "compensated keep-alive never sends early and retains original node identity")
    check(drifted.currentKeepAliveNode(at: effective.addingTimeInterval(600)) == nodes[2] &&
        drifted.currentKeepAliveNode(at: effective.addingTimeInterval(601)) == nil,
        "compensated opportunity keeps a bounded ten-minute confirmation grace")
    check(drifted.currentNode(at: effective) == nil, "drift compensation does not extend three-minute resume tolerance")
    check(policy(at: effective.addingTimeInterval(-120), plan: drifted).interval == 20,
        "compensated boundary independently keeps quota polling fast")
    check(drifted.retryOpportunity(at: effective.addingTimeInterval(-1)) == nil &&
        drifted.retryOpportunity(at: effective.addingTimeInterval(599))?.node == nodes[2],
        "compensated retry budget begins at its effective date and lasts through the final opportunity minutes")
    var changedAccount = drifted; changedAccount.accountID = "other-account"
    check(changedAccount.nextKeepAliveNode(after: nodes[2].addingTimeInterval(-1)) == nodes[2],
        "another account cannot reuse persisted Keeper window evidence")
    var changedPlan = drifted; changedPlan.confirmedWindows = windows.map {
        KeepAliveWindowEvidence(accountID: $0.accountID, node: $0.node, windowReset: $0.windowReset,
            confirmedAt: $0.confirmedAt, anchorMinutes: 481, timeZoneID: $0.timeZoneID)
    }
    check(changedPlan.nextKeepAliveNode(after: nodes[2].addingTimeInterval(-1)) == nodes[2],
        "a changed daily plan cannot reuse otherwise matching node evidence")
    var changedZone = drifted; changedZone.confirmedWindows = windows.map {
        KeepAliveWindowEvidence(accountID: $0.accountID, node: $0.node, windowReset: $0.windowReset,
            confirmedAt: $0.confirmedAt, anchorMinutes: $0.anchorMinutes, timeZoneID: "different-zone")
    }
    check(changedZone.nextKeepAliveNode(after: nodes[2].addingTimeInterval(-1)) == nodes[2],
        "timezone provenance is required for drift compensation")
    var excessive = drifted; excessive.confirmedWindows = [KeepAliveWindowEvidence(accountID: "polling-account",
        node: nodes[1], windowReset: nodes[2].addingTimeInterval(1201), confirmedAt: nodes[1].addingTimeInterval(1210),
        anchorMinutes: 480, timeZoneID: calendar.timeZone.identifier)]
    check(excessive.nextKeepAliveNode(after: nodes[2].addingTimeInterval(-1)) == nodes[2],
        "drift beyond twenty minutes does not create an unlimited late opportunity")
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
    let nextAnchor = schedule.nodes(on: tomorrow)[0]
    check(drifted.nextKeepAliveNode(after: nextAnchor.addingTimeInterval(-1)) == nextAnchor,
        "next daily anchor discards the previous day's drift")
    let reloaded = ExecutionEventLog(url: evidenceURL).keepAliveWindows()
    drifted.confirmedWindows = reloaded
    check(drifted.currentKeepAliveNode(at: effective) == nodes[2], "restarting from persisted evidence restores the same compensated opportunity")
    var ordinary = live; ordinary.capturedAt = effective; ordinary.fiveHour?.resetsAt = effective.addingTimeInterval(18000)
    check(schedule.currentKeepAliveNode(at: effective) == nil,
        "ordinary user windows do not create schedule compensation")

    for (step, short, expected) in [(20, false, 5), (20, true, 15), (1, true, 20)] {
        var uptime: TimeInterval = 0
        let transport = PollingBudgetTransport()
        transport.quotaError = .server("error sending request")
        var connections = 0
        let provider = AppServerUsageProvider(makeTransport: { connections += 1; return transport },
            contextIdentity: { Data("same-auth".utf8) }, uptime: { uptime })
        for tick in stride(from: 0, to: 600, by: step) {
            uptime = Double(tick)
            if short { provider.setRetryOpportunity(UsageRetryOpportunity(node: day, end: day.addingTimeInterval(1200)), now: day.addingTimeInterval(uptime)) }
            _ = try? provider.read()
            _ = try? provider.pingModel()
            _ = try? provider.read()
        }
        check(transport.quotaCalls / 2 == expected && transport.models == 0 && connections == 1 && transport.closes == 0,
            "shared retained connection enforces finite automatic failure budget: \(step), \(short)")
        if short {
            uptime = 600; let before = transport.quotaCalls; _ = try? provider.read()
            check(transport.quotaCalls == before, "repeated opportunity setters cannot renew the ten-minute special period")
        }
    }
    do {
        var uptime: TimeInterval = 0
        let transport = PollingBudgetTransport(); transport.quotaError = .server("error sending request")
        let provider = AppServerUsageProvider(makeTransport: { transport }, contextIdentity: { nil }, uptime: { uptime })
        _ = try? provider.read()
        uptime = 20
        check((try? provider.pingModel()) != nil && transport.models == 1, "model discovery can recover on the retained connection")
        _ = try? provider.read()
        check(transport.quotaCalls == 2, "successful model discovery cannot bypass shared automatic admission")
        uptime = 40; _ = try? provider.read()
        uptime = 60; _ = try? provider.read()
        check(transport.quotaCalls == 4, "successful model discovery does not reset quota failure backoff debt")
        check((try? provider.pingModel()) != nil && transport.models == 1, "bounded model cache bridges a failed quota preflight without extra RPCs")
        uptime = 341; _ = try? provider.pingModel()
        check(transport.models == 2, "model permission discovery is repeated after its five-minute cache expires")
    }
    for error in [CodexConnectionError.timeout, .ended, .invalidResponse, .server("HTTP/1.1 401 Unauthorized"),
                  .server("request timed out"), .server("workspace routing discovery timeout")] {
        var uptime: TimeInterval = 0
        let transport = PollingBudgetTransport(); transport.quotaError = error
        let provider = AppServerUsageProvider(makeTransport: { transport }, contextIdentity: { nil }, uptime: { uptime })
        provider.setRetryOpportunity(UsageRetryOpportunity(node: day, end: day.addingTimeInterval(600)), now: day)
        for tick in stride(from: 0, to: 600, by: 20) { uptime = Double(tick); _ = try? provider.read() }
        check(transport.quotaCalls == 5, "authentication, protocol, process and timeout faults keep ordinary backoff: \(UsageReadFailure.reason(for: error))")
    }
    do {
        var uptime: TimeInterval = 0
        let transport = PollingBudgetTransport(); transport.quotaError = .server("error sending request")
        let provider = AppServerUsageProvider(makeTransport: { transport }, contextIdentity: { nil }, uptime: { uptime })
        provider.setRetryOpportunity(UsageRetryOpportunity(node: day, end: day.addingTimeInterval(600)), now: day)
        _ = try? provider.read()
        uptime = 1; _ = try? provider.readForUserRefresh()
        uptime = 5; _ = try? provider.readForUserRefresh()
        uptime = 6; _ = try? provider.readForUserRefresh()
        check(transport.quotaCalls == 6, "manual failures retain their separate five-second throttle during the special period")
    }
    do {
        let transport = CountingUsageTransport(); transport.delay = 0.25
        let provider = AppServerUsageProvider(makeTransport: { transport }, contextIdentity: { nil })
        let reading = Task.detached { try provider.read() }
        for _ in 0..<100 { if transport.calls > 0 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let began = ProcessInfo.processInfo.systemUptime
        provider.setRetryOpportunity(UsageRetryOpportunity(node: day, end: Date().addingTimeInterval(600)), now: Date())
        check(ProcessInfo.processInfo.systemUptime - began < 0.1, "main-thread opportunity setter does not wait on the blocking RPC lock")
        _ = try await reading.value
    }

    let observerHome = root.appendingPathComponent("observer-home")
    try FileManager.default.createDirectory(at: observerHome, withIntermediateDirectories: true)
    var clock = Date()
    var observation = live; observation.capturedAt = clock; observation.fiveHour?.resetsAt = clock.addingTimeInterval(18000)
    let queuedProvider = PollingFixtureUsage(observation)
    queuedProvider.pause()
    let observer = UsageObserver(codexHome: observerHome, provider: queuedProvider,
        logURL: root.appendingPathComponent("observer.jsonl"), now: { clock })
    observer.refresh()
    for _ in 0..<100 { if queuedProvider.reads > 0 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    for _ in 0..<20 { observer.refresh() }
    for _ in 0..<20 { observer.refresh(source: "session_activity", critical: true) }
    queuedProvider.release()
    try await pollingSettle { !observer.refreshing }
    check(queuedProvider.reads == 2 && queuedProvider.manualReads == 0 && !observer.criticalRefreshPending,
        "critical automatic activity coalesces one follow-up while ordinary ticks never queue reads")
    let firstCapture = observer.snapshot!.capturedAt
    clock = clock.addingTimeInterval(30); observation.capturedAt = clock; queuedProvider.set(observation)
    observer.refresh(); try await pollingSettle { !observer.refreshing }
    check((observer.snapshot?.capturedAt ?? .distantPast) > firstCapture && observer.hasReliableReading && observer.lastError == nil,
        "equal quota values still update capture time and successful reading state")
    let wake = clock.addingTimeInterval(140)
    observer.setPolling(UsagePollingPolicy(interval: 300, wakeAt: wake), retryOpportunity: nil)
    clock = clock.addingTimeInterval(80)
    check(observer.nextAutomaticRefreshAt == wake && observer.hasReliableReading && observer.snapshot?.isFresh(at: clock) == false,
        "idle timer retains the boundary reservation after sixty-second execution freshness expires")
    var display = MenuPresentation()
    let freshPlan = DecisionEngine(schedule: schedule).plan(now: day, enabled: true, autoResume: false,
        earlyRecoveryPolicy: "ask", usage: live, blocked: [])
    let freshDisplay = display.build(plan: freshPlan, usage: live, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(), now: day)
    let oldDisplay = display.build(plan: stalePlan, usage: live, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(), now: day.addingTimeInterval(180))
    check(oldDisplay.headline == freshDisplay.headline && !oldDisplay.quotas.isEmpty && !oldDisplay.isSyncing,
        "normal idle aging preserves timestamped menu content instead of creating a synchronization error")

    let appHome = root.appendingPathComponent("app-home")
    let traces = appHome.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
    try pollingMakeLogs(home: appHome)
    let suite = "keeper.polling.tests." + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    clock = Date()
    let parts = calendar.dateComponents([.hour, .minute], from: clock)
    prefs.register(defaults: ["enabled": true, "autoResume": true, "dailyAnchorMinutes": (parts.hour! * 60 + parts.minute! + 120) % 1440,
        "earlyRecoveryPolicy": "ask", "resumeWorkspaceReminder": false])
    observation.capturedAt = clock; observation.fiveHour?.resetsAt = clock.addingTimeInterval(18000)
    observation.weekly?.resetsAt = clock.addingTimeInterval(86400)
    let appProvider = PollingFixtureUsage(observation)
    let state = AppState(provider: appProvider, defaults: prefs, runtimeURL: root.appendingPathComponent("app-support/pending-runtime.json"),
        codexHome: appHome, startMonitoring: false, now: { clock })
    check(state.usage.polling.interval == 20, "AppState initialization cannot assume that an unscanned home is idle")
    state.refresh(); try await pollingSettle { state.sessions.hasScanned && !state.usage.refreshing }
    state.recompute(allowExecution: false)
    check(state.usage.polling.interval == 300 && state.nextAction?.date != nil, "real AppState enters idle polling only after reliable initialization")
    let beforeAging = appProvider.reads
    clock = clock.addingTimeInterval(80)
    state.recompute(allowExecution: false)
    check(state.usage.polling.interval == 300 && state.nextAction?.date != nil && appProvider.reads == beforeAging,
        "AppState keeps its plan wakeup without issuing an aging-induced quota refresh")
    func publishFresh(_ used: Double = 10) {
        observation.capturedAt = clock; observation.fiveHour?.usedPercent = used; appProvider.set(observation)
    }
    let id = UUID().uuidString
    let file = traces.appendingPathComponent("rollout-\(id).jsonl")
    var trace = pollingMetadata(id, at: clock.addingTimeInterval(-1), subagent: true) + pollingEvent("task_started", at: clock)
    publishFresh()
    try trace.write(to: file, atomically: true, encoding: .utf8)
    let beforeActivity = appProvider.reads
    state.sessions.refresh(); try await pollingSettle { appProvider.reads > beforeActivity && !state.usage.refreshing }
    check(state.usage.polling.interval == 20 && state.sessions.sessions.contains { $0.id == id && $0.isSubagent && $0.taskRunning },
        "new observed child activity wakes quota immediately after local discovery")
    clock = Date(timeIntervalSince1970: floor(clock.timeIntervalSince1970) + 2)
    publishFresh(); appProvider.pause()
    let coveredReads = appProvider.reads
    state.usage.refresh(); try await pollingSettle { appProvider.reads > coveredReads }
    let coveredEvent = clock.addingTimeInterval(-1)
    trace += pollingEvent("user_message", at: coveredEvent)
    try trace.write(to: file, atomically: true, encoding: .utf8)
    state.sessions.refresh()
    try await pollingSettle { state.sessions.sessions.first { $0.id == id }?.lastUserMessageAt == coveredEvent }
    check(!state.usage.criticalRefreshPending && appProvider.reads == coveredReads + 1,
        "activity preceding an in-flight quota query does not queue a redundant read")
    appProvider.release(); try await pollingSettle { !state.usage.refreshing }
    check(appProvider.reads == coveredReads + 1, "same-phase local scans do not double healthy quota polling")
    clock = clock.addingTimeInterval(1); publishFresh(); appProvider.pause()
    let uncoveredReads = appProvider.reads
    state.usage.refresh(); try await pollingSettle { appProvider.reads > uncoveredReads }
    clock = clock.addingTimeInterval(1); publishFresh()
    trace += pollingEvent("user_message", at: clock)
    try trace.write(to: file, atomically: true, encoding: .utf8)
    state.sessions.refresh(); try await pollingSettle { state.usage.criticalRefreshPending }
    check(state.usage.polling.interval == 20, "activity after query admission stays fast until its follow-up is covered")
    appProvider.release(); try await pollingSettle { !state.usage.refreshing }
    check(appProvider.reads == uncoveredReads + 2 && appProvider.manualReads == 0,
        "activity after query admission merges exactly one automatic follow-up")
    clock = clock.addingTimeInterval(1)
    for _ in 0..<25 {
        let next = UUID().uuidString
        let path = traces.appendingPathComponent("rollout-\(next).jsonl")
        try (pollingMetadata(next, at: clock) + pollingEvent("task_complete", at: clock)).write(to: path, atomically: true, encoding: .utf8)
    }
    state.sessions.watchedIDs = [] // Exercise the worker's own remembered running IDs.
    state.sessions.refresh(); try await pollingSettle { state.sessions.sessions.count >= 21 }
    check(state.sessions.sessions.contains { $0.id == id && $0.taskRunning },
        "known running child remains monitored after more than twenty newer rollouts")
    trace += pollingEvent("task_complete", at: clock)
    try trace.write(to: file, atomically: true, encoding: .utf8)
    publishFresh()
    state.sessions.refresh(); try await pollingSettle { !state.sessions.sessions.contains { $0.id == id && $0.taskRunning } && !state.usage.refreshing }
    state.recompute(allowExecution: false)
    check(state.usage.polling.interval == 300, "completed tasks can return the actual AppState to idle polling")
    let stoppedID = UUID().uuidString
    let stoppedFile = traces.appendingPathComponent("rollout-\(stoppedID).jsonl")
    clock = clock.addingTimeInterval(1)
    var stoppedTrace = pollingMetadata(stoppedID, at: clock.addingTimeInterval(-1)) + pollingEvent("error", at: clock, extra: ["message": "usage_limit_reached"])
    observation.accountID = "recovery-account"
    try Data("{\"tokens\":{\"account_id\":\"recovery-account\"}}".utf8).write(to: appHome.appendingPathComponent("auth.json"))
    publishFresh(100)
    try stoppedTrace.write(to: stoppedFile, atomically: true, encoding: .utf8)
    state.sessions.refresh(); try await pollingSettle { state.availableTasks.contains { $0.id == stoppedID } && !state.usage.refreshing }
    check(state.usage.polling.interval == 20, "quota-stopped tasks remain fast throughout a far recovery deadline")
    let savedRuntime = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("app-support/pending-runtime.json"))) as! [String: Any]
    check((savedRuntime["accounts"] as? [String: String])?[stoppedID] == "recovery-account",
        "a task discovered with an identity change waits for covered quota before account binding")
    prefs.set(false, forKey: "autoResume"); publishFresh(100); state.recompute(allowExecution: false)
    try await pollingSettle { !state.usage.refreshing }
    check(state.usage.polling.interval == 300, "explicitly disabled automatic continuation does not permanently block idle polling")
    prefs.set(true, forKey: "autoResume"); publishFresh(100); state.recompute(allowExecution: false)
    try await pollingSettle { !state.usage.refreshing }
    check(state.usage.polling.interval == 20, "reenabling a pending continuation restores fast polling")
    clock = clock.addingTimeInterval(1); publishFresh()
    state.usage.refresh(); try await pollingSettle { !state.usage.refreshing }
    state.recompute(allowExecution: false)
    check(state.nextAction?.mode == .keepAlive && state.choices.recoveryDecisions?.isEmpty == false && state.usage.polling.interval == 20,
        "recovery choice remains a demand even when the displayed next action is keep-alive")
    let secondID = UUID().uuidString
    let secondFile = traces.appendingPathComponent("rollout-\(secondID).jsonl")
    try (pollingMetadata(secondID, at: clock.addingTimeInterval(-1)) + pollingEvent("error", at: clock, extra: ["message": "usage_limit_reached"]))
        .write(to: secondFile, atomically: true, encoding: .utf8)
    publishFresh(100); state.sessions.refresh()
    try await pollingSettle { state.availableTasks.count == 2 && !state.usage.refreshing }
    check(state.usage.polling.interval == 20 && state.choices.recoveryDecisions?.isEmpty == false,
        "one task awaiting a choice cannot hide another task's blocked recovery demand")
    state.useKeepAlive(for: state.availableTasks)
    check(state.usage.polling.interval == 300, "explicit cancellation of all historical episodes permits true idle polling")
    let identityReads = appProvider.reads
    try Data("{\"tokens\":{\"account_id\":\"fixture-only\"}}".utf8).write(to: appHome.appendingPathComponent("auth.json"))
    publishFresh(100); state.sessions.refresh()
    try await pollingSettle { appProvider.reads > identityReads && !state.usage.refreshing }
    check(appProvider.manualReads == 0 && state.usage.hasReliableReading,
        "local identity fingerprint changes wake idle quota without network polling or manual bypass")
    clock = clock.addingTimeInterval(1); publishFresh()
    stoppedTrace += pollingEvent("user_message", at: clock) + pollingEvent("task_started", at: clock)
    try stoppedTrace.write(to: stoppedFile, atomically: true, encoding: .utf8)
    let manualResumeReads = appProvider.reads
    state.sessions.refresh(); try await pollingSettle { appProvider.reads > manualResumeReads && !state.usage.refreshing }
    check(!state.blockedSessions.contains { $0.id == stoppedID } && state.usage.polling.interval == 20,
        "detected manual task recovery revokes the stop and requests automatic live quota")
    let environmentReads = appProvider.reads
    state.environmentChanged(); try await pollingSettle { !state.usage.refreshing }
    check(appProvider.reads > environmentReads && appProvider.manualReads == 0,
        "wake/network/clock environment route requests automatic quota rather than using manual throttle")
    clock = clock.addingTimeInterval(86400); publishFresh()
    let crossingReads = appProvider.reads
    state.recompute(allowExecution: false); try await pollingSettle { !state.usage.refreshing }
    check(appProvider.reads > crossingReads, "local day crossing recalculates the schedule and automatically requests fresh quota")
    state.usage.stop(); state.sessions.stop()

    let gateHome = root.appendingPathComponent("gate-home")
    try FileManager.default.createDirectory(at: gateHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try pollingMakeLogs(home: gateHome)
    let gateSuite = "keeper.polling.gate." + UUID().uuidString
    let gatePrefs = UserDefaults(suiteName: gateSuite)!
    defer { gatePrefs.removePersistentDomain(forName: gateSuite) }
    gatePrefs.register(defaults: ["enabled": true, "autoResume": false, "dailyAnchorMinutes": 480])
    var gateClock = schedule.nodes(on: Date())[0].addingTimeInterval(-10)
    var gateUsage = live
    gateUsage.capturedAt = gateClock
    gateUsage.fiveHour = QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: gateClock.addingTimeInterval(18000))
    gateUsage.weekly?.resetsAt = gateClock.addingTimeInterval(86400)
    gateUsage.zeroUseWindowActive = false
    let gateProvider = PollingFixtureUsage(gateUsage)
    let gatePings = ReminderTestPing()
    let gateExecution = ExecutionCoordinator(provider: gateProvider, defaults: gatePrefs,
        ledgerURL: root.appendingPathComponent("gate-support/resume-attempts.json"),
        pingTransport: gatePings, codexHome: gateHome, now: { gateClock })
    let gateState = AppState(provider: gateProvider, defaults: gatePrefs,
        runtimeURL: root.appendingPathComponent("gate-support/pending-runtime.json"),
        codexHome: gateHome, execution: gateExecution, startMonitoring: false, now: { gateClock })
    gateState.refresh(); try await pollingSettle { gateState.sessions.hasScanned && !gateState.usage.refreshing }
    gateProvider.pause()
    let gateReads = gateProvider.reads
    gateState.usage.refresh(); try await pollingSettle { gateProvider.reads > gateReads }
    gateClock = gateClock.addingTimeInterval(11)
    gateState.usage.refresh(source: "session_activity", critical: true)
    gateState.recompute()
    check(gateState.usage.snapshot?.isFresh(at: gateClock) == true &&
        gateState.usage.criticalRefreshPending && !gateExecution.running && gatePings.count == 0,
        "an uncovered critical event blocks automatic dispatch despite a fresh pre-event snapshot at a due node")
    gateProvider.release()
    try await pollingSettle { !gateState.usage.refreshing && !gateExecution.running && gatePings.count == 1 }
    check(!gateState.usage.criticalRefreshPending && gatePings.count == 1,
        "automatic dispatch proceeds once after the critical follow-up completes")
    gateClock = gateClock.addingTimeInterval(18000)
    gateUsage.capturedAt = gateClock
    gateUsage.fiveHour?.resetsAt = gateClock.addingTimeInterval(18000)
    gateProvider.set(gateUsage)
    gateProvider.setModelError(CodexConnectionError.server("fixture model unavailable"))
    let failedReads = gateProvider.reads
    gateState.usage.refresh()
    try await pollingSettle { !gateState.usage.refreshing && !gateExecution.running && gateExecution.lastFailure != nil }
    try await Task.sleep(nanoseconds: 100_000_000)
    check(gateProvider.reads == failedReads + 1 && gatePings.count == 1,
        "failed model preflight cannot create a quota refresh and automatic redispatch loop")
    gateState.usage.stop(); gateState.sessions.stop()
}

private func pollingMakeLogs(home: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(home.appendingPathComponent("logs_1.sqlite").path, &database) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
}

private func pollingMetadata(_ id: String, at: Date, subagent: Bool = false) -> String {
    var payload: [String: Any] = ["id": id, "cwd": "/fixture", "timestamp": ISO8601DateFormatter().string(from: at)]
    if subagent { payload["source"] = ["subagent": ["thread_spawn": [:]]] }
    return pollingLine(type: "session_meta", at: at, payload: payload)
}

private func pollingEvent(_ type: String, at: Date, extra: [String: Any] = [:]) -> String {
    var payload = extra; payload["type"] = type
    return pollingLine(type: "event_msg", at: at, payload: payload)
}

private func pollingLine(type: String, at: Date, payload: [String: Any]) -> String {
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let row: [String: Any] = ["type": type, "timestamp": iso.string(from: at), "payload": payload]
    return String(data: try! JSONSerialization.data(withJSONObject: row), encoding: .utf8)! + "\n"
}

@MainActor private func pollingSettle(_ ready: () -> Bool) async throws {
    for _ in 0..<300 { if ready() { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    guard ready() else { throw CodexConnectionError.timeout }
    // Combine publications are delivered on the following main-queue turn.
    try await Task.sleep(nanoseconds: 30_000_000)
}

private final class PollingBudgetTransport: CodexTransport {
    var quotaError: CodexConnectionError?
    var quotaCalls = 0
    var models = 0
    var closes = 0
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        if method == "account/read" { return ["account": ["type": "chatgpt"]] }
        if method == "model/list" {
            models += 1
            return ["data": [["id": "gpt-6-luna", "supportedReasoningEfforts": [["reasoningEffort": "low"]]]]]
        }
        quotaCalls += 1
        if let quotaError { throw quotaError }
        return ["accountId": "polling-account", "rateLimits": ["primary": ["usedPercent": 10,
            "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(18000).timeIntervalSince1970]]]
    }
    func nextMessage(timeout: TimeInterval) throws -> [String: Any] { throw CodexConnectionError.timeout }
    func close() { closes += 1 }
}

private final class PollingFixtureUsage: UsageProvider, @unchecked Sendable {
    private let condition = NSCondition()
    private var snapshot: UsageSnapshot
    private var paused = false
    private var count = 0
    private var manualCount = 0
    private var modelError: Error?
    init(_ snapshot: UsageSnapshot) { self.snapshot = snapshot }
    var reads: Int { condition.lock(); defer { condition.unlock() }; return count }
    var manualReads: Int { condition.lock(); defer { condition.unlock() }; return manualCount }
    func set(_ snapshot: UsageSnapshot) { condition.lock(); self.snapshot = snapshot; condition.unlock() }
    func pause() { condition.lock(); paused = true; condition.unlock() }
    func release() { condition.lock(); paused = false; condition.broadcast(); condition.unlock() }
    func setModelError(_ error: Error) { condition.lock(); modelError = error; condition.unlock() }
    func readForUserRefresh() throws -> UsageSnapshot {
        condition.lock(); manualCount += 1; condition.unlock()
        return try read()
    }
    func read() throws -> UsageSnapshot {
        condition.lock(); defer { condition.unlock() }
        count += 1
        let deadline = Date().addingTimeInterval(3)
        while paused { if !condition.wait(until: deadline) { throw CodexConnectionError.timeout } }
        return snapshot
    }
    func pingModel() throws -> PingModel {
        condition.lock(); defer { condition.unlock() }
        if let modelError { throw modelError }
        return PingModel(model: "gpt-6-luna", reasoningEffort: "low")
    }
}
