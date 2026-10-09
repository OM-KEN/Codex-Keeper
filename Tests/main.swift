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
        do {
            let updateSuite = "keeper.updates.tests." + UUID().uuidString
            let updateDefaults = UserDefaults(suiteName: updateSuite)!
            defer { updateDefaults.removePersistentDomain(forName: updateSuite) }
            let currentVersion = SemanticVersion(tag: "0.1.4")!
            check(SemanticVersion(tag: "v0.1.10")! > currentVersion &&
                SemanticVersion(tag: "1.0.0")! > SemanticVersion(tag: "0.99.99")! &&
                SemanticVersion(tag: "0.2.0")! > SemanticVersion(tag: "0.1.99")!,
                "stable versions compare each numeric component instead of sorting strings")
            check(SemanticVersion(tag: "V0.1.4") == currentVersion &&
                ["0.1", "0.1.4-beta.1", "0.1.4+build", "01.1.4", "0.-1.4", "0.1.４"].allSatisfy { SemanticVersion(tag: $0) == nil },
                "stable versions accept the tag prefix and reject noncanonical or prerelease versions")
            func releaseResponse(_ tag: String = "v0.1.4", status: Int = 200, url: String? = nil) -> HTTPURLResponse {
                let defaultURL = status == 404 ? "https://github.com/OM-KEN/Codex-Keeper/releases/latest" :
                    "https://github.com/OM-KEN/Codex-Keeper/releases/tag/\(tag)"
                return HTTPURLResponse(url: URL(string: url ?? defaultURL)!,
                    statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            }
            let newRelease = AppRelease(version: SemanticVersion(tag: "0.1.10")!,
                pageURL: releaseResponse("v0.1.10").url!)
            check(LatestReleaseParser.parse(response: releaseResponse("v0.1.10")) == .release(newRelease),
                "latest release redirect preserves the trusted stable version and release page")
            check(LatestReleaseParser.parse(response: releaseResponse(status: 404)) == .noStableRelease,
                "missing latest release reports that no stable release is available")
            for status in [403, 500, 302] {
                check(LatestReleaseParser.parse(response: releaseResponse(status: status)) == .failure,
                    "unsuccessful or unfinished release response is not a successful check: \(status)")
            }
            let invalidReleaseURLs = [
                "http://github.com/OM-KEN/Codex-Keeper/releases/tag/v0.1.10",
                "https://github.com/OM-KEN/Copied/releases/tag/v0.1.10",
                "https://github.com.evil.example/OM-KEN/Codex-Keeper/releases/tag/v0.1.10",
                "https://github.com/OM-KEN/Codex-Keeper/releases/latest",
                "https://github.com/OM-KEN/Codex-Keeper/releases/tag/v0.1.10-beta.1",
                "https://github.com/OM-KEN/Codex-Keeper/releases/tag/v0.1.10/extra",
                "https://github.com/OM-KEN/Codex-Keeper/releases/tag/v0.1.10?next=elsewhere"
            ]
            check(invalidReleaseURLs.allSatisfy {
                LatestReleaseParser.parse(response: releaseResponse(url: $0)) == .failure
            }, "only a finished HTTPS release redirect for this repository and a numeric stable tag is accepted")
            check(LatestReleaseParser.parse(response: releaseResponse(status: 404,
                url: "https://github.com/OM-KEN/Copied/releases/latest")) == .failure,
                "a missing release in another repository cannot report that Codex Keeper has no stable release")
            check(LatestReleaseParser.parse(response: URLResponse(url: releaseResponse().url!, mimeType: nil,
                expectedContentLength: 0, textEncodingName: nil)) == .failure,
                "non-HTTP release responses cannot report an available update")
            for tag in ["v0.1.4", "v0.1.3"] {
                let service = AppUpdateService(defaults: updateDefaults, currentVersion: "0.1.4", loadResponse: { _ in releaseResponse(tag) })
                await service.checkManually()
                check(service.status == .upToDate && service.availableRelease == nil,
                    "equal or older releases never offer a downgrade: \(tag)")
            }
            var requests: [URLRequest] = []
            var pendingResponse: CheckedContinuation<URLResponse, Error>?
            var requestStarted: CheckedContinuation<Void, Never>?
            let service = AppUpdateService(defaults: updateDefaults, currentVersion: "0.1.4", loadResponse: { request in
                requests.append(request)
                return try await withCheckedThrowingContinuation {
                    pendingResponse = $0
                    requestStarted?.resume()
                    requestStarted = nil
                }
            })
            check(service.status == .idle && requests.isEmpty, "creating the update service does not start a check")
            let firstCheck = Task { await service.checkManually() }
            await withCheckedContinuation { requestStarted = $0 }
            await service.checkManually()
            check(service.status == .checking && requests.count == 1,
                "another manual check does not send a duplicate request while the first is pending")
            check(requests.first?.url?.absoluteString == "https://github.com/OM-KEN/Codex-Keeper/releases/latest" &&
                requests.first?.httpMethod == "HEAD" && requests.first?.timeoutInterval == 10 &&
                requests.first?.cachePolicy == .reloadIgnoringLocalCacheData,
                "manual update request uses a fresh short HEAD request to this repository's latest release")
            pendingResponse?.resume(returning: releaseResponse("v0.1.10"))
            await firstCheck.value
            check(service.status == .updateAvailable(newRelease) && service.availableRelease == newRelease,
                "a new stable release exposes only its validated GitHub page")
            var retryCount = 0
            let retryService = AppUpdateService(defaults: updateDefaults, currentVersion: "0.1.4", loadResponse: { _ in
                retryCount += 1
                if retryCount == 1 { throw URLError(.timedOut) }
                return releaseResponse()
            })
            await retryService.checkManually()
            check(retryService.status == .failed && retryService.availableRelease == newRelease,
                "network failure leaves a visible failed state and preserves a previously trusted release")
            await retryService.checkManually()
            check(retryService.status == .upToDate && retryCount == 2,
                "a failed manual update check can immediately be retried")
            let missingService = AppUpdateService(defaults: updateDefaults, currentVersion: "0.1.4", loadResponse: { _ in releaseResponse(status: 404) })
            await missingService.checkManually()
            check(missingService.status == .noStableRelease, "404 flows through to the manual no-stable-release state")
            let invalidService = AppUpdateService(defaults: updateDefaults, currentVersion: "—", loadResponse: { _ in
                check(false, "an unknown local version must not query for updates")
                return releaseResponse()
            })
            await invalidService.checkManually()
            check(invalidService.status == .failed, "an unknown local version does not claim the app is current")

            let automaticSuite = "keeper.automatic-updates.tests." + UUID().uuidString
            let automaticDefaults = UserDefaults(suiteName: automaticSuite)!
            defer { automaticDefaults.removePersistentDomain(forName: automaticSuite) }
            var clock = Date(timeIntervalSince1970: 1_800_000_000)
            var automaticRequests = 0
            let automaticService = AppUpdateService(defaults: automaticDefaults, currentVersion: "0.1.4", now: { clock }, loadResponse: { _ in
                automaticRequests += 1
                return releaseResponse("v0.1.10")
            })
            check(automaticService.automaticRemindersEnabled && !automaticService.showsMenuUpdateIndicator && automaticRequests == 0,
                "update reminders default to enabled without querying until an automatic trigger")
            await automaticService.checkAutomaticallyIfDue()
            check(automaticRequests == 1 && automaticService.showsMenuUpdateIndicator,
                "a first automatic trigger checks the stable release and enables the menu reminder")
            let restartedService = AppUpdateService(defaults: automaticDefaults, currentVersion: "0.1.4", now: { clock }, loadResponse: { _ in
                automaticRequests += 1
                return releaseResponse("v0.1.10")
            })
            check(restartedService.availableRelease == newRelease && restartedService.showsMenuUpdateIndicator,
                "a restart restores the trusted newer release before a throttled network check")
            await restartedService.checkAutomaticallyIfDue()
            clock.addTimeInterval(24 * 60 * 60 - 1)
            await restartedService.checkAutomaticallyIfDue()
            check(automaticRequests == 1, "successful automatic checks remain throttled across a restart for a full day")
            clock.addTimeInterval(1)
            await restartedService.checkAutomaticallyIfDue()
            check(automaticRequests == 2, "automatic checking resumes exactly after the 24-hour interval")
            restartedService.setAutomaticRemindersEnabled(false)
            clock.addTimeInterval(24 * 60 * 60)
            await restartedService.checkAutomaticallyIfDue()
            check(automaticRequests == 2 && !restartedService.showsMenuUpdateIndicator && restartedService.availableRelease == newRelease,
                "disabling reminders stops automatic queries and hides the menu marker while retaining the update link")
            let disabledRestart = AppUpdateService(defaults: automaticDefaults, currentVersion: "0.1.4", now: { clock }, loadResponse: { _ in
                automaticRequests += 1
                return releaseResponse("v0.1.10")
            })
            check(!disabledRestart.automaticRemindersEnabled && !disabledRestart.showsMenuUpdateIndicator,
                "disabled reminders remain disabled after restarting")
            await disabledRestart.checkManually()
            check(automaticRequests == 3 && disabledRestart.availableRelease == newRelease && !disabledRestart.showsMenuUpdateIndicator,
                "manual update checks and release links still work when reminders are disabled")
            disabledRestart.setAutomaticRemindersEnabled(true)
            check(disabledRestart.showsMenuUpdateIndicator,
                "reenabling reminders immediately restores the known available-version marker")
            var failureRequests = 0
            let automaticRetry = AppUpdateService(defaults: automaticDefaults, currentVersion: "0.1.4", now: { clock }, loadResponse: { _ in
                failureRequests += 1
                if failureRequests == 1 { throw URLError(.cannotConnectToHost) }
                return releaseResponse("v0.1.10")
            })
            clock.addTimeInterval(24 * 60 * 60)
            await automaticRetry.checkAutomaticallyIfDue()
            check(failureRequests == 1 && automaticRetry.status == .failed && automaticRetry.showsMenuUpdateIndicator,
                "an automatic network failure preserves the previously discovered menu update reminder")
            clock.addTimeInterval(60 * 60 - 1)
            await automaticRetry.checkAutomaticallyIfDue()
            check(failureRequests == 1, "failed automatic checks back off for a full hour")
            let failureRestart = AppUpdateService(defaults: automaticDefaults, currentVersion: "0.1.4", now: { clock }, loadResponse: { _ in
                failureRequests += 1
                return releaseResponse("v0.1.10")
            })
            await failureRestart.checkAutomaticallyIfDue()
            check(failureRequests == 1 && failureRestart.showsMenuUpdateIndicator,
                "a restart preserves both failure backoff and the existing update marker")
            clock.addTimeInterval(1)
            await failureRestart.checkAutomaticallyIfDue()
            check(failureRequests == 2 && failureRestart.status == .updateAvailable(newRelease),
                "failed automatic checks can retry exactly after an hour")
            let upgradedService = AppUpdateService(defaults: automaticDefaults, currentVersion: "0.1.10", now: { clock }, loadResponse: { _ in releaseResponse("v0.1.10") })
            check(upgradedService.availableRelease == nil && !upgradedService.showsMenuUpdateIndicator,
                "installing the cached newer version removes the obsolete menu reminder")
            automaticDefaults.set("https://github.com/OM-KEN/Copied/releases/tag/v99.0.0", forKey: "appUpdateCachedReleaseURL")
            let invalidCacheService = AppUpdateService(defaults: automaticDefaults, currentVersion: "0.1.4", now: { clock }, loadResponse: { _ in releaseResponse() })
            check(invalidCacheService.availableRelease == nil && !invalidCacheService.showsMenuUpdateIndicator &&
                automaticDefaults.object(forKey: "appUpdateCachedReleaseURL") == nil,
                "an untrusted cached release is discarded instead of becoming a menu update link")
            check(MenuVersionTextFormatter.string(version: "0.1.4", hasUpdate: false) == "版本 0.1.4" &&
                MenuVersionTextFormatter.string(version: "0.1.4", hasUpdate: true) == "版本 0.1.4 · 有新版本",
                "the available-version reminder follows the version text in the menu")
            let environment = FeedbackEnvironment(appVersion: "0.1.4 + & #", macOSVersion: "15.7", chip: "Apple M4")
            let emailURL = FeedbackSupport.emailURL(for: environment)!
            let components = URLComponents(url: emailURL, resolvingAgainstBaseURL: false)!
            let body = components.queryItems?.first { $0.name == "body" }?.value ?? ""
            check(components.scheme == "mailto" && components.path == "omken.feedback@gmail.com" &&
                components.queryItems?.first { $0.name == "subject" }?.value == "Codex Keeper 问题反馈" &&
                body.contains(environment.appVersion) && body.contains(environment.macOSVersion) && body.contains(environment.chip) &&
                body.contains("问题描述") && body.contains("复现步骤") && !emailURL.absoluteString.contains("+") &&
                emailURL.absoluteString.contains("%0A"),
                "feedback email preserves environment fields and encodes reserved characters and line breaks")
            check(FeedbackSupport.githubIssueChooserURL.absoluteString == "https://github.com/OM-KEN/Codex-Keeper/issues/new/choose",
                "GitHub feedback opens the issue chooser for Codex Keeper")
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
        // Real missed keep-alive times require their own grace, while held continuation keeps three minutes.
        do {
            var shanghai = cal; shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let planner = DecisionEngine(schedule: schedule)
            func idle(at time: Date) -> UsageSnapshot {
                UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: time.addingTimeInterval(18000)),
                    weekly: nil, capturedAt: time, accountID: "grace-account", sourceFile: "app-server", zeroUseWindowActive: false)
            }
            for observed in [date("2026-10-01T15:03:16Z"), date("2026-10-03T10:03:08Z")] {
                let plan = planner.plan(now: observed, calendar: shanghai, enabled: true, autoResume: false,
                    earlyRecoveryPolicy: "ask", usage: idle(at: observed), blocked: [])
                check(plan.date == observed && plan.decision == .ping(reason: "计划节点，当前无窗口"),
                    "real late reset \(iso.string(from: observed)) remains a keep-alive opportunity")
            }
            let node = date("2026-10-03T10:00:00Z")
            for offset in [-1.0, 0, 180, 181, 599, 600, 600.001] {
                let time = node.addingTimeInterval(offset)
                let plan = planner.plan(now: time, calendar: shanghai, enabled: true, autoResume: false,
                    earlyRecoveryPolicy: "ask", usage: idle(at: time), blocked: [])
                let due = offset >= 0 && offset <= 600
                check((plan.decision == .ping(reason: "计划节点，当前无窗口")) == due,
                    "keep-alive grace boundary \(offset) seconds is enforced without early or late sends")
            }
            var active = idle(at: node); active.fiveHour?.usedPercent = 1
            active.fiveHour?.resetsAt = date("2026-10-03T10:03:08Z")
            let delayedPlan = planner.plan(now: node, calendar: shanghai, enabled: true, autoResume: false,
                earlyRecoveryPolicy: "ask", usage: active, blocked: [])
            check(delayedPlan.date == active.fiveHour?.resetsAt,
                "18:03:08 window expiry keeps the 18:00 keep-alive round instead of skipping to 23:00")
            let target = BlockedSession(id: "held-grace", project: "Grace", cwd: "/fixture", blockedAt: node.addingTimeInterval(-60),
                fiveHourResetAt: node, weeklyResetAt: nil, fileURL: URL(fileURLWithPath: "/fixture/held.jsonl"))
            for offset in [180.0, 181, 600] {
                let time = node.addingTimeInterval(offset)
                let plan = planner.plan(now: time, calendar: shanghai, enabled: true, autoResume: true,
                    earlyRecoveryPolicy: "keepPlan", usage: idle(at: time), blocked: [target], heldForPlan: true)
                check((plan.date == time) == (offset == 180), "held continuation retains its three-minute grace at \(offset) seconds")
            }
            let midnight = ScheduleEngine(anchorMinutes: 1200)
            let afterMidnight = date("2026-10-03T17:03:16Z")
            let midnightPlan = DecisionEngine(schedule: midnight).plan(now: afterMidnight, calendar: shanghai,
                enabled: true, autoResume: false, earlyRecoveryPolicy: "ask", usage: idle(at: afterMidnight), blocked: [])
            check(midnightPlan.date == afterMidnight && midnightPlan.decision == .ping(reason: "计划节点，当前无窗口"),
                "keep-alive grace finds yesterday's schedule node across local midnight")

            let menuNode = schedule.nodes(on: now)[1]
            let windowStart = menuNode.addingTimeInterval(188)
            var menuUsage = idle(at: windowStart.addingTimeInterval(30)); menuUsage.fiveHour?.usedPercent = 1
            menuUsage.fiveHour?.resetsAt = windowStart.addingTimeInterval(18000)
            let menuPlan = planner.plan(now: menuUsage.capturedAt, enabled: true, autoResume: false,
                earlyRecoveryPolicy: "ask", usage: menuUsage, blocked: [])
            let menu = MenuSummary.build(plan: menuPlan, usage: menuUsage, schedule: schedule, tasks: [], now: menuUsage.capturedAt)
            check(menu.badge == "计划内" && menu.action == "保持活动" && menu.timeline.first?.date == windowStart,
                "a 13:03:08 keep-alive window is shown on plan at its real start time")
            let lateStart = menuNode.addingTimeInterval(608)
            menuUsage.capturedAt = lateStart.addingTimeInterval(30); menuUsage.fiveHour?.resetsAt = lateStart.addingTimeInterval(18000)
            let latePlan = planner.plan(now: menuUsage.capturedAt, enabled: true, autoResume: false,
                earlyRecoveryPolicy: "ask", usage: menuUsage, blocked: [])
            let confirmed = ExecutionConfirmation(kind: .keepAlive, actionAt: menuNode.addingTimeInterval(599),
                confirmedAt: menuUsage.capturedAt, windowStart: lateStart)
            let confirmedMenu = MenuSummary.build(plan: latePlan, usage: menuUsage, schedule: schedule, tasks: [],
                confirmations: [confirmed], now: menuUsage.capturedAt)
            check(confirmedMenu.badge == "计划内" && confirmedMenu.timeline.first?.kind == .completedKeepAlive && confirmedMenu.timeline.first?.date == lateStart,
                "a legal late keep-alive confirmed just beyond grace remains on plan without moving the real window")
            check(MenuSummary.build(plan: latePlan, usage: menuUsage, schedule: schedule, tasks: [], now: menuUsage.capturedAt).badge == "计划外",
                "a window beyond grace needs matching confirmation to claim a scheduled keep-alive")
            let gapReset = menuNode.addingTimeInterval(-300)
            menuUsage.capturedAt = menuNode.addingTimeInterval(-600); menuUsage.fiveHour?.resetsAt = gapReset
            let gapPlan = planner.plan(now: menuUsage.capturedAt, enabled: true, autoResume: false,
                earlyRecoveryPolicy: "ask", usage: menuUsage, blocked: [])
            let gapMenu = MenuSummary.build(plan: gapPlan, usage: menuUsage, schedule: schedule, tasks: [], now: menuUsage.capturedAt)
            check(gapMenu.timeline.map(\.kind) == [.start, .reset, .keepAlive] && gapMenu.timeline[1].date == gapReset &&
                gapMenu.timeline.last?.solidBefore == false,
                "12:55 expiry and 13:00 keep-alive retain the real five-minute timeline gap")
        }
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
        // A fresh poll from before the quota stop does not prove that the stopped task recovered.
        do {
            let blockedAt = date("2026-09-27T17:48:08Z")
            let reset = date("2026-09-27T20:07:35Z")
            let observed = date("2026-09-27T17:48:23Z")
            let target = BlockedSession(id: "snapshot-before-stop", project: "Recovery", cwd: "/fixture",
                blockedAt: blockedAt, fiveHourResetAt: reset, weeklyResetAt: nil,
                fileURL: URL(fileURLWithPath: "/fixture/rollout.jsonl"))
            var live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 97, windowMinutes: 300, resetsAt: reset),
                weekly: QuotaWindow(usedPercent: 32, windowMinutes: 10080, resetsAt: reset.addingTimeInterval(604800)),
                capturedAt: date("2026-09-27T17:48:04Z"), accountID: "timing-account", sourceFile: "app-server")
            func available(_ snapshot: UsageSnapshot?, account: String? = "timing-account") -> Bool {
                UsageRecovery.hasAvailableQuota(for: target, usage: snapshot, boundAccount: account, now: observed)
            }
            check(!available(live), "fresh 97-percent snapshot captured four seconds before the stop cannot create a recovery decision")
            live.capturedAt = blockedAt
            check(!available(live), "a snapshot captured at the stop cannot prove recovery either")
            live.capturedAt = observed
            check(available(live), "available quota sampled after the stop remains eligible for an early-recovery decision")
            check(!available(nil) && !available(live, account: nil) && !available(live, account: " ") && !available(live, account: "other"),
                "recovery reminder still requires a live snapshot and matching nonempty account binding")
            var changed = live; changed.capturedAt = observed.addingTimeInterval(-61)
            check(!available(changed), "a stale sample cannot establish reminder eligibility")
            changed = live; changed.sourceFile = "rollout.jsonl"
            check(!available(changed), "rollout fallback cannot establish reminder eligibility")
            changed = live; changed.fiveHour = nil
            check(!available(changed), "a stopped five-hour window must exist in the recovery sample")
            changed = live; changed.weekly?.usedPercent = 100
            check(!available(changed), "weekly exhaustion still prevents a recovery decision")
            let node = date("2026-09-28T00:00:00Z")
            let atNodeTarget = BlockedSession(id: target.id, project: target.project, cwd: target.cwd, blockedAt: node,
                fiveHourResetAt: node.addingTimeInterval(18000), weeklyResetAt: nil, fileURL: target.fileURL)
            var shanghai = cal; shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            for offset in [-4.0, 0.0] {
                changed = live; changed.capturedAt = node.addingTimeInterval(offset); changed.fiveHour?.resetsAt = node.addingTimeInterval(18000)
                let pendingPlan = DecisionEngine(schedule: schedule).plan(now: node.addingTimeInterval(15), calendar: shanghai, enabled: true, autoResume: true,
                    earlyRecoveryPolicy: "ask", usage: changed, blocked: [atNodeTarget])
                check(pendingPlan.date == nil && pendingPlan.decision == .wait(reason: "等待额度恢复确认"),
                    "a \(Int(offset))-second pre-stop sample cannot authorize continuation inside the scheduled node")
            }

            let recoveredAt = date("2026-09-27T20:07:49Z")
            live.capturedAt = recoveredAt; live.fiveHour?.usedPercent = 0
            live.fiveHour?.resetsAt = recoveredAt.addingTimeInterval(18000); live.zeroUseWindowActive = false
            let recovered = UsageRecovery.canResumeAfterScheduledReset(target, usage: live, boundAccount: "timing-account", now: recoveredAt)
            let protected = DecisionEngine(schedule: schedule).plan(now: recoveredAt, calendar: shanghai, enabled: true, autoResume: true,
                earlyRecoveryPolicy: "ask", usage: live, blocked: [target], observedRecovery: recovered)
            check(recovered && protected.date == date("2026-09-28T00:00:00Z") && protected.decision == .wait(reason: "按计划自动继续"),
                "04:07 Beijing natural recovery waits through the 03:00-08:00 anchor protection interval")
        }
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
        // Early recovery waits for a choice, including at a scheduled node.
        do {
            let at = date("2026-09-27T10:30:00Z")
            let windowReset = date("2026-09-27T15:11:00Z")
            let task = BlockedSession(id: "early-weekly", project: "Lithe", cwd: "/tmp", blockedAt: date("2026-09-25T15:03:00Z"),
                fiveHourResetAt: nil, weeklyResetAt: date("2026-09-29T06:47:00Z"), fileURL: URL(fileURLWithPath: "/tmp/early-weekly"))
            var live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 5, windowMinutes: 300, resetsAt: windowReset),
                weekly: QuotaWindow(usedPercent: 10, windowMinutes: 10080, resetsAt: date("2026-10-04T06:47:00Z")),
                capturedAt: at, accountID: "same-account", sourceFile: "app-server")
            var shanghai = cal; shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let waiting = engine.plan(now: at, calendar: shanghai, enabled: true, autoResume: true,
                earlyRecoveryPolicy: "ask", usage: live, blocked: [task])
            check(waiting.date == nil && waiting.needsRecoveryDecision && waiting.decision == .wait(reason: "额度已恢复，等待决定"),
                "early weekly recovery retains a reminder without promising an automatic continuation")
            let node = date("2026-09-27T15:00:00Z")
            live.capturedAt = node
            let atNode = engine.plan(now: node, calendar: shanghai, enabled: true, autoResume: true,
                earlyRecoveryPolicy: "ask", usage: live, blocked: [task])
            check(atNode.date == nil && atNode.needsRecoveryDecision && atNode.decision == .wait(reason: "额度已恢复，等待决定"),
                "an unanswered early-recovery reminder cannot continue automatically at 23:00")
            live.capturedAt = at
            var keepAlivePlan = engine.plan(now: at, calendar: shanghai, enabled: true, autoResume: false, earlyRecoveryPolicy: "keepPlan", usage: live, blocked: [])
            keepAlivePlan.needsRecoveryDecision = true
            let summary = MenuSummary.build(plan: keepAlivePlan, usage: live, schedule: schedule, tasks: [task], now: at)
            let clock = DateFormatter(); clock.dateFormat = "HH:mm"
            check(summary.headline == clock.string(from: windowReset) && summary.action == "额度重置" && summary.statusSymbol == "arrow.clockwise.circle.fill" && summary.badge == "计划外" && summary.tasks == [task.displayName],
                "an unanswered task retains its entry while the off-plan idle window shows the real reset")
        }
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
        var transientConnections = 0
        let transientTransport = CountingUsageTransport()
        transientTransport.onRequest = { call in
            if call == 1 { throw CodexConnectionError.server("error sending request") }
        }
        let transientProvider = AppServerUsageProvider(makeTransport: {
            transientConnections += 1
            return transientTransport
        }, contextIdentity: { nil }, uptime: { testUptime })
        check((try? transientProvider.read().fiveHour?.usedPercent) == 2,
            "one transient rate-limit connection error retries the read")
        check(transientTransport.calls == 2 && transientConnections == 1 && transientTransport.closes == 0,
            "transient retry reuses the app-server process")
        let repeatedNetworkTransport = CountingUsageTransport()
        repeatedNetworkTransport.onRequest = { _ in throw CodexConnectionError.server("error sending request") }
        let repeatedNetworkProvider = AppServerUsageProvider(makeTransport: { repeatedNetworkTransport },
            contextIdentity: { nil }, uptime: { testUptime })
        check((try? repeatedNetworkProvider.read()) == nil && repeatedNetworkTransport.calls == 2 && repeatedNetworkTransport.closes == 0,
            "persistent upstream error retries only once before cooldown without closing healthy stdio")
        for message in ["error sending request", "request timed out", "workspace routing discovery timeout", "unexpected status code: 503"] {
            var clock: TimeInterval = 100
            var connections = 0
            let connection = CountingUsageTransport()
            let failedCalls = message == "error sending request" ? 2 : 1
            connection.onRequest = { call in
                if call <= failedCalls { throw CodexConnectionError.server(message) }
            }
            let provider = AppServerUsageProvider(makeTransport: {
                connections += 1
                return connection
            }, contextIdentity: { nil }, uptime: { clock })
            check((try? provider.read()) == nil && connection.calls == failedCalls && connection.closes == 0,
                "complete retryable server error retains its healthy connection: \(message)")
            for _ in 0..<10 { _ = try? provider.read() }
            check(connections == 1 && connection.calls == failedCalls,
                "retained server connection still respects background cooldown: \(message)")
            clock += 20
            let recovered = try? provider.read()
            check(recovered?.sourceFile == "app-server" && connections == 1 && connection.closes == 0 && connection.calls == failedCalls + 1,
                "poll after cooldown recovers on the same server connection: \(message)")
        }
        for error in [CodexConnectionError.timeout, .ended, .invalidResponse, .server("HTTP/1.1 401 Unauthorized error sending request"), .server("unrecognized server failure")] {
            let connection = CountingUsageTransport()
            connection.onRequest = { _ in throw error }
            let provider = AppServerUsageProvider(makeTransport: { connection }, contextIdentity: { nil })
            check((try? provider.read()) == nil && connection.closes == 1 && connection.calls == 1,
                "transport, authentication and unknown errors close without the upstream retry: \(UsageReadFailure.reason(for: error))")
        }
        for authUnavailable in [false, true] {
            var authChanged = false
            let connection = CountingUsageTransport()
            connection.onRequest = { _ in
                authChanged = true
                throw CodexConnectionError.server("unexpected status code: 503")
            }
            let provider = AppServerUsageProvider(makeTransport: { connection }, contextIdentity: {
                if authChanged && authUnavailable { throw CocoaError(.fileReadNoPermission) }
                return Data((authChanged ? "changed-account" : "initial-account").utf8)
            })
            check((try? provider.read()) == nil && connection.closes == 1,
                "retryable RPC error cannot retain a changed or unreadable authentication context: \(authUnavailable)")
        }
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
        do { _ = try failingProvider.read(); check(false, "cooldown must report a read failure") }
        catch let failure as UsageReadFailure {
            check(failure.diagnostic.requestStage == "cooldown" && failure.diagnostic.rpcAttempted == false &&
                failure.diagnostic.cooldown && failure.diagnostic.reason == "connection_ended" && UsageReadFailure.canRetry(failure),
                "failure cooldown reports no new Keeper RPC and retains the transient error category")
        }
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
        let initializingFailure = AppServerUsageProvider(makeTransport: { throw CodexConnectionError.timeout }, contextIdentity: { nil })
        do { _ = try initializingFailure.read(); check(false, "initialization timeout must reject the read") }
        catch let failure as UsageReadFailure {
            check(failure.diagnostic.requestStage == "connection" && failure.diagnostic.rpcAttempted == nil && !failure.diagnostic.cooldown,
                "connection initialization failure leaves internal Keeper RPC activity unknown")
        }
        let numberedFailure = CodexConnectionError.server("error sending request id=403000 endpoint port=1401")
        check(UsageReadFailure.reason(for: numberedFailure) == "connection_failed" && UsageReadFailure.canRetry(numberedFailure),
            "numbers in request identities and ports cannot be mistaken for authentication status")
        check(["unexpected status code: 401", "HTTP/1.1 403 Forbidden"].allSatisfy {
            UsageReadFailure.reason(for: CodexConnectionError.server($0)) == "authentication_failed" &&
                !UsageReadFailure.canRetry(CodexConnectionError.server($0))
        }, "explicit HTTP authentication status remains terminal for verification")

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
        check(failedSync.headline == "待同步" && failedSync.statusText == "待同步" && !failedSync.isSyncing,
            "idle retry cooldown explicitly waits for sync without reporting an execution failure")
        var retryingSync = MenuSummary(headline: "正在同步", isSyncing: true)
        retryingSync.applyUsageRefreshState(refreshing: true, error: "连接超时")
        check(retryingSync.isSyncing && retryingSync.statusText == "同步中" && retryingSync.note.contains("重新同步"),
            "active manual retry has an explicit syncing status instead of a dash")
        var firstSync = MenuSummary(headline: "正在同步", isSyncing: true)
        firstSync.applyUsageRefreshState(refreshing: false, error: nil)
        check(firstSync.headline == "待同步" && firstSync.statusText == "待同步", "initial idle synchronization has an explicit waiting status")
        var recoveredSync = MenuSummary(headline: "14:20", action: "保持活动", isTime: true)
        recoveredSync.applyIssues(usageError: nil, sessionError: nil, executionFailure: "连接失败", executionAction: "保活")
        check(recoveredSync.error.isEmpty && recoveredSync.note.contains("上次保活失败") && recoveredSync.warning.isEmpty && recoveredSync.statusSymbol == "waveform.path.ecg",
            "viewed execution failure remains in expanded history without controlling a recovered status icon")
        for action in ["保活", "自动继续"] {
            var unseenFailure = MenuSummary(headline: "14:20", action: action, isTime: true)
            unseenFailure.applyIssues(usageError: nil, sessionError: nil, executionFailure: "本次执行失败", executionAction: action,
                executionFailureIsCurrent: true)
            check(unseenFailure.statusSymbol == "exclamationmark.circle" && !unseenFailure.warning.isEmpty && unseenFailure.note.contains("本次执行失败"),
                "unviewed current execution failure remains a status warning: \(action)")
        }
        var currentSyncFailure = MenuSummary(headline: "正在同步", isSyncing: true)
        currentSyncFailure.applyIssues(usageError: "当前额度读取失败", sessionError: nil,
            executionFailure: "旧保活失败", executionAction: "保活")
        check(currentSyncFailure.error == "当前额度读取失败" && currentSyncFailure.note.contains("旧保活失败") && currentSyncFailure.statusSymbol == "exclamationmark.circle",
            "actionable quota failure keeps its warning while execution history remains separately visible")
        var freshSyncFailure = MenuSummary(headline: "14:20", action: "保持活动", isTime: true)
        freshSyncFailure.applyIssues(usageError: "后台暂时连接失败", sessionError: nil, executionFailure: nil, executionAction: "保活",
            usageErrorIsTransient: true)
        freshSyncFailure.applyUsageRefreshState(refreshing: false, error: "后台暂时连接失败")
        check(freshSyncFailure.headline == "14:20" && freshSyncFailure.isTime && freshSyncFailure.statusSymbol == "waveform.path.ecg" && !freshSyncFailure.error.isEmpty,
            "temporary background failure retains a fresh plan and normal icon while showing error details")
        var pendingSyncFailure = MenuSummary(headline: "正在同步", isSyncing: true)
        pendingSyncFailure.applyIssues(usageError: "后台暂时连接失败", sessionError: nil, executionFailure: nil, executionAction: "保活",
            usageErrorIsTransient: true)
        pendingSyncFailure.applyUsageRefreshState(refreshing: false, error: "后台暂时连接失败")
        check(pendingSyncFailure.statusText == "待同步" && pendingSyncFailure.statusSymbol == "arrow.triangle.2.circlepath" && !pendingSyncFailure.error.isEmpty,
            "temporary failure without a fresh reading waits for sync instead of warning about execution")
        freshSyncFailure.applyIssues(usageError: "后台暂时连接失败", sessionError: "任务扫描不兼容", executionFailure: nil, executionAction: "保活",
            usageErrorIsTransient: true)
        check(freshSyncFailure.statusSymbol == "exclamationmark.circle" && freshSyncFailure.error.contains("任务扫描不兼容") && freshSyncFailure.error.contains("后台暂时连接失败"),
            "a temporary quota error cannot hide an actionable task scanning error")

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
        do { _ = try changedAccountProvider.read(); check(false, "changed-account cooldown must reject confirmation") }
        catch let failure as UsageReadFailure {
            check(failure.diagnostic.cooldown && failure.diagnostic.reason == "account_changed" && !UsageReadFailure.canRetry(failure),
                "account changes remain terminal even when the provider returns a cooled failure")
        }
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
        let displayQuota = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: localNode.addingTimeInterval(660)), weekly: nil, capturedAt: localNode, sourceFile: "app-server")
        let displayPlan = engine.plan(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: displayQuota, blocked: [])
        let display = MenuSummary.build(plan: displayPlan, usage: displayQuota, schedule: schedule, tasks: [], now: localNode)
        check(display.headline == "13:11" && display.action == "额度重置" && display.badge == "计划外", "off-plan menu highlights real reset without promising scheduled ping")
        check(display.note.isEmpty && display.timeline.map(\.time) == ["08:11", "13:11", "18:00"], "off-plan timeline replaces conditional paragraph with real window and plan")
        check(display.timeline.map(\.solidBefore) == [false, true, false], "actual window uses solid line and waiting uses dotted line")
        check(display.statusText == "13:11", "menu bar displays the actual next reset instead of plan status or conditional keepalive")
        var stoppedUsage = displayQuota; stoppedUsage.fiveHour?.usedPercent = 100
        let stoppedTask = BlockedSession(id: "current", project: "Codex Keeper", cwd: "/tmp", blockedAt: localNode, fiveHourResetAt: localNode.addingTimeInterval(660), weeklyResetAt: nil, fileURL: URL(fileURLWithPath: "/tmp/current"))
        let stoppedPlan = engine.plan(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: stoppedUsage, blocked: [stoppedTask])
        let stoppedMenu = MenuSummary.build(plan: stoppedPlan, usage: stoppedUsage, schedule: schedule, tasks: [stoppedTask], now: localNode)
        check(stoppedPlan.mode == .resume && stoppedPlan.date == displayQuota.fiveHour?.resetsAt, "quota-stop changes next action from 18:00 ping to 13:11 resume")
        check(stoppedMenu.timeline.map(\.time) == ["08:11", "13:11"] && stoppedMenu.timeline.last?.kind == .resume, "resume merges reset and continue into one point without 18:00 ping")
        check(stoppedMenu.badge == "计划外" && stoppedMenu.taskCount == 1, "pending task does not replace plan status badge")
        check(display.timeline.map(\.symbol) == ["circle.fill", "arrow.clockwise.circle.fill", "waveform.path.ecg"], "off-plan timeline uses requested native symbols")
        check(stoppedMenu.timeline.last?.symbol == "paperplane", "resume action uses paperplane without enclosing circle")
        let confirmation = ExecutionConfirmation(kind: .resume, actionAt: localNode.addingTimeInterval(-17340), confirmedAt: localNode, windowStart: nil)
        let completedMenu = MenuSummary.build(plan: displayPlan, usage: displayQuota, schedule: schedule, tasks: [], confirmations: [confirmation], now: localNode)
        check(completedMenu.timeline.first?.symbol == "checkmark.circle.fill", "confirmed off-plan resume marks actual start complete")
        let unrelatedConfirmation = ExecutionConfirmation(kind: .keepAlive, actionAt: localNode.addingTimeInterval(-18000), confirmedAt: localNode, windowStart: nil)
        check(MenuSummary.build(plan: displayPlan, usage: displayQuota, schedule: schedule, tasks: [], confirmations: [unrelatedConfirmation], now: localNode).timeline.first?.kind == .start, "unrelated successful operation cannot mark current window as Keeper controlled")
        let recoveredAt = localNode.addingTimeInterval(670)
        let recoveredUsage = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: recoveredAt.addingTimeInterval(18000)), weekly: nil, capturedAt: recoveredAt, sourceFile: "app-server", zeroUseWindowActive: false)
        let recoveredPlan = engine.plan(now: recoveredAt, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: recoveredUsage, blocked: [stoppedTask], observedRecovery: true)
        if case .resume = recoveredPlan.decision { check(true, "confirmed natural recovery executes pending task at 13:11") }
        else { check(false, "confirmed natural recovery executes pending task at 13:11") }
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
        // Unanswered reminders retain their task while the main time follows normal keep-alive.
        do {
            let start = schedule.nodes(on: now)[0]
            let at = start.addingTimeInterval(900)
            let task = BlockedSession(id: "planned-waiting", project: "Recovery", cwd: "/fixture",
                blockedAt: start.addingTimeInterval(-600), fiveHourResetAt: nil, weeklyResetAt: nil,
                fileURL: URL(fileURLWithPath: "/fixture/planned-waiting.jsonl"))
            var choices = ResumeChoices(); choices.requestRecoveryDecision(for: task, now: at)
            var live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 5, windowMinutes: 300, resetsAt: start.addingTimeInterval(18000)),
                weekly: nil, capturedAt: at, accountID: "timing-account", sourceFile: "app-server")
            let clock = DateFormatter(); clock.dateFormat = "HH:mm"
            func waitingMenu(_ quota: UsageSnapshot, confirmations: [ExecutionConfirmation] = []) -> MenuSummary {
                var plan = engine.plan(now: at, enabled: true, autoResume: false, earlyRecoveryPolicy: "keepPlan", usage: quota, blocked: [])
                plan.needsRecoveryDecision = true
                var summary = MenuSummary.build(plan: plan, usage: quota, schedule: schedule, tasks: [task], confirmations: confirmations, now: at)
                summary.applyRecoveryReminder(tasks: [task], choices: choices)
                return summary
            }
            for drift in [0.0, 103.0, 180.0] {
                live.fiveHour?.resetsAt = start.addingTimeInterval(18000 + drift)
                let confirmed = ExecutionConfirmation(kind: .keepAlive, actionAt: start.addingTimeInterval(drift),
                    confirmedAt: at, windowStart: start.addingTimeInterval(drift))
                let summary = waitingMenu(live, confirmations: [confirmed])
                let planned = engine.plan(now: at, enabled: true, autoResume: false, earlyRecoveryPolicy: "keepPlan", usage: live, blocked: [])
                let independent = MenuSummary.build(plan: planned, usage: live, schedule: schedule, tasks: [task], confirmations: [confirmed], now: at)
                check(summary.headline == independent.headline && summary.action == "保持活动" && summary.statusSymbol == "waveform.path.ecg" && summary.badge == "计划内",
                    "an unanswered on-plan window shows the normal keep-alive time and icon with \(Int(drift))-second drift")
                check(summary.timeline.map(\.date) == independent.timeline.map(\.date) && summary.timeline.first?.kind == .completedKeepAlive && !summary.timeline.contains { $0.kind == .resume },
                    "an unanswered reminder retains confirmed history without inventing a future continuation with \(Int(drift))-second drift")
                check(summary.tasks == [task.displayName] && summary.taskCount == 1 && !summary.reminderTitle.isEmpty && summary.reminderBody.contains(L10n.text("未选择时，提醒会一直保留，任务不会自动继续。")),
                    "an unanswered window retains its paused task and standalone reminder with \(Int(drift))-second drift")
            }
            live.fiveHour?.resetsAt = start.addingTimeInterval(18000)
            live.weekly = QuotaWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: at.addingTimeInterval(86400))
            let weeklyPlan = engine.plan(now: at, enabled: true, autoResume: false, earlyRecoveryPolicy: "keepPlan", usage: live, blocked: [])
            let exhausted = waitingMenu(live)
            check(exhausted.headline == clock.string(from: weeklyPlan.date!) && exhausted.timeline.contains { $0.kind == .keepAlive && $0.date == weeklyPlan.date } && weeklyPlan.date! > live.fiveHour!.resetsAt,
                "weekly exhaustion moves keep-alive to the next feasible node without approving the unanswered task")
            live.weekly?.resetsAt = at.addingTimeInterval(-1)
            let unconfirmed = waitingMenu(live)
            check(!unconfirmed.isTime && unconfirmed.timeline.isEmpty && unconfirmed.action.isEmpty,
                "elapsed weekly exhaustion without confirmation never fabricates an action time")
            live.weekly = nil; live.fiveHour?.resetsAt = start.addingTimeInterval(18660)
            let offPlan = waitingMenu(live)
            check(offPlan.action == "额度重置" && offPlan.statusSymbol == "arrow.clockwise.circle.fill" && offPlan.badge == "计划外" && offPlan.headline == clock.string(from: live.fiveHour!.resetsAt) && !offPlan.reminderTitle.isEmpty,
                "off-plan waiting tasks retain the reminder while showing the real-window reset")
            live.fiveHour?.usedPercent = 0; live.zeroUseWindowActive = false
            let noWindow = waitingMenu(live)
            check(noWindow.isTime && noWindow.action == "保持活动" && noWindow.statusSymbol == "waveform.path.ecg" && noWindow.timeline.map(\.kind) == [.keepAlive] && !noWindow.reminderTitle.isEmpty,
                "available quota without an active window shows normal keep-alive and the unanswered reminder")
            live.zeroUseWindowActive = nil
            let unknownActivity = waitingMenu(live)
            check(unknownActivity.isSyncing && !unknownActivity.isTime && unknownActivity.badge.isEmpty && unknownActivity.quotas.first?.detail == "—" && !unknownActivity.reminderTitle.isEmpty,
                "unknown window activity waits for sync while retaining the unanswered reminder")
            let approvedPlan = engine.plan(now: at, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: live, blocked: [task], heldForPlan: true)
            let approved = MenuSummary.build(plan: approvedPlan, usage: live, schedule: schedule, tasks: [task], now: at)
            check(approved.isTime && approved.action == "自动继续" && approved.statusSymbol == "paperplane" && approved.badge.isEmpty && approved.quotas.first?.detail == "—" && approved.timeline.map(\.kind) == [.resume],
                "an explicitly approved continuation retains its valid plan without inventing unknown window details")
        }
        let resumeMenu = MenuSummary.build(plan: plannedResume, usage: exhaustedEvening, schedule: schedule, tasks: [resetTarget], now: evening)
        check(resumeMenu.action == "自动继续" && resumeMenu.tasks == [resetTarget.displayName], "resume still shows pending task and automatic action")
        let staleMenu = MenuSummary.build(plan: displayPlan, usage: oldEvening, schedule: schedule, tasks: [], now: evening)
        check(staleMenu.headline == "正在同步" && !staleMenu.isTime && staleMenu.badge.isEmpty, "stale quota cannot claim plan status or reset time")
        var expiredDisplayQuota = displayQuota
        expiredDisplayQuota.capturedAt = localNode.addingTimeInterval(-60)
        check(MenuSummary.build(plan: displayPlan, usage: expiredDisplayQuota, schedule: schedule, tasks: [], now: localNode).isTime,
            "a live reading at the 60-second freshness boundary can still show its plan")
        expiredDisplayQuota.capturedAt = localNode.addingTimeInterval(-61)
        var expiredDisplayMenu = MenuSummary.build(plan: displayPlan, usage: expiredDisplayQuota, schedule: schedule, tasks: [], now: localNode)
        expiredDisplayMenu.applyUsageRefreshState(refreshing: false, error: "暂时连接失败")
        check(!expiredDisplayMenu.isTime && expiredDisplayMenu.quotas.isEmpty && expiredDisplayMenu.statusText == "待同步",
            "expired live readings display waiting for sync without exposing stale quota or plan time")
        checkSteadyMenuPresentation(check)
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
        check(engine.decide(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "immediately", usage: onlyWeek, blocked: [pending]) == .wait(reason: "等待额度恢复确认"),
            "a five-hour stop still requires its five-hour window before continuation")
        let weeklyOnlyTarget = BlockedSession(id: pending.id, project: pending.project, cwd: pending.cwd, blockedAt: pending.blockedAt,
            fiveHourResetAt: nil, weeklyResetAt: localNode.addingTimeInterval(-5), fileURL: pending.fileURL)
        let weeklyResume = engine.decide(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "immediately", usage: onlyWeek, blocked: [weeklyOnlyTarget])
        if case .resume = weeklyResume { check(true, "weekly-only supports resume") } else { check(false, "weekly-only supports resume") }
        var stale = onlyWeek; stale.capturedAt = localNode.addingTimeInterval(-61)
        if case .resume = engine.decide(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "immediately", usage: stale, blocked: [weeklyOnlyTarget]) { check(false, "stale snapshot prevents resume") } else { check(true, "stale snapshot prevents resume") }
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
        check(WorkspaceGuard.resumePrompt("继续", before: "old", after: "new", reminderEnabled: true) == WorkspaceGuard.reminder + "\n\n继续", "changed project separates the reminder from selected content")
        check(WorkspaceGuard.resumePrompt("继续", before: nil, after: "new", reminderEnabled: true) == WorkspaceGuard.reminder + "\n\n继续", "missing baseline prompts a check without claiming a detected change")
        check(WorkspaceGuard.resumePrompt("继续", before: "old", after: nil, reminderEnabled: true) == WorkspaceGuard.reminder + "\n\n继续", "unreadable current state receives the same neutral reminder")
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
        quotaFailures=0
        for line in sys.stdin:
            request=json.loads(line)
            method=request['method']
            if method=='initialized': initialized=True; continue
            if method=='initialize':
                assert os.environ.get('CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED') == '1'
                result={'userAgent':'fake'}
            elif method=='account/read': result={'account':{'type':'chatgpt'}}
            elif method=='fail-upstream-rate-limits': quotaFailures=2; result={}
            elif method=='account/rateLimits/read' and quotaFailures:
                quotaFailures-=1
                print(json.dumps({'id':request['id'],'error':{'message':'error sending request'}}),flush=True)
                continue
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
        let healthyErrorClient = try AppServerClient(binary: executable, usageOnly: true)
        let healthyErrorPID = try healthyErrorClient.request("arguments", params: [:])["pid"] as? Int
        _ = try healthyErrorClient.request("fail-upstream-rate-limits", params: [:])
        var healthyErrorClock: TimeInterval = 100
        var healthyErrorConnections = 0
        let healthyErrorProvider = AppServerUsageProvider(makeTransport: {
            healthyErrorConnections += 1
            return healthyErrorClient
        }, contextIdentity: { nil }, accountIdentity: { "healthy-error-fixture" }, uptime: { healthyErrorClock })
        check((try? healthyErrorProvider.read()) == nil && healthyErrorPID.map { kill(Int32($0), 0) == 0 } == true,
            "complete JSON RPC upstream errors leave the real app-server child alive during cooldown")
        healthyErrorClock += 20
        let healthyErrorQuota = try? healthyErrorProvider.read()
        let recoveredErrorPID = try? healthyErrorClient.request("arguments", params: [:])["pid"] as? Int
        check(healthyErrorQuota?.sourceFile == "app-server" && healthyErrorConnections == 1 && recoveredErrorPID == healthyErrorPID,
            "a real JSONL connection recovers after server errors without changing its child PID")
        healthyErrorClient.close()
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
        if case .wait = engine.decide(now: offNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask", usage: recovered, blocked: [naturalTarget]) { check(true, "early or unobserved recovery waits for an explicit choice") } else { check(false, "early or unobserved recovery waits for an explicit choice") }
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
        let nestedCLIPath = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let currentBundles = [runningBundle, URL(fileURLWithPath: "/Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"), locatorHome.appendingPathComponent("Applications/Codex.app"),
            locatorHome.appendingPathComponent("Applications/ChatGPT.app")]
        for bundle in currentBundles {
            let executable = bundle.appendingPathComponent(nestedCLIPath).path
            check((try? CodexLocator.binary(environment: [:], userHome: locatorHome, runningBundles: [runningBundle],
                isExecutable: { $0 == executable }))?.path == executable,
                "locator finds nested CLI without shell PATH: \(bundle.path)")
        }
        let nestedRunningCLI = runningBundle.appendingPathComponent(nestedCLIPath).path
        check((try? CodexLocator.binary(environment: ["PATH": "/custom/bin"], userHome: locatorHome, runningBundles: [runningBundle],
            isExecutable: { [nestedRunningCLI, userCLI, "/Applications/Codex.app/Contents/Resources/codex", "/custom/bin/codex"].contains($0) }))?.path == nestedRunningCLI,
            "running official nested CLI takes priority over other installations and PATH")
        let manualCLI = locatorHome.appendingPathComponent("manual CLI/codex")
        try FileManager.default.createDirectory(at: manualCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: manualCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: manualCLI.path)
        check((try? CodexLocator.binary(environment: [:], userHome: locatorHome, runningBundles: [],
            fallbackPath: manualCLI.path, isExecutable: { _ in false })) == manualCLI,
            "locator uses saved executable only when all automatic candidates are missing")
        check((try? CodexLocator.binary(environment: [:], userHome: locatorHome, runningBundles: [],
            fallbackPath: " \n~/manual CLI/codex\t ", isExecutable: { _ in false })) == manualCLI,
            "manual CLI fallback trims whitespace and expands tilde while preserving spaces")
        check((try? CodexLocator.binary(environment: [:], userHome: locatorHome, runningBundles: [runningBundle],
            fallbackPath: manualCLI.path, isExecutable: { $0 == nestedRunningCLI }))?.path == nestedRunningCLI,
            "automatic CLI discovery takes priority over a valid manual fallback")
        check((try? CodexLocator.binary(environment: ["PATH": "/custom/bin"], userHome: locatorHome, runningBundles: [],
            fallbackPath: "relative/invalid", isExecutable: { $0 == "/custom/bin/codex" }))?.path == "/custom/bin/codex",
            "a stale manual fallback cannot block successful automatic discovery")
        check(try CodexLocator.validateFallbackPath(" \n\t ", userHome: locatorHome) == nil,
            "blank manual CLI path clears fallback")
        let nonExecutableCLI = manualCLI.deletingLastPathComponent().appendingPathComponent("not-executable")
        try Data().write(to: nonExecutableCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutableCLI.path)
        let linkedCLI = manualCLI.deletingLastPathComponent().appendingPathComponent("codex-link")
        let linkedDirectory = manualCLI.deletingLastPathComponent().appendingPathComponent("directory-link")
        let brokenCLI = manualCLI.deletingLastPathComponent().appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(at: linkedCLI, withDestinationURL: manualCLI)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: manualCLI.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: brokenCLI, withDestinationURL: locatorHome.appendingPathComponent("missing"))
        check(try CodexLocator.validateFallbackPath(linkedCLI.path) == linkedCLI,
            "manual CLI accepts executable symlinks and preserves the link path")
        let literalCLI = manualCLI.deletingLastPathComponent().appendingPathComponent("codex $(literal) ; file")
        try FileManager.default.copyItem(at: manualCLI, to: literalCLI)
        check(try CodexLocator.validateFallbackPath(literalCLI.path)?.path == literalCLI.path,
            "manual CLI treats shell metacharacters as literal filename characters")
        for (path, expected) in [("relative/codex", CodexCLIPathError.relative), ("$HOME/codex", .relative),
            (locatorHome.appendingPathComponent("missing").path, .missing), (brokenCLI.path, .missing),
            (manualCLI.deletingLastPathComponent().path, .notFile), (linkedDirectory.path, .notFile),
            (nonExecutableCLI.path, .notExecutable)] {
            do {
                _ = try CodexLocator.validateFallbackPath(path, userHome: locatorHome)
                check(false, "manual CLI rejects invalid path: \(path)")
            } catch {
                check(error as? CodexCLIPathError == expected && !error.localizedDescription.isEmpty,
                    "manual CLI returns a localized validation error: \(expected)")
            }
        }
        let fallbackSuite = "keeper.cli-fallback.tests." + UUID().uuidString
        let fallbackDefaults = UserDefaults(suiteName: fallbackSuite)!
        defer { fallbackDefaults.removePersistentDomain(forName: fallbackSuite) }
        check(try CodexLocator.saveFallbackPath(" \n~/manual CLI/codex\t", defaults: fallbackDefaults, userHome: locatorHome) == manualCLI.path &&
            fallbackDefaults.string(forKey: CodexLocator.fallbackPathKey) == manualCLI.path,
            "saving manual CLI persists the validated absolute path")
        check((try? CodexLocator.saveFallbackPath(nonExecutableCLI.path, defaults: fallbackDefaults)) == nil &&
            fallbackDefaults.string(forKey: CodexLocator.fallbackPathKey) == manualCLI.path,
            "invalid manual CLI save preserves the previous valid setting")
        check(try CodexLocator.saveFallbackPath(" \n ", defaults: fallbackDefaults).isEmpty &&
            fallbackDefaults.object(forKey: CodexLocator.fallbackPathKey) == nil,
            "saving blank removes the stored CLI fallback")
        check((try? CodexLocator.binary(environment: [:], userHome: locatorHome, runningBundles: [],
            fallbackPath: fallbackDefaults.string(forKey: CodexLocator.fallbackPathKey), isExecutable: { _ in false })) == nil,
            "cleared fallback cannot be reused when automatic discovery fails")

        var fallbackClock: TimeInterval = 100
        var fallbackFailures = 0
        let fallbackFailureProvider = AppServerUsageProvider(makeTransport: {
            fallbackFailures += 1; throw CodexConnectionError.unavailable
        }, contextIdentity: { nil }, fallbackPath: { fallbackDefaults.string(forKey: CodexLocator.fallbackPathKey) }, uptime: { fallbackClock })
        _ = try? fallbackFailureProvider.read()
        _ = try? fallbackFailureProvider.readForUserRefresh()
        try CodexLocator.saveFallbackPath(manualCLI.path, defaults: fallbackDefaults)
        _ = try? fallbackFailureProvider.read()
        check(fallbackFailures == 2, "a changed fallback does not bypass background failure backoff")
        _ = try? fallbackFailureProvider.readForUserRefresh()
        check(fallbackFailures == 3, "a saved path change permits one immediate manual retry inside the five-second limit")
        for _ in 0..<10 {
            try CodexLocator.saveFallbackPath("  " + manualCLI.path + "  ", defaults: fallbackDefaults)
            _ = try? fallbackFailureProvider.readForUserRefresh()
            _ = try? fallbackFailureProvider.read()
        }
        check(fallbackFailures == 3, "equivalent saves and repeated reads retain manual throttling and background backoff")
        fallbackClock += 5
        _ = try? fallbackFailureProvider.readForUserRefresh()
        check(fallbackFailures == 4, "failure after changed-path retry still uses the existing five-second manual cooldown")
        try CodexLocator.saveFallbackPath("", defaults: fallbackDefaults)
        _ = try? fallbackFailureProvider.readForUserRefresh()
        check(fallbackFailures == 5, "clearing the saved path also permits one explicit retry")

        var fallbackConnections = 0
        let fallbackTransport = CountingUsageTransport()
        let fallbackProvider = AppServerUsageProvider(makeTransport: {
            fallbackConnections += 1
            _ = try CodexLocator.binary(environment: [:], userHome: locatorHome, runningBundles: [],
                fallbackPath: fallbackDefaults.string(forKey: CodexLocator.fallbackPathKey), isExecutable: { _ in false })
            return fallbackTransport
        }, contextIdentity: { nil }, fallbackPath: { fallbackDefaults.string(forKey: CodexLocator.fallbackPathKey) }, uptime: { fallbackClock })
        _ = try? fallbackProvider.read()
        _ = try? fallbackProvider.readForUserRefresh()
        let fallbackRuntime = temp.appendingPathComponent("fallback-support/pending-runtime.json")
        let fallbackState = AppState(provider: fallbackProvider, defaults: fallbackDefaults, runtimeURL: fallbackRuntime,
            codexHome: locatorHome, startMonitoring: false)
        try CodexLocator.saveFallbackPath(manualCLI.path, defaults: fallbackDefaults)
        for _ in 0..<300 {
            if fallbackConnections == 3 && !fallbackState.usage.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(fallbackConnections == 3 && fallbackState.usage.snapshot?.sourceFile == "app-server" && fallbackState.usage.lastError == nil,
            "saving a fallback drives AppState's immediate manual quota retry without restart")
        try CodexLocator.saveFallbackPath(manualCLI.path, defaults: fallbackDefaults)
        _ = try? CodexLocator.saveFallbackPath(nonExecutableCLI.path, defaults: fallbackDefaults)
        try await Task.sleep(nanoseconds: 50_000_000)
        check(fallbackTransport.calls == 1, "unchanged or invalid saves do not enqueue another quota refresh")
        fallbackTransport.delay = 0.05
        fallbackState.usage.refresh()
        try CodexLocator.saveFallbackPath("", defaults: fallbackDefaults)
        for _ in 0..<300 {
            if fallbackTransport.calls == 3 && !fallbackState.usage.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(fallbackTransport.calls == 3 && fallbackConnections == 3 && fallbackTransport.closes == 0 && fallbackTransport.maxActive == 1,
            "path changes queue one read behind active quota work and reuse its healthy connection")
        let fallbackEvents = try String(contentsOf: fallbackRuntime.deletingLastPathComponent().appendingPathComponent("usage-transitions.jsonl"), encoding: .utf8)
        check(fallbackEvents.contains("cli_path") && fallbackEvents.contains("usage_refresh_queued"),
            "saved-path refreshes use the existing manual-refresh diagnostic flow")
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
        let readFailure = eventRows.first { $0["event"] as? String == "usage_read_failed" }
        check(readFailure?["request_stage"] as? String == "rate_limits" && readFailure?["rpc_attempted"] as? Bool == true &&
            readFailure?["cooldown"] as? Bool == false && (readFailure?["elapsed_ms"] as? Int ?? -1) >= 100,
            "quota failure diagnostics name the actual Keeper RPC stage and monotonic duration")
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
        successTransport.onRequest = { _ in throw CodexConnectionError.server("unexpected status code: 503") }
        let recentCapture = successObserver.snapshot?.capturedAt
        successObserver.refresh()
        for _ in 0..<300 { if !successObserver.refreshing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check(successObserver.lastErrorIsTransient && successObserver.snapshot?.capturedAt == recentCapture && successObserver.snapshot?.isFresh(at: Date()) == true,
            "temporary failure preserves only the existing live reading without refreshing its timestamp")
        successObserver.invalidate()
        successObserver.refresh()
        for _ in 0..<300 { if !successObserver.refreshing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check(successObserver.lastErrorIsTransient && successObserver.snapshot == nil,
            "a retry cooldown cannot resurrect an invalidated reading for decisions or display")
        successTransport.onRequest = { _ in }
        let accountFailureTransport = CountingUsageTransport()
        accountFailureTransport.onRequest = { call in
            if call > 1 { throw CodexConnectionError.server("HTTP/1.1 401 Unauthorized") }
        }
        let accountFailureObserver = UsageObserver(codexHome: fakeHome,
            provider: AppServerUsageProvider(makeTransport: { accountFailureTransport }, contextIdentity: { nil }),
            logURL: temp.appendingPathComponent("refresh-account-failure.jsonl"))
        accountFailureObserver.refresh()
        for _ in 0..<300 { if !accountFailureObserver.refreshing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check(accountFailureObserver.snapshot?.isFresh(at: Date()) == true, "account failure fixture starts with a fresh live reading")
        accountFailureObserver.refresh()
        for _ in 0..<300 { if !accountFailureObserver.refreshing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check(accountFailureObserver.lastError != nil && !accountFailureObserver.lastErrorIsTransient && accountFailureObserver.snapshot == nil && accountFailureTransport.closes == 1,
            "authentication failure discards the recent account reading instead of continuing to trust it")
        for message in ["unexpected status code: 503", "error sending request"] {
            for authUnreadable in [false, true] {
                var authenticationFailed = false
                let connection = CountingUsageTransport()
                connection.onRequest = { call in
                    if call > 1 {
                        authenticationFailed = true
                        throw CodexConnectionError.server(message)
                    }
                }
                let provider = AppServerUsageProvider(makeTransport: { connection }, contextIdentity: {
                    if authenticationFailed && authUnreadable { throw CocoaError(.fileReadNoPermission) }
                    return Data((authenticationFailed ? "changed-account" : "initial-account").utf8)
                })
                let failureLog = temp.appendingPathComponent("network-auth-failure-\(UUID().uuidString).jsonl")
                let observer = UsageObserver(codexHome: fakeHome, provider: provider, logURL: failureLog)
                observer.refresh()
                for _ in 0..<300 { if !observer.refreshing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
                check(observer.snapshot?.isFresh(at: Date()) == true, "network/authentication fixture begins with live quota")
                observer.refresh()
                for _ in 0..<300 { if !observer.refreshing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
                check(observer.lastError != nil && !observer.lastErrorIsTransient && observer.snapshot == nil && connection.closes == 1 && connection.calls == 2,
                    "authentication fault during RPC failure clears live quota and stops the immediate retry: \(message), unreadable=\(authUnreadable)")
                let rows = try String(contentsOf: failureLog, encoding: .utf8).split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
                let failure = rows.first { $0["event"] as? String == "usage_read_failed" }
                check(failure?["request_stage"] as? String == "authentication" &&
                    failure?["reason"] as? String == (authUnreadable ? "authentication_failed" : "account_changed"),
                    "authentication evidence takes priority over the simultaneous upstream error: \(message), unreadable=\(authUnreadable)")
                do { _ = try provider.read(); check(false, "authentication fault remains cooled") }
                catch let failure as UsageReadFailure {
                    check(failure.diagnostic.cooldown && !UsageReadFailure.canRetry(failure),
                        "authentication fault cannot become a retryable upstream failure during cooldown")
                }
            }
        }
        let failureObserver = UsageObserver(codexHome: fakeHome, provider: manualFailureProvider,
            logURL: temp.appendingPathComponent("refresh-failure.jsonl"))
        failureObserver.refresh(manual: true, source: "button")
        for _ in 0..<300 {
            if !failureObserver.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!failureObserver.refreshing && failureObserver.refreshMessage.contains("刷新失败") && failureObserver.lastError != nil,
            "failed manual read clears busy state and offers an explicit retry")
        do {
            let rotationLog = temp.appendingPathComponent("rotated-usage.jsonl")
            let firstRow = "{\"event\":\"historical_fixture\",\"marker\":\"original-history\"}\n"
            let filler = "{\"event\":\"historical_fixture\",\"marker\":\"bounded-padding\"}\n"
            let historical = firstRow + String(repeating: filler, count: (1024 * 1024 / filler.utf8.count) + 1)
            try historical.write(to: rotationLog, atomically: true, encoding: .utf8)
            let rotationObserver = UsageObserver(codexHome: fakeHome, provider: successProvider, logURL: rotationLog)
            rotationObserver.refresh(manual: true, source: "button")
            for _ in 0..<300 { if !rotationObserver.refreshing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let backup = rotationLog.appendingPathExtension("1")
            check((try? String(contentsOf: backup, encoding: .utf8)) == historical,
                "quota log rotation retains complete historical rows in a bounded backup instead of cutting the file tail")
            for index in 2...4 {
                try historical.replacingOccurrences(of: "original-history", with: "history-\(index)")
                    .write(to: rotationLog, atomically: true, encoding: .utf8)
                rotationObserver.refresh(manual: true, source: "button")
                for _ in 0..<300 { if !rotationObserver.refreshing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            }
            let retained = (1...3).compactMap { try? String(contentsOf: rotationLog.appendingPathExtension(String($0)), encoding: .utf8) }
            check(retained.count == 3 && retained[0].contains("history-4") && retained[2].contains("history-2") &&
                !FileManager.default.fileExists(atPath: rotationLog.appendingPathExtension("4").path),
                "quota history rotates through exactly three bounded backups and removes only the oldest generation")
            let current = try String(contentsOf: rotationLog, encoding: .utf8)
            check(current.split(separator: "\n").allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil },
                "quota rotation preserves whole JSONL rows in the current log")
        }
        let shutdownRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/tests/shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shutdownRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shutdownRoot) }
        let shutdownExecutable = shutdownRoot.appendingPathComponent("fake-codex")
        let shutdownScript = """
        #!/usr/bin/python3
        import json,os,signal,sys,time
        failing=False
        for line in sys.stdin:
            request=json.loads(line)
            method=request['method']
            if method=='initialized': continue
            if method=='fail-rate-limits':
                signal.signal(signal.SIGTERM,signal.SIG_IGN)
                failing=True
            if method=='account/rateLimits/read' and failing:
                os.close(1)
                break
            elif method=='account/read': response={'result':{'account':{'type':'chatgpt'}}}
            elif method=='account/rateLimits/read':
                response={'result':{'accountId':'shutdown-test','rateLimits':{'primary':{'usedPercent':7,'windowDurationMins':300,'resetsAt':2000000000}}}}
            else: response={'result':{}}
            print(json.dumps(dict(response,id=request['id'])),flush=True)
        while failing: time.sleep(1)
        """
        try shutdownScript.write(to: shutdownExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shutdownExecutable.path)
        let unnotifiedProcess = UnnotifiedExitProcess()
        let shutdownClient = try AppServerClient(binary: shutdownExecutable, usageOnly: true, process: unnotifiedProcess)
        _ = try shutdownClient.request("fail-rate-limits", params: [:])
        unnotifiedProcess.holdExitNotification = true
        var shutdownUptime: TimeInterval = 100
        var shutdownConnections = 0
        let shutdownProvider = AppServerUsageProvider(makeTransport: {
            shutdownConnections += 1
            return shutdownConnections == 1 ? shutdownClient : try AppServerClient(binary: shutdownExecutable, usageOnly: true)
        }, contextIdentity: { nil }, uptime: { shutdownUptime })
        let shutdownLog = shutdownRoot.appendingPathComponent("usage-transitions.jsonl")
        let shutdownObserver = UsageObserver(codexHome: shutdownRoot, provider: shutdownProvider, logURL: shutdownLog)
        shutdownObserver.refresh()
        for _ in 0..<300 {
            if !shutdownObserver.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!shutdownObserver.refreshing && shutdownObserver.lastError != nil,
            "automatic quota failure clears refreshing within three seconds despite a lost child-exit notification")
        check(kill(unnotifiedProcess.processIdentifier, 0) == -1 && errno == ESRCH && unnotifiedProcess.isRunning,
            "shutdown kills the unresponsive child even while Foundation reports stale running state")
        // Let the old implementation finish after the bounded assertion, so a regression never hangs this suite.
        unnotifiedProcess.releaseExitWait()
        for _ in 0..<300 {
            if !shutdownObserver.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        shutdownClient.close()
        shutdownObserver.refresh()
        for _ in 0..<300 {
            if !shutdownObserver.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!shutdownObserver.refreshing && shutdownConnections == 1 && shutdownObserver.lastError != nil,
            "automatic polling after shutdown preserves connection failure cooldown")
        shutdownUptime += 20
        shutdownObserver.refresh()
        for _ in 0..<300 {
            if !shutdownObserver.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!shutdownObserver.refreshing && shutdownObserver.lastError == nil && shutdownConnections == 2 &&
            shutdownObserver.snapshot?.fiveHour?.usedPercent == 7 && shutdownObserver.snapshot?.accountID == "shutdown-test",
            "automatic polling rebuilds and reads live quota after cooldown without a menu or button retry")
        shutdownObserver.refresh()
        for _ in 0..<300 {
            if !shutdownObserver.refreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!shutdownObserver.refreshing && shutdownObserver.lastError == nil && shutdownConnections == 2,
            "automatic polling reuses the recovered app-server connection")
        let shutdownEvents = try String(contentsOf: shutdownLog, encoding: .utf8)
        check(shutdownEvents.contains("usage_read_failed") && shutdownEvents.contains("automatic") &&
            shutdownEvents.contains("connection_ended") && !shutdownEvents.contains("usage_refresh_started"),
            "shutdown recovery records the automatic failure without a manual refresh")
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
        root=pathlib.Path(os.environ['CODEX_HOME'])
        if 'features.daemon_auto_start = false' not in (root/'config.toml').read_text():
            print('Background server has incompatible feature settings',flush=True)
            time.sleep(25)
            sys.exit(1)
        directory=root/'sessions'
        directory.mkdir(parents=True,exist_ok=True)
        rows=[{'type':'session_meta','payload':{'id':'11111111-1111-1111-1111-111111111111'}},{'payload':{'type':'task_started','turn_id':'22222222-2222-2222-2222-222222222222'}},{'payload':{'role':'assistant','content':[{'text':'OK'}]}},{'payload':{'type':'task_complete','turn_id':'22222222-2222-2222-2222-222222222222'}}]
        (directory/'rollout-fake.jsonl').write_text(chr(10).join(json.dumps(x) for x in rows))
        print('ready',flush=True)
        time.sleep(25)
        """
        try ttyScript.write(to: fakeTUI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeTUI.path)
        var pingBefore = beforePing; pingBefore.capturedAt = Date(); pingBefore.fiveHour?.resetsAt = Date().addingTimeInterval(-10)
        let pingResult = try PTYPingTransport(codexHome: fakeHome, supportRoot: pingRoot, binary: fakeTUI,
            timing: PingTiming(warning: 0.2, timeout: 1.5, pollInterval: 0.05))
            .ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: FakePingUsage(account: pingBefore.accountID!))
        check(pingResult.fiveHour != nil, "PTY ping runs independently of incompatible shared daemon and confirms live window")
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
        let completedTUI = temp.appendingPathComponent("completed-fake-tui")
        let completedScript = slowScript.replacingOccurrences(of: "time.sleep(0.5)", with: "time.sleep(0.05)")
            .replacingOccurrences(of: "time.sleep(10)", with: "time.sleep(0.05)")
        try completedScript.write(to: completedTUI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: completedTUI.path)
        let recoveringRoot = temp.appendingPathComponent("recovering-ping")
        let recoveringUsage = ConfirmationTestUsage { call in
            if call <= 2 { throw CodexConnectionError.timeout }
            return try FakePingUsage(account: pingBefore.accountID!).read()
        }
        var recoveryProgress: [PingDiagnostic] = []
        do {
            _ = try PTYPingTransport(codexHome: fakeHome, supportRoot: recoveringRoot, binary: completedTUI, timing: testTiming)
                .ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: recoveringUsage) { recoveryProgress.append($0) }
            check(recoveringUsage.calls == 3 && recoveryProgress.last?.windowConfirmed == true,
                "completed ping survives temporary quota errors and PTY exit until the live window confirms")
        } catch {
            check(false, "completed ping survives temporary quota errors and PTY exit until the live window confirms")
        }
        check(try String(contentsOf: recoveringRoot.appendingPathComponent("home/launch-count"), encoding: .utf8) == "1",
            "quota verification recovery sends exactly one keep-alive")
        let cooledRoot = temp.appendingPathComponent("cooled-quota-ping")
        let cooledFailure = CountingUsageTransport(); cooledFailure.onRequest = { _ in throw CodexConnectionError.timeout }
        let cooledRecovery = CountingUsageTransport()
        var cooledConnections = 0
        let cooledProvider = AppServerUsageProvider(makeTransport: {
            cooledConnections += 1
            return cooledConnections == 1 ? cooledFailure : cooledRecovery
        }, contextIdentity: { nil }, uptime: { ProcessInfo.processInfo.systemUptime * 40 })
        var providerPingBefore = pingBefore; providerPingBefore.accountID = "usage-test"
        var cooledProgress: [PingDiagnostic] = []
        _ = try PTYPingTransport(codexHome: fakeHome, supportRoot: cooledRoot, binary: completedTUI, timing: testTiming)
            .ping(before: providerPingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: cooledProvider) { cooledProgress.append($0) }
        _ = try cooledProvider.read()
        check(cooledConnections == 2 && cooledFailure.calls == 1 && cooledRecovery.calls == 2 && cooledRecovery.closes == 0,
            "read-only ping verification respects production provider cooldown and reuses the recovered connection")
        check(cooledProgress.contains { $0.quotaReadFailure?.requestStage == "rate_limits" && $0.quotaReadFailure?.rpcAttempted == true } &&
            cooledProgress.contains { $0.quotaReadFailure?.cooldown == true && $0.quotaReadFailure?.rpcAttempted == false },
            "ping diagnostics distinguish failed Keeper RPC from cached cooldown errors")
        check(try String(contentsOf: cooledRoot.appendingPathComponent("home/launch-count"), encoding: .utf8) == "1",
            "production provider cooldown recovery never relaunches the completed ping")
        let persistentRoot = temp.appendingPathComponent("persistent-quota-ping")
        let persistentUsage = ConfirmationTestUsage { _ in throw CodexConnectionError.timeout }
        var persistentProgress: [PingDiagnostic] = []
        let verificationTiming = PingTiming(warning: 0.2, timeout: 0.7, pollInterval: 0.05)
        do {
            _ = try PTYPingTransport(codexHome: fakeHome, supportRoot: persistentRoot, binary: completedTUI, timing: verificationTiming)
                .ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: persistentUsage) { persistentProgress.append($0) }
            check(false, "persistent quota failure cannot confirm a completed ping")
        } catch let failure as PingFailure {
            check(failure.diagnostic.elapsedSeconds >= verificationTiming.timeout && failure.diagnostic.okReceived &&
                failure.diagnostic.taskCompleted && !failure.diagnostic.windowConfirmed,
                "persistent quota errors keep the original confirmation deadline after the completed PTY exits")
            check(failure.localizedDescription.contains("保活已发送") && persistentProgress.contains {
                $0.outcome == "waiting" && $0.elapsedSeconds >= verificationTiming.warning && $0.quotaReadFailure != nil
            }, "read-only verification failure still warns at the configured threshold and distinguishes sent but unconfirmed")
        }
        check(try String(contentsOf: persistentRoot.appendingPathComponent("home/launch-count"), encoding: .utf8) == "1",
            "persistent quota verification errors never relaunch keep-alive")
        check(recoveryProgress.filter { $0.quotaReadFailure != nil && $0.elapsedSeconds < testTiming.warning }.count <= 1,
            "unchanged quota errors do not flood early progress diagnostics")
        let changedRoot = temp.appendingPathComponent("changed-account-ping")
        let changedUsage = ConfirmationTestUsage { _ in try FakePingUsage(account: "other-confirmation-account").read() }
        do {
            _ = try PTYPingTransport(codexHome: fakeHome, supportRoot: changedRoot, binary: completedTUI, timing: testTiming)
                .ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: changedUsage)
            check(false, "another account cannot confirm a sent keep-alive")
        } catch let failure as PingFailure {
            check(failure.diagnostic.reason == .accountChanged && changedUsage.calls == 1 && failure.diagnostic.elapsedSeconds < testTiming.timeout,
                "another account's live window ends verification immediately after one read")
        }
        check(try String(contentsOf: changedRoot.appendingPathComponent("home/launch-count"), encoding: .utf8) == "1",
            "account change stops verification without a second keep-alive send")
        for (name, error) in [("invalid-response", CodexConnectionError.invalidResponse),
                              ("authentication", CodexConnectionError.server("unauthorized Authorization: Bearer fixture-quota-secret"))] {
            let root = temp.appendingPathComponent(name + "-ping")
            let fatalUsage = ConfirmationTestUsage { _ in throw error }
            do {
                _ = try PTYPingTransport(codexHome: fakeHome, supportRoot: root, binary: completedTUI, timing: testTiming)
                    .ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: fatalUsage)
                check(false, "terminal \(name) error must stop verification")
            } catch let failure as PingFailure {
                check(fatalUsage.calls == 1 && failure.diagnostic.elapsedSeconds < testTiming.timeout && failure.diagnostic.reason == .quotaRead,
                    "terminal \(name) error stops completed ping verification immediately")
                let data = try JSONEncoder().encode(failure.diagnostic)
                check(!String(decoding: data, as: UTF8.self).contains("fixture-quota-secret") && !String(decoding: data, as: UTF8.self).contains("Authorization"),
                    "\(name) quota diagnostics exclude raw server errors and credentials")
            }
            check(try String(contentsOf: root.appendingPathComponent("home/launch-count"), encoding: .utf8) == "1",
                "terminal \(name) verification error keeps launch count at one")
        }
        let unsupportedQuota = CompatibilityTransport(); unsupportedQuota.account = ["type": "apiKey"]
        let unsupportedProvider = AppServerUsageProvider(makeTransport: { unsupportedQuota }, contextIdentity: { nil })
        do {
            _ = try PTYPingTransport(codexHome: fakeHome, supportRoot: temp.appendingPathComponent("unsupported-confirmation-ping"),
                binary: completedTUI, timing: testTiming)
                .ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: unsupportedProvider)
            check(false, "unsupported account capability cannot verify keep-alive")
        } catch let failure as PingFailure {
            check(failure.diagnostic.quotaReadFailure?.reason == "capability_or_authentication" &&
                failure.diagnostic.elapsedSeconds < testTiming.timeout && unsupportedQuota.quotaCalls == 0,
                "provider capability failure ends verification before any quota RPC")
        }
        let cancelQuotaRoot = temp.appendingPathComponent("cancelled-quota-ping")
        let cancelQuotaTransport = PTYPingTransport(codexHome: fakeHome, supportRoot: cancelQuotaRoot, binary: completedTUI, timing: testTiming)
        let cancelQuotaUsage = ConfirmationTestUsage { _ in cancelQuotaTransport.cancel(); throw CodexConnectionError.timeout }
        do {
            _ = try cancelQuotaTransport.ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: cancelQuotaUsage)
            check(false, "cancellation during quota verification must stop")
        } catch let failure as PingFailure {
            check(failure.diagnostic.outcome == "cancelled" && cancelQuotaUsage.calls == 1 && !failure.diagnostic.windowConfirmed,
                "cancellation during failed quota read takes priority and ends verification")
        }
        check(try String(contentsOf: cancelQuotaRoot.appendingPathComponent("home/launch-count"), encoding: .utf8) == "1",
            "cancelling read-only confirmation never sends a second keep-alive")
        let lateQuotaUsage = ConfirmationTestUsage { _ in Thread.sleep(forTimeInterval: 0.35); throw CodexConnectionError.timeout }
        let lateQuotaTiming = PingTiming(warning: 0.1, timeout: 0.3, pollInterval: 0.05)
        do {
            _ = try PTYPingTransport(codexHome: fakeHome, supportRoot: temp.appendingPathComponent("late-quota-ping"),
                binary: completedTUI, timing: lateQuotaTiming)
                .ping(before: pingBefore, model: PingModel(model: "gpt-5.6-luna", reasoningEffort: "low"), provider: lateQuotaUsage)
            check(false, "a failed in-flight query cannot confirm past deadline")
        } catch let failure as PingFailure {
            check(lateQuotaUsage.calls == 1 && failure.diagnostic.elapsedSeconds >= lateQuotaTiming.timeout,
                "an already in-flight read may finish past the target but never starts another read after deadline")
        }
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

        do {
            var decisions = ResumeChoices()
            decisions.requestRecoveryDecision(for: pending, now: now)
            check(decisions.recoveryDecisions?[pending.episodeKey]?.phase == .waitingForActivity && decisions.recoveryDecisions?[pending.episodeKey]?.deadline == nil && decisions.keepAliveEpisodes.isEmpty,
                "a new early-recovery reminder has no cancellation countdown")
            let deadline = now.addingTimeInterval(600)
            decisions.recoveryDecisions?[pending.episodeKey]?.phase = .waitingForChoice
            decisions.recoveryDecisions?[pending.episodeKey]?.deadline = deadline
            decisions.recoveryDecisions?[pending.episodeKey]?.notification = .delivered
            decisions.requestRecoveryDecision(for: pending, now: deadline.addingTimeInterval(3600))
            let saved = try JSONDecoder().decode(ResumeChoices.self, from: JSONEncoder().encode(decisions))
            check(saved == decisions && saved.recoveryDecisions?[pending.episodeKey]?.deadline == deadline && saved.keepAliveEpisodes.isEmpty,
                "legacy phase and deadline survive restart without cancelling the unanswered reminder")
            check(saved.recoveryDecisions?[pending.episodeKey]?.message == L10n.text("未选择时，提醒会一直保留，任务不会自动继续。"),
                "a legacy countdown reminder explains that it waits for an explicit choice")
            var afterDeadline = saved
            check(afterDeadline.resolveRecoveryDecision(.now, for: pending) && afterDeadline.recoveryDecisions?[pending.episodeKey]?.phase == .responded && afterDeadline.recoveryDecisions?[pending.episodeKey]?.deadline == nil && afterDeadline.keepAliveEpisodes.isEmpty,
                "an expired legacy deadline cannot cancel an explicit continue-now choice")
            check(afterDeadline.keepAliveIgnoredEpisodes.contains(pending.episodeKey) && saved.keepAliveIgnoredEpisodes.contains(pending.episodeKey),
                "manually handled and unanswered episodes both allow normal keep-alive")
            var cancelled = saved
            check(cancelled.resolveRecoveryDecision(.cancel, for: pending) && cancelled.keepAliveEpisodes.contains(pending.episodeKey),
                "explicit cancel remains the only reminder choice that skips this continuation")
            cancelled.requestRecoveryDecision(for: pending, now: deadline)
            cancelled.requestRecoveryDecision(for: laterStop, now: deadline)
            check(cancelled.recoveryDecisions?[pending.episodeKey] == nil && cancelled.recoveryDecisions?[laterStop.episodeKey]?.phase == .waitingForActivity,
                "a cancelled episode stays cancelled while a new stop has its own reminder")
            var scheduled = saved
            check(scheduled.resolveRecoveryDecision(.plan, for: pending) && scheduled.recoveryDecisions?[pending.episodeKey] == nil,
                "an explicit plan choice dismisses its reminder")
            var deselected = saved
            deselected.deselectedEpisodes.insert(pending.episodeKey)
            check(!deselected.resolveRecoveryDecision(.now, for: pending) && deselected.recoveryDecisions?[pending.episodeKey]?.deadline == deadline,
                "deselecting cannot erase a reminder or act on a different selection")
            let persistedWait = engine.plan(now: localNode, enabled: true, autoResume: true, earlyRecoveryPolicy: "ask",
                usage: UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 1, windowMinutes: 300, resetsAt: future), weekly: nil, capturedAt: localNode, sourceFile: "app-server"),
                blocked: [pending], observedRecovery: true, needsRecoveryDecision: true)
            check(persistedWait.needsRecoveryDecision && persistedWait.date == nil && persistedWait.decision == .wait(reason: "等待续跑决定"),
                "a persisted unanswered reminder cannot continue at a scheduled node even after natural recovery")
            var inactive = recovered; inactive.fiveHour?.usedPercent = 0; inactive.zeroUseWindowActive = false
            var inactivePlan = engine.plan(now: inactive.capturedAt, enabled: true, autoResume: false, earlyRecoveryPolicy: "keepPlan", usage: inactive, blocked: [])
            inactivePlan.needsRecoveryDecision = true
            let noWindow = MenuSummary.build(plan: inactivePlan, usage: inactive, schedule: schedule, tasks: [pending], now: inactive.capturedAt)
            check(noWindow.isTime && noWindow.action == "保持活动" && noWindow.taskCount == 1 && noWindow.statusSymbol == "waveform.path.ecg",
                "an unanswered reminder with no active window retains its task and displays normal keep-alive")
            var available = recovered; available.accountID = "test-account"
            check(!UsageRecovery.hasAvailableQuota(for: pending, usage: available, boundAccount: "other", now: available.capturedAt),
                "a different account cannot generate a recovery reminder")
            available.fiveHour = nil
            check(!UsageRecovery.hasAvailableQuota(for: pending, usage: available, boundAccount: "test-account", now: available.capturedAt),
                "the required quota window cannot be omitted from reminder eligibility")
        }

        // Token growth after a real desktop user request, never snapshots or inherited text.
        func desktopUser(_ at: Date, kind: String = "user.text") -> String {
            let value: [String: Any] = ["type": "response_item", "timestamp": iso.string(from: at), "payload": [
                "type": "message", "role": "user", "content": [["type": "input_text", "text": "Continue working"]],
                "internal_chat_message_metadata_passthrough": ["content_item_kinds": [kind]]]]
            return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)! + "\n"
        }
        func tokenUsage(_ at: Date, total: Int, used: Int = 1, limit: String = "codex") -> String {
            event("token_count", at, ["info": ["total_token_usage": ["total_tokens": total], "last_token_usage": ["total_tokens": 10, "output_tokens": 4]],
                "rate_limits": ["limit_id": limit, "primary": ["used_percent": used, "window_minutes": 300, "resets_at": at.addingTimeInterval(18000).timeIntervalSince1970]]])
        }
        do {
            let trace = temp.appendingPathComponent("user-usage.jsonl")
            let promptAt = now.addingTimeInterval(-10)
            let header = try metadata(parentID, at: promptAt.addingTimeInterval(-10))
            func parse(_ content: String) throws -> SessionActivity { try content.write(to: trace, atomically: true, encoding: .utf8); return SessionWatcher.parse(url: trace, mtime: now)! }
            check(try parse(header + desktopUser(promptAt) + tokenUsage(now, total: 10)).userUsage?.promptAt == promptAt,
                "a new main session counts its first real positive token usage after the user request")
            check(try parse(header + tokenUsage(promptAt.addingTimeInterval(-1), total: 10) + desktopUser(promptAt) + tokenUsage(now, total: 10)).userUsage?.promptAt == nil,
                "a repeated last-token-usage snapshot after the request is not new usage")
            check(try parse(header + tokenUsage(promptAt.addingTimeInterval(-1), total: 10) + desktopUser(promptAt) + tokenUsage(now, total: 20, used: 0)).userUsage?.promptAt == promptAt,
                "cumulative token growth verifies usage even when usage percent rounds to zero")
            check(try parse(header + desktopUser(promptAt, kind: "agents_md.instructions") + tokenUsage(now, total: 20)).userUsage?.promptAt == nil,
                "AGENTS metadata cannot count as user activity")
            check(try parse(header + desktopUser(promptAt, kind: "environments.environment_context") + tokenUsage(now, total: 20)).userUsage?.promptAt == nil,
                "environment metadata cannot count as user activity")
            check(try parse(header + event("user_message", promptAt) + tokenUsage(now, total: 20)).userUsage?.promptAt == nil,
                "legacy CLI messages without verifiable user metadata do not start cancellation")
            check(try parse(header + desktopUser(promptAt) + tokenUsage(now, total: 20, used: 100)).userUsage?.promptAt == nil,
                "exhausted quota cannot prove successful recovered usage")
            check(try parse(header + desktopUser(promptAt) + tokenUsage(now, total: 20, limit: "premium")).userUsage?.promptAt == nil,
                "another quota category cannot start the recovery deadline")
            let realUse = header + desktopUser(promptAt) + tokenUsage(promptAt.addingTimeInterval(1), total: 10)
            let replay = try parse(realUse + tokenUsage(now, total: 10))
            check(replay.userUsage?.fiveHourResetAt == promptAt.addingTimeInterval(18001),
                "a later unchanged token snapshot cannot attach a new quota window to old usage")
            let reached = event("token_count", now, ["info": ["total_token_usage": ["total_tokens": 20], "last_token_usage": ["total_tokens": 10]],
                "rate_limits": ["limit_id": "codex", "rate_limit_reached_type": "primary", "primary": ["used_percent": 99, "window_minutes": 300, "resets_at": now.addingTimeInterval(18000).timeIntervalSince1970]]])
            check(try parse(header + desktopUser(promptAt) + reached).userUsage == nil,
                "an explicit reached flag rejects seemingly nonexhausted rounded percentages")
            let childHeader = try metadata(childID, at: now, parent: parentID)
            check(try parse(childHeader + desktopUser(promptAt) + tokenUsage(promptAt.addingTimeInterval(1), total: 20)).userUsage?.promptAt == nil,
                "forked inherited user history never counts as a fresh human return")
            let excludedLog = ExecutionEventLog(url: temp.appendingPathComponent("activity-exclusion/events.jsonl"))
            check(excludedLog.resumeStarts()?.isEmpty == true, "an absent Keeper event log contains no automated sessions")
            try excludedLog.record("started", kind: "resume", node: nil, threadID: parentID)
            check(excludedLog.resumeStarts()?[parentID] != nil, "persisted Keeper starts identify sessions to exclude from human usage")
            try "malformed".write(to: excludedLog.url, atomically: true, encoding: .utf8)
            check(excludedLog.resumeStarts() == nil, "unreadable execution evidence conservatively prevents a cancellation deadline")
        }

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

        // Drive the actual AppState, persistence, notification route and manual coordinator with an isolated home.
        do {
            let root = temp.appendingPathComponent("recovery-app-state")
            let home = root.appendingPathComponent("codex")
            let traces = home.appendingPathComponent("sessions")
            let runtime = root.appendingPathComponent("support/pending-runtime.json")
            try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
            var connection: OpaquePointer?
            sqlite3_open(home.appendingPathComponent("logs_1.sqlite").path, &connection)
            sqlite3_exec(connection, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil)
            sqlite3_close(connection)
            var clockNow = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let observedAt = clockNow
            let stopAt = clockNow.addingTimeInterval(-119.82)
            let fiveReset = clockNow.addingTimeInterval(15000)
            let weekReset = clockNow.addingTimeInterval(604800)
            let live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 2, windowMinutes: 300, resetsAt: fiveReset),
                weekly: QuotaWindow(usedPercent: 3, windowMinutes: 10080, resetsAt: weekReset), capturedAt: clockNow, accountID: "test-account", sourceFile: "app-server")
            let provider = RecoveryTestUsage(snapshot: live)
            func limits(weekly: Int = 3) -> [String: Any] { ["limit_id": "codex",
                "primary": ["used_percent": 2, "window_minutes": 300, "resets_at": fiveReset.timeIntervalSince1970],
                "secondary": ["used_percent": weekly, "window_minutes": 10080, "resets_at": weekReset.timeIntervalSince1970]] }
            func stopped(_ id: String, at: Date) throws -> String {
                try metadata(id, at: at.addingTimeInterval(-60)) + event("token_count", at.addingTimeInterval(-1), ["rate_limits": limits(weekly: 100)]) + event("error", at, ["message": "usage_limit_reached"])
            }
            let firstPath = traces.appendingPathComponent("rollout-\(parentID).jsonl")
            let secondPath = traces.appendingPathComponent("rollout-\(childID).jsonl")
            let firstTrace = try stopped(parentID, at: stopAt)
            try firstTrace.write(to: firstPath, atomically: true, encoding: .utf8)
            try stopped(childID, at: stopAt).write(to: secondPath, atomically: true, encoding: .utf8)
            let appSuite = "keeper.recovery.tests." + UUID().uuidString
            let appDefaults = UserDefaults(suiteName: appSuite)!
            defer { appDefaults.removePersistentDomain(forName: appSuite) }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: clockNow)
            appDefaults.register(defaults: ["enabled": true, "autoResume": true, "earlyRecoveryPolicy": "ask", "resumeWorkspaceReminder": false,
                "dailyAnchorMinutes": ((parts.hour! * 60 + parts.minute!) + 20) % 1440])
            let appRecorder = BatchRecorder(expected: 1)
            let appExecution = ExecutionCoordinator(provider: provider, makeResumeTransport: { BatchTransport(recorder: appRecorder) },
                defaults: appDefaults, ledgerURL: runtime.deletingLastPathComponent().appendingPathComponent("resume-attempts.json"), codexHome: home)
            func makeState() -> AppState { AppState(provider: provider, defaults: appDefaults, runtimeURL: runtime,
                codexHome: home, execution: appExecution, startMonitoring: false, now: { clockNow }) }
            var state = makeState()
            func sync(_ state: AppState) async throws {
                state.refresh()
                for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
                state.recompute(allowExecution: false)
            }
            try await sync(state)
            let first = state.availableTasks.first { $0.id == parentID }!
            let second = state.availableTasks.first { $0.id == childID }!
            check(state.choices.recoveryDecisions?.count == 2 && state.choices.recoveryDecisions?[first.episodeKey]?.phase == .waitingForActivity && state.nextAction?.needsRecoveryDecision == true,
                "real AppState persists unanswered reminders for both recovered episodes")
            check(state.nextAction?.mode == .keepAlive && state.nextAction?.date != nil,
                "unanswered reminders leave the main AppState plan on normal keep-alive")
            let initialReminder = state.claimRecoveryReminder(for: first.episodeKey)!
            state.finishRecoveryReminder(for: first.episodeKey, phase: initialReminder.phase, delivered: false)
            check(state.choices.recoveryDecisions?[first.episodeKey]?.notification == .unavailable && state.claimRecoveryReminder(for: first.episodeKey) == nil,
                "notification denial stays undelivered and persistently deduplicated with the task entry intact")
            state.setSelected(first, false); state.setSelected(first, true)
            check(state.choices.recoveryDecisions?[first.episodeKey]?.phase == .waitingForActivity,
                "deselect and reselect use the same durable recovery decision")
            var opened = 0
            state.openRecoveryDecisions { opened += 1 }
            check(opened == 1 && appRecorder.count == 0 && !appExecution.running,
                "the actual notification route opens current choices without dispatching a message")
            state = makeState(); try await sync(state)
            check(state.claimRecoveryReminder(for: first.episodeKey) == nil && state.choices.recoveryDecisions?[first.episodeKey]?.phase == .waitingForActivity,
                "AppState restart preserves the notification result and no-activity waiting state")

            let humanPath = traces.appendingPathComponent("rollout-\(forkID).jsonl")
            let promptAt = observedAt.addingTimeInterval(-30)
            let humanTrace = try metadata(forkID, at: promptAt.addingTimeInterval(-60)) + desktopUser(promptAt) +
                event("token_count", promptAt.addingTimeInterval(1), ["info": ["total_token_usage": ["total_tokens": 10], "last_token_usage": ["total_tokens": 10]], "rate_limits": limits()])
            try humanTrace.write(to: humanPath, atomically: true, encoding: .utf8)
            // This already-happened use belongs to a different window, so reading current quota alone must not start a timer.
            var changedWindow = live; changedWindow.fiveHour?.resetsAt = fiveReset.addingTimeInterval(300)
            provider.set(changedWindow)
            try await sync(state)
            check(state.choices.recoveryDecisions?[first.episodeKey]?.phase == .waitingForActivity,
                "old-window user usage plus a current quota poll cannot start cancellation")
            provider.set(live)
            let keeperEvent = runtime.deletingLastPathComponent().appendingPathComponent("execution-events.jsonl")
            let sameSecondStart: [String: Any] = ["event": "started", "kind": "resume", "thread_id": forkID,
                "at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: floor(stopAt.timeIntervalSince1970)))]
            try JSONSerialization.data(withJSONObject: sameSecondStart).write(to: keeperEvent)
            try await sync(state)
            check(state.choices.recoveryDecisions?[first.episodeKey]?.phase == .waitingForActivity,
                "same-second Keeper start excludes its session despite fractional stop timestamps")
            try FileManager.default.removeItem(at: keeperEvent)
            try await sync(state)
            let deadline = observedAt.addingTimeInterval(600)
            check(state.choices.recoveryDecisions?[first.episodeKey]?.deadline == nil && state.choices.recoveryDecisions?[second.episodeKey]?.deadline == nil,
                "human usage no longer starts a cancellation countdown for scheduled tasks")
            state.finishRecoveryReminder(for: first.episodeKey, phase: .waitingForChoice, delivered: true)
            check(state.choices.recoveryDecisions?[first.episodeKey]?.notification == .unavailable,
                "a legacy-stage notification callback cannot acknowledge the current reminder")
            state = makeState(); try await sync(state)
            check(state.choices.recoveryDecisions?[first.episodeKey]?.deadline == nil && state.claimRecoveryReminder(for: first.episodeKey) == nil,
                "restart preserves the untimed reminder and does not redeliver its notification")
            let beforeActions = try Data(contentsOf: runtime)
            state.resolveRecoveryDecision(.plan, for: [second])
            let chosenPlan = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime)) as! [String: Any]
            check((chosenPlan["held"] as? [String])?.contains(second.episodeKey) == true && state.choices.recoveryDecisions?[second.episodeKey] == nil,
                "the real plan button durably releases only the selected episode into the existing schedule")
            var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime)) as! [String: Any]
            var legacyChoices = legacy["choices"] as! [String: Any]
            var legacyDecisions = legacyChoices["recoveryDecisions"] as! [String: [String: Any]]
            legacyDecisions[first.episodeKey]?["phase"] = RecoveryDecision.Phase.waitingForChoice.rawValue
            legacyDecisions[first.episodeKey]?["deadline"] = deadline.timeIntervalSinceReferenceDate
            legacyChoices["recoveryDecisions"] = legacyDecisions; legacy["choices"] = legacyChoices
            try JSONSerialization.data(withJSONObject: legacy).write(to: runtime, options: .atomic)
            state = makeState(); try await sync(state)
            clockNow = deadline
            state.openRecoveryDecisions { opened += 1 }
            check(!state.choices.keepAliveEpisodes.contains(first.episodeKey) && !state.choices.keepAliveEpisodes.contains(second.episodeKey) && state.choices.recoveryDecisions?[first.episodeKey]?.phase == .waitingForChoice && appRecorder.count == 0,
                "opening a legacy reminder after ten minutes retains it without cancellation or continuation")
            let newStop = clockNow.addingTimeInterval(-5)
            try stopped(parentID, at: newStop).write(to: firstPath, atomically: true, encoding: .utf8)
            var fresh = live; fresh.capturedAt = clockNow; provider.set(fresh)
            try await sync(state)
            let nextEpisode = state.availableTasks.first { $0.id == parentID }!
            state.resolveRecoveryDecision(.now, for: [first])
            check(nextEpisode.episodeKey != first.episodeKey && state.choices.recoveryDecisions?[nextEpisode.episodeKey]?.phase == .waitingForActivity && appRecorder.count == 0,
                "a new quota stop receives a new decision while stale button scope cannot act on it")
            state.resolveRecoveryDecision(.cancel, for: [nextEpisode])
            check(state.choices.keepAliveEpisodes.contains(nextEpisode.episodeKey) && !state.choices.keepAliveEpisodes.contains(second.episodeKey),
                "the actual cancel button affects only its frozen selected episode")

            // Restore this isolated fixture with a near-expiry deadline, then suspend the fake preflight read.
            clockNow = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            fresh = live; fresh.capturedAt = clockNow; provider.set(fresh)
            try firstTrace.write(to: firstPath, atomically: true, encoding: .utf8)
            var fixture = try JSONSerialization.jsonObject(with: beforeActions) as! [String: Any]
            var savedChoices = fixture["choices"] as! [String: Any]
            var savedDecisions = savedChoices["recoveryDecisions"] as! [String: [String: Any]]
            for key in savedDecisions.keys {
                savedDecisions[key]?["phase"] = RecoveryDecision.Phase.waitingForChoice.rawValue
                savedDecisions[key]?["deadline"] = clockNow.addingTimeInterval(1).timeIntervalSinceReferenceDate
            }
            savedChoices["recoveryDecisions"] = savedDecisions; fixture["choices"] = savedChoices
            try JSONSerialization.data(withJSONObject: fixture).write(to: runtime, options: .atomic)
            state = makeState(); try await sync(state)
            provider.pause()
            state.resolveRecoveryDecision(.now, for: [first])
            check(state.choices.recoveryDecisions?[first.episodeKey]?.phase == .responded && state.choices.recoveryDecisions?[first.episodeKey]?.deadline == nil,
                "the real now button durably acknowledges the choice before async manual preflight")
            clockNow = clockNow.addingTimeInterval(2)
            state.recompute(allowExecution: false)
            check(!state.choices.keepAliveEpisodes.contains(first.episodeKey) && !state.choices.keepAliveEpisodes.contains(second.episodeKey) && state.choices.recoveryDecisions?[second.episodeKey]?.phase == .waitingForChoice,
                "an old deadline during manual preflight cannot cancel the chosen episode or unanswered scheduled peers")
            provider.release()
            for _ in 0..<400 { if !appExecution.running { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            check(appRecorder.count == 1 && appExecution.hasAttempted(first) && !appExecution.hasAttempted(second),
                "the real manual coordinator sends only the explicitly chosen episode through the fake transport")

            // A preflight error must keep a responded decision and must not enter an immediate retry loop.
            clockNow = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            for key in savedDecisions.keys { savedDecisions[key]?["deadline"] = clockNow.addingTimeInterval(600).timeIntervalSinceReferenceDate }
            savedChoices["recoveryDecisions"] = savedDecisions; fixture["choices"] = savedChoices
            try JSONSerialization.data(withJSONObject: fixture).write(to: runtime, options: .atomic)
            fresh.capturedAt = clockNow; provider.set(fresh)
            state = makeState(); try await sync(state)
            provider.set(fresh, failing: true)
            state.resolveRecoveryDecision(.now, for: [second])
            for _ in 0..<100 { if !appExecution.running { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            check(state.choices.recoveryDecisions?[second.episodeKey]?.phase == .responded && !appExecution.hasAttempted(second) && appRecorder.count == 1,
                "manual preflight failure keeps an explicit responded state without a send or cancellation")
            let readsAfterFailure = provider.readCount
            try await Task.sleep(nanoseconds: 100_000_000)
            check(provider.readCount == readsAfterFailure && !appExecution.running,
                "an execution completion refresh cannot spin into immediate automatic retries")
            clockNow = Date(); fresh.capturedAt = clockNow; provider.set(fresh)
            let retryNode = Calendar.current.dateComponents([.hour, .minute], from: clockNow)
            appDefaults.set(retryNode.hour! * 60 + retryNode.minute!, forKey: "dailyAnchorMinutes")
            try await sync(state); state.recompute()
            check(state.choices.recoveryDecisions?[second.episodeKey]?.phase == .responded && !appExecution.hasAttempted(second) && appRecorder.count == 1 && !appExecution.running,
                "a failed explicit continue-now choice cannot silently retry at a later scheduled node")
            appDefaults.set(false, forKey: "enabled"); state.recompute(allowExecution: false)
            check(state.nextAction?.note == "已停用", "a manually handled task cannot override the disabled Keeper state")
            appDefaults.set(true, forKey: "enabled")
            state = makeState()
            state.openRecoveryDecisions { opened += 1 }
            check(state.choices.recoveryDecisions?[second.episodeKey]?.phase == .responded && appRecorder.count == 1,
                "restart and an old notification cannot retry a failed explicit continuation")
            // Off node, a naturally recovered task must run independently of another task waiting for its plan.
            clockNow = Date()
            fresh.capturedAt = clockNow; provider.set(fresh)
            let nodeParts = Calendar.current.dateComponents([.hour, .minute], from: clockNow)
            appDefaults.set((nodeParts.hour! * 60 + nodeParts.minute! + 1380) % 1440, forKey: "dailyAnchorMinutes")
            let naturalReset = clockNow.addingTimeInterval(-60)
            try (metadata(parentID, at: stopAt.addingTimeInterval(-60)) + event("token_count", stopAt.addingTimeInterval(-1), ["rate_limits": [
                "limit_id": "codex", "primary": ["used_percent": 100, "window_minutes": 300, "resets_at": naturalReset.timeIntervalSince1970]]]) +
                event("error", stopAt, ["message": "usage_limit_reached"]))
                .write(to: firstPath, atomically: true, encoding: .utf8)
            let multiRuntime = root.appendingPathComponent("multi/pending-runtime.json")
            var multiFixture = try JSONSerialization.jsonObject(with: beforeActions) as! [String: Any]
            var multiChoices = multiFixture["choices"] as! [String: Any]
            var multiDecisions = multiChoices["recoveryDecisions"] as! [String: [String: Any]]
            multiDecisions.removeValue(forKey: first.episodeKey)
            multiChoices["recoveryDecisions"] = multiDecisions; multiFixture["choices"] = multiChoices
            var multiConfirmed = multiFixture["confirmed"] as! [String: Any]
            multiConfirmed.removeValue(forKey: first.id); multiFixture["confirmed"] = multiConfirmed
            try FileManager.default.createDirectory(at: multiRuntime.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: multiFixture).write(to: multiRuntime, options: .atomic)
            let multiRecorder = BatchRecorder(expected: 1)
            let multiExecution = ExecutionCoordinator(provider: provider, makeResumeTransport: { BatchTransport(recorder: multiRecorder) },
                defaults: appDefaults, ledgerURL: multiRuntime.deletingLastPathComponent().appendingPathComponent("resume-attempts.json"), codexHome: home)
            let multiState = AppState(provider: provider, defaults: appDefaults, runtimeURL: multiRuntime, codexHome: home,
                execution: multiExecution, startMonitoring: false)
            try await sync(multiState)
            for _ in 0..<400 { if !multiExecution.running { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            check(multiRecorder.count == 1 && multiExecution.hasAttempted(first) && !multiExecution.hasAttempted(second) && multiState.choices.recoveryDecisions?[second.episodeKey] != nil,
                "off-node natural recovery runs task A immediately while waiting task B keeps its next scheduled node")
            multiState.resolveRecoveryDecision(.plan, for: [second])
            check(multiRecorder.count == 1 && multiState.choices.recoveryDecisions?[second.episodeKey] == nil && multiState.nextAction?.date == multiState.schedule.nextNode(after: clockNow) && multiState.nextAction?.mode == .resume,
                "an explicit plan choice approves the waiting task for the next scheduled continuation")
            multiState.usage.stop(); multiState.sessions.stop()
            state.usage.stop(); state.sessions.stop()
        }

        // Replay pre-stop 97% -> confirmed exhaustion -> protected natural reset through production AppState.
        do {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/tests/resume-timing-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appendingPathComponent("codex")
            let traces = home.appendingPathComponent("sessions")
            let runtime = root.appendingPathComponent("support/pending-runtime.json")
            try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
            var connection: OpaquePointer?
            sqlite3_open(home.appendingPathComponent("logs_1.sqlite").path, &connection)
            sqlite3_exec(connection, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil)
            sqlite3_close(connection)
            // Use the current minute as the anchor so the coordinator's real-clock preflight can run at the final node.
            let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let anchorMinutes = parts.hour! * 60 + parts.minute!
            let anchor = Calendar.current.date(bySettingHour: parts.hour!, minute: parts.minute!, second: 0, of: Date())!
            let blockedAt = anchor.addingTimeInterval(-22312)
            let reset = anchor.addingTimeInterval(-13945)
            var clockNow = blockedAt.addingTimeInterval(-4)
            var live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 97, windowMinutes: 300, resetsAt: reset),
                weekly: QuotaWindow(usedPercent: 32, windowMinutes: 10080, resetsAt: anchor.addingTimeInterval(604800)),
                capturedAt: clockNow, accountID: "timing-account", sourceFile: "app-server")
            let provider = RecoveryTestUsage(snapshot: live)
            func header(_ id: String, at time: Date) throws -> String {
                let payload: [String: Any] = ["id": id, "cwd": root.path, "timestamp": iso.string(from: time), "source": "vscode"]
                return String(data: try JSONSerialization.data(withJSONObject: ["type": "session_meta", "timestamp": iso.string(from: time), "payload": payload]), encoding: .utf8)! + "\n"
            }
            func stoppedTrace(_ id: String, at time: Date, used: Int, resetsAt: Date) throws -> String {
                try header(id, at: time.addingTimeInterval(-60)) + event("token_count", time.addingTimeInterval(-1), ["rate_limits": [
                    "limit_id": "codex", "primary": ["used_percent": used, "window_minutes": 300, "resets_at": resetsAt.timeIntervalSince1970]]]) +
                    event("error", time, ["message": "usage_limit_reached"])
            }
            let path = traces.appendingPathComponent("rollout-\(parentID).jsonl")
            try header(parentID, at: blockedAt.addingTimeInterval(-60)).write(to: path, atomically: true, encoding: .utf8)
            let suite = "keeper.resume.timing." + UUID().uuidString
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            prefs.register(defaults: ["enabled": true, "autoResume": true, "earlyRecoveryPolicy": "ask", "resumeWorkspaceReminder": false,
                "dailyAnchorMinutes": anchorMinutes])
            let pings = ReminderTestPing()
            let resumes = BatchRecorder(expected: 1)
            let execution = ExecutionCoordinator(provider: provider, makeResumeTransport: { BatchTransport(recorder: resumes) }, defaults: prefs,
                ledgerURL: runtime.deletingLastPathComponent().appendingPathComponent("resume-attempts.json"), pingTransport: pings, codexHome: home, now: { clockNow })
            func makeState() -> AppState { AppState(provider: provider, defaults: prefs, runtimeURL: runtime, codexHome: home,
                execution: execution, startMonitoring: false, now: { clockNow }) }
            var state = makeState()
            func settle() async throws { for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) } }
            func readUsage() async throws {
                provider.set(live); state.usage.refresh(); try await settle()
                state.recompute(allowExecution: false)
            }
            state.sessions.refresh(); try await settle(); try await readUsage()
            clockNow = blockedAt.addingTimeInterval(15)
            try stoppedTrace(parentID, at: blockedAt, used: 99, resetsAt: reset).write(to: path, atomically: true, encoding: .utf8)
            state.sessions.refresh(); try await settle()
            let target = state.availableTasks.first!
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime)) as! [String: Any]
            let savedDecisions = (saved["choices"] as? [String: Any])?["recoveryDecisions"] as? [String: Any]
            check(state.usage.snapshot?.capturedAt == blockedAt.addingTimeInterval(-4) && state.choices.recoveryDecisions?[target.episodeKey] == nil && savedDecisions?[target.episodeKey] == nil,
                "production session refresh cannot persist an early-recovery decision from the fresh pre-stop 97-percent poll")
            clockNow = blockedAt.addingTimeInterval(16)
            live.capturedAt = clockNow; live.fiveHour?.usedPercent = 100
            try await readUsage()
            check(state.availableTasks.first?.fiveHourResetAt == reset && state.choices.recoveryDecisions?[target.episodeKey] == nil && state.nextAction?.date == anchor && resumes.count == 0 && pings.count == 0,
                "the next 100-percent poll retains the true reset and waits for the protected anchor without creating a decision")
            clockNow = reset.addingTimeInterval(-20); live.capturedAt = clockNow
            try await readUsage()
            clockNow = reset.addingTimeInterval(14); live.capturedAt = clockNow
            live.fiveHour?.usedPercent = 0; live.fiveHour?.resetsAt = clockNow.addingTimeInterval(18000); live.zeroUseWindowActive = false
            try await readUsage()
            check(state.choices.recoveryDecisions?[target.episodeKey] == nil && state.nextAction?.date == anchor && state.nextAction?.decision == .wait(reason: "按计划自动继续") && resumes.count == 0 && pings.count == 0,
                "a naturally observed reset inside anchor protection waits for the anchor through real AppState")
            state = makeState(); state.sessions.refresh(); try await settle(); try await readUsage()
            check(state.choices.recoveryDecisions?[target.episodeKey] == nil && state.nextAction?.date == anchor && resumes.count == 0,
                "restart retains the natural-reset deadline and anchor protection without inventing a pending decision")
            clockNow = Date(); live.capturedAt = clockNow; live.fiveHour?.resetsAt = clockNow.addingTimeInterval(18000)
            try await readUsage()
            for _ in 0..<400 { if !execution.running { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            check(state.schedule.currentNode(at: clockNow) == anchor && resumes.count == 1 && execution.hasAttempted(target) && pings.count == 0 && execution.confirmations.filter { $0.kind == .resume }.count == 1,
                "the protected task resumes once at its anchor through the fake transport instead of dispatching a ping")
            state.recompute(); try await settle()
            state = makeState(); state.sessions.refresh(); try await settle(); try await readUsage()
            check(resumes.count == 1 && pings.count == 0 && execution.confirmations.filter { $0.kind == .resume }.count == 1,
                "recompute and restart cannot duplicate the confirmed anchor continuation")

            clockNow = anchor.addingTimeInterval(-600); live.capturedAt = clockNow; live.fiveHour?.resetsAt = clockNow.addingTimeInterval(18000)
            try await readUsage()
            let earlyStop = clockNow.addingTimeInterval(-120)
            let earlyPath = traces.appendingPathComponent("rollout-\(childID).jsonl")
            try stoppedTrace(childID, at: earlyStop, used: 100, resetsAt: clockNow.addingTimeInterval(18000)).write(to: earlyPath, atomically: true, encoding: .utf8)
            state.sessions.refresh(); try await settle()
            let earlyTask = state.availableTasks.first!
            let earlyDecision = state.choices.recoveryDecisions?[earlyTask.episodeKey]
            check(earlyTask.id == childID && earlyDecision?.phase == .waitingForActivity && state.nextAction?.date == anchor && state.nextAction?.mode == .keepAlive && resumes.count == 1,
                "available quota after a stop creates an unanswered reminder while the main plan stays on keep-alive")
            state = makeState(); state.sessions.refresh(); try await settle(); try await readUsage()
            check(state.choices.recoveryDecisions?[earlyTask.episodeKey] == earlyDecision && state.nextAction?.date == anchor && resumes.count == 1,
                "restart keeps an unanswered reminder without scheduling its continuation")
            let earlySummary = MenuSummary.build(plan: state.nextAction, usage: state.usage.snapshot, schedule: state.schedule, tasks: state.selectedTasks, now: clockNow)
            check(earlySummary.isTime && earlySummary.action == "保持活动" && earlySummary.statusSymbol == "waveform.path.ecg" && earlySummary.timeline.map(\.kind) == [.keepAlive] && earlySummary.tasks == [earlyTask.displayName],
                "production unanswered reminder with no active window retains its task while showing normal keep-alive")
            var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime)) as! [String: Any]
            var legacyChoices = legacy["choices"] as! [String: Any]
            var legacyDecisions = legacyChoices["recoveryDecisions"] as! [String: [String: Any]]
            legacyDecisions[earlyTask.episodeKey]?["phase"] = RecoveryDecision.Phase.waitingForChoice.rawValue
            legacyDecisions[earlyTask.episodeKey]?["deadline"] = anchor.addingTimeInterval(-1).timeIntervalSinceReferenceDate
            legacyChoices["recoveryDecisions"] = legacyDecisions; legacy["choices"] = legacyChoices
            try JSONSerialization.data(withJSONObject: legacy).write(to: runtime, options: .atomic)
            state = makeState(); state.sessions.refresh(); try await settle(); try await readUsage()
            clockNow = Date(); live.capturedAt = clockNow; live.fiveHour?.resetsAt = clockNow.addingTimeInterval(18000)
            let availableNow = live
            for gate in ["exhausted", "missing", "account", "stale"] {
                live = availableNow
                switch gate {
                case "exhausted": live.fiveHour?.usedPercent = 100
                case "missing": live.fiveHour = nil
                case "account": live.accountID = "different-account"
                default: live.capturedAt = clockNow.addingTimeInterval(-61)
                }
                try await readUsage()
                check(resumes.count == 1 && !execution.hasAttempted(earlyTask) && pings.count == 0 && !state.choices.keepAliveEpisodes.contains(earlyTask.episodeKey),
                    "unanswered legacy reminder at its node remains pending with \(gate) quota without cancelling or sending")
            }
            live = availableNow; try await readUsage()
            check(resumes.count == 1 && !execution.hasAttempted(earlyTask) && state.choices.recoveryDecisions?[earlyTask.episodeKey]?.phase == .waitingForChoice && !state.choices.keepAliveEpisodes.contains(earlyTask.episodeKey),
                "an unanswered reminder with an expired legacy deadline stays pending at a node with available quota")
            state.resolveRecoveryDecision(.plan, for: [earlyTask])
            for _ in 0..<400 { if !execution.running { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            check(resumes.count == 2 && execution.hasAttempted(earlyTask) && pings.count == 0 && execution.confirmations.filter { $0.kind == .resume }.count == 2 && !state.choices.keepAliveEpisodes.contains(earlyTask.episodeKey),
                "explicit continue-as-scheduled choice resumes once at the node through normal preflight")
            state.recompute(); try await settle()
            check(resumes.count == 2 && execution.confirmations.filter { $0.kind == .resume }.count == 2,
                "the explicitly approved scheduled continuation does not resend after completion")
            state.usage.stop(); state.sessions.stop()
        }

        // The coordinator uses original node keys even as each five-hour window drifts later.
        do {
            let root = temp.appendingPathComponent("keepalive-grace-coordinator")
            let home = root.appendingPathComponent("codex")
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            let suite = "keeper.grace.coordinator." + UUID().uuidString
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            prefs.register(defaults: ["enabled": true, "dailyAnchorMinutes": 480])
            let nodes = schedule.nodes(on: Date())
            var clockNow = nodes[0]
            func idle() -> UsageSnapshot {
                UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: clockNow.addingTimeInterval(18000)),
                    weekly: nil, capturedAt: clockNow, accountID: "grace-account", sourceFile: "app-server", zeroUseWindowActive: false)
            }
            let provider = RecoveryTestUsage(snapshot: idle())
            let pings = ReminderTestPing()
            let ledger = root.appendingPathComponent("support/resume-attempts.json")
            var coordinator: ExecutionCoordinator? = ExecutionCoordinator(provider: provider, defaults: prefs, ledgerURL: ledger,
                pingTransport: pings, codexHome: home, now: { clockNow })
            func settle() async throws {
                for _ in 0..<300 { if coordinator?.running != true { break }; try await Task.sleep(nanoseconds: 10_000_000) }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            for (index, node) in nodes.enumerated() {
                clockNow = node.addingTimeInterval(Double(50 + index * 90)); provider.set(idle())
                coordinator!.ping(schedule: schedule, accountID: "grace-account", hasPending: { false })
                try await settle()
                check(pings.count == index + 1, "four-node accumulated drift still executes keep-alive round \(index + 1) once")
                clockNow = clockNow.addingTimeInterval(10); provider.set(idle())
                coordinator!.ping(schedule: schedule, accountID: "grace-account", hasPending: { false })
                try await settle()
                check(pings.count == index + 1, "refresh after drifted keep-alive round \(index + 1) cannot duplicate its original node")
            }
            let attempted = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: ledger))) ?? []
            check(Set(attempted) == Set(nodes.map { "ping:grace-account:\($0.timeIntervalSince1970)" }),
                "all drifted keep-alive attempts persist their planned node instead of their delayed send time")
            coordinator = nil
            coordinator = ExecutionCoordinator(provider: provider, defaults: prefs, ledgerURL: ledger,
                pingTransport: pings, codexHome: home, now: { clockNow })
            coordinator!.ping(schedule: schedule, accountID: "grace-account", hasPending: { false }); try await settle()
            check(pings.count == 4, "restarted coordinator cannot resend the final drifted scheduled round")
            coordinator = nil
            for (name, from, to, expected) in [("three-minute crossing", 179.0, 182.0, true), ("ten-minute crossing", 599.0, 600.001, false)] {
                clockNow = nodes[0].addingTimeInterval(from); provider.set(idle()); provider.pause()
                coordinator = ExecutionCoordinator(provider: provider, defaults: prefs, ledgerURL: root.appendingPathComponent(name + "/attempts.json"),
                    pingTransport: pings, codexHome: home, now: { clockNow })
                let oldCount = pings.count
                coordinator!.ping(schedule: schedule, accountID: "grace-account", hasPending: { false })
                try await Task.sleep(nanoseconds: 50_000_000)
                clockNow = nodes[0].addingTimeInterval(to); provider.set(idle()); provider.release(); try await settle()
                check(pings.count == oldCount + (expected ? 1 : 0), "final send guard honors \(name) without changing the attempt node")
                coordinator = nil
            }
        }

        // A manually handled episode must not suppress ordinary keep-alive at due nodes.
        do {
            let root = temp.appendingPathComponent("reminder-keepalive")
            let home = root.appendingPathComponent("codex")
            let traces = home.appendingPathComponent("sessions")
            let runtime = root.appendingPathComponent("support/pending-runtime.json")
            try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
            var connection: OpaquePointer?
            sqlite3_open(home.appendingPathComponent("logs_1.sqlite").path, &connection)
            sqlite3_exec(connection, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil)
            sqlite3_close(connection)
            let at = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            var pingNow = at
            let path = traces.appendingPathComponent("rollout-\(parentID).jsonl")
            try (metadata(parentID, at: at.addingTimeInterval(-300)) + event("error", at.addingTimeInterval(-120), ["message": "usage_limit_reached"]))
                .write(to: path, atomically: true, encoding: .utf8)
            let idle = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: at.addingTimeInterval(18000)),
                weekly: QuotaWindow(usedPercent: 5, windowMinutes: 10080, resetsAt: at.addingTimeInterval(604800)),
                capturedAt: at, accountID: "test-account", sourceFile: "app-server", zeroUseWindowActive: false)
            let provider = RecoveryTestUsage(snapshot: idle)
            let suite = "keeper.reminder.ping." + UUID().uuidString
            let prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: at)
            prefs.register(defaults: ["enabled": true, "autoResume": true, "earlyRecoveryPolicy": "ask", "dailyAnchorMinutes": parts.hour! * 60 + parts.minute!])
            let pings = ReminderTestPing()
            let resumes = BatchRecorder(expected: 1)
            let execution = ExecutionCoordinator(provider: provider, makeResumeTransport: { BatchTransport(recorder: resumes) }, defaults: prefs,
                ledgerURL: root.appendingPathComponent("support/resume-attempts.json"), pingTransport: pings, codexHome: home, now: { pingNow })
            func makeState() -> AppState { AppState(provider: provider, defaults: prefs, runtimeURL: runtime, codexHome: home,
                execution: execution, startMonitoring: false, now: { pingNow }) }
            let storedTarget = BlockedSessionDetector.detect(in: [SessionWatcher.parse(url: path, mtime: at)!]).first!
            var handledChoices = ResumeChoices(); handledChoices.requestRecoveryDecision(for: storedTarget, now: at)
            _ = handledChoices.resolveRecoveryDecision(.now, for: storedTarget)
            let savedChoices = try JSONSerialization.jsonObject(with: JSONEncoder().encode(handledChoices))
            let savedTarget = try JSONSerialization.jsonObject(with: JSONEncoder().encode(storedTarget))
            try JSONSerialization.data(withJSONObject: ["confirmed": [storedTarget.id: savedTarget], "accounts": [storedTarget.id: "test-account"],
                "workspaces": [:], "held": [], "choices": savedChoices]).write(to: runtime, options: .atomic)
            var state = makeState()
            state.sessions.refresh()
            for _ in 0..<30 { try await Task.sleep(nanoseconds: 10_000_000) }
            state.usage.refresh()
            for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
            state.recompute()
            for _ in 0..<40 { if !execution.running { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let target = state.availableTasks.first!
            check(pings.count == 1 && execution.confirmations.filter { $0.kind == .keepAlive }.count == 1,
                "a manually handled episode still permits one confirmed scheduled keep-alive through real AppState")
            check(resumes.count == 0 && !execution.hasAttempted(target) && state.choices.recoveryDecisions?[target.episodeKey]?.phase == .responded,
                "normal keep-alive never continues or clears a manually handled task")
            var summary = MenuSummary.build(plan: state.nextAction, usage: state.usage.snapshot, schedule: state.schedule, tasks: state.selectedTasks)
            summary.applyRecoveryReminder(tasks: state.availableTasks, choices: state.choices)
            check(summary.statusText == L10n.text("待决定") && summary.reminderTitle.isEmpty,
                "a manually handled task does not fabricate a scheduled automatic retry or an unanswered reminder")
            func settle() async throws { for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) } }
            func snapshot(at time: Date) -> UsageSnapshot {
                var result = idle; result.capturedAt = time; result.fiveHour?.resetsAt = time.addingTimeInterval(18000)
                return result
            }
            func reload(_ value: UsageSnapshot) async throws {
                provider.set(value)
                state = makeState()
                state.sessions.refresh(); try await settle()
                state.usage.refresh(); try await settle()
            }
            func setPhase(_ phase: RecoveryDecision.Phase, deadline: Date?, account: String = "test-account") throws {
                var data = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime)) as! [String: Any]
                var choices = data["choices"] as! [String: Any]
                var decisions = choices["recoveryDecisions"] as! [String: [String: Any]]
                decisions[target.episodeKey]?["phase"] = phase.rawValue
                decisions[target.episodeKey]?["deadline"] = deadline?.timeIntervalSinceReferenceDate
                choices["recoveryDecisions"] = decisions; data["choices"] = choices
                data["accounts"] = [target.id: account]
                try JSONSerialization.data(withJSONObject: data).write(to: runtime, options: .atomic)
            }
            state.recompute(); try await settle()
            check(pings.count == 1, "repeated refreshes do not duplicate an already attempted keep-alive node")
            pingNow = at.addingTimeInterval(18000)
            try setPhase(.waitingForActivity, deadline: nil)
            try await reload(snapshot(at: pingNow))
            check(pings.count == 2 && state.choices.recoveryDecisions?[target.episodeKey]?.phase == .waitingForActivity && resumes.count == 0,
                "an unanswered reminder survives the next normal keep-alive node without automatic continuation")
            summary = MenuSummary.build(plan: state.nextAction, usage: state.usage.snapshot, schedule: state.schedule, tasks: state.selectedTasks, now: pingNow)
            summary.applyRecoveryReminder(tasks: state.availableTasks, choices: state.choices)
            check(summary.action == "保持活动" && !summary.reminderTitle.isEmpty && summary.tasks == [target.displayName],
                "an unanswered reminder remains visible with its task and normal keep-alive time after the node")
            pingNow = at.addingTimeInterval(36000)
            let deadline = pingNow.addingTimeInterval(-600)
            try setPhase(.waitingForChoice, deadline: deadline)
            try await reload(snapshot(at: pingNow))
            check(pings.count == 3 && state.choices.recoveryDecisions?[target.episodeKey]?.deadline == deadline,
                "normal keep-alive preserves an unanswered expired legacy reminder across restart")
            pingNow = at.addingTimeInterval(54000)
            try setPhase(.waitingForChoice, deadline: deadline, account: "previous-account")
            try await reload(snapshot(at: pingNow))
            check(pings.count == 4 && state.choices.recoveryDecisions?[target.episodeKey]?.phase == .waitingForChoice && resumes.count == 0,
                "an unanswered other-account task cannot globally stop keep-alive on the current account")

            pingNow = at.addingTimeInterval(86400)
            var unavailable = snapshot(at: pingNow); unavailable.zeroUseWindowActive = true
            try await reload(unavailable)
            check(pings.count == 4, "an existing active window still suppresses keep-alive with a pending reminder")
            unavailable = snapshot(at: pingNow); unavailable.capturedAt = pingNow.addingTimeInterval(-61)
            try await reload(unavailable)
            check(pings.count == 4, "stale quota never permits keep-alive while reminders are ignored")
            unavailable = snapshot(at: pingNow); unavailable.weekly?.usedPercent = 100
            try await reload(unavailable)
            check(pings.count == 4, "weekly exhaustion still blocks keep-alive while reminders are ignored")
            var failedSummary = MenuSummary.build(plan: state.nextAction, usage: nil, schedule: state.schedule, tasks: state.selectedTasks)
            failedSummary.applyIssues(usageError: "同步失败", sessionError: nil, executionFailure: nil, executionAction: "保活")
            var waitingChoices = state.choices
            waitingChoices.recoveryDecisions?[target.episodeKey]?.phase = .waitingForActivity
            failedSummary.applyRecoveryReminder(tasks: state.availableTasks, choices: waitingChoices)
            check(!failedSummary.reminderTitle.isEmpty && !failedSummary.reminderBody.isEmpty && !failedSummary.error.isEmpty && failedSummary.note.isEmpty,
                "a standalone persistent reminder stays visible alongside sync errors without becoming a footnote")

            // Stage a fresh, idle reading without dispatch, then race the execution preflight.
            func readyForRace() async throws {
                prefs.set(false, forKey: "enabled")
                try await reload(snapshot(at: pingNow))
                prefs.set(true, forKey: "enabled")
                provider.pause()
                state.recompute()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try await readyForRace()
            var switched = snapshot(at: pingNow); switched.accountID = "different-account"
            provider.set(switched); provider.release(); try await settle()
            check(pings.count == 4 && execution.lastFailure != nil,
                "changing the actual ping account during preflight still blocks every send")
            try await readyForRace()
            unavailable = snapshot(at: pingNow); unavailable.zeroUseWindowActive = true
            provider.set(unavailable); provider.release(); try await settle()
            check(pings.count == 4, "a window that becomes active during ping preflight is not opened again")
            try await readyForRace()
            let surprisePath = traces.appendingPathComponent("rollout-\(childID).jsonl")
            try (metadata(childID, at: pingNow.addingTimeInterval(-60)) + event("error", pingNow.addingTimeInterval(-1), ["message": "usage_limit_reached"]))
                .write(to: surprisePath, atomically: true, encoding: .utf8)
            provider.release(); try await settle()
            check(pings.count == 4 && execution.lastFailure != nil,
                "the final fresh task scan rejects a newly paused episode outside the frozen ignored set")
            try FileManager.default.removeItem(at: surprisePath)
            try await readyForRace()
            let originalTrace = try String(contentsOf: path, encoding: .utf8)
            try (originalTrace + event("user_message", pingNow)).write(to: path, atomically: true, encoding: .utf8)
            state.sessions.refresh(); try await settle()
            provider.release(); try await settle()
            check(pings.count == 4 && state.choices.recoveryDecisions?[target.episodeKey] == nil,
                "a changed task that revokes the frozen ignored state aborts the pending keep-alive")
            check(resumes.count == 0 && !execution.hasAttempted(target),
                "all keep-alive paths leave the paused task's resume attempt ledger untouched")
            state.usage.stop(); state.sessions.stop()
        }

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

final class UnnotifiedExitProcess: Process, @unchecked Sendable {
    // NSTask is a class cluster on macOS; forward process work to its concrete instance.
    private let child = Process()
    var holdExitNotification = false
    private let exitWait = DispatchSemaphore(value: 0)
    override var executableURL: URL? { get { child.executableURL } set { child.executableURL = newValue } }
    override var arguments: [String]? { get { child.arguments } set { child.arguments = newValue } }
    override var environment: [String: String]? { get { child.environment } set { child.environment = newValue } }
    override var standardInput: Any? { get { child.standardInput } set { child.standardInput = newValue } }
    override var standardOutput: Any? { get { child.standardOutput } set { child.standardOutput = newValue } }
    override var standardError: Any? { get { child.standardError } set { child.standardError = newValue } }
    override var processIdentifier: Int32 { child.processIdentifier }
    override var isRunning: Bool { holdExitNotification || child.isRunning }
    override func run() throws { try child.run() }
    override func terminate() { child.terminate() }
    override func waitUntilExit() { exitWait.wait() }
    func releaseExitWait() { exitWait.signal() }
}

struct FakePingUsage: UsageProvider {
    let account: String
    func pingModel() throws -> PingModel { PingModel(model: "gpt-5.6-luna", reasoningEffort: "low") }
    func read() throws -> UsageSnapshot {
        let now = Date()
        return UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 0, windowMinutes: 300, resetsAt: now.addingTimeInterval(5 * 3600)), weekly: nil, capturedAt: now, accountID: account, sourceFile: "app-server", zeroUseWindowActive: true)
    }
}

final class ConfirmationTestUsage: UsageProvider {
    private(set) var calls = 0
    private let onRead: (Int) throws -> UsageSnapshot
    init(_ onRead: @escaping (Int) throws -> UsageSnapshot) { self.onRead = onRead }
    func read() throws -> UsageSnapshot { calls += 1; return try onRead(calls) }
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

final class RecoveryTestUsage: UsageProvider, @unchecked Sendable {
    private let condition = NSCondition()
    private var snapshot: UsageSnapshot
    private var failing = false
    private var paused = false
    private var reads = 0
    init(snapshot: UsageSnapshot) { self.snapshot = snapshot }
    var readCount: Int { condition.lock(); defer { condition.unlock() }; return reads }
    func pingModel() throws -> PingModel { PingModel(model: "gpt-5.6-luna", reasoningEffort: "low") }
    func set(_ value: UsageSnapshot, failing: Bool = false) {
        condition.lock(); defer { condition.unlock() }
        snapshot = value; self.failing = failing
    }
    func pause() { condition.lock(); paused = true; condition.unlock() }
    func release() { condition.lock(); paused = false; condition.broadcast(); condition.unlock() }
    func read() throws -> UsageSnapshot {
        condition.lock(); defer { condition.unlock() }
        reads += 1
        let limit = Date().addingTimeInterval(3)
        while paused { if !condition.wait(until: limit) { throw CodexConnectionError.timeout } }
        if failing { throw CodexConnectionError.timeout }
        return snapshot
    }
}

final class ReminderTestPing: PingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider) throws -> UsageSnapshot {
        lock.lock(); calls += 1; lock.unlock()
        var after = before
        after.zeroUseWindowActive = true
        after.fiveHour?.usedPercent = 1
        return after
    }
    func cancel() {}
}

private func checkSteadyMenuPresentation(_ check: (Bool, String) -> Void) {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9, minute: 40))!
    let schedule = ScheduleEngine(anchorMinutes: 480)
    let start = schedule.nodes(on: now)[0]
    let reset = start.addingTimeInterval(18000)
    let live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: reset),
        weekly: QuotaWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: now.addingTimeInterval(6 * 86400)),
        capturedAt: now, accountID: "steady-menu-account", sourceFile: "app-server")
    let task = BlockedSession(id: "steady-task", project: "Fixture", cwd: "/fixture",
        blockedAt: now.addingTimeInterval(-600), fiveHourResetAt: reset, weeklyResetAt: nil,
        fileURL: URL(fileURLWithPath: "/fixture/steady-task.jsonl"), title: "仍在继续的任务")
    let confirmed = ExecutionConfirmation(kind: .keepAlive, actionAt: start,
        confirmedAt: start.addingTimeInterval(60), windowStart: start)
    func render(_ presentation: inout MenuPresentation, usage: UsageSnapshot?, time: Date? = nil,
                tasks: [BlockedSession] = [], available: [BlockedSession]? = nil, choices: ResumeChoices = ResumeChoices(),
                enabled: Bool = true, autoResume: Bool = true, policy: String = "keepPlan", anchor: Int = 480,
                plan override: NextAction? = nil, usageError: String? = nil, transient: Bool = false,
                sessionError: String? = nil, running: Bool = false, mode: NextActionMode? = nil,
                failure: String? = nil, warning: String? = nil, refreshing: Bool = false, message: String = "",
                confirmations: [ExecutionConfirmation]? = nil) -> MenuSummary {
        let at = time ?? now
        let schedule = ScheduleEngine(anchorMinutes: anchor)
        let plan = override ?? DecisionEngine(schedule: schedule).plan(now: at, enabled: enabled,
            autoResume: autoResume, earlyRecoveryPolicy: policy, usage: usage, blocked: tasks)
        return presentation.build(plan: plan, usage: usage, schedule: schedule, tasks: tasks,
            availableTasks: available ?? tasks, choices: choices, enabled: enabled, autoResume: autoResume,
            earlyRecoveryPolicy: policy, confirmations: confirmations ?? [confirmed], usageError: usageError,
            usageErrorIsTransient: transient, sessionError: sessionError, running: running,
            executionMode: mode, executionFailure: failure, executionWarning: warning,
            refreshing: refreshing, refreshMessage: message, now: at)
    }

    var presentation = MenuPresentation()
    let shown = render(&presentation, usage: live)
    for seconds in [20.0, 61.0, 121.0, 300.0] {
        let syncing = render(&presentation, usage: live, time: now.addingTimeInterval(seconds),
            usageError: seconds > 60 ? "临时连接失败" : nil, transient: true, refreshing: true)
        check(syncing.headline == shown.headline && syncing.action == shown.action && syncing.isTime,
            "continuous background synchronization retains the last valid primary menu time past sixty seconds: \(Int(seconds))")
        check(syncing.timeline.map(\.date) == shown.timeline.map(\.date) && syncing.quotas.count == shown.quotas.count,
            "continuous background synchronization retains the timeline and quota blocks: \(Int(seconds))")
        check(syncing.refreshMessage == shown.refreshMessage && syncing.statusSymbol == shown.statusSymbol,
            "background refresh preserves the real update timestamp and primary icon: \(Int(seconds))")
    }
    check(!live.isFresh(at: now.addingTimeInterval(61)) &&
        DecisionEngine(schedule: schedule).plan(now: now.addingTimeInterval(61), enabled: true, autoResume: true,
            earlyRecoveryPolicy: "keepPlan", usage: live, blocked: []).date == nil,
        "display continuity never extends quota freshness or supplies an executable plan")
    var invalidated = live; invalidated.capturedAt = .distantPast
    let afterInvalidation = render(&presentation, usage: invalidated, refreshing: true)
    check(afterInvalidation.headline == shown.headline && afterInvalidation.timeline.map(\.date) == shown.timeline.map(\.date),
        "environment-triggered invalidation retains the last displayed valid menu during the next read")
    var rollout = live; rollout.sourceFile = "rollout.jsonl"; rollout.accountID = nil
    let fallback = render(&presentation, usage: rollout, time: now.addingTimeInterval(301), usageError: "临时服务失败", transient: true)
    let missing = render(&presentation, usage: nil, time: now.addingTimeInterval(302), usageError: "临时服务失败", transient: true)
    check(fallback.headline == shown.headline && missing.headline == shown.headline &&
        fallback.refreshMessage == shown.refreshMessage && missing.refreshMessage == shown.refreshMessage &&
        missing.quotas.count == shown.quotas.count,
        "rollout fallback or missing readings cannot erase or replace the last valid app-server display")
    var recovered = live; recovered.capturedAt = now.addingTimeInterval(303)
    recovered.fiveHour?.resetsAt = reset.addingTimeInterval(660); recovered.fiveHour?.usedPercent = 37
    let updated = render(&presentation, usage: recovered, time: recovered.capturedAt)
    check(updated.headline == "13:11" && updated.action == "额度重置" && updated.quotas.first?.remaining == 63 &&
        updated.error.isEmpty && updated.refreshMessage != shown.refreshMessage,
        "a new valid reading immediately replaces the retained time, quota, timestamp and temporary error")
    var noWindows = recovered; noWindows.fiveHour = nil; noWindows.weekly = nil
    noWindows.capturedAt.addTimeInterval(1)
    let emptyUpdate = render(&presentation, usage: noWindows, time: noWindows.capturedAt)
    let emptyRetry = render(&presentation, usage: nil, time: noWindows.capturedAt, usageError: "临时服务失败", transient: true)
    check(emptyUpdate.quotas.isEmpty && emptyUpdate.timeline.isEmpty && !emptyUpdate.isTime &&
        emptyRetry.quotas.isEmpty && emptyRetry.timeline.isEmpty,
        "a real reading explicitly without windows replaces the old display and cannot revive it on failure")
    var unknown = recovered; unknown.fiveHour?.usedPercent = 0; unknown.zeroUseWindowActive = nil
    let unknownUpdate = render(&presentation, usage: unknown, time: unknown.capturedAt)
    check(!unknownUpdate.isTime && unknownUpdate.statusText == "待同步" && unknownUpdate.timeline.isEmpty && unknownUpdate.quotas.first?.detail == "—",
        "a meaningful new unknown-window reading replaces an old confirmed window")

    var first = MenuPresentation()
    let firstIdle = render(&first, usage: nil)
    let firstReading = render(&first, usage: nil, refreshing: true)
    let firstFailure = render(&first, usage: rollout, usageError: "临时连接失败", transient: true)
    check(firstIdle.statusText == "待同步" && firstReading.statusText == "同步中" && firstFailure.quotas.isEmpty &&
        firstFailure.timeline.isEmpty && !firstFailure.error.isEmpty,
        "first launch without any valid display still reports idle, reading and failure states accurately")

    for issue in ["账户认证失败", "接口不兼容", "无效响应"] {
        var fatal = MenuPresentation(); _ = render(&fatal, usage: live)
        let failed = render(&fatal, usage: live, usageError: issue)
        let retry = render(&fatal, usage: nil, usageError: "临时连接失败", transient: true)
        check(failed.statusSymbol == "exclamationmark.circle" && failed.quotas.isEmpty && !failed.isTime &&
            retry.quotas.isEmpty && !retry.isTime,
            "fatal usage errors clear old display and cannot be covered by a later transient retry: \(issue)")
    }
    var account = MenuPresentation(); _ = render(&account, usage: live)
    var switched = invalidated; switched.accountID = "another-account"
    let changed = render(&account, usage: switched, refreshing: true)
    check(changed.quotas.isEmpty && changed.timeline.isEmpty && !changed.isTime,
        "an observed app-server account change clears retained display even before the new account has a fresh reading")
    var mismatch = MenuPresentation(); _ = render(&mismatch, usage: live)
    let accountPlan = NextAction(mode: .resume, date: nil, decision: .wait(reason: "账户已改变"), note: "账户已改变")
    let refused = render(&mismatch, usage: nil, plan: accountPlan, usageError: "临时连接失败", transient: true)
    check(!refused.isTime && refused.quotas.isEmpty && refused.statusSymbol == "exclamationmark.circle",
        "an account mismatch in the actual task plan cannot reuse an earlier account's display")
    var scanner = MenuPresentation(); _ = render(&scanner, usage: live)
    let scanFailure = render(&scanner, usage: live, sessionError: "任务扫描不兼容")
    check(!scanFailure.isTime && scanFailure.quotas.isEmpty && scanFailure.statusSymbol == "exclamationmark.circle",
        "fatal task scanning errors clear retained action display while exposing the current error")

    var stopped = live; stopped.fiveHour?.usedPercent = 100
    var settings = MenuPresentation(); _ = render(&settings, usage: stopped, tasks: [task])
    let disabled = render(&settings, usage: stopped, tasks: [task], enabled: false)
    let reopened = render(&settings, usage: nil, tasks: [task])
    check(disabled.headline == "已停用" && disabled.quotas.isEmpty && !reopened.isTime && reopened.timeline.isEmpty,
        "turning Keeper off and on never resurrects the previous cached plan")
    for setting in 0..<3 {
        var altered = MenuPresentation(); _ = render(&altered, usage: stopped, tasks: [task])
        let next = render(&altered, usage: nil, tasks: [task], autoResume: setting != 0,
            policy: setting == 1 ? "ask" : "keepPlan", anchor: setting == 2 ? 540 : 480)
        check(!next.isTime && next.timeline.isEmpty && next.action.isEmpty,
            "changed automatic continuation, policy or schedule settings discard the old action plan: \(setting)")
    }
    var selection = MenuPresentation(); _ = render(&selection, usage: stopped, tasks: [task])
    var deselected = ResumeChoices(); deselected.deselectedEpisodes.insert(task.episodeKey)
    let unselected = render(&selection, usage: nil, tasks: [], available: [task], choices: deselected)
    check(!unselected.isTime && unselected.timeline.isEmpty && unselected.tasks == [task.displayName],
        "changing the task selection clears the previous resume plan while showing the currently available task")
    var cancellation = MenuPresentation(); _ = render(&cancellation, usage: stopped, tasks: [task])
    var canceled = ResumeChoices(); canceled.useKeepAlive(for: [task])
    let afterCancel = render(&cancellation, usage: nil, choices: canceled)
    check(afterCancel.tasks.isEmpty && afterCancel.timeline.isEmpty && !afterCancel.isTime,
        "canceling a stop episode cannot retain its old task bubble or continuation node")
    var changedPlan = MenuPresentation(); _ = render(&changedPlan, usage: live)
    let differentPlan = NextAction(mode: .keepAlive, date: reset.addingTimeInterval(18000),
        decision: .wait(reason: "新的计划"), note: "新的计划")
    let replanned = render(&changedPlan, usage: nil, plan: differentPlan)
    let replannedRetry = render(&changedPlan, usage: nil)
    check(!replanned.isTime && replanned.timeline.isEmpty && !replannedRetry.isTime,
        "a changed meaningful plan cannot be overwritten by the previous display while quota is stale")
    var nextDay = MenuPresentation(); _ = render(&nextDay, usage: live)
    let overnight = render(&nextDay, usage: nil, time: now.addingTimeInterval(86400), refreshing: true)
    check(!overnight.isTime && overnight.timeline.isEmpty && overnight.quotas.isEmpty,
        "a new calendar day cannot reuse yesterday's today-or-tomorrow labels and action plan")

    var executing = MenuPresentation()
    let beforeExecution = render(&executing, usage: stopped, tasks: [task])
    let began = render(&executing, usage: stopped, tasks: [task], running: true, mode: .resume)
    check(began.headline == "正在继续" && began.timeline.map(\.date) == beforeExecution.timeline.map(\.date) &&
        began.timeline.first?.kind == .completedKeepAlive && began.timeline.last?.kind == .resume,
        "starting continuation retains confirmed keep-alive history without marking the running continuation complete")
    let attempted = render(&executing, usage: invalidated, time: now.addingTimeInterval(61), tasks: [],
        usageError: "临时连接失败", transient: true, running: true, mode: .resume, refreshing: true)
    check(attempted.headline == "正在继续" && attempted.timeline.map(\.date) == began.timeline.map(\.date) &&
        attempted.tasks == began.tasks && attempted.quotas.count == began.quotas.count &&
        attempted.refreshMessage == began.refreshMessage,
        "a persisted attempt filtering out the selected task and an invalidated reading retain the executing menu blocks past sixty seconds")
    var runningLive = live; runningLive.capturedAt = now.addingTimeInterval(62); runningLive.fiveHour?.usedPercent = 9
    let runningUpdate = render(&executing, usage: runningLive, time: runningLive.capturedAt, running: true, mode: .resume)
    check(runningUpdate.quotas.first?.remaining == 91 && runningUpdate.timeline.map(\.date) == began.timeline.map(\.date) &&
        runningUpdate.tasks == began.tasks && runningUpdate.timeline.last?.kind == .resume,
        "new quota updates during continuation preserve the captured timeline and task without claiming completion")
    let runningRetry = render(&executing, usage: nil, time: runningLive.capturedAt.addingTimeInterval(61),
        usageError: "临时连接失败", transient: true, running: true, mode: .resume)
    check(runningRetry.quotas.first?.remaining == 91 && runningRetry.timeline.map(\.date) == began.timeline.map(\.date) &&
        runningRetry.tasks == began.tasks && runningRetry.refreshMessage.hasSuffix(String(runningUpdate.refreshMessage.suffix(8))),
        "a later stale or failed read during execution retains the newest valid quota rather than reverting to the execution-start quota")
    let finished = render(&executing, usage: runningLive, time: runningLive.capturedAt, mode: .resume)
    check(finished.headline != "正在继续" && finished.isTime && finished.tasks.isEmpty &&
        !finished.timeline.contains { $0.kind == .resume },
        "when execution ends the display immediately returns to the current normal plan without the frozen task")
    let continuedAt = now.addingTimeInterval(63)
    var continued = runningLive; continued.capturedAt = continuedAt
    continued.fiveHour?.resetsAt = continuedAt.addingTimeInterval(18000)
    let confirmedFinish = render(&executing, usage: continued, time: continuedAt,
        confirmations: [ExecutionConfirmation(kind: .resume, actionAt: continuedAt,
            confirmedAt: continuedAt, windowStart: continuedAt)])
    check(confirmedFinish.timeline.first?.kind == .completedResume && confirmedFinish.tasks.isEmpty && confirmedFinish.isTime,
        "an actual matching confirmation updates the normal post-execution timeline to completed continuation")
    var runningAccount = MenuPresentation()
    _ = render(&runningAccount, usage: stopped, tasks: [task], running: true, mode: .resume)
    _ = render(&runningAccount, usage: nil, running: true, mode: .resume)
    let runningChanged = render(&runningAccount, usage: switched, running: true, mode: .resume)
    check(runningChanged.timeline.isEmpty && runningChanged.quotas.isEmpty && runningChanged.tasks.isEmpty,
        "account changes during an executing fallback also clear the captured account's timeline and task")
    var warningState = MenuPresentation()
    _ = render(&warningState, usage: live, running: true, mode: .keepAlive)
    let waiting = render(&warningState, usage: nil, running: true, mode: .keepAlive, warning: "本轮仍在等待真实确认")
    let warningCleared = render(&warningState, usage: nil, running: true, mode: .keepAlive)
    check(waiting.headline == "保活等待中" && waiting.statusSymbol == "exclamationmark.circle" &&
        !waiting.timeline.isEmpty && warningCleared.warning.isEmpty && warningCleared.note.isEmpty,
        "current wait warnings overlay retained history and disappear as soon as the real warning clears")
    var history = MenuPresentation()
    let firstHistory = render(&history, usage: live, failure: "旧保活失败")
    let repeatedHistory = render(&history, usage: live, time: now.addingTimeInterval(61), failure: "旧保活失败")
    let clearedHistory = render(&history, usage: live, time: now.addingTimeInterval(62))
    check(firstHistory.note == repeatedHistory.note && clearedHistory.note.isEmpty && clearedHistory.error.isEmpty,
        "cached bases never accumulate old execution failures or other transient overlays")
    var reminderState = MenuPresentation()
    var reminderChoices = ResumeChoices(); reminderChoices.requestRecoveryDecision(for: task, now: now)
    _ = render(&reminderState, usage: live, tasks: [task], choices: reminderChoices)
    reminderChoices.recoveryDecisions?[task.episodeKey]?.notification = .delivered
    let deliveredReminder = render(&reminderState, usage: nil, tasks: [task], choices: reminderChoices,
        usageError: "临时连接失败", transient: true)
    check(!deliveredReminder.reminderTitle.isEmpty && !deliveredReminder.quotas.isEmpty,
        "notification delivery does not clear unchanged action context and the current recovery reminder survives sync failure")
    let resolvedReminder = render(&reminderState, usage: live)
    check(resolvedReminder.reminderTitle.isEmpty && resolvedReminder.reminderBody.isEmpty,
        "resolved recovery reminders never linger in the cached base display")

    var manual = MenuPresentation(); _ = render(&manual, usage: live)
    manual.requestRefreshFeedback()
    let clicked = render(&manual, usage: live, refreshing: true, message: "正在刷新额度…")
    let queued = render(&manual, usage: live, refreshing: true, message: "正在同步，完成后重新读取…")
    let clickFailure = render(&manual, usage: live, usageError: "临时失败", transient: true,
        message: "刷新失败，请点击刷新按钮重试。")
    check(clicked.isRefreshing && clicked.refreshMessage == "正在刷新额度…" &&
        queued.refreshMessage == "正在同步，完成后重新读取…" && clickFailure.refreshMessage.contains("刷新失败"),
        "explicit refresh clicks retain immediate, queued and completed feedback for the accessible production view")
    let automatic = render(&manual, usage: live, refreshing: true, message: "刷新失败，请点击刷新按钮重试。")
    check(automatic.refreshMessage == shown.refreshMessage && !automatic.refreshMessage.contains("刷新失败"),
        "a later background read displays the last real update instead of inheriting a previous manual failure message")
}
