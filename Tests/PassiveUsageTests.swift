import Foundation
import SQLite3

@MainActor func checkPassiveUsage(_ check: (Bool, String) -> Void, root: URL) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = try PassiveUsageFixture(home: root.appendingPathComponent("reader"))
    let clock = PassiveUsageClock(Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
    let reader = RolloutUsageReader(home: fixture.home, now: { clock.value })
    let firstID = UUID().uuidString
    let first = fixture.home.appendingPathComponent("sessions/2026/10/24/rollout-\(firstID).jsonl")
    try fixture.write(first, thread: firstID, at: clock.value, used: 37)
    check(reader.read(changedPaths: [first.path]).isEmpty, "unregistered new rollout cannot establish an account reading")
    try fixture.register(first, thread: firstID)
    var readings = reader.read()
    check(readings.last?.snapshot.fiveHour?.usedPercent == 37 && readings.last?.snapshot.accountID == "passive-a",
        "database registration after the first write discovers its complete first quota without another append")
    clock.advance()
    try fixture.append(first, at: clock.value, used: 37)
    readings = reader.read(changedPaths: [first.path])
    check(readings.last?.snapshot.capturedAt == clock.value, "equal quota percentages still advance the real collection timestamp")
    clock.advance()
    let pending = try fixture.quota(at: clock.value, used: 38)
    try fixture.appendData(first, data: pending.prefix(pending.count / 2))
    check(reader.read(changedPaths: [first.path]).isEmpty, "an incomplete JSONL quota is held without publication")
    try fixture.appendData(first, data: pending.suffix(pending.count - pending.count / 2))
    check(reader.read(changedPaths: [first.path]).last?.snapshot.fiveHour?.usedPercent == 38,
        "the remaining bytes complete the same quota exactly once")
    check(reader.read(changedPaths: [first.path]).isEmpty, "an unchanged file never replays old quota lines")
    clock.advance(); try fixture.append(first, at: clock.value, used: 100)
    clock.advance(); try fixture.append(first, at: clock.value, used: 38)
    check(reader.read(changedPaths: [first.path]).map { $0.snapshot.fiveHour!.usedPercent } == [100, 38],
        "one native batch preserves an intervening quota collision and recovery instead of returning only its last line")
    for limits in [["limit_id": "premium"], ["limitId": "premium"], ["limit_name": "premium"], ["limitName": "premium"]] {
        clock.advance(); try fixture.appendData(first, data: fixture.quota(at: clock.value, used: 99, extraLimits: limits))
        check(reader.read(changedPaths: [first.path]).isEmpty, "non-codex limit identifiers and named legacy buckets are rejected: \(limits)")
    }
    clock.advance(); try fixture.appendData(first, data: fixture.quota(at: clock.value, used: 39, omitID: true))
    check(reader.read(changedPaths: [first.path]).last?.snapshot.fiveHour?.usedPercent == 39,
        "a compatible unlabelled ordinary legacy bucket remains readable")
    for timestamp in [clock.value.addingTimeInterval(-301), clock.value.addingTimeInterval(1)] {
        try fixture.append(first, at: timestamp, used: 99)
        check(reader.read(changedPaths: [first.path]).isEmpty, "expired and future events cannot masquerade as current quota")
    }
    try fixture.appendData(first, data: fixture.quota(at: nil, used: 99))
    check(reader.read(changedPaths: [first.path]).isEmpty, "missing event timestamp is never replaced by the file modification time")
    clock.advance()
    let next = fixture.home.appendingPathComponent("sessions/2026/10/25/rollout-new-\(firstID).jsonl")
    try fixture.write(next, thread: firstID, at: clock.value, used: 40)
    try fixture.register(next, thread: firstID)
    try fixture.append(first, at: clock.value, used: 99)
    readings = reader.read(changedPaths: [first.path, next.path])
    check(readings.count == 1 && readings.last?.snapshot.fiveHour?.usedPercent == 40 && readings.last?.snapshot.sourceFile == next.path,
        "a cross-date replacement follows threads.rollout_path even when the old rollout was written later")
    clock.advance()
    let moved = next.appendingPathExtension("old")
    try FileManager.default.moveItem(at: next, to: moved)
    check(reader.read(changedPaths: [next.path]).isEmpty, "a renamed registered rollout contributes no fabricated replacement")
    try fixture.write(next, thread: firstID, at: clock.value, used: 41)
    check(reader.read(changedPaths: [next.path]).last?.snapshot.fiveHour?.usedPercent == 41, "a replacement inode at the current registered path is rediscovered")
    clock.advance()
    let handle = try FileHandle(forWritingTo: next)
    try handle.truncate(atOffset: 0); try handle.close()
    try fixture.write(next, thread: firstID, at: clock.value, used: 42, padding: 500)
    check(reader.read(changedPaths: [next.path]).last?.snapshot.fiveHour?.usedPercent == 42,
        "same-inode truncation followed by a longer rewrite resets the incremental cursor")
    let wrongID = UUID().uuidString
    let wrong = fixture.home.appendingPathComponent("sessions/other/rollout-\(wrongID).jsonl")
    try fixture.write(wrong, thread: UUID().uuidString, at: clock.value, used: 99)
    try fixture.register(wrong, thread: wrongID)
    check(reader.read(changedPaths: [wrong.path]).isEmpty, "session_meta ownership must agree with the database thread")
    try fixture.register(next, thread: UUID().uuidString)
    check(reader.read(changedPaths: [next.path]).isEmpty, "same-account duplicate registrations for one path remain ambiguous")
    let forkID = UUID().uuidString
    let fork = fixture.home.appendingPathComponent("sessions/other/rollout-\(forkID).jsonl")
    clock.advance()
    try fixture.write(fork, thread: forkID, at: clock.value, used: 99, fork: true)
    try fixture.register(fork, thread: forkID)
    check(reader.read(changedPaths: [fork.path]).isEmpty, "fork history re-stamped at the owning metadata time is excluded")
    clock.advance(); try fixture.append(fork, at: clock.value, used: 43)
    check(reader.read(changedPaths: [fork.path]).last?.snapshot.fiveHour?.usedPercent == 43, "new fork activity after the inherited cutoff is accepted")
    try fixture.authenticate("passive-b")
    check(reader.read().isEmpty && reader.authenticationChanged, "switching accounts immediately isolates previously observed rollout data")
    try fixture.register(fork, thread: forkID, account: "passive-b")
    check(reader.read().last?.snapshot.accountID == "passive-b", "only a current rollout explicitly owned by the new account can reappear")
    try checkConcurrentPassiveIndexUpdates(check, root: root.appendingPathComponent("concurrent-index"))
    try await checkFiveMinuteRecovery(check, root: root.appendingPathComponent("five-minute-recovery"))
    try await checkPassiveResumeAdmission(check, root: root.appendingPathComponent("resume-admission"))
    try await checkPassiveUsagePresentation(check, root: root.appendingPathComponent("presentation"))
    try await checkNativePassiveDiscovery(check, root: root.appendingPathComponent("native"))
}

