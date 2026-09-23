import Foundation
import SQLite3
import Darwin

@main struct RegressionTests {
    @MainActor static func main() async throws {
        var failed = 0
        var count = 0
        func check(_ value: Bool, _ name: String) {
            count += 1
            if !value { failed += 1; print("FAIL: \(name)") }
        }
        let onboardingSuite = "keeper.onboarding.tests." + UUID().uuidString
        let onboardingDefaults = UserDefaults(suiteName: onboardingSuite)!
        defer { onboardingDefaults.removePersistentDomain(forName: onboardingSuite) }
        check(OnboardingPreferences.needsSetup(defaults: onboardingDefaults, domainName: onboardingSuite), "fresh install requires setup before starting services")
        onboardingDefaults.register(defaults: ["enabled": true, "autoResume": true])
        check(OnboardingPreferences.needsSetup(defaults: onboardingDefaults, domainName: onboardingSuite), "registered defaults cannot skip first-launch setup")
        onboardingDefaults.set(false, forKey: "enabled")
        check(!OnboardingPreferences.needsSetup(defaults: onboardingDefaults, domainName: onboardingSuite), "existing disabled user skips onboarding")
        onboardingDefaults.removeObject(forKey: "enabled")
        onboardingDefaults.set(570, forKey: "dailyAnchorMinutes")
        check(!OnboardingPreferences.needsSetup(defaults: onboardingDefaults, domainName: onboardingSuite), "upgrade preserves existing daily start time")
        onboardingDefaults.set(false, forKey: "onboardingCompleted")
        check(OnboardingPreferences.needsSetup(defaults: onboardingDefaults, domainName: onboardingSuite), "unfinished setup opens again")
        OnboardingPreferences.complete(anchorMinutes: 615, defaults: onboardingDefaults)
        check(onboardingDefaults.integer(forKey: "dailyAnchorMinutes") == 615 && !OnboardingPreferences.needsSetup(defaults: onboardingDefaults, domainName: onboardingSuite), "chosen time persists and completed setup never repeats")
        let defaultMode = ResumeMessagePreferences.Mode.localizedDefault
        let customMode = ResumeMessagePreferences.Mode.custom
        check(ResumeMessagePreferences.mode(saved: "继续", storedMode: nil, legacyCustomized: false) == defaultMode &&
            ResumeMessagePreferences.mode(saved: "Continue", storedMode: nil, legacyCustomized: false) == defaultMode &&
            ResumeMessagePreferences.content(saved: "继续", mode: defaultMode, localizedDefault: "Continue") == "Continue",
            "legacy built-in text follows the app language")
        check(ResumeMessagePreferences.mode(saved: "检查项目", storedMode: nil, legacyCustomized: false) == customMode &&
            ResumeMessagePreferences.mode(saved: "继续", storedMode: nil, legacyCustomized: true) == customMode &&
            ResumeMessagePreferences.content(saved: "继续", mode: customMode, localizedDefault: "Continue") == "继续",
            "legacy custom text stays unchanged")
        check(ResumeMessagePreferences.mode(saved: "检查项目", storedMode: "default", legacyCustomized: true) == defaultMode &&
            ResumeMessagePreferences.mode(saved: "继续", storedMode: "custom", legacyCustomized: false) == customMode,
            "explicit selection takes precedence over legacy preferences")
        check(ResumeMessagePreferences.content(saved: "检查项目", mode: defaultMode, localizedDefault: "Continue") == "Continue" &&
            ResumeMessagePreferences.content(saved: "检查项目", mode: customMode, localizedDefault: "Continue") == "检查项目" &&
            ResumeMessagePreferences.content(saved: "", mode: customMode, localizedDefault: "Continue") == "Continue",
            "default selection ignores stored custom text and empty custom text does not send a blank prompt")
        for message in ["workspace routing discovery timed out", "workspace routing discovery timedout"] {
            check(CodexConnectionError.server(message).localizedDescription == "Codex 服务连接超时，请检查网络或代理后重新同步。" &&
                CodexConnectionError.serverFailureReason(message) == "workspace_routing_timeout",
                "workspace routing timeout has Chinese UI text and stable diagnostic reason: \(message)")
        }
        check(CodexConnectionError.server("账户已改变，暂停自动继续").localizedDescription == "账户已改变，暂停自动继续",
            "internal Chinese safety errors retain their specific instructions")
        let iso = ISO8601DateFormatter()
        func date(_ s: String) -> Date { iso.date(from: s)! }
        let now = date("2026-09-10T13:00:00Z")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let schedule = ScheduleEngine(anchorMinutes: 480)
        check(schedule.currentNode(at: now.addingTimeInterval(-1), calendar: cal) == nil, "node cannot run early")
        check(schedule.currentNode(at: now.addingTimeInterval(180), calendar: cal) == now, "three-minute grace includes its closing boundary")
        check(schedule.currentNode(at: now.addingTimeInterval(181), calendar: cal) == nil, "past three minutes is outside the scheduled round")
        check(schedule.firstNode(onOrAfter: now.addingTimeInterval(103), calendar: cal) == now.addingTimeInterval(103), "reset delayed by 103 seconds retains this execution opportunity")
        check(ScheduleEngine(anchorMinutes: 1200).nextNode(after: date("2026-09-11T00:00:00Z"), calendar: cal) == date("2026-09-11T01:00:00Z"), "yesterday cross-midnight node")
        // Reproduce 18:01:54 exhausted → reset 18:02:19 → observed 18:03:00.5.
        let recoveryNode = schedule.nodes(on: now)[1]
        let recoveryReset = recoveryNode.addingTimeInterval(139)
        let recoveryObserved = recoveryNode.addingTimeInterval(180.5)
        let recoveryBefore = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 100, windowMinutes: 300, resetsAt: recoveryReset), weekly: nil,
            capturedAt: recoveryReset.addingTimeInterval(-25), accountID: "recovery-test", sourceFile: "app-server")
        let recoveryAfter = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: recoveryObserved.addingTimeInterval(18000)), weekly: nil,
            capturedAt: recoveryObserved, accountID: "recovery-test", sourceFile: "app-server")
        check(UsageRecovery.isNatural(from: recoveryBefore, to: recoveryAfter, now: recoveryObserved), "66-second polling gap around scheduled reset still counts as natural recovery")
        let recoveryTarget = BlockedSession(id: "recovery-fixture", project: "Recovery", cwd: "/fixture", blockedAt: recoveryNode.addingTimeInterval(-3600), fiveHourResetAt: recoveryReset, weeklyResetAt: nil, fileURL: URL(fileURLWithPath: "/fixture/rollout.jsonl"))
        let recoveryDecision = DecisionEngine(schedule: schedule).decide(now: recoveryObserved, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: recoveryAfter, blocked: [recoveryTarget],
            observedRecovery: UsageRecovery.isNatural(from: recoveryBefore, to: recoveryAfter, now: recoveryObserved))
        if case .resume = recoveryDecision { check(true, "observed recovery can resume just after node grace closes") }
        else { check(false, "observed recovery can resume just after node grace closes") }
        var changedRecovery = recoveryAfter
        changedRecovery.accountID = "other-account"
        check(!UsageRecovery.isNatural(from: recoveryBefore, to: changedRecovery, now: recoveryObserved), "recovery cannot cross accounts")
        changedRecovery = recoveryAfter; changedRecovery.capturedAt = recoveryReset.addingTimeInterval(-1)
        check(!UsageRecovery.isNatural(from: recoveryBefore, to: changedRecovery, now: changedRecovery.capturedAt), "early/manual reset is not a natural recovery")
        changedRecovery.capturedAt = recoveryReset.addingTimeInterval(91)
        check(!UsageRecovery.isNatural(from: recoveryBefore, to: changedRecovery, now: changedRecovery.capturedAt), "late reconnect does not invent continuously observed recovery")
        var oldRecovery = recoveryBefore; oldRecovery.capturedAt = recoveryReset.addingTimeInterval(-91)
        check(!UsageRecovery.isNatural(from: oldRecovery, to: recoveryAfter, now: recoveryObserved), "old exhaustion evidence remains bounded near scheduled reset")
        check(!UsageRecovery.isNatural(from: recoveryBefore, to: recoveryAfter, now: recoveryObserved.addingTimeInterval(61)), "resume still needs a fresh current reading")
        changedRecovery = recoveryAfter; changedRecovery.fiveHour = nil
        check(!UsageRecovery.isNatural(from: recoveryBefore, to: changedRecovery, now: recoveryObserved), "missing quota window cannot count as recovered")
        changedRecovery = recoveryAfter; changedRecovery.weekly = QuotaWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: recoveryObserved.addingTimeInterval(3600))
        check(!UsageRecovery.isNatural(from: recoveryBefore, to: changedRecovery, now: recoveryObserved), "weekly exhaustion still blocks recovery")
        // Sept 22: the last live exhausted poll was 14:19; the first recovered poll was 14:47.
        do {
            let reset = date("2026-09-22T06:31:12Z")
            let observed = date("2026-09-22T06:47:15Z")
            let stopped = BlockedSession(id: "weekly-recovery", project: "Recovery", cwd: "/fixture",
                blockedAt: date("2026-09-17T16:12:11Z"), fiveHourResetAt: nil, weeklyResetAt: reset,
                fileURL: URL(fileURLWithPath: "/fixture/rollout.jsonl"))
            let live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: observed.addingTimeInterval(18000)),
                weekly: QuotaWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: observed.addingTimeInterval(604800)),
                capturedAt: observed, accountID: "weekly-account", sourceFile: "app-server", zeroUseWindowActive: false)
            var before = live
            before.capturedAt = date("2026-09-22T06:19:36Z")
            before.weekly = QuotaWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: reset)
            func canRecover(_ usage: UsageSnapshot?, account: String? = "weekly-account", target: BlockedSession? = nil, at: Date? = nil) -> Bool {
                UsageRecovery.canResumeAfterScheduledReset(target ?? stopped, usage: usage, boundAccount: account, now: at ?? observed)
            }
            func withResets(_ five: Date?, _ weekly: Date?, blockedAt: Date? = nil) -> BlockedSession {
                BlockedSession(id: stopped.id, project: stopped.project, cwd: stopped.cwd, blockedAt: blockedAt ?? stopped.blockedAt,
                    fiveHourResetAt: five, weeklyResetAt: weekly, fileURL: stopped.fileURL)
            }
            check(!UsageRecovery.isNatural(from: before, to: live, now: observed) && canRecover(live),
                "missed weekly reset uses the stopped task deadline without claiming continuous observation")
            var shanghai = cal; shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let planner = DecisionEngine(schedule: schedule)
            let resumed = planner.plan(now: observed, calendar: shanghai, enabled: true, autoResume: true,
                earlyRecoveryPolicy: "ask", usage: live, blocked: [stopped], observedRecovery: canRecover(live))
            if case .resume = resumed.decision { check(true, "14:47 live weekly recovery resumes without waiting for 18:00") }
            else { check(false, "14:47 live weekly recovery resumes without waiting for 18:00") }
            check(!canRecover(nil) && !canRecover(live, account: nil) && !canRecover(live, account: "") && !canRecover(live, account: "other"),
                "scheduled recovery requires live quota and the existing nonempty account binding")
            var changed = live; changed.accountID = nil
            check(!canRecover(changed), "scheduled recovery rejects missing current account")
            changed = live; changed.sourceFile = "rollout-old.jsonl"
            check(!canRecover(changed), "rollout fallback never authorizes scheduled recovery")
            changed = live; changed.capturedAt = observed.addingTimeInterval(-61)
            check(!canRecover(changed), "scheduled recovery still requires a fresh current poll")
            changed = live; changed.capturedAt = .distantPast
            check(!canRecover(changed) && canRecover(live), "environment invalidation pauses recovery until a fresh poll arrives")
            check(!canRecover(live, target: withResets(nil, nil)), "unknown stop deadline cannot invent recovery")
            check(!canRecover(live, target: withResets(nil, stopped.blockedAt)), "deadline must follow this stop episode")
            changed = live; changed.capturedAt = reset.addingTimeInterval(-1)
            check(!canRecover(changed, at: changed.capturedAt), "early quota reset cannot release a task before its scheduled reset")
            check(!canRecover(changed, at: reset), "a fresh pre-reset reading cannot authorize post-reset recovery")
            changed = live; changed.weekly = nil
            check(!canRecover(changed), "weekly stop requires the weekly window in current quota")
            changed = live; changed.fiveHour = nil
            check(!canRecover(changed, target: withResets(reset, nil)), "five-hour stop requires the five-hour window in current quota")
            changed = live; changed.weekly?.usedPercent = 100
            check(!canRecover(changed), "weekly exhaustion still blocks scheduled recovery")
            changed = live; changed.fiveHour?.usedPercent = 100
            check(!canRecover(changed), "five-hour exhaustion also blocks recovered weekly task")
            check(!canRecover(live, target: withResets(reset, observed.addingTimeInterval(600))),
                "both exhausted windows must reach the later scheduled reset")
            check(canRecover(live, target: withResets(reset, nil)), "five-hour scheduled stop also survives missed recovery polls")
            let held = planner.plan(now: observed, calendar: shanghai, enabled: true, autoResume: true,
                earlyRecoveryPolicy: "ask", usage: live, blocked: [stopped], observedRecovery: canRecover(live), heldForPlan: true)
            check(held.decision == .wait(reason: "按计划自动继续") && held.date == date("2026-09-22T10:00:00Z"),
                "held tasks keep the next plan node after disconnected weekly recovery")
            let protectedAt = date("2026-09-23T22:00:00Z")
            changed = live; changed.capturedAt = protectedAt
            let protected = planner.plan(now: protectedAt, calendar: shanghai, enabled: true, autoResume: true,
                earlyRecoveryPolicy: "ask", usage: changed, blocked: [stopped], observedRecovery: canRecover(changed, at: protectedAt))
            check(protected.decision == .wait(reason: "按计划自动继续") && protected.date == date("2026-09-24T00:00:00Z"),
                "scheduled recovery preserves the anchor protection interval")
            let laterStop = withResets(nil, observed.addingTimeInterval(604800), blockedAt: observed.addingTimeInterval(-1))
            check(laterStop.episodeKey != stopped.episodeKey && !canRecover(live, target: laterStop),
                "a new stop in the same task must wait for its own reset deadline")
        }
        let localNode = schedule.nodes(on: now)[1]
        let future = localNode.addingTimeInterval(3600)
        let engine = DecisionEngine(schedule: schedule)
        let full = QuotaWindow(usedPercent: 100, windowMinutes: 300, resetsAt: localNode.addingTimeInterval(-1))
        let weekly = QuotaWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: future)
        func decide(_ five: QuotaWindow?, _ week: QuotaWindow?) -> KeeperDecision {
            engine.decide(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: UsageSnapshot(fiveHour: five, weekly: week, capturedAt: localNode, sourceFile: "app-server"), blocked: [])
        }
        if case .ping = decide(full, nil) { check(false, "expired exhausted must wait") } else { check(true, "expired exhausted must wait") }
        if case .ping = decide(QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: localNode.addingTimeInterval(-1)), weekly) { check(false, "weekly gates ping") } else { check(true, "weekly gates ping") }
        if case .ping = decide(nil, QuotaWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: future)) { check(false, "weekly-only must not ping") } else { check(true, "weekly-only must not ping") }
        // The displayed action must be the same action the executor can perform.
        let evening = date("2026-09-10T21:13:00Z")
        let midnightReset = date("2026-09-11T00:52:44Z")
        let liveEvening = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 83, windowMinutes: 300, resetsAt: midnightReset), weekly: nil, capturedAt: evening, sourceFile: "app-server")
        let plannedPing = engine.plan(now: evening, calendar: cal, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: liveEvening, blocked: [])
        check(plannedPing.mode == .keepAlive && plannedPing.date == date("2026-09-11T08:00:00Z"), "active window spanning 23 skips to next morning keepalive")
        check(liveEvening.nextResetDate(at: evening) == midnightReset, "prominent reset comes from live quota, not schedule")
        check(plannedPing.mode != .resume, "no blocked task has no resume action")
        let resetTarget = BlockedSession(id: "waiting", project: "Project", cwd: "/tmp", blockedAt: evening, fiveHourResetAt: midnightReset, weeklyResetAt: nil, fileURL: URL(fileURLWithPath: "/tmp/fake"))
        var exhaustedEvening = liveEvening; exhaustedEvening.fiveHour?.usedPercent = 100
        let plannedResume = engine.plan(now: evening, calendar: cal, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: exhaustedEvening, blocked: [resetTarget])
        check(plannedResume.mode == .resume && plannedResume.date == midnightReset, "blocked task displays actual blocking reset across midnight")
        exhaustedEvening.weekly = QuotaWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: date("2026-09-12T13:00:00Z"))
        let weeklyPlan = engine.plan(now: evening, calendar: cal, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: exhaustedEvening, blocked: [resetTarget])
        check(weeklyPlan.date == date("2026-09-12T13:00:00Z"), "weekly exhausted window gates next resume date")
        var oldEvening = liveEvening; oldEvening.capturedAt = evening.addingTimeInterval(-61)
        check(engine.plan(now: evening, calendar: cal, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: oldEvening, blocked: []).date == nil, "stale quota never displays a fabricated schedule date")
        check(oldEvening.nextResetDate(at: evening) == nil, "stale quota cannot supply prominent reset")
        let graceTime = date("2026-09-10T13:00:00Z")
        let graceReset = graceTime.addingTimeInterval(8)
        let graceUsage = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 50, windowMinutes: 300, resetsAt: graceReset), weekly: nil, capturedAt: graceTime, sourceFile: "app-server")
        check(engine.plan(now: graceTime, calendar: cal, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: graceUsage, blocked: []).date == graceReset, "reset seconds after node stays in the same grace window")
        var rolling = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: localNode.addingTimeInterval(18000)), weekly: nil, capturedAt: localNode, sourceFile: "app-server", zeroUseWindowActive: false)
        if case .ping = engine.decide(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: rolling, blocked: []) { check(true, "rolling zero-use reset does not suppress due ping") }
        else { check(false, "rolling zero-use reset does not suppress due ping") }
        rolling.zeroUseWindowActive = true
        if case .skip = engine.decide(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: rolling, blocked: []) { check(true, "fixed zero-use window prevents duplicate ping") }
        else { check(false, "fixed zero-use window prevents duplicate ping") }
        var usageConnections = 0
        let repeatedUsageTransport = CountingUsageTransport()
        let reusableUsage = AppServerUsageProvider(makeTransport: {
            usageConnections += 1
            return repeatedUsageTransport
        }, contextIdentity: { nil })
        let initialUsage = try reusableUsage.read()
        let refreshedUsage = try reusableUsage.read()
        check(usageConnections == 1, "same usage provider reuses one connection")
        check(repeatedUsageTransport.closes == 0, "successful usage read keeps connection open")
        check(initialUsage.fiveHour?.usedPercent == 1 && refreshedUsage.fiveHour?.usedPercent == 2,
            "reused usage connection fetches fresh quota on every read")
        let separateTransport = CountingUsageTransport()
        let separateProvider = AppServerUsageProvider(makeTransport: { separateTransport }, contextIdentity: { nil })
        _ = try separateProvider.read()
        check(separateTransport.calls == 1 && repeatedUsageTransport.calls == 2, "different providers keep independent connections")
        let releaseTransport = CountingUsageTransport()
        var releasedProvider: AppServerUsageProvider? = AppServerUsageProvider(makeTransport: { releaseTransport }, contextIdentity: { nil })
        _ = try releasedProvider?.read()
        releasedProvider = nil
        check(releaseTransport.closes == 1, "provider deinit closes its retained connection")

        var testUptime: TimeInterval = 100
        var failureConnections = 0
        let failedTransport = CountingUsageTransport()
        failedTransport.onRequest = { _ in throw CodexConnectionError.ended }
        let recoveredTransport = CountingUsageTransport()
        let failingProvider = AppServerUsageProvider(makeTransport: {
            failureConnections += 1
            return failureConnections == 1 ? failedTransport : recoveredTransport
        }, contextIdentity: { nil }, uptime: { testUptime })
        check((try? failingProvider.read()) == nil && failedTransport.closes == 1, "failed usage read closes connection without retry")
        for _ in 0..<10 { _ = try? failingProvider.read() }
        check(failureConnections == 1 && failedTransport.calls == 1, "refresh storm cannot reconnect during failure cooldown")
        testUptime += 20
        _ = try failingProvider.read()
        _ = try failingProvider.read()
        check(failureConnections == 2 && recoveredTransport.calls == 2, "next poll recovers once and reuses recovered connection")
        var creationAttempts = 0
        let failedFactory = AppServerUsageProvider(makeTransport: {
            creationAttempts += 1
            throw CodexConnectionError.unavailable
        }, contextIdentity: { nil }, uptime: { testUptime })
        for _ in 0..<10 { _ = try? failedFactory.read() }
        check(creationAttempts == 1, "failed connection creation is also cooled down")

        var manualConnections = 0
        let manualFailed = CountingUsageTransport()
        manualFailed.onRequest = { _ in throw CodexConnectionError.timeout }
        let manualRecovered = CountingUsageTransport()
        let manualProvider = AppServerUsageProvider(makeTransport: {
            manualConnections += 1
            return manualConnections == 1 ? manualFailed : manualRecovered
        }, contextIdentity: { nil }, uptime: { testUptime })
        _ = try? manualProvider.read()
        _ = try? manualProvider.read()
        check(manualConnections == 1, "background refresh retains backoff after timeout")
        _ = try manualProvider.readForUserRefresh()
        _ = try manualProvider.readForUserRefresh()
        check(manualConnections == 2 && manualRecovered.calls == 2, "manual refresh bypasses failed background cooldown and then reuses healthy connection")
        var manualFailures = 0
        let manualFailureProvider = AppServerUsageProvider(makeTransport: {
            manualFailures += 1
            throw CodexConnectionError.unavailable
        }, contextIdentity: { nil }, uptime: { testUptime })
        _ = try? manualFailureProvider.read()
        for _ in 0..<10 { _ = try? manualFailureProvider.readForUserRefresh() }
        check(manualFailures == 2, "repeated manual failure clicks coalesce for five seconds")
        testUptime += 5
        _ = try? manualFailureProvider.readForUserRefresh()
        check(manualFailures == 3, "manual retry becomes available before long automatic backoff")
        var failedSync = MenuSummary(headline: "正在同步", isSyncing: true)
        failedSync.applyUsageRefreshState(refreshing: false, error: "连接超时")
        check(failedSync.headline == "同步失败" && !failedSync.isSyncing, "failed idle read does not display an endless spinner")
        var retryingSync = MenuSummary(headline: "正在同步", isSyncing: true)
        retryingSync.applyUsageRefreshState(refreshing: true, error: "连接超时")
        check(retryingSync.isSyncing && retryingSync.note.contains("重新同步"), "active manual retry remains visibly distinct from failed idle read")

        var authIdentity: Data? = Data("account-a".utf8)
        var authConnections: [CountingUsageTransport] = []
        let authProvider = AppServerUsageProvider(makeTransport: {
            let connection = CountingUsageTransport()
            authConnections.append(connection)
            return connection
        }, contextIdentity: { authIdentity }, uptime: { testUptime })
        _ = try authProvider.read()
        authIdentity = Data("account-b".utf8)
        _ = try authProvider.read()
        _ = try authProvider.read()
        check(authConnections.count == 2 && authConnections[0].closes == 1 && authConnections[1].calls == 2,
            "authentication change invalidates old connection once and updates its baseline")
        authConnections[1].onRequest = { _ in authIdentity = nil }
        check((try? authProvider.read()) == nil && authConnections[1].closes == 1,
            "authentication change during RPC rejects snapshot and closes connection")
        testUptime += 20
        _ = try authProvider.read()
        check(authConnections.count == 3, "authentication removal establishes a new context on next poll")
        var unreadableAuth = false
        let unreadableTransport = CountingUsageTransport()
        let unreadableProvider = AppServerUsageProvider(makeTransport: { unreadableTransport }, contextIdentity: {
            if unreadableAuth { throw CocoaError(.fileReadNoPermission) }
            return nil
        })
        _ = try unreadableProvider.read()
        unreadableAuth = true
        check((try? unreadableProvider.read()) == nil && unreadableTransport.closes == 1,
            "unreadable authentication cannot reuse previous account connection")

        let parallelTransport = CountingUsageTransport()
        parallelTransport.delay = 0.01
        let parallelProvider = AppServerUsageProvider(makeTransport: { parallelTransport }, contextIdentity: { nil })
        let concurrentReads = UsageReadBatch(provider: parallelProvider)
        concurrentReads.run(count: 12)
        check(concurrentReads.failures == 0 && parallelTransport.calls == 12 && parallelTransport.maxActive == 1,
            "concurrent readers serialize fresh RPCs on retained transport")
        let zeroConcurrentTransport = CountingUsageTransport()
        zeroConcurrentTransport.zero = true
        zeroConcurrentTransport.accountForCall = { $0 <= 2 ? "first-account" : "second-account" }
        let zeroConcurrent = UsageReadBatch(provider: AppServerUsageProvider(makeTransport: { zeroConcurrentTransport }, contextIdentity: { nil }))
        zeroConcurrent.run(count: 2)
        check(zeroConcurrent.failures == 0 && zeroConcurrentTransport.calls == 4,
            "zero-percent double-read remains one serialized operation")
        let changedAccountTransport = CountingUsageTransport()
        changedAccountTransport.zero = true
        changedAccountTransport.accountForCall = { "account-\($0)" }
        let changedAccountProvider = AppServerUsageProvider(makeTransport: { changedAccountTransport }, contextIdentity: { nil })
        check((try? changedAccountProvider.read()) == nil && changedAccountTransport.calls == 2 && changedAccountTransport.closes == 1,
            "account change between zero-percent reads rejects snapshot and closes connection")
        let floatingRead = try AppServerUsageProvider(makeTransport: { ZeroWindowTransport(rolling: true) }, contextIdentity: { nil }).read()
        let fixedRead = try AppServerUsageProvider(makeTransport: { ZeroWindowTransport(rolling: false) }, contextIdentity: { nil }).read()
        check(floatingRead.activeFiveHourWindow == false, "provider recognizes service rolling now-plus-five-hour reset")
        check(fixedRead.activeFiveHourWindow == true, "provider recognizes stable reset even when usage rounds to zero")
        check(PingConfirmation.accepts(before: floatingRead, after: fixedRead, now: Date()), "ping confirms fixed window after a rolling inactive reset")
        check(!PingConfirmation.accepts(before: floatingRead, after: floatingRead, now: Date()), "rolling response cannot falsely confirm ping")
        var compatibilityClock: TimeInterval = 0
        let catalogTransport = CompatibilityTransport()
        catalogTransport.pages = [["data": [["model": "other"]], "nextCursor": "page-2"],
            ["data": [["id": "gpt-5.6-luna", "supportedReasoningEfforts": [["reasoningEffort": "low"]]]]]]
        var catalogConnections = 0
        let catalogProvider = AppServerUsageProvider(makeTransport: { catalogConnections += 1; return catalogTransport },
            contextIdentity: { nil }, uptime: { compatibilityClock })
        _ = try catalogProvider.read()
        let liveModel = try catalogProvider.pingModel()
        _ = try catalogProvider.read()
        check(liveModel == PingModel(model: "gpt-5.6-luna", reasoningEffort: "low") && catalogConnections == 1,
            "online paginated Luna discovery reuses the quota connection without model cache")
        check(catalogTransport.modelParams.count == 2 && catalogTransport.modelParams[1]["cursor"] as? String == "page-2" &&
            catalogTransport.modelParams[0]["includeHidden"] as? Bool == false, "model pagination sends official fields")
        catalogTransport.pages = [["data": [["model": "gpt-5.6-luna", "supportedReasoningEfforts": [["reasoningEffort": "medium"]], "defaultReasoningEffort": "medium"]]]]
        check(try catalogProvider.pingModel().reasoningEffort == "medium", "unsupported low effort uses declared supported default")
        catalogTransport.pages = [["data": [["model": "gpt-5.6-luna"]]]]
        check(try catalogProvider.pingModel().reasoningEffort == nil, "missing capability leaves reasoning to model default")
        catalogTransport.pages = [["data": [["model": "gpt-5.6-luna", "supportedReasoningEfforts": [["reasoningEffort": "invalid\"value"]], "defaultReasoningEffort": "invalid\"value"]]]]
        check(try catalogProvider.pingModel().reasoningEffort == nil, "unknown reasoning value cannot enter generated TOML")
        catalogTransport.pages = [["data": [["model": "expensive-alternative"]]]]
        check((try? catalogProvider.pingModel()) == nil, "missing Luna never substitutes another model")
        let modelCallsAtFailure = catalogTransport.modelParams.count
        for _ in 0..<10 { _ = try? catalogProvider.pingModel() }
        _ = try catalogProvider.read()
        check(catalogTransport.modelParams.count == modelCallsAtFailure && catalogConnections == 1 && catalogTransport.closes == 0,
            "missing model cooldown keeps healthy quota reads and prevents process/RPC storms")
        compatibilityClock += 300
        catalogTransport.pages = [["data": [["model": "gpt-5.6-luna"]]]]
        check((try? catalogProvider.pingModel()) != nil, "model discovery recovers after bounded cooldown")
        let loopTransport = CompatibilityTransport()
        loopTransport.pages = [["data": [], "nextCursor": "same"]]
        let loopProvider = AppServerUsageProvider(makeTransport: { loopTransport }, contextIdentity: { nil })
        check((try? loopProvider.pingModel()) == nil && loopTransport.modelParams.count == 2, "repeating model cursor stops bounded pagination")
        let apiTransport = CompatibilityTransport()
        apiTransport.account = ["type": "apiKey"]
        let apiProvider = AppServerUsageProvider(makeTransport: { apiTransport }, contextIdentity: { nil })
        check((try? apiProvider.read()) == nil && apiTransport.quotaCalls == 0 && apiTransport.closes == 0,
            "API key account is explicitly rejected before quota read without reconnect storm")
        apiTransport.account = NSNull()
        check((try? apiProvider.read()) == nil && apiTransport.quotaCalls == 0, "logged-out account cannot read subscription quota")
        apiTransport.account = ["type": "chatgpt"]
        check((try? apiProvider.read()) != nil, "login can recover on existing connection")
        let noIDTransport = CompatibilityTransport()
        noIDTransport.reportedAccount = nil
        let noIDProvider = AppServerUsageProvider(makeTransport: { noIDTransport }, contextIdentity: { nil }, accountIdentity: { "local-account" })
        check(try noIDProvider.read().accountID == "local-account", "missing protocol account ID uses same auth context stable ID")
        let mismatchProvider = AppServerUsageProvider(makeTransport: { CompatibilityTransport() }, contextIdentity: { nil }, accountIdentity: { "different" })
        check((try? mismatchProvider.read()) == nil, "conflicting protocol and local account IDs reject execution context")
        let unknownProvider = AppServerUsageProvider(makeTransport: { noIDTransport }, contextIdentity: { nil })
        check((try? unknownProvider.read()) == nil, "missing stable account identity cannot permit automatic operations")
        let displayQuota = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: localNode.addingTimeInterval(300)), weekly: nil, capturedAt: localNode, sourceFile: "app-server")
        let displayPlan = engine.plan(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: displayQuota, blocked: [])
        let display = MenuSummary.build(plan: displayPlan, usage: displayQuota, schedule: schedule, tasks: [], now: localNode)
        check(display.headline == "13:05" && display.action == "额度重置" && display.badge == "计划外", "off-plan menu highlights real reset without promising scheduled ping")
        check(display.note.isEmpty && display.timeline.map(\.time) == ["08:05", "13:05", "18:00"], "off-plan timeline replaces conditional paragraph with real window and plan")
        check(display.timeline.map(\.solidBefore) == [false, true, false], "actual window uses solid line and waiting uses dotted line")
        check(display.statusText == "13:05", "menu bar displays the actual next reset instead of plan status or conditional keepalive")
        var stoppedUsage = displayQuota; stoppedUsage.fiveHour?.usedPercent = 100
        let stoppedTask = BlockedSession(id: "current", project: "Codex Keeper", cwd: "/tmp", blockedAt: localNode, fiveHourResetAt: localNode.addingTimeInterval(300), weeklyResetAt: nil, fileURL: URL(fileURLWithPath: "/tmp/current"))
        let stoppedPlan = engine.plan(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: stoppedUsage, blocked: [stoppedTask])
        let stoppedMenu = MenuSummary.build(plan: stoppedPlan, usage: stoppedUsage, schedule: schedule, tasks: [stoppedTask], now: localNode)
        check(stoppedPlan.mode == .resume && stoppedPlan.date == displayQuota.fiveHour?.resetsAt, "quota-stop changes next action from 18:00 ping to 13:05 resume")
        check(stoppedMenu.timeline.map(\.time) == ["08:05", "13:05"] && stoppedMenu.timeline.last?.kind == .resume, "resume merges reset and continue into one point without 18:00 ping")
        check(stoppedMenu.badge == "计划外" && stoppedMenu.taskCount == 1, "pending task does not replace plan status badge")
        check(display.timeline.map(\.symbol) == ["circle.fill", "arrow.clockwise.circle.fill", "waveform.path.ecg"], "off-plan timeline uses requested native symbols")
        check(stoppedMenu.timeline.last?.symbol == "paperplane", "resume action uses paperplane without enclosing circle")
        let confirmation = ExecutionConfirmation(kind: .resume, actionAt: localNode.addingTimeInterval(-17700), confirmedAt: localNode, windowStart: nil)
        let completedMenu = MenuSummary.build(plan: displayPlan, usage: displayQuota, schedule: schedule, tasks: [], confirmations: [confirmation], now: localNode)
        check(completedMenu.timeline.first?.symbol == "checkmark.circle.fill", "confirmed off-plan resume marks actual start complete")
        let unrelatedConfirmation = ExecutionConfirmation(kind: .keepAlive, actionAt: localNode.addingTimeInterval(-18000), confirmedAt: localNode, windowStart: nil)
        check(MenuSummary.build(plan: displayPlan, usage: displayQuota, schedule: schedule, tasks: [], confirmations: [unrelatedConfirmation], now: localNode).timeline.first?.kind == .start, "unrelated successful operation cannot mark current window as Keeper controlled")
        let recoveredAt = localNode.addingTimeInterval(310)
        let recoveredUsage = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: recoveredAt.addingTimeInterval(18000)), weekly: nil, capturedAt: recoveredAt, sourceFile: "app-server", zeroUseWindowActive: false)
        let recoveredPlan = engine.plan(now: recoveredAt, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: recoveredUsage, blocked: [stoppedTask], observedRecovery: true)
        if case .resume = recoveredPlan.decision { check(true, "confirmed natural recovery executes pending task at 13:05") }
        else { check(false, "confirmed natural recovery executes pending task at 13:05") }
        let idlePlan = engine.plan(now: recoveredAt, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: recoveredUsage, blocked: [])
        let idleMenu = MenuSummary.build(plan: idlePlan, usage: recoveredUsage, schedule: schedule, tasks: [], now: recoveredAt)
        check(idleMenu.timeline.map(\.time) == ["18:00"], "idle rolling reset creates no invented start or reset on timeline")
        var uncertainUsage = recoveredUsage; uncertainUsage.zeroUseWindowActive = nil
        let uncertainPlan = engine.plan(now: recoveredAt, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: uncertainUsage, blocked: [])
        let uncertainMenu = MenuSummary.build(plan: uncertainPlan, usage: uncertainUsage, schedule: schedule, tasks: [], now: recoveredAt)
        check(uncertainMenu.timeline.isEmpty && uncertainMenu.quotas.first?.detail == "—", "unknown window cannot display rolling timestamp or duplicate loading label")
        check(uncertainMenu.isSyncing && uncertainMenu.headline == "正在同步", "quota confirmation shares one native loading state")
        let alignedQuota = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: localNode.addingTimeInterval(8)), weekly: nil, capturedAt: localNode, sourceFile: "app-server")
        let alignedPlan = engine.plan(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: alignedQuota, blocked: [])
        let alignedMenu = MenuSummary.build(plan: alignedPlan, usage: alignedQuota, schedule: schedule, tasks: [], now: localNode)
        check(alignedMenu.badge == "计划内" && alignedMenu.action == "保持活动" && alignedMenu.note.isEmpty, "seconds of reset drift keep normal concise planned UI")
        check(alignedMenu.timeline.map(\.time) == ["08:00", "13:00", "18:00", "23:00"], "aligned timeline displays daily plan")
        var delayedQuota = alignedQuota
        delayedQuota.fiveHour?.resetsAt = localNode.addingTimeInterval(103)
        let delayedPlan = engine.plan(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: delayedQuota, blocked: [])
        let delayedMenu = MenuSummary.build(plan: delayedPlan, usage: delayedQuota, schedule: schedule, tasks: [], now: localNode)
        check(delayedMenu.badge == "计划内" && delayedMenu.timeline.first?.time == "08:01", "103-second drift remains aligned while displaying the actual window time")
        check(delayedPlan.date == delayedQuota.fiveHour?.resetsAt, "next keepalive waits for the actual reset within grace rather than skipping five hours")
        let resumeMenu = MenuSummary.build(plan: plannedResume, usage: exhaustedEvening, schedule: schedule, tasks: [resetTarget], now: evening)
        check(resumeMenu.action == "自动继续" && resumeMenu.tasks == [resetTarget.displayName], "resume still shows pending task and automatic action")
        let staleMenu = MenuSummary.build(plan: displayPlan, usage: oldEvening, schedule: schedule, tasks: [], now: evening)
        check(staleMenu.headline == "正在同步" && !staleMenu.isTime && staleMenu.badge.isEmpty, "stale quota cannot claim plan status or reset time")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let confirmationURL = temp.appendingPathComponent("confirmations.jsonl")
        let confirmationRows = """
        {"at":"2026-09-11T08:05:00Z","event":"started","kind":"resume","thread_id":"a"}
        {"at":"2026-09-11T08:06:00Z","event":"started","kind":"resume","thread_id":"b"}
        {"at":"2026-09-11T08:07:00Z","event":"failed","kind":"resume","thread_id":"b"}
        {"at":"2026-09-11T08:08:00Z","event":"confirmed","kind":"resume","thread_id":"a","turn_id":"turn-a"}
        {"at":"2026-09-11T13:00:00Z","event":"started","kind":"ping","node":"2026-09-11T13:00:00Z"}
        {"at":"2026-09-11T13:01:00Z","event":"confirmed","kind":"ping","node":"2026-09-11T13:00:00Z","after_reset":"2026-09-11T18:00:05Z"}
        {"partial":
        """
        try confirmationRows.write(to: confirmationURL, atomically: true, encoding: .utf8)
        let confirmations = ExecutionEventLog(url: confirmationURL).confirmations()
        check(confirmations.count == 2, "started and failed events never count as confirmed completion")
        check(confirmations.first?.actionAt == date("2026-09-11T08:05:00Z"), "concurrent resume completion matches its own task start")
        check(confirmations.last?.windowStart == date("2026-09-11T13:00:05Z"), "confirmed keepalive uses actual resulting quota window")
        let oldChoicesData = Data("{\"keepAliveEpisodes\":[],\"deselectedEpisodes\":[],\"messages\":{}}".utf8)
        check(try JSONDecoder().decode(ResumeChoices.self, from: oldChoicesData).mode(for: stoppedTask) == .fixed, "old pending settings default to fixed message without migration loss")
        let draftURL = temp.appendingPathComponent("drafts.json")
        func writeDrafts(_ atoms: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": atoms]).write(to: draftURL)
        }
        let reader = ComposerDraftReader(url: draftURL)
        let draftKey = "local:" + stoppedTask.id
        var draftRequest = ResumeRequest(target: stoppedTask, prompt: "固定内容", accountID: nil, workspace: nil, messageMode: .composerDraft)
        try writeDrafts(["composer-prompt-drafts-v2": [draftKey: ["prompt": "第一段\n第二段"]]])
        check(try draftRequest.resolvedPrompt(reader: reader) == "第一段\n第二段", "draft mode reads only the selected task text")
        try writeDrafts(["composer-prompt-drafts-v2": [draftKey: ["prompt": "刚刚修改"]]])
        check(try draftRequest.resolvedPrompt(reader: reader) == "刚刚修改", "draft is read at dispatch instead of cached when selection changes")
        try writeDrafts(["composer-prompt-drafts-v2": [:], "composer-prompt-drafts-v1": [draftKey: "已发送的旧稿"]])
        check(try draftRequest.resolvedPrompt(reader: reader) == "继续", "empty v2 never resurrects old v1 and falls back to continue")
        try writeDrafts(["composer-prompt-drafts-v2": ["local:other": "另一个会话", draftKey: " \n "]])
        check(try draftRequest.resolvedPrompt(reader: reader) == "继续", "blank draft falls back without borrowing another task draft")
        let doc: [String: Any] = ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "草稿正文"]]]]]
        try writeDrafts(["composer-prompt-drafts-v2": [draftKey: ["prompt": ["document": doc]]]])
        check(try reader.read(threadID: stoppedTask.id) == "草稿正文", "native paragraph document can be read as text")
        try writeDrafts(["composer-prompt-drafts-v2": [draftKey: ["prompt": ["document": ["type": "unknown-reference"]]]]])
        do { _ = try reader.read(threadID: stoppedTask.id); check(false, "unknown references cannot be silently lost") }
        catch { check(true, "unknown references cannot be silently lost") }
        draftRequest.messageMode = .fixed
        check(try draftRequest.resolvedPrompt(reader: reader) == "固定内容", "fixed mode never depends on draft readability")
        let file = temp.appendingPathComponent("rollout-11111111-1111-1111-1111-111111111111.jsonl")
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"22222222-2222-2222-2222-222222222222\",\"cwd\":\"/tmp/project\"}}\n"
        let events = meta + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
        try events.write(to: file, atomically: true, encoding: .utf8)
        let session = SessionWatcher.parse(url: file, mtime: now)!
        check(session.cwd == "/tmp/project" && session.id.hasPrefix("2222"), "session_meta identity and cwd")
        check(session.taskRunning, "file order works without ordinal")
        var done = session; done.taskRunning = false; done.fiveHour = QuotaWindow(usedPercent: 100, windowMinutes: 300, resetsAt: future)
        check(BlockedSessionDetector.detect(in: [done], now: localNode).isEmpty, "100 percent plus completion is not quota blocked")
        let liveWindow: [String: Any] = ["usedPercent": 12, "windowDurationMins": 300, "resetsAt": future.timeIntervalSince1970]
        let weeklyWindow: [String: Any] = ["usedPercent": 34, "windowDurationMins": 10080, "resetsAt": future.timeIntervalSince1970]
        let decoded = try UsageDecoder.account(["accountId": "account-a", "rateLimits": ["primary": weeklyWindow], "rateLimitsByLimitId": ["codex": ["secondary": liveWindow, "primary": weeklyWindow]]], at: now)
        check(decoded.fiveHour?.usedPercent == 12 && decoded.weekly?.usedPercent == 34 && decoded.accountID == "account-a", "codex bucket and duration identify windows")
        check(decoded.isFresh(at: now.addingTimeInterval(59)), "fresh live source")
        check(!decoded.isFresh(at: now.addingTimeInterval(61)), "stale live source")
        var rollout = decoded; rollout.sourceFile = "rollout.jsonl"
        check(!rollout.isFresh(at: now), "recent rollout remains fallback evidence")
        let pending = BlockedSession(id: session.id, project: session.project, cwd: temp.path, blockedAt: localNode.addingTimeInterval(-60), fiveHourResetAt: localNode.addingTimeInterval(-5), weeklyResetAt: nil, fileURL: file)
        let onlyWeek = UsageSnapshot(fiveHour: nil, weekly: QuotaWindow(usedPercent: 5, windowMinutes: 10080, resetsAt: future), capturedAt: localNode, sourceFile: "app-server")
        let weeklyResume = engine.decide(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: onlyWeek, blocked: [pending])
        if case .resume = weeklyResume { check(true, "weekly-only supports resume") } else { check(false, "weekly-only supports resume") }
        var stale = onlyWeek; stale.capturedAt = localNode.addingTimeInterval(-61)
        if case .resume = engine.decide(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "immediately", usage: stale, blocked: [pending]) { check(false, "stale snapshot prevents resume") } else { check(true, "stale snapshot prevents resume") }
        let prefix = "session_loop{thread_id=UUID}:submission_dispatch{otel.name=\"op.dispatch.turn_input\"}:turn{model=\"example\"}:session_task.run:run_turn: Turn error: "
        check(QuotaErrorLogProvider.isQuotaTurnError(prefix + "You've hit your usage limit."), "real quoted log span is accepted")
        check(!QuotaErrorLogProvider.isQuotaTurnError("prompt: Turn error: You've hit your usage limit."), "prompt quote does not prove stop")
        check(!QuotaErrorLogProvider.isQuotaTurnError(prefix + "Model at capacity"), "capacity is not quota")
        check(!QuotaErrorLogProvider.isQuotaTurnError(prefix + "Network error"), "network is not quota")
        let database = temp.appendingPathComponent("logs_2.sqlite")
        var db: OpaquePointer?
        sqlite3_open(database.path, &db)
        sqlite3_exec(db, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil)
        func log(_ id: Int, _ target: String, _ body: String) {
            let escaped = body.replacingOccurrences(of: "'", with: "''")
            sqlite3_exec(db, "INSERT INTO logs VALUES(\(id), \(Int(now.timeIntervalSince1970)), 123000000, '\(target)', '\(session.id)', '\(escaped)')", nil, nil, nil)
        }
        log(1, "codex_core::prewarm", prefix + "You've hit your usage limit.")
        log(2, "codex_core::session::turn", "prompt: Turn error: You've hit your usage limit.")
        let logs = QuotaErrorLogProvider(databaseURL: database)
        check(try logs.read(now: now).isEmpty, "sqlite filters prewarm and prompt records")
        log(3, "codex_core::session::turn", prefix + "You've hit your usage limit.")
        let stops = try logs.read(now: now)
        check(abs((stops[session.id]?.at.timeIntervalSince1970 ?? 0) - now.timeIntervalSince1970 - 0.123) < 0.000001, "incremental sqlite real quota stop with nanoseconds")
        sqlite3_close(db)
        let discoveredLogs = QuotaErrorLogProvider(codexHome: temp)
        check(try discoveredLogs.read(now: now)[session.id] != nil, "logs discovery validates existing schema")
        let rotatedDB = temp.appendingPathComponent("logs_9.sqlite")
        try FileManager.default.moveItem(at: database, to: rotatedDB)
        sqlite3_open(rotatedDB.path, &db)
        sqlite3_exec(db, "DELETE FROM logs", nil, nil, nil)
        log(1, "codex_core::session::turn", prefix + "You've hit your usage limit.")
        sqlite3_close(db)
        check(try discoveredLogs.read(now: now)[session.id] != nil, "database rotation resets cursor for low IDs in new logs filename")
        sqlite3_open(rotatedDB.path, &db)
        sqlite3_exec(db, "DELETE FROM logs", nil, nil, nil)
        sqlite3_close(db)
        check(try discoveredLogs.read(now: now).isEmpty, "truncated database clears stale cached stop evidence")
        try FileManager.default.removeItem(at: rotatedDB)
        sqlite3_open(rotatedDB.path, &db)
        sqlite3_exec(db, "CREATE TABLE logs(id INTEGER)", nil, nil, nil)
        sqlite3_close(db)
        do { _ = try discoveredLogs.read(now: now); check(false, "incompatible logs schema gives actionable error") }
        catch { check(error.localizedDescription.contains("日志格式不兼容"), "incompatible logs schema gives actionable error") }
        try FileManager.default.removeItem(at: rotatedDB)
        func event(_ type: String, _ time: Date, _ extra: [String: Any] = [:]) -> String {
            var payload = extra; payload["type"] = type
            let entry: [String: Any] = ["type": "event_msg", "timestamp": iso.string(from: time), "payload": payload]
            return String(data: try! JSONSerialization.data(withJSONObject: entry), encoding: .utf8)! + "\n"
        }
        let quotaTrace = meta + event("task_started", now.addingTimeInterval(-2)) + event("error", now, ["message": "usage_limit_reached"]) + event("task_complete", now.addingTimeInterval(1))
        try quotaTrace.write(to: file, atomically: true, encoding: .utf8)
        let blockedTrace = SessionWatcher.parse(url: file, mtime: now)!
        check(BlockedSessionDetector.detect(in: [blockedTrace], now: now.addingTimeInterval(10000)).count == 1, "explicit stop survives cleanup completion and elapsed reset")
        try (quotaTrace + event("task_started", now.addingTimeInterval(2))).write(to: file, atomically: true, encoding: .utf8)
        check(BlockedSessionDetector.detect(in: [SessionWatcher.parse(url: file, mtime: now)!]).isEmpty, "new turn cancels old stop")
        try (quotaTrace + event("user_message", now.addingTimeInterval(2))).write(to: file, atomically: true, encoding: .utf8)
        check(BlockedSessionDetector.detect(in: [SessionWatcher.parse(url: file, mtime: now)!]).isEmpty, "new user message cancels stop")
        var subagent = blockedTrace; subagent.isSubagent = true
        check(BlockedSessionDetector.detect(in: [subagent]).isEmpty, "subagents never auto resume")
        let before = WorkspaceGuard.fingerprint(cwd: temp.path)
        try "changed".write(to: temp.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        check(before != WorkspaceGuard.fingerprint(cwd: temp.path), "workspace guard includes hidden files")
        check(WorkspaceGuard.resumePrompt("继续", before: "same", after: "same", reminderEnabled: true) == "继续", "unchanged project sends only selected content")
        check(WorkspaceGuard.resumePrompt("继续", before: "old", after: "new", reminderEnabled: true) == WorkspaceGuard.reminder + "\n继续", "changed project receives a clear Keeper reminder")
        check(WorkspaceGuard.resumePrompt("继续", before: nil, after: "new", reminderEnabled: true) == WorkspaceGuard.reminder + "\n继续", "missing baseline prompts a check without claiming a detected change")
        check(WorkspaceGuard.resumePrompt("继续", before: "old", after: nil, reminderEnabled: true) == WorkspaceGuard.reminder + "\n继续", "unreadable current state receives the same neutral reminder")
        check(WorkspaceGuard.resumePrompt("第一行\n第二行", before: nil, after: nil, reminderEnabled: false) == "第一行\n第二行", "disabled reminder preserves multiline content exactly")
        // Full scan: copied parent history in a child must never resurrect a continued parent.
        let scanHome = temp.appendingPathComponent("scan-home")
        let scanSessions = scanHome.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: scanSessions, withIntermediateDirectories: true)
        let scanDB = scanHome.appendingPathComponent("logs_2.sqlite")
        var scanConnection: OpaquePointer?
        sqlite3_open(scanDB.path, &scanConnection)
        sqlite3_exec(scanConnection, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil)
        let scanTime = Date().addingTimeInterval(-20)
        let parentID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let childID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let forkID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        func metadata(_ id: String, at time: Date, parent: String? = nil, subagent: Bool = false) throws -> String {
            var payload: [String: Any] = ["id": id, "cwd": temp.path, "timestamp": iso.string(from: time)]
            payload["source"] = subagent ? ["subagent": ["thread_spawn": ["parent_thread_id": parent!]]] : "vscode"
            if let parent { payload["forked_from_id"] = parent }
            return String(data: try JSONSerialization.data(withJSONObject: ["type": "session_meta", "timestamp": iso.string(from: time), "payload": payload]), encoding: .utf8)! + "\n"
        }
        let parentPath = scanSessions.appendingPathComponent("rollout-\(parentID).jsonl")
        let childPath = scanSessions.appendingPathComponent("rollout-\(childID).jsonl")
        let forkPath = scanSessions.appendingPathComponent("rollout-\(forkID).jsonl")
        let parentMeta = try metadata(parentID, at: scanTime.addingTimeInterval(-60))
        try (parentMeta + event("error", scanTime, ["message": "usage_limit_reached"]) + event("user_message", scanTime.addingTimeInterval(5)) + event("task_started", scanTime.addingTimeInterval(6))).write(to: parentPath, atomically: true, encoding: .utf8)
        let forkTime = scanTime.addingTimeInterval(10)
        let inherited = try metadata(parentID, at: forkTime) + event("error", forkTime, ["message": "usage_limit_reached"])
        try (metadata(childID, at: forkTime, parent: parentID, subagent: true) + inherited).write(to: childPath, atomically: true, encoding: .utf8)
        try (metadata(forkID, at: forkTime, parent: parentID) + inherited).write(to: forkPath, atomically: true, encoding: .utf8)
        let logBody = (prefix + "You've hit your usage limit.").replacingOccurrences(of: "'", with: "''")
        sqlite3_exec(scanConnection, "INSERT INTO logs VALUES(1, \(Int(scanTime.timeIntervalSince1970)), 0, 'codex_core::session::turn', '\(parentID)', '\(logBody)')", nil, nil, nil)
        sqlite3_close(scanConnection)
        let scannedChild = SessionWatcher.parse(url: childPath, mtime: Date())!
        check(scannedChild.id == childID && scannedChild.isSubagent, "first metadata owns child identity despite inherited parent metadata")
        check(try SessionWatcher.freshBlockedSessions(codexHome: scanHome).isEmpty, "full worker cannot resurrect manually continued parent from fork history and database stop")
        let forkOwnError = try metadata(forkID, at: forkTime, parent: parentID) + inherited + event("task_started", forkTime.addingTimeInterval(1)) + event("error", forkTime.addingTimeInterval(2), ["message": "usage_limit_reached"])
        try forkOwnError.write(to: forkPath, atomically: true, encoding: .utf8)
        let realForkStops = try SessionWatcher.freshBlockedSessions(codexHome: scanHome)
        check(realForkStops.map(\.id) == [forkID] && realForkStops.first?.fileURL.resolvingSymlinksInPath() == forkPath.resolvingSymlinksInPath(), "fork own new quota stop remains detectable by full worker")
        // A rollout can stop at 99%, then emit an unrelated premium bucket with no windows.
        do {
            let stop = Date(timeIntervalSince1970: 1790062247.487003)
            let reset = date("2026-09-22T12:05:46Z")
            let liveAt = date("2026-09-22T07:30:49Z")
            let recoveredAt = date("2026-09-22T12:30:33Z")
            let traceFile = temp.appendingPathComponent("missing-stop-evidence.jsonl")
            let codexLimits: [String: Any] = ["limit_id": "codex",
                "primary": ["used_percent": 99, "window_minutes": 300, "resets_at": 1790078746],
                "secondary": ["used_percent": 15, "window_minutes": 10080, "resets_at": 1790665546]]
            let premiumLimits: [String: Any] = ["limit_id": "premium", "primary": NSNull(), "secondary": NSNull()]
            let stoppedTrace = try metadata(parentID, at: stop.addingTimeInterval(-1800)) +
                event("task_started", stop.addingTimeInterval(-1799)) +
                event("token_count", stop.addingTimeInterval(-4), ["rate_limits": codexLimits]) +
                event("token_count", stop, ["rate_limits": premiumLimits]) +
                event("error", stop, ["message": "usage_limit_reached"]) + event("task_complete", stop.addingTimeInterval(1))
            try stoppedTrace.write(to: traceFile, atomically: true, encoding: .utf8)
            let parsed = SessionWatcher.parse(url: traceFile, mtime: stop)!
            let target = BlockedSessionDetector.detect(in: [parsed]).first!
            check(parsed.fiveHour?.usedPercent == 99 && parsed.weekly?.usedPercent == 15,
                "premium null windows cannot erase the last codex quota snapshot")
            check(target.fiveHourResetAt == nil && target.weeklyResetAt == nil,
                "99 percent plus generic quota error never guesses which window exhausted")
            let exhausted = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 100, windowMinutes: 300, resetsAt: reset),
                weekly: QuotaWindow(usedPercent: 16, windowMinutes: 10080, resetsAt: date("2026-09-29T07:05:46Z")),
                capturedAt: liveAt, accountID: "stop-account", sourceFile: "app-server")
            func attach(_ usage: UsageSnapshot?, previous: BlockedSession? = nil, account: String? = "stop-account", at: Date? = nil) -> BlockedSession {
                target.withRecoveryEvidence(from: previous, usage: usage, boundAccount: account, now: at ?? liveAt)
            }
            let supported = attach(exhausted)
            check(supported.fiveHourResetAt == reset && supported.weeklyResetAt == nil,
                "fresh exhausted poll 1.5 seconds after stop supplies only the actual blocking window")
            let saved = try JSONEncoder().encode([supported.id: supported])
            let reloaded = try JSONDecoder().decode([String: BlockedSession].self, from: saved)[supported.id]!
            var fallback = exhausted; fallback.sourceFile = "rollout.jsonl"; fallback.capturedAt = stop
            let rescanned = BlockedSessionDetector.detect(in: [SessionWatcher.parse(url: traceFile, mtime: recoveredAt)!]).first!
                .withRecoveryEvidence(from: reloaded, usage: fallback, boundAccount: "stop-account", now: recoveredAt)
            check(rescanned.fiveHourResetAt == reset && rescanned.episodeKey == target.episodeKey,
                "serialized same-episode evidence survives restart, rescan and stale rollout fallback")
            var recovered = exhausted; recovered.capturedAt = recoveredAt; recovered.fiveHour?.usedPercent = 0
            recovered.fiveHour?.resetsAt = recoveredAt.addingTimeInterval(18000)
            let retained = attach(recovered, previous: rescanned, at: recoveredAt)
            check(retained.fiveHourResetAt == reset && attach(nil, previous: retained).fiveHourResetAt == reset,
                "recovered or invalidated quota cannot erase the recorded stop deadline")
            let allowed = UsageRecovery.canResumeAfterScheduledReset(retained, usage: recovered, boundAccount: "stop-account", now: recoveredAt)
            var shanghai = cal; shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let plan = engine.plan(now: recoveredAt, calendar: shanghai, enabled: true, autoResume: true,
                earlyRecoveryPolicy: "ask", usage: recovered, blocked: [retained], observedRecovery: allowed)
            if case .resume = plan.decision { check(true, "99-to-stop episode resumes at late 20:30 confirmation rather than 23:00") }
            else { check(false, "99-to-stop episode resumes at late 20:30 confirmation rather than 23:00") }
            check(attach(exhausted, account: nil).fiveHourResetAt == nil && attach(exhausted, account: "").fiveHourResetAt == nil && attach(exhausted, account: "other").fiveHourResetAt == nil,
                "exhaustion evidence needs the existing nonempty matching account binding")
            var invalid = exhausted; invalid.accountID = nil
            check(attach(invalid).fiveHourResetAt == nil, "missing current account cannot attach exhaustion evidence")
            invalid = exhausted; invalid.capturedAt = liveAt.addingTimeInterval(-61)
            check(attach(invalid).fiveHourResetAt == nil && attach(fallback).fiveHourResetAt == nil,
                "stale and rollout-only exhaustion cannot create a stop deadline")
            invalid = exhausted; invalid.fiveHour?.resetsAt = target.blockedAt
            check(attach(invalid).fiveHourResetAt == nil, "deadline must occur after the actual stop")
            invalid = exhausted; invalid.fiveHour?.usedPercent = 99
            check(attach(invalid).fiveHourResetAt == nil, "rounded 99 percent live quota is not exhaustion evidence")
            invalid.weekly?.usedPercent = 100
            check(attach(invalid).fiveHourResetAt == nil && attach(invalid).weeklyResetAt == invalid.weekly?.resetsAt,
                "weekly exhaustion cannot be misclassified as a five-hour stop")
            let newEpisode = BlockedSession(id: target.id, project: target.project, cwd: target.cwd,
                blockedAt: recoveredAt, fiveHourResetAt: nil, weeklyResetAt: nil, fileURL: target.fileURL)
            check(newEpisode.withRecoveryEvidence(from: retained, usage: recovered, boundAccount: "stop-account", now: recoveredAt).fiveHourResetAt == nil,
                "a new stop in the same thread cannot inherit the prior episode deadline")
            var onlyPremium = premiumLimits
            onlyPremium["primary"] = ["used_percent": 100, "window_minutes": 300, "resets_at": 1790078746]
            onlyPremium["rate_limit_reached_type"] = "primary"
            try (metadata(parentID, at: stop.addingTimeInterval(-60)) + event("token_count", stop, ["rate_limits": onlyPremium])).write(to: traceFile, atomically: true, encoding: .utf8)
            let premium = SessionWatcher.parse(url: traceFile, mtime: stop)!
            check(premium.fiveHour == nil && BlockedSessionDetector.detect(in: [premium]).isEmpty,
                "non-codex exhausted window and reached flag never fabricate a codex quota stop")
            var legacy = codexLimits; legacy.removeValue(forKey: "limit_id")
            try (metadata(parentID, at: stop.addingTimeInterval(-60)) + event("token_count", stop, ["rate_limits": legacy])).write(to: traceFile, atomically: true, encoding: .utf8)
            check(SessionWatcher.parse(url: traceFile, mtime: stop)?.fiveHour?.usedPercent == 99,
                "legacy rollout limits without limit id remain supported")
            try (stoppedTrace + event("task_started", recoveredAt)).write(to: traceFile, atomically: true, encoding: .utf8)
            check(BlockedSessionDetector.detect(in: [SessionWatcher.parse(url: traceFile, mtime: recoveredAt)!]).isEmpty,
                "manually resumed task is no longer eligible for saved recovery evidence")
        }
        let fake = FakeTransport(threadID: pending.id, cwd: pending.cwd)
        let receipt = try AppServerResumeTransport(makeTransport: { fake }).resume(pending, prompt: "继续")
        check(receipt.turnID == "turn-1" && fake.closed, "resume observes matching completion")
        check(fake.calls.map { $0.0 } == ["thread/resume", "turn/start"], "resume never creates new thread")
        check(fake.calls.allSatisfy { $0.1["approvalPolicy"] == nil && $0.1["sandboxPolicy"] == nil && $0.1["sandbox"] == nil }, "resume does not override user permissions")
        let ownerConnection = FakeDesktopConnection()
        ownerConnection.onStart = {
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(event("task_complete", Date(), ["turn_id": "desktop-turn"]).utf8))
        }
        let unusedBackend = FakeTransport(threadID: pending.id, cwd: pending.cwd)
        let ownedReceipt = try OwnedSessionResumeTransport(makeDesktop: { ownerConnection }, fallback: AppServerResumeTransport(makeTransport: { unusedBackend })).resume(pending, prompt: "继续")
        check(ownedReceipt.turnID == "desktop-turn" && unusedBackend.calls.isEmpty && ownerConnection.starts == 1, "desktop-owned task resumes through existing writer without second backend")
        let noOwner = FakeDesktopConnection(); noOwner.ownerID = nil
        let unownedBackend = FakeTransport(threadID: pending.id, cwd: pending.cwd)
        _ = try OwnedSessionResumeTransport(makeDesktop: { noOwner }, fallback: AppServerResumeTransport(makeTransport: { unownedBackend })).resume(pending, prompt: "继续")
        check(unownedBackend.calls.count == 2 && noOwner.starts == 0, "unowned task still supports headless app-server resume")
        let timeoutOwner = FakeDesktopConnection(); timeoutOwner.onStart = { throw CodexConnectionError.timeout }
        let mustNotRetry = FakeTransport(threadID: pending.id, cwd: pending.cwd)
        do {
            _ = try OwnedSessionResumeTransport(makeDesktop: { timeoutOwner }, fallback: AppServerResumeTransport(makeTransport: { mustNotRetry })).resume(pending, prompt: "继续")
            check(false, "ambiguous desktop submission must fail")
        } catch { check(mustNotRetry.calls.isEmpty && timeoutOwner.starts == 1, "desktop timeout never retries through another writer") }
        var turnMonitor = ResumeTurnMonitor(turnID: "ours")
        check(try !turnMonitor.consume(Data(event("task_complete", now, ["turn_id": "other"]).utf8)), "another completed turn cannot confirm our resume")
        let finishedLine = Data(event("task_complete", now, ["turn_id": "ours"]).utf8)
        check(try !turnMonitor.consume(finishedLine.prefix(10)), "partial rollout line waits for remaining bytes")
        check(try turnMonitor.consume(finishedLine.dropFirst(10)), "matching complete rollout line confirms resume")
        var failedTurn = ResumeTurnMonitor(turnID: "ours")
        do {
            _ = try failedTurn.consume(Data(event("task_complete", now, ["turn_id": "ours", "error": ["message": "usage limit"]]).utf8))
            check(false, "quota error completion must fail")
        } catch { check(true, "quota error task_complete is not successful resume") }
        let approval = FakeTransport(threadID: pending.id, cwd: pending.cwd); approval.needsApproval = true
        do { _ = try AppServerResumeTransport(makeTransport: { approval }).resume(pending, prompt: "继续"); check(false, "approval pauses") }
        catch CodexConnectionError.approvalRequired { check(approval.calls.last?.0 == "turn/interrupt", "approval pauses without approving") }
        let wrong = FakeTransport(threadID: "wrong", cwd: pending.cwd)
        do { _ = try AppServerResumeTransport(makeTransport: { wrong }).resume(pending, prompt: "继续"); check(false, "mismatch refuses turn") }
        catch { check(wrong.calls.count == 1, "mismatched resume refuses turn start") }
        let executable = temp.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/python3
        import sys,json,os,time
        initialized=False
        for line in sys.stdin:
            request=json.loads(line)
            method=request['method']
            if method=='initialized': initialized=True; continue
            if method=='initialize':
                assert os.environ.get('CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED') == '1'
                result={'userAgent':'fake'}
            elif method=='account/rateLimits/read' and initialized: result={'rateLimits':{'primary':{'usedPercent':1,'windowDurationMins':300,'resetsAt':2000000000}}}
            else: result={'pid':os.getpid(),'arguments':sys.argv[1:]}
            if method=='close-input': os.close(0)
            print(json.dumps({'id':request['id'],'result':result}),flush=True)
            if method=='close-input': time.sleep(10); break
            if method=='exit': break
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let processClient = try AppServerClient(binary: executable)
        let resumeArguments = try processClient.request("arguments", params: [:])["arguments"] as? [String]
        check(resumeArguments == ["app-server"], "default resume client preserves normal plugin configuration")
        let usageProcessClient = try AppServerClient(binary: executable, usageOnly: true)
        let usageArguments = try usageProcessClient.request("arguments", params: [:])["arguments"] as? [String]
        check(usageArguments == ["app-server", "-c", "features.plugins=false", "-c", "features.remote_plugin=false"],
            "usage-only child receives temporary plugin catalog disable arguments")
        let pluginFreeUsage = try UsageDecoder.account(usageProcessClient.request("account/rateLimits/read", params: [:]), at: now)
        check(pluginFreeUsage.fiveHour?.usedPercent == 1, "usage-only child keeps quota RPC handshake working")
        usageProcessClient.close()
        let fromFake = try UsageDecoder.account(processClient.request("account/rateLimits/read", params: [:]), at: now)
        processClient.close()
        check(fromFake.fiveHour?.usedPercent == 1, "fake process validates initialize initialized JSONL handshake")
        processClient.close()
        check((try? processClient.request("after-close", params: [:])) == nil, "closed client rejects writes and repeated close is harmless")
        let brokenPipeClient = try AppServerClient(binary: executable)
        _ = try brokenPipeClient.request("close-input", params: [:])
        check((try? brokenPipeClient.request("write-to-closed-pipe", params: [:])) == nil,
            "closed child stdin throws without SIGPIPE terminating Keeper")
        brokenPipeClient.close()
        let exitedClient = try AppServerClient(binary: executable)
        _ = try exitedClient.request("exit", params: [:])
        check((try? exitedClient.nextMessage(timeout: 2)) == nil, "child exit is observed as connection failure")
        check((try? exitedClient.request("after-exit", params: [:])) == nil, "request after child exit fails safely")
        exitedClient.close()
        let ownClientA = try AppServerClient(binary: executable)
        let ownClientB = try AppServerClient(binary: executable)
        let ownPidA = try ownClientA.request("pid", params: [:])["pid"] as! Int
        let ownPidB = try ownClientB.request("pid", params: [:])["pid"] as! Int
        let unrelatedProcess = Process()
        unrelatedProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelatedProcess.arguments = ["20"]
        try unrelatedProcess.run()
        AppServerClient.closeAll()
        check(kill(Int32(ownPidA), 0) == -1 && kill(Int32(ownPidB), 0) == -1 && unrelatedProcess.isRunning,
            "application shutdown terminates only its registered app-server children")
        ownClientA.close(); ownClientB.close()
        unrelatedProcess.terminate(); unrelatedProcess.waitUntilExit()
        var beforePing = decoded
        beforePing.fiveHour?.resetsAt = now.addingTimeInterval(-5)
        var afterPing = decoded
        afterPing.fiveHour?.resetsAt = now.addingTimeInterval(5 * 3600)
        check(PingConfirmation.accepts(before: beforePing, after: afterPing, now: now), "ping requires actual new five-hour window")
        check(!PingConfirmation.accepts(before: beforePing, after: beforePing, now: now), "OK without changed window is unconfirmed")
        afterPing.accountID = "different"
        check(!PingConfirmation.accepts(before: beforePing, after: afterPing, now: now), "ping cannot confirm another account's window")
        afterPing.accountID = decoded.accountID; afterPing.capturedAt = now.addingTimeInterval(-100)
        check(!PingConfirmation.accepts(before: beforePing, after: afterPing, now: now), "stale ping confirmation is rejected")
        let offNode = localNode.addingTimeInterval(600)
        let recovered = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: future), weekly: nil, capturedAt: offNode, sourceFile: "app-server")
        let naturalTarget = BlockedSession(id: pending.id, project: pending.project, cwd: pending.cwd, blockedAt: localNode, fiveHourResetAt: offNode.addingTimeInterval(-5), weeklyResetAt: nil, fileURL: pending.fileURL)
        if case .wait = engine.decide(now: offNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: recovered, blocked: [naturalTarget]) { check(true, "early or unobserved recovery automatically waits for plan") } else { check(false, "early or unobserved recovery automatically waits for plan") }
        if case .resume = engine.decide(now: offNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: recovered, blocked: [naturalTarget], observedRecovery: true) { check(true, "continuously observed natural recovery resumes") } else { check(false, "continuously observed natural recovery resumes") }
        try (quotaTrace + event("turn_aborted", now.addingTimeInterval(2))).write(to: file, atomically: true, encoding: .utf8)
        let aborted = SessionWatcher.parse(url: file, mtime: now)!
        check(aborted.lastAbortedAt == now.addingTimeInterval(2) && BlockedSessionDetector.detect(in: [aborted]).isEmpty, "user interruption prevents automatic resurrection")
        let locatorHome = temp.appendingPathComponent("locator-user")
        let userCLI = locatorHome.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path
        check(try CodexLocator.binary(environment: [:], userHome: locatorHome, runningBundles: [], isExecutable: { $0 == userCLI }).path == userCLI,
            "locator finds per-user Applications")
        check(try CodexLocator.binary(environment: ["PATH": ".:/custom/bin"], userHome: locatorHome, runningBundles: [], isExecutable: { $0 == "/custom/bin/codex" }).path == "/custom/bin/codex",
            "locator supports absolute PATH entries")
        check((try? CodexLocator.binary(environment: ["PATH": "."], userHome: locatorHome, runningBundles: [], isExecutable: { $0 == "./codex" })) == nil,
            "locator ignores current-directory PATH executables")
        let runningBundle = temp.appendingPathComponent("Moved Codex.app")
        let runningCLI = runningBundle.appendingPathComponent("Contents/Resources/codex").path
        check(try CodexLocator.binary(environment: [:], userHome: locatorHome, runningBundles: [runningBundle], isExecutable: { $0 == runningCLI }).path == runningCLI,
            "locator finds running official bundle outside standard Applications")
        check(CodexEnvironment.home(environment: ["CODEX_HOME": "/custom/codex"], userHome: locatorHome).path == "/custom/codex" &&
            CodexEnvironment.home(environment: [:], userHome: locatorHome) == locatorHome.appendingPathComponent(".codex"), "unified home supports override and default")
        let emptyHome = temp.appendingPathComponent("empty-codex-home")
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        check((try? SessionWatcher.freshBlockedSessions(codexHome: emptyHome))?.isEmpty == true,
            "first run without logs is an empty task set, not a global error")
        let savedHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", emptyHome.path, 1)
        check(ComposerDraftReader().url == emptyHome.appendingPathComponent(".codex-global-state.json"),
            "composer follows CODEX_HOME")
        if let savedHome { setenv("CODEX_HOME", savedHome, 1) } else { unsetenv("CODEX_HOME") }
        try Data("{\"tokens\":{\"account_id\":\"fixture-account\"}}".utf8).write(to: emptyHome.appendingPathComponent("auth.json"))
        check(try AppServerUsageProvider.authenticationAccountID(home: emptyHome) == "fixture-account", "private auth compatibility reads only stable account field")
        try Data("{\"tokens\":{}}".utf8).write(to: emptyHome.appendingPathComponent("auth.json"))
        check(try AppServerUsageProvider.authenticationAccountID(home: emptyHome) == nil, "unknown auth format cannot fabricate identity")
        let fakeHome = temp.appendingPathComponent("fake-home")
        let observerFailed = CountingUsageTransport()
        observerFailed.delay = 0.1
        observerFailed.onRequest = { _ in throw CodexConnectionError.timeout }
        let observerRecovered = CountingUsageTransport()
        var observerConnections = 0
        let observerProvider = AppServerUsageProvider(makeTransport: {
            observerConnections += 1
            return observerConnections == 1 ? observerFailed : observerRecovered
        }, contextIdentity: { nil })
        let observerLog = temp.appendingPathComponent("observer-events.jsonl")
        let observer = UsageObserver(codexHome: fakeHome, provider: observerProvider, logURL: observerLog)
        observer.refresh()
        for _ in 0..<10 { observer.refresh(manual: true) }
        for _ in 0..<300 {
            if !observer.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!observer.refreshing && observer.lastError == nil && observer.snapshot?.sourceFile == "app-server" && observerConnections == 2,
            "clicks during failed read queue one fresh retry and release syncing state")
        let observerEvents = try String(contentsOf: observerLog, encoding: .utf8)
        check(observerEvents.contains("usage_read_failed") && observerEvents.contains("request_timeout"),
            "quota read failure leaves a structured cause instead of only stale fallback data")
        check(observer.refreshMessage.hasPrefix("已更新"), "manual retry gives success feedback even without closing menu")
        let eventRows = observerEvents.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let starts = eventRows.filter { $0["event"] as? String == "usage_refresh_started" }
        let finishes = eventRows.filter { $0["event"] as? String == "usage_refresh_finished" }
        check(starts.count == 1 && finishes.count == 1 && starts[0]["request_id"] as? String == finishes[0]["request_id"] as? String,
            "manual start and finish can be correlated independently of quota transitions")
        let successTransport = CountingUsageTransport()
        successTransport.delay = 0.05
        let successProvider = AppServerUsageProvider(makeTransport: { successTransport }, contextIdentity: { nil })
        let successLog = temp.appendingPathComponent("refresh-success.jsonl")
        let successObserver = UsageObserver(codexHome: fakeHome, provider: successProvider, logURL: successLog)
        successObserver.refresh()
        successObserver.refresh(manual: true, source: "button")
        check(successObserver.refreshing && successObserver.refreshMessage.contains("完成后重新读取"),
            "click during an existing read immediately acknowledges queued refresh")
        for _ in 0..<10 { successObserver.refresh(manual: true, source: "button") }
        for _ in 0..<300 {
            if !successObserver.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!successObserver.refreshing && successTransport.calls == 2 && successObserver.refreshMessage.hasPrefix("已更新"),
            "click during successful background read performs exactly one new manual read")
        successObserver.refresh(manual: true, source: "button")
        check(successObserver.refreshing && successObserver.refreshMessage == "正在刷新额度…",
            "fresh quota does not hide immediate manual refresh feedback")
        for _ in 0..<300 {
            if !successObserver.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let successEvents = try String(contentsOf: successLog, encoding: .utf8)
        check(successTransport.calls == 3 && successEvents.contains("button") && successEvents.contains("usage_refresh_finished"),
            "button source and completed read remain visible in diagnostic log")
        let failureObserver = UsageObserver(codexHome: fakeHome, provider: manualFailureProvider,
            logURL: temp.appendingPathComponent("refresh-failure.jsonl"))
        failureObserver.refresh(manual: true, source: "button")
        for _ in 0..<300 {
            if !failureObserver.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!failureObserver.refreshing && failureObserver.refreshMessage.contains("刷新失败") && failureObserver.lastError != nil,
            "failed manual read clears busy state and offers an explicit retry")
        let retryEvidence = PingLogEvidence.classify("stream disconnected - retrying sampling request (4/5 in 1.648s)... retries=4 max_retries=5 sampling_error=request timed out")
        check(retryEvidence?.reason == .requestTimeout && retryEvidence?.retryCount == 4, "request timeout preserves observed retry count without blaming proxy or server")
        check(PingLogEvidence.classify("request payload: proxy authentication required") == nil, "quoted request content is not connection evidence")
        check(PingLogEvidence.classify("stream disconnected - retrying sampling request (1/5)... sampling_error=proxy authentication required")?.reason == .proxy, "explicit proxy failure has its own category")
        check(PingLogEvidence.classify("stream disconnected - retrying sampling request (1/5)... sampling_error=unexpected status 503 Service Unavailable")?.reason == .server, "explicit server HTTP failure has its own category")
        check(PingTiming().warning == 90 && PingTiming().timeout == 180, "warning at 90 does not replace 180-second deadline")
        let pingRoot = temp.appendingPathComponent("keeper-ping")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        try Data("test-credential-only".utf8).write(to: fakeHome.appendingPathComponent("auth.json"))
        let fakeTUI = temp.appendingPathComponent("fake-tui")
        let ttyScript = """
        #!/usr/bin/python3
        import os,sys,time,json,pathlib
        assert os.isatty(0) and os.isatty(1)
        assert sys.argv[-1]=='ok'
        assert os.environ['CODEX_HOME'] != '\(fakeHome.path)'
        assert not os.environ.get('OPENAI_API_KEY')
        directory=pathlib.Path(os.environ['CODEX_HOME'])/'sessions'
        directory.mkdir(parents=True,exist_ok=True)
        rows=[{'type':'session_meta','payload':{'id':'11111111-1111-1111-1111-111111111111'}},{'payload':{'type':'task_started','turn_id':'22222222-2222-2222-2222-222222222222'}},{'payload':{'role':'assistant','content':[{'text':'OK'}]}},{'payload':{'type':'task_complete','turn_id':'22222222-2222-2222-2222-222222222222'}}]
        (directory/'rollout-fake.jsonl').write_text(chr(10).join(json.dumps(x) for x in rows))
        print('ready',flush=True)
        time.sleep(25)
        """
        try ttyScript.write(to: fakeTUI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeTUI.path)
        var pingBefore = beforePing; pingBefore.capturedAt = Date(); pingBefore.fiveHour?.resetsAt = Date().addingTimeInterval(-10)
        let pingResult = try PTYPingTransport(codexHome: fakeHome, supportRoot: pingRoot, binary: fakeTUI).ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: FakePingUsage(account: pingBefore.accountID!))
        check(pingResult.fiveHour != nil, "PTY smoke test uses actual terminal and confirms live window")
        let receiptHome = pingRoot.appendingPathComponent("home")
        check(PingReceipt.completed(home: receiptHome, excluding: []), "own new OK completion proves ping was sent")
        let previousReceipts = Set(SessionWatcher.recentRollouts(codexHome: receiptHome, limit: 20).map(\.url))
        check(!PingReceipt.completed(home: receiptHome, excluding: previousReceipts), "old OK receipt cannot confirm another request")
        let copiedAuth = try Data(contentsOf: pingRoot.appendingPathComponent("home/auth.json"))
        check(copiedAuth == Data("test-credential-only".utf8), "ping uses isolated home with local-only credential copy")
        check(!FileManager.default.fileExists(atPath: fakeHome.appendingPathComponent("sessions").path), "ping does not create normal-home history")
        let pingConfig = try String(contentsOf: receiptHome.appendingPathComponent("config.toml"), encoding: .utf8)
        check(pingConfig.contains("[projects.\"" + pingRoot.appendingPathComponent("work").path + "\"]"), "generated TOML project path has no invalid escaped forward slashes")
        try "#!/bin/sh\nprintf 'Error loading config.toml: invalid escape\\n'\nexit 1\n".write(to: fakeTUI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeTUI.path)
        do {
            _ = try PTYPingTransport(codexHome: fakeHome, supportRoot: pingRoot, binary: fakeTUI).ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: FakePingUsage(account: pingBefore.accountID!))
            check(false, "config startup failure cannot report quota confirmation timeout")
        } catch {
            check(error.localizedDescription.contains("无法读取保活配置"), "config startup failure cannot report quota confirmation timeout")
        }
        let diagnosticHome = temp.appendingPathComponent("ping-log-fixture")
        try FileManager.default.createDirectory(at: diagnosticHome, withIntermediateDirectories: true)
        var pingDB: OpaquePointer?
        sqlite3_open(diagnosticHome.appendingPathComponent("logs_2.sqlite").path, &pingDB)
        sqlite3_exec(pingDB, "CREATE TABLE logs(ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil)
        let pingThread = "11111111-1111-1111-1111-111111111111"
        let pingTurn = "22222222-2222-2222-2222-222222222222"
        let pingOther = "33333333-3333-3333-3333-333333333333"
        let logStart = Date(timeIntervalSince1970: 1000.5)
        func addPingLog(_ second: Int, _ nano: Int, _ thread: String, _ turn: String, _ reason: String, _ target: String = "codex_core::responses_retry") {
            let body = "stream disconnected - retrying sampling request (4/5 in 1s)... turn_id=\(turn) retries=4 max_retries=5 sampling_error=\(reason)"
            sqlite3_exec(pingDB, "INSERT INTO logs VALUES(\(second),\(nano),'\(target)','\(thread)','\(body)')", nil, nil, nil)
        }
        addPingLog(1000, 100_000_000, pingThread, pingTurn, "proxy authentication required")
        addPingLog(1001, 0, pingOther, pingTurn, "proxy authentication required")
        addPingLog(1001, 0, pingThread, pingOther, "proxy authentication required")
        let logReader = PingDiagnosticLogReader(home: diagnosticHome)
        check(logReader.read(threadID: pingThread, turnID: pingTurn, since: logStart, until: Date(timeIntervalSince1970: 1002)).evidence == nil,
            "ping evidence excludes old nanosecond, another thread and another turn")
        addPingLog(1001, 0, pingThread, pingTurn, "request timed out Authorization: Bearer fixture-secret-token")
        addPingLog(1003, 0, pingThread, pingTurn, "proxy authentication required")
        addPingLog(1001, 500_000_000, pingThread, pingTurn, "proxy authentication required", "codex_core::prewarm")
        sqlite3_close(pingDB)
        let scopedEvidence = logReader.read(threadID: pingThread, turnID: pingTurn, since: logStart, until: Date(timeIntervalSince1970: 1002))
        check(scopedEvidence.evidence?.reason == .requestTimeout && scopedEvidence.evidence?.retryCount == 4 && scopedEvidence.status == "readable",
            "ping evidence selects exact attempt and ignores future and unrelated target logs")
        var safeDiagnostic = PingDiagnostic(elapsedSeconds: 90, warningSeconds: 90, timeoutSeconds: 180, threadID: pingThread, turnID: pingTurn)
        safeDiagnostic.reason = scopedEvidence.evidence!.reason; safeDiagnostic.retryCount = scopedEvidence.evidence?.retryCount
        let safeEventURL = temp.appendingPathComponent("ping-diagnostic-events.jsonl")
        try ExecutionEventLog(url: safeEventURL).record("diagnostic", kind: "ping", node: nil, diagnostic: safeDiagnostic)
        let safeEvent = try String(contentsOf: safeEventURL, encoding: .utf8)
        check(!safeEvent.contains("fixture-secret-token") && !safeEvent.contains("Authorization") && !safeEvent.contains("sampling_error") && safeEvent.contains(pingTurn),
            "execution diagnostic persists classifications and identity, never raw HTTP/log content")
        check(safeDiagnostic.warning.contains("超时") && safeDiagnostic.warning.contains("180"), "90-second warning explains timeout and continuing deadline")
        safeDiagnostic.okReceived = true; safeDiagnostic.taskCompleted = true
        check(safeDiagnostic.warning.contains("已收到 OK") && !safeDiagnostic.warning.contains("重试"), "OK completion advances warning to window confirmation")
        safeDiagnostic.okReceived = false; safeDiagnostic.taskCompleted = false; safeDiagnostic.reason = .unknown
        check(!safeDiagnostic.warning.contains("重试") && !safeDiagnostic.warning.contains("代理"), "unknown wait does not invent network evidence")
        let warningMenu = MenuSummary(headline: "保活等待中", note: safeDiagnostic.warning, warning: safeDiagnostic.warning)
        check(warningMenu.statusSymbol == "exclamationmark.circle" && warningMenu.error.isEmpty, "pending warning has visible icon without final failure")

        // Shortened test timing exercises the same PTY loop without network access or real runtime data.
        let slowTUI = temp.appendingPathComponent("slow-fake-tui")
        let slowScript = """
        #!/usr/bin/python3
        import os,time,json,pathlib
        root=pathlib.Path(os.environ['CODEX_HOME'])
        directory=root/'sessions'
        directory.mkdir(parents=True,exist_ok=True)
        rows=[{'type':'session_meta','payload':{'id':'\(pingThread)'}},{'payload':{'type':'task_started','turn_id':'\(pingTurn)'}}]
        output=directory/'rollout-delayed.jsonl'
        output.write_text(chr(10).join(json.dumps(x) for x in rows))
        (root/'launch-count').open('a').write('1')
        time.sleep(0.5)
        rows += [{'payload':{'role':'assistant','content':[{'text':'OK'}]}},{'payload':{'type':'task_complete','turn_id':'\(pingTurn)'}}]
        output.write_text(chr(10).join(json.dumps(x) for x in rows))
        time.sleep(10)
        """
        try slowScript.write(to: slowTUI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slowTUI.path)
        let slowRoot = temp.appendingPathComponent("slow-ping")
        let testTiming = PingTiming(warning: 0.2, timeout: 1.5, pollInterval: 0.05)
        var progressEvents: [PingDiagnostic] = []
        let slowTransport = PTYPingTransport(codexHome: fakeHome, supportRoot: slowRoot, binary: slowTUI, timing: testTiming)
        _ = try slowTransport.ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: FakePingUsage(account: pingBefore.accountID!)) { progressEvents.append($0) }
        check(progressEvents.first?.outcome == "waiting" && progressEvents.first!.elapsedSeconds >= testTiming.warning && progressEvents.last?.outcome == "confirmed",
            "warning does not terminate PTY; delayed valid receipt still confirms within same attempt")
        check(try String(contentsOf: slowRoot.appendingPathComponent("home/launch-count"), encoding: .utf8) == "1", "warning never launches a duplicate ping")
        let noReplyScript = slowScript.replacingOccurrences(of: "time.sleep(0.5)", with: "time.sleep(10)")
        try noReplyScript.write(to: slowTUI, atomically: true, encoding: .utf8)
        var timedOutProgress: [PingDiagnostic] = []
        let timeoutTiming = PingTiming(warning: 0.2, timeout: 0.7, pollInterval: 0.05)
        do {
            _ = try PTYPingTransport(codexHome: fakeHome, supportRoot: temp.appendingPathComponent("timeout-ping"), binary: slowTUI, timing: timeoutTiming)
                .ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: FakePingUsage(account: pingBefore.accountID!)) { timedOutProgress.append($0) }
            check(false, "no reply must reach final timeout")
        } catch let failure as PingFailure {
            check(timedOutProgress.first?.outcome == "waiting" && failure.diagnostic.elapsedSeconds >= timeoutTiming.timeout && failure.diagnostic.reason == .unknown,
                "unknown reply waits beyond warning until full final deadline without invented cause")
        }
        let cancelledTransport = PTYPingTransport(codexHome: fakeHome, supportRoot: temp.appendingPathComponent("cancelled-ping"), binary: slowTUI, timing: testTiming)
        do {
            _ = try cancelledTransport.ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: FakePingUsage(account: pingBefore.accountID!)) { progress in
                if progress.outcome == "waiting" { cancelledTransport.cancel() }
            }
            check(false, "cancel after warning must stop without success")
        } catch let failure as PingFailure {
            check(failure.diagnostic.outcome == "cancelled" && !failure.diagnostic.windowConfirmed, "cancellation after warning remains unconfirmed")
        }
        var choices = ResumeChoices()
        let another = BlockedSession(id: "33333333-3333-3333-3333-333333333333", project: "Another", cwd: temp.path,
            blockedAt: pending.blockedAt, fiveHourResetAt: pending.fiveHourResetAt, weeklyResetAt: nil, fileURL: file)
        check(choices.selected([pending, another]).count == 2, "all blocked tasks are selected by default")
        choices.messages[pending.episodeKey] = "继续并检查测试"
        choices.deselectedEpisodes.insert(another.episodeKey)
        let naturalOldTask = engine.plan(now: offNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: recovered, blocked: [pending], observedRecovery: true)
        if case .resume = naturalOldTask.decision { check(true, "current observed recovery releases older blocked episodes") }
        else { check(false, "current observed recovery releases older blocked episodes") }
        let restored = try JSONDecoder().decode(ResumeChoices.self, from: JSONEncoder().encode(choices))
        check(restored.selected([pending, another]).map(\.id) == [pending.id], "selection persists per episode")
        check(restored.message(for: pending, default: "继续") == "继续并检查测试", "per-task prompt persists")
        choices.useKeepAlive(for: [pending, another])
        check(choices.available([pending, another]).isEmpty, "switch to keepalive excludes every current blocked task")
        let laterStop = BlockedSession(id: pending.id, project: pending.project, cwd: pending.cwd,
            blockedAt: pending.blockedAt.addingTimeInterval(100), fiveHourResetAt: future, weeklyResetAt: nil, fileURL: file)
        check(choices.selected([laterStop]).count == 1, "a new quota stop defaults to resume again")

        // Exercise the real coordinator with fake transports: task two must start before
        // task one completes, each prompt goes to the matching task, and neither repeats.
        let suite = "keeper.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: ["enabled": true, "executionEnabled": false, "autoResume": true, "dailyAnchorMinutes": 480, "resumeWorkspaceReminder": false])
        let recorder = BatchRecorder(expected: 2)
        var requests: [ResumeRequest] = []
        let batchHome = temp.appendingPathComponent("batch-home")
        try FileManager.default.createDirectory(at: batchHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        var batchDB: OpaquePointer?
        sqlite3_open(batchHome.appendingPathComponent("logs_1.sqlite").path, &batchDB)
        sqlite3_exec(batchDB, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil)
        sqlite3_close(batchDB)
        for (index, id) in [pending.id, another.id].enumerated() {
            let path = batchHome.appendingPathComponent("sessions/rollout-\(id).jsonl")
            let metadata: [String: Any] = ["type": "session_meta", "payload": ["id": id, "cwd": temp.path]]
            let stoppedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 5)
            let trace = String(data: try JSONSerialization.data(withJSONObject: metadata), encoding: .utf8)! + "\n" + event("error", stoppedAt, ["message": "usage_limit_reached"])
            try trace.write(to: path, atomically: true, encoding: .utf8)
            let task = BlockedSession(id: id, project: "Task \(index)", cwd: temp.path, blockedAt: stoppedAt,
                fiveHourResetAt: Date().addingTimeInterval(-1), weeklyResetAt: nil, fileURL: path)
            requests.append(ResumeRequest(target: task, prompt: "custom-\(index)", accountID: "test-account", workspace: nil))
        }
        let target = requests[0].target
        check((try? ResumePreflight.read(target: target, provider: FakePingUsage(account: "test-account"), codexHome: batchHome)) != nil,
            "resume preflight accepts current explicit quota stop")
        let olderEpisode = BlockedSession(id: target.id, project: target.project, cwd: target.cwd, blockedAt: target.blockedAt.addingTimeInterval(-1), fiveHourResetAt: nil, weeklyResetAt: nil, fileURL: target.fileURL)
        check((try? ResumePreflight.read(target: olderEpisode, provider: FakePingUsage(account: "test-account"), codexHome: batchHome)) == nil,
            "resume rejects obsolete stop episode")
        let validDatabase = batchHome.appendingPathComponent("logs_1.sqlite")
        let savedDatabase = batchHome.appendingPathComponent("saved-logs")
        try FileManager.default.moveItem(at: validDatabase, to: savedDatabase)
        check((try? ResumePreflight.read(target: target, provider: FakePingUsage(account: "test-account"), codexHome: batchHome)) == nil,
            "resume cannot use stale evidence when log database is missing")
        sqlite3_open(validDatabase.path, &batchDB)
        sqlite3_exec(batchDB, "CREATE TABLE logs(id INTEGER)", nil, nil, nil)
        sqlite3_close(batchDB)
        let blockedRecorder = BatchRecorder(expected: 1)
        let blockedCoordinator = ExecutionCoordinator(provider: FakePingUsage(account: "test-account"),
            makeResumeTransport: { BatchTransport(recorder: blockedRecorder) }, defaults: defaults,
            ledgerURL: temp.appendingPathComponent("blocked-batch/attempts.json"), codexHome: batchHome)
        blockedCoordinator.resume([requests[0]], schedule: schedule, manual: true)
        for _ in 0..<500 {
            if !blockedCoordinator.running { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!blockedCoordinator.running && blockedRecorder.count == 0 && !blockedCoordinator.hasAttempted(target) && blockedCoordinator.lastFailure != nil,
            "incompatible logs stop real coordinator before any send or attempt consumption")
        try FileManager.default.removeItem(at: validDatabase)
        try FileManager.default.moveItem(at: savedDatabase, to: validDatabase)
        let validTrace = try String(contentsOf: target.fileURL, encoding: .utf8)
        let metadataOnly = String(validTrace.split(separator: "\n")[0]) + "\n"
        try metadataOnly.write(to: target.fileURL, atomically: true, encoding: .utf8)
        check((try? ResumePreflight.read(target: target, provider: FakePingUsage(account: "test-account"), codexHome: batchHome)) == nil,
            "valid logs without target stop evidence cannot resume")
        try validTrace.write(to: target.fileURL, atomically: true, encoding: .utf8)
        for index in 0..<21 {
            let newer = batchHome.appendingPathComponent("sessions/newer-\(index).jsonl")
            try "{}".write(to: newer, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: newer.path)
        }
        check((try? ResumePreflight.read(target: target, provider: FakePingUsage(account: "test-account"), codexHome: batchHome)) != nil,
            "watched target outside newest twenty rollouts retains validated stop evidence")
        let coordinator = ExecutionCoordinator(provider: FakePingUsage(account: "test-account"),
            makeResumeTransport: { BatchTransport(recorder: recorder) }, defaults: defaults,
            ledgerURL: temp.appendingPathComponent("batch/attempts.json"), codexHome: batchHome)
        defaults.set(false, forKey: "enabled")
        coordinator.resume(requests, schedule: schedule, manual: true)
        check(!coordinator.running && recorder.count == 0, "disabled Keeper cannot dispatch even manual resume")
        defaults.set(true, forKey: "enabled")
        coordinator.resume(requests, schedule: schedule, manual: true)
        for _ in 0..<500 {
            if !coordinator.running { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!coordinator.running && recorder.count == 2 && !recorder.timedOut, "all selected tasks start without waiting for first completion")
        check(recorder.prompt(for: requests[0].target.id) == "custom-0" && recorder.prompt(for: requests[1].target.id) == "custom-1", "disabled reminder sends each task's exact prompt through the real coordinator")
        coordinator.resume(requests, schedule: schedule, manual: true)
        check(!coordinator.running && recorder.count == 2, "completed or uncertain episodes never dispatch twice")
        let ledger = try JSONDecoder().decode([String].self, from: Data(contentsOf: temp.appendingPathComponent("batch/attempts.json")))
        check(requests.allSatisfy { ledger.contains($0.target.episodeKey) }, "each task attempt is durable")

        print("\(count - failed)/\(count) regression checks passed")
        if failed > 0 { exit(1) }
    }
}