private func checkConcurrentPassiveIndexUpdates(_ check: (Bool, String) -> Void, root: URL) throws {
    let fixture = try PassiveUsageFixture(home: root)
    let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let id = UUID().uuidString
    let first = fixture.home.appendingPathComponent("sessions/original/rollout-\(id).jsonl")
    let replacement = fixture.home.appendingPathComponent("sessions/restored/rollout-\(id).jsonl")
    try fixture.write(first, thread: id, at: date, used: 37)
    try fixture.write(replacement, thread: id, at: date, used: 38)
    try fixture.register(first, thread: id)
    var duringRead: (() throws -> Void)?
    var writeError: Error?
    let reader = RolloutUsageReader(home: fixture.home, now: {
        let operation = duringRead; duringRead = nil
        do { try operation?() } catch { writeError = error }
        return date
    })
    duringRead = { try fixture.execute("UPDATE threads SET updated_at = updated_at + 1") }
    let unchangedOwner = reader.read()
    if let writeError { throw writeError }
    check(unchangedOwner.last?.snapshot.fiveHour?.usedPercent == 37,
        "unrelated database updates during a rollout read do not starve valid quota delivery")
    try fixture.append(first, at: date, used: 39)
    duringRead = { try fixture.register(replacement, thread: id) }
    let changedOwner = reader.read(changedPaths: [first.path])
    if let writeError { throw writeError }
    check(changedOwner.isEmpty, "a canonical rollout replacement during a read rejects the former path's quota")
    check(reader.read().last?.snapshot.fiveHour?.usedPercent == 38,
        "a canonical replacement is read on the following local scan without replaying the old path")
}

@MainActor private func checkPassiveUsagePresentation(_ check: (Bool, String) -> Void, root: URL) async throws {
    let fixture = try PassiveUsageFixture(home: root)
    let clock = PassiveUsageClock(Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
    let start = clock.value
    var live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 37, windowMinutes: 300, resetsAt: start.addingTimeInterval(18000)),
        weekly: QuotaWindow(usedPercent: 10, windowMinutes: 10080, resetsAt: start.addingTimeInterval(86400)),
        capturedAt: start, accountID: "passive-a", sourceFile: "app-server")
    let provider = PassiveUsageProvider(live)
    let observer = UsageObserver(codexHome: fixture.home, provider: provider, logURL: root.appendingPathComponent("keeper/usage.jsonl"), now: { clock.value })
    observer.refresh()
    try await passiveSettle { !observer.refreshing }
    let schedule = ScheduleEngine(anchorMinutes: 480)
    let plan = NextAction(mode: .keepAlive, date: start.addingTimeInterval(18000), decision: .wait(reason: "等待下一可行计划节点"), note: "")
    var presentation = MenuPresentation()
    _ = presentation.build(plan: plan, usage: observer.snapshot, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(), now: start)
    observer.startPassiveMonitoring()
    clock.advance(80)
    let id = UUID().uuidString
    let file = fixture.home.appendingPathComponent("sessions/2026/10/25/rollout-\(id).jsonl")
    try fixture.write(file, thread: id, at: clock.value, used: 39, reset: live.fiveHour!.resetsAt)
    try fixture.register(file, thread: id)
    observer.rescanPassive()
    try await passiveSettle { observer.displaySnapshot?.fiveHour?.usedPercent == 39 }
    check(provider.reads == 1 && observer.snapshot?.fiveHour?.usedPercent == 37 && observer.snapshot?.isFresh(at: clock.value) == false,
        "ordinary local quota updates neither query the provider nor renew authoritative execution freshness")
    let summary = presentation.build(plan: plan, usage: observer.snapshot, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(),
        displayUsage: observer.displaySnapshot, now: clock.value)
    check(summary.quotas.first?.remaining == 61 && summary.isTime && summary.timeline.count > 0,
        "real MenuPresentation overlays current local quota after the online snapshot has expired while preserving its plan")
    var unprimed = MenuPresentation()
    let unprimedSummary = unprimed.build(plan: plan, usage: observer.snapshot, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(),
        displayUsage: observer.displaySnapshot, now: clock.value)
    check(unprimedSummary.isTime && unprimedSummary.quotas.first?.remaining == 61 && !unprimedSummary.isSyncing,
        "a fresh local quota plus a known conditional plan remains visible even without a primed presentation cache")
    _ = unprimed.build(plan: plan, usage: observer.snapshot, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(),
        sessionError: "fixture scan error", displayUsage: observer.displaySnapshot, now: clock.value)
    let afterScanRecovery = unprimed.build(plan: plan, usage: observer.snapshot, schedule: schedule, tasks: [], availableTasks: [], choices: ResumeChoices(),
        displayUsage: observer.displaySnapshot, now: clock.value)
    check(afterScanRecovery.isTime && afterScanRecovery.quotas.first?.remaining == 61,
        "a recovered local scan restores the conditional plan without waiting for another five-minute online read")
    check(summary.refreshMessage.contains("上次更新") && observer.displaySnapshot?.capturedAt == clock.value,
        "the displayed collection time advances with the verified local reading")
    clock.advance(); try fixture.append(file, at: clock.value, used: 39, reset: live.fiveHour!.resetsAt); observer.rescanPassive()
    try await passiveSettle { observer.displaySnapshot?.capturedAt == clock.value }
    check(provider.reads == 1, "same percentage with a new event time still makes no quota RPC")
    for used: Double in [38, 41, 40] {
        clock.advance(); try fixture.append(file, at: clock.value, used: used,
            reset: live.fiveHour!.resetsAt.addingTimeInterval(used == 38 ? 0.1 : 0),
            weeklyReset: live.weekly!.resetsAt)
        observer.rescanPassive()
        try await Task.sleep(nanoseconds: 100_000_000)
        check(observer.displaySnapshot?.fiveHour?.usedPercent == (used == 38 ? 39 : 41) && provider.reads == 1,
            "a later cached ordinary reading cannot roll back same-window usage or add an RPC: \(used)")
    }
    clock.advance(); live.capturedAt = clock.value; live.fiveHour?.usedPercent = 100; provider.set(live)
    try fixture.append(file, at: clock.value, used: 100, reset: live.fiveHour!.resetsAt); observer.rescanPassive()
    try await passiveSettle { provider.reads == 2 && !observer.refreshing }
    check(observer.snapshot?.fiveHour?.usedPercent == 100 && observer.hasReliableReading, "a local quota collision requests one online verification")
    let localCollisionAt = clock.value
    clock.advance(); live.capturedAt = clock.value; provider.set(live)
    observer.refresh(); try await passiveSettle { provider.reads == 3 && !observer.refreshing }
    let onlineCollisionAt = clock.value
    clock.advance(70); live.capturedAt = clock.value; live.fiveHour?.usedPercent = 40; provider.set(live)
    try fixture.append(file, at: clock.value, used: 40, reset: live.fiveHour!.resetsAt); observer.rescanPassive()
    try await passiveSettle { provider.reads == 4 && !observer.refreshing }
    check(observer.verifiedPassiveRecovery(at: clock.value)?.before.fiveHour?.usedPercent == 100,
        "recovery is recorded as explicit local evidence only after a subsequent fresh account-matched online read")
    check(observer.snapshot?.sourceFile == "app-server" && observer.passiveRecovery?.after.sourceFile == file.path,
        "local recovery evidence keeps its actual provenance and never impersonates app-server")
    check(observer.passiveRecovery?.before.capturedAt == onlineCollisionAt && onlineCollisionAt > localCollisionAt,
        "a post-stop online exhaustion reading supersedes the pre-stop local collision when recovery arrives later")
    let nextReset = live.fiveHour!.resetsAt.addingTimeInterval(3600)
    clock.advance(); live.capturedAt = clock.value; live.fiveHour?.resetsAt = nextReset; provider.set(live)
    try fixture.append(file, at: clock.value, used: 40, reset: live.fiveHour!.resetsAt); observer.rescanPassive()
    try await passiveSettle { provider.reads == 5 && !observer.refreshing }
    check(observer.snapshot?.fiveHour?.resetsAt == live.fiveHour?.resetsAt, "a new local quota window obtains online confirmation")
    provider.pause(); clock.advance(); live.capturedAt = clock.value; live.accountID = "passive-b"; provider.set(live)
    try fixture.authenticate("passive-b"); observer.rescanPassive()
    try await passiveSettle { provider.reads == 6 && observer.refreshing }
    check(observer.displaySnapshot == nil && observer.passiveRecovery == nil && !observer.hasReliableReading,
        "an authentication change immediately clears local display/recovery caches before the online query completes")
    provider.release(); try await passiveSettle { !observer.refreshing }
    check(observer.snapshot?.accountID == "passive-b" && observer.displaySnapshot?.accountID == "passive-b",
        "only the newly verified account returns to the display after authentication settles")
    observer.refresh(manual: true); try await passiveSettle { !observer.refreshing }
    check(provider.reads == 7 && provider.manualReads == 1, "manual refresh still invokes the user-refresh provider path")
    clock.advance(); live.capturedAt = clock.value; live.fiveHour?.usedPercent = 39; provider.set(live)
    observer.refresh(); try await passiveSettle { !observer.refreshing }
    check(observer.displaySnapshot?.fiveHour?.usedPercent == 39,
        "an explicit new online reading remains authoritative even when it corrects usage downward")
    observer.stop()
}