final class FakeTransport: CodexTransport {
    let threadID: String
    let cwd: String
    var calls: [(String, [String: Any])] = []
    var closed = false
    var needsApproval = false
    var waited = false
    init(threadID: String, cwd: String) { self.threadID = threadID; self.cwd = cwd }
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        calls.append((method, params))
        if method == "thread/resume" { return ["thread": ["id": threadID, "status": ["type": "idle"]], "cwd": cwd] }
        return ["turn": ["id": "turn-1"]]
    }
    func nextMessage(timeout: TimeInterval) throws -> [String: Any] {
        if !waited { waited = true; throw CodexConnectionError.timeout }
        if needsApproval { return ["id": 100, "method": "item/commandExecution/requestApproval"] }
        return ["method": "turn/completed", "params": ["threadId": threadID, "turn": ["id": "turn-1", "status": "completed"]]]
    }
    func close() { closed = true }
}

struct FakePingUsage: UsageProvider {
    let account: String
    func pingModel() throws -> PingModel { PingModel(model: "gpt-5.6-luna", reasoningEffort: "low") }
    func read() throws -> UsageSnapshot {
        let now = Date()
        return UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: now.addingTimeInterval(5 * 3600)), weekly: nil, capturedAt: now, accountID: account, sourceFile: "app-server", zeroUseWindowActive: true)
    }
}