@MainActor private func checkFiveMinuteRecovery(_ check: (Bool, String) -> Void, root: URL) async throws {
    let fixture = try PassiveUsageFixture(home: root)
    try fixture.execute("CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", database: "logs_1.sqlite")
    let clock = PassiveUsageClock(Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
    let id = UUID().uuidString
    let file = fixture.home.appendingPathComponent("sessions/2026/10/24/rollout-\(id).jsonl")
    let reset = clock.value.addingTimeInterval(18000)
    try fixture.write(file, thread: id, at: clock.value, used: 100, reset: reset)
    clock.advance()
    let stoppedAt = clock.value
    var stopped = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: stoppedAt),
        "payload": ["type": "error", "message": "usage_limit_reached"]]); stopped.append(10)
    try fixture.appendData(file, data: stopped); try fixture.register(file, thread: id)
    let originalTrace = try Data(contentsOf: file)
    clock.advance()
    var live = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 100, windowMinutes: 300, resetsAt: reset),
        weekly: QuotaWindow(usedPercent: 10, windowMinutes: 10080, resetsAt: clock.value.addingTimeInterval(86400)),
        capturedAt: clock.value, accountID: "passive-a", sourceFile: "app-server")
    let provider = PassiveUsageProvider(live)
    let suite = "keeper.passive.recovery." + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    let parts = Calendar.current.dateComponents([.hour, .minute], from: clock.value)
    prefs.register(defaults: ["enabled": true, "autoResume": true, "earlyRecoveryPolicy": "ask", "resumeWorkspaceReminder": false,
        "dailyAnchorMinutes": (parts.hour! * 60 + parts.minute! + 120) % 1440])
    let state = AppState(provider: provider, defaults: prefs, runtimeURL: fixture.home.appendingPathComponent("keeper/pending.json"),
        codexHome: fixture.home, startMonitoring: false, now: { clock.value })
    state.refresh()
    try await passiveSettle { state.availableTasks.count == 1 && !state.usage.refreshing }
    let target = state.availableTasks[0]
    check(state.displayAccountID == "passive-a" && state.choices.recoveryDecisions?.isEmpty != false,
        "a real quota-stopped task starts bound to the verified online account without a recovery choice")
    let exhausted = live
    clock.advance(301)
    state.recompute(allowExecution: false)
    check(state.nextAction?.mode == .resume && state.nextAction?.date == reset && state.usage.polling.interval == 300,
        "an expired online reading preserves a far conditional recovery date and five-minute fallback")
    live.capturedAt = clock.value; live.fiveHour?.usedPercent = 1; provider.set(live)
    check(!UsageRecovery.isEarly(from: state.usage.snapshot!, to: live, now: clock.value),
        "the original sixty-second generic early-recovery rule remains strict after five minutes")
    state.refresh()
    try await passiveSettle { !state.usage.refreshing && state.choices.recoveryDecisions?[target.episodeKey] != nil }
    let unchangedTrace = try Data(contentsOf: file)
    check(provider.reads == 2 && unchangedTrace == originalTrace && state.recoveryReminderTasks.map(\.id) == [id] && !state.execution.running,
        "a five-minute online fallback discovers manual early reset without log updates and asks for the task's recovery choice")
    state.resolveRecoveryDecision(.plan, for: state.availableTasks)
    check(state.choices.recoveryDecisions?[target.episodeKey] == nil && state.recoveryReminderTasks.isEmpty &&
        state.nextAction?.date.map({ $0 > clock.value }) == true && !state.execution.running,
        "the actual task flow preserves the user's choice to wait for its plan")
    let account = "passive-a"
    check(UsageRecovery.isEarlyAfterQuotaStop(target, from: exhausted, usage: live, boundAccount: account, now: clock.value), "explicit future quota-stop evidence supports a freshly confirmed task recovery")
    var unconfirmed = exhausted; unconfirmed.fiveHour?.usedPercent = 20
    check(!UsageRecovery.isEarlyAfterQuotaStop(target, from: unconfirmed, usage: live, boundAccount: account, now: clock.value),
        "available quota without an observed online exhaustion does not invent a manual reset")
    unconfirmed = exhausted; unconfirmed.capturedAt = stoppedAt.addingTimeInterval(-1)
    check(!UsageRecovery.isEarlyAfterQuotaStop(target, from: unconfirmed, usage: live, boundAccount: account, now: clock.value),
        "an earlier pause's online exhaustion cannot grant a newer pause an early-recovery choice")
    unconfirmed = exhausted; unconfirmed.sourceFile = file.path
    check(!UsageRecovery.isEarlyAfterQuotaStop(target, from: unconfirmed, usage: live, boundAccount: account, now: clock.value),
        "historical local quota alone cannot prove the task's online exhaustion")
    var invalid = live; invalid.accountID = "other"
    check(!UsageRecovery.isEarlyAfterQuotaStop(target, from: exhausted, usage: invalid, boundAccount: account, now: clock.value), "task-anchored recovery rejects a different online account")
    invalid = live; invalid.capturedAt = clock.value.addingTimeInterval(-61)
    check(!UsageRecovery.isEarlyAfterQuotaStop(target, from: exhausted, usage: invalid, boundAccount: account, now: clock.value), "task-anchored recovery rejects expired online quota")
    invalid = live; invalid.sourceFile = file.path
    check(!UsageRecovery.isEarlyAfterQuotaStop(target, from: exhausted, usage: invalid, boundAccount: account, now: clock.value), "local logs cannot authorize task-anchored recovery")
    invalid = live; invalid.fiveHour = nil
    check(!UsageRecovery.isEarlyAfterQuotaStop(target, from: exhausted, usage: invalid, boundAccount: account, now: clock.value), "task-anchored recovery requires the stopped quota window to be present")
    let unknown = BlockedSession(id: id, project: "fixture", cwd: root.path, blockedAt: stoppedAt,
        fiveHourResetAt: nil, weeklyResetAt: nil, fileURL: file)
    check(!UsageRecovery.isEarlyAfterQuotaStop(unknown, from: exhausted, usage: live, boundAccount: account, now: clock.value), "generic quota errors with no concrete reset never guess an early recovery")
    let nearReset = BlockedSession(id: id, project: "fixture", cwd: root.path, blockedAt: stoppedAt,
        fiveHourResetAt: clock.value.addingTimeInterval(60), weeklyResetAt: nil, fileURL: file)
    invalid = live; invalid.capturedAt = clock.value.addingTimeInterval(-59)
    check(!UsageRecovery.isEarlyAfterQuotaStop(nearReset, from: exhausted, usage: invalid, boundAccount: account, now: clock.value),
        "a nearly due reset is not labelled early by measuring from an older but still fresh capture time")
    clock.advance(); live.capturedAt = clock.value; live.fiveHour?.usedPercent = 0; live.zeroUseWindowActive = false; provider.set(live)
    state.refresh(); try await passiveSettle { !state.usage.refreshing }
    state.usage.startPassiveMonitoring()
    clock.advance(80); try fixture.append(file, at: clock.value, used: 0, reset: reset, weeklyReset: live.weekly?.resetsAt); state.usage.rescanPassive()
    try await passiveSettle { state.usage.displaySnapshot?.capturedAt == clock.value }
    state.recompute(allowExecution: false)
    check(provider.reads == 3 && state.usage.polling.interval == 300 && state.usage.displaySnapshot?.sourceFile == file.path,
        "a local zero-percent reading without window-state metadata preserves the verified five-minute cadence")
    state.usage.stop(); state.sessions.stop()
}