final class BatchRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var prompts: [String: String] = [:]
    private let expected: Int
    private var timeout = false
    init(expected: Int) { self.expected = expected }
    var count: Int { condition.lock(); defer { condition.unlock() }; return prompts.count }
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return timeout }
    func prompt(for id: String) -> String? { condition.lock(); defer { condition.unlock() }; return prompts[id] }
    func receive(_ id: String, _ prompt: String) {
        condition.lock(); defer { condition.unlock() }
        prompts[id] = prompt
        condition.broadcast()
        let deadline = Date().addingTimeInterval(2)
        while prompts.count < expected {
            if !condition.wait(until: deadline) { timeout = true; break }
        }
    }
}
struct BatchTransport: ResumeTransport {
    let recorder: BatchRecorder
    func resume(_ target: BlockedSession, prompt: String) throws -> ResumeReceipt {
        recorder.receive(target.id, prompt)
        return ResumeReceipt(threadID: target.id, turnID: "fake-turn", message: "completed")
    }
}

final class ZeroWindowTransport: CodexTransport {
    let rolling: Bool
    let fixed = Date().addingTimeInterval(18000)
    init(rolling: Bool) { self.rolling = rolling }
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        if method == "account/read" { return ["account": ["type": "chatgpt"]] }
        return ["accountId": "zero-test", "rateLimits": ["primary": ["usedPercent": 0, "windowDurationMins": 300,
            "resetsAt": (rolling ? Date().addingTimeInterval(18000) : fixed).timeIntervalSince1970]]]
    }
    func nextMessage(timeout: TimeInterval) throws -> [String: Any] { throw CodexConnectionError.timeout }
    func close() {}
}

final class FakeDesktopConnection: DesktopConnection {
    var ownerID: String? = "desktop-owner"
    var starts = 0
    var onStart: () throws -> Void = {}
    func owner(of threadID: String) throws -> String? { ownerID }
    func start(threadID: String, prompt: String, owner: String) throws -> String {
        starts += 1
        try onStart()
        return "desktop-turn"
    }
    func cancel() {}
}

final class CountingUsageTransport: CodexTransport {
    private let lock = NSLock()
    private var total = 0
    private var active = 0
    private var peak = 0
    private var closeCount = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return total }
    var closes: Int { lock.lock(); defer { lock.unlock() }; return closeCount }
    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var delay: TimeInterval = 0
    var zero = false
    var onRequest: (Int) throws -> Void = { _ in }
    var accountForCall: (Int) -> String = { _ in "usage-test" }
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        if method == "account/read" { return ["account": ["type": "chatgpt"]] }
        lock.lock()
        total += 1
        let call = total
        active += 1
        peak = max(peak, active)
        lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        try onRequest(call)
        return ["accountId": accountForCall(call), "rateLimits": ["primary": ["usedPercent": zero ? 0 : call,
            "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(18000).timeIntervalSince1970]]]
    }
    func nextMessage(timeout: TimeInterval) throws -> [String: Any] { throw CodexConnectionError.timeout }
    func close() { lock.lock(); closeCount += 1; lock.unlock() }
}

final class UsageReadBatch: @unchecked Sendable {
    let provider: AppServerUsageProvider
    private let lock = NSLock()
    private(set) var failures = 0
    init(provider: AppServerUsageProvider) { self.provider = provider }
    func run(count: Int) {
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            do { _ = try self.provider.read() }
            catch { self.lock.lock(); self.failures += 1; self.lock.unlock() }
        }
    }
}

final class CompatibilityTransport: CodexTransport {
    var account: Any = ["type": "chatgpt"]
    var reportedAccount: String? = "test-account"
    var pages: [[String: Any]] = []
    var modelParams: [[String: Any]] = []
    var quotaCalls = 0
    var closes = 0
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        if method == "account/read" { return ["account": account] }
        if method == "model/list" {
            modelParams.append(params)
            guard !pages.isEmpty else { throw CodexConnectionError.invalidResponse }
            return pages.count > 1 ? pages.removeFirst() : pages[0]
        }
        quotaCalls += 1
        var result: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 1, "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(18000).timeIntervalSince1970]]]
        if let reportedAccount { result["accountId"] = reportedAccount }
        return result
    }
    func nextMessage(timeout: TimeInterval) throws -> [String: Any] { throw CodexConnectionError.timeout }
    func close() { closes += 1 }
}