@MainActor private func checkNativePassiveDiscovery(_ check: (Bool, String) -> Void, root: URL) async throws {
    let fixture = try PassiveUsageFixture(home: root)
    let clock = PassiveUsageClock(Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
    var seen: [PassiveUsageReading] = []
    for _ in 0..<25 {
        let id = UUID().uuidString
        try fixture.register(fixture.home.appendingPathComponent("sessions/history/rollout-\(id).jsonl"), thread: id, updatedAt: Int(Date().timeIntervalSince1970) + 1000)
    }
    let monitor = RolloutUsageMonitor(home: fixture.home, now: { clock.value }) { readings, _ in
        Task { @MainActor in seen.append(contentsOf: readings) }
    }
    monitor.start()
    defer { monitor.stop() }
    // The initial read may run before either the file or its database row exists.
    try await Task.sleep(nanoseconds: 100_000_000)
    let id = UUID().uuidString
    let file = fixture.home.appendingPathComponent("sessions/2030/01/01/rollout-\(id).jsonl")
    try fixture.write(file, thread: id, at: clock.value, used: 45)
    try await Task.sleep(nanoseconds: 100_000_000)
    try fixture.register(file, thread: id, updatedAt: 0)
    try await passiveSettle { seen.last?.snapshot.fiveHour?.usedPercent == 45 }
    check(seen.last?.snapshot.sourceFile == file.path, "native events discover a cross-directory restored thread outside the recent set after delayed database registration")
    clock.advance(); try fixture.append(file, at: clock.value, used: 46)
    try await passiveSettle { seen.last?.snapshot.fiveHour?.usedPercent == 46 }
    check(seen.last?.snapshot.capturedAt == clock.value, "native file events incrementally deliver an append without online reads")
    let writer = try FileHandle(forWritingTo: file)
    defer { try? writer.close() }
    try writer.seekToEnd()
    for used: Double in [47, 48, 49] {
        clock.advance()
        try writer.write(contentsOf: fixture.quota(at: clock.value, used: used))
        try await passiveSettle { seen.last?.snapshot.fiveHour?.usedPercent == used }
        check(seen.last?.snapshot.fiveHour?.usedPercent == used,
            "an open persistent writer delivers quota before closing its descriptor: \(used)")
    }
    clock.advance()
    let replaced = file.appendingPathExtension("old")
    try FileManager.default.moveItem(at: file, to: replaced)
    try fixture.write(file, thread: id, at: clock.value, used: 50)
    try await passiveSettle { seen.last?.snapshot.fiveHour?.usedPercent == 50 }
    clock.advance(); try fixture.append(file, at: clock.value, used: 51)
    try await passiveSettle { seen.last?.snapshot.fiveHour?.usedPercent == 51 }
    check(seen.last?.snapshot.fiveHour?.usedPercent == 51,
        "vnode monitoring follows replacement at the registered path and retires the old inode")
}

private final class PassiveUsageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval = 1) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
}

private final class PassiveUsageProvider: UsageProvider, @unchecked Sendable {
    private let condition = NSCondition()
    private var value: UsageSnapshot
    private var count = 0
    private var manualCount = 0
    private var held = false
    init(_ value: UsageSnapshot) { self.value = value }
    var reads: Int { condition.lock(); defer { condition.unlock() }; return count }
    var manualReads: Int { condition.lock(); defer { condition.unlock() }; return manualCount }
    func set(_ value: UsageSnapshot) { condition.lock(); self.value = value; condition.unlock() }
    func pause() { condition.lock(); held = true; condition.unlock() }
    func release() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }
    func readForUserRefresh() throws -> UsageSnapshot {
        condition.lock(); manualCount += 1; condition.unlock(); return try read()
    }
    func read() throws -> UsageSnapshot {
        condition.lock(); defer { condition.unlock() }; count += 1
        while held { condition.wait() }
        return value
    }
}

private struct PassiveUsageFixture {
    let home: URL
    init(home: URL) throws {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try authenticate("passive-a")
        try execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, creator_account_id TEXT, updated_at INTEGER)")
    }
    func authenticate(_ account: String) throws {
        try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": account]]).write(to: home.appendingPathComponent("auth.json"))
    }
    func register(_ file: URL, thread: String, account: String = "passive-a", updatedAt: Int = Int(Date().timeIntervalSince1970)) throws {
        func sql(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        try execute("INSERT OR REPLACE INTO threads VALUES(\(sql(thread)), \(sql(file.path)), \(sql(account)), \(updatedAt))")
    }
    func execute(_ sql: String, database: String = "state_5.sqlite") throws {
        var db: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent(database).path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
    }
    func write(_ file: URL, thread: String, at date: Date, used: Double, reset: Date? = nil, fork: Bool = false, padding: Int = 0) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var metadata: [String: Any] = ["id": thread, "cwd": home.path, "forked_from_id": NSNull(), "history_base": NSNull(), "source": NSNull()]
        if fork { metadata["forked_from_id"] = UUID().uuidString }
        let row: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: date), "type": "session_meta", "payload": metadata]
        var data = try JSONSerialization.data(withJSONObject: row); data.append(10)
        if padding > 0 { data.append(Data(repeating: 32, count: padding)); data.append(10) }
        data.append(try quota(at: date, used: used, reset: reset))
        try data.write(to: file)
    }
    func append(_ file: URL, at date: Date, used: Double, reset: Date? = nil, weeklyReset: Date? = nil) throws { try appendData(file, data: quota(at: date, used: used, reset: reset, weeklyReset: weeklyReset)) }
    func appendData(_ file: URL, data: Data) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    func quota(at date: Date?, used: Double, reset: Date? = nil, weeklyReset: Date? = nil, extraLimits: [String: String] = [:], omitID: Bool = false) throws -> Data {
        var limits: [String: Any] = ["primary": ["used_percent": used, "window_minutes": 300,
            "resets_at": (reset ?? (date ?? Date()).addingTimeInterval(18000)).timeIntervalSince1970],
            "secondary": ["used_percent": 10, "window_minutes": 10080, "resets_at": (weeklyReset ?? (date ?? Date()).addingTimeInterval(86400)).timeIntervalSince1970]]
        limits["limit_id"] = omitID ? NSNull() : "codex" as Any
        limits["limit_name"] = NSNull()
        for (key, value) in extraLimits { limits[key] = value }
        if extraLimits["limitId"] != nil || extraLimits["limit_name"] != nil || extraLimits["limitName"] != nil { limits.removeValue(forKey: "limit_id") }
        var row: [String: Any] = ["type": "event_msg", "payload": ["type": "token_count", "rate_limits": limits, "thread_id": NSNull()]]
        if let date { row["timestamp"] = ISO8601DateFormatter().string(from: date) }
        var data = try JSONSerialization.data(withJSONObject: row); data.append(10); return data
    }
}

@MainActor private func passiveSettle(line: Int = #line, _ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(domain: "PassiveUsageTests.wait", code: line, userInfo: [NSLocalizedDescriptionKey: "Timed out at test line \(line)"])
}

@MainActor private func checkPassiveResumeAdmission(_ check: (Bool, String) -> Void, root: URL) async throws {
    let fixture = try PassiveUsageFixture(home: root)
    try fixture.execute("CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", database: "logs_1.sqlite")
    let schedule = ScheduleEngine(anchorMinutes: 480)
    let clock = PassiveUsageClock(schedule.nodes()[1].addingTimeInterval(-90))
    let id = UUID().uuidString
    let file = fixture.home.appendingPathComponent("sessions/rollout-\(id).jsonl")
    let reset = clock.value.addingTimeInterval(18000)
    try fixture.write(file, thread: id, at: clock.value.addingTimeInterval(-2), used: 100, reset: reset)
    var stop = try JSONSerialization.data(withJSONObject: ["type": "event_msg",
        "timestamp": ISO8601DateFormatter().string(from: clock.value.addingTimeInterval(-1)),
        "payload": ["type": "error", "message": "usage_limit_reached"]])
    stop.append(10); try fixture.appendData(file, data: stop); try fixture.register(file, thread: id)
    let online = UsageSnapshot(fiveHour: QuotaWindow(usedPercent: 100, windowMinutes: 300, resetsAt: reset),
        weekly: QuotaWindow(usedPercent: 10, windowMinutes: 10080, resetsAt: clock.value.addingTimeInterval(86400)),
        capturedAt: clock.value, accountID: "passive-a", sourceFile: "app-server")
    let provider = PassiveUsageProvider(online)
    let sender = PassiveResumeTrap()
    let suite = "keeper.passive.resume-admission." + UUID().uuidString
    let prefs = UserDefaults(suiteName: suite)!
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.register(defaults: ["enabled": true, "autoResume": true, "dailyAnchorMinutes": 480,
        "earlyRecoveryPolicy": "immediately", "resumeWorkspaceReminder": false])
    let execution = ExecutionCoordinator(provider: provider, makeResumeTransport: { sender }, defaults: prefs,
        ledgerURL: root.appendingPathComponent("keeper/attempts.json"), pingTransport: sender, codexHome: fixture.home, now: { clock.value })
    let state = AppState(provider: provider, defaults: prefs, runtimeURL: root.appendingPathComponent("keeper/pending.json"),
        codexHome: fixture.home, execution: execution, startMonitoring: false, now: { clock.value })
    defer { provider.release(); state.usage.stop(); state.sessions.stop(); execution.stopOwnedTasks() }
    state.refresh()
    try await passiveSettle { state.availableTasks.count == 1 && !state.usage.refreshing }
    state.usage.startPassiveMonitoring()
    provider.pause()
    clock.advance(95)
    var fresh = online; fresh.capturedAt = clock.value; provider.set(fresh)
    try fixture.append(file, at: clock.value, used: 1, reset: reset, weeklyReset: online.weekly?.resetsAt)
    state.usage.rescanPassive()
    try await passiveSettle { state.usage.displaySnapshot?.sourceFile == file.path && state.usage.criticalRefreshPending }
    state.recompute()
    check(state.usage.displaySnapshot?.fiveHour?.usedPercent == 1 && state.usage.snapshot?.fiveHour?.usedPercent == 100 &&
        state.usage.snapshot?.isFresh(at: clock.value) == false && sender.submissions == 0 && execution.operations.isEmpty,
        "a local recovery at a plan node updates display but cannot authorize continuation while online verification is pending")
    provider.release()
    try await passiveSettle { !state.usage.refreshing }
    state.recompute()
    check(state.usage.hasReliableReading && state.usage.snapshot?.fiveHour?.usedPercent == 100 &&
        sender.submissions == 0 && execution.operations.isEmpty,
        "fresh online exhaustion continues to block continuation even after a local recovery was displayed")
}

private final class PassiveResumeTrap: ResumeTransport, PingTransport {
    private let lock = NSLock()
    private var count = 0
    var submissions: Int { lock.lock(); defer { lock.unlock() }; return count }
    func cancel() {}
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider) throws -> UsageSnapshot {
        throw CodexConnectionError.unavailable
    }
    func resume(_ target: BlockedSession, prompt: String) throws -> ResumeReceipt {
        lock.lock(); count += 1; lock.unlock()
        throw CodexConnectionError.unavailable
    }
}
