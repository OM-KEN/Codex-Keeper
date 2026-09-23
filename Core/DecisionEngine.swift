import Foundation

/// Pure decisions; the execution coordinator rechecks the same enable switch before sending.
enum KeeperDecision: Equatable {
    case ping(reason: String)
    case resume(project: String, reason: String)
    case skip(reason: String)
    case wait(reason: String)

    var text: String {
        switch self {
        case .ping(reason: let r): return "保活 · \(r)"
        case .resume(let p, let r): return "续跑 \(p) · \(r)"
        case .skip(reason: let r): return "跳过 · \(r)"
        case .wait(reason: let r): return "等待 · \(r)"
        }
    }
}

/// One plan supplies both the menu and the executor. Dates are conditional on fresh quota.
struct DecisionEngine {
    let schedule: ScheduleEngine

    func decide(now: Date = Date(), enabled: Bool, autoResume: Bool, earlyRecoveryPolicy: String,
                usage: UsageSnapshot?, blocked: [BlockedSession], observedRecovery: Bool = false) -> KeeperDecision {
        plan(now: now, enabled: enabled, autoResume: autoResume, earlyRecoveryPolicy: earlyRecoveryPolicy,
             usage: usage, blocked: blocked, observedRecovery: observedRecovery).decision
    }

    func plan(now: Date = Date(), calendar: Calendar = .current, enabled: Bool, autoResume: Bool,
              earlyRecoveryPolicy: String, usage: UsageSnapshot?, blocked: [BlockedSession],
              observedRecovery: Bool = false, heldForPlan: Bool = false) -> NextAction {
        let target = blocked.first
        let mode: NextActionMode = target != nil ? .resume : .keepAlive
        func wait(_ reason: String, at date: Date? = nil) -> NextAction {
            NextAction(mode: mode, date: date, decision: .wait(reason: reason), note: reason)
        }
        guard enabled else { return wait("已停用") }
        guard let usage, usage.fiveHour != nil || usage.weekly != nil else { return wait("等待额度同步") }
        guard usage.isFresh(at: now) else { return wait("额度已过期，等待实时确认") }
        if target != nil && !autoResume { return wait("自动续跑已关闭") }
        let five = usage.fiveHour
        let exhausted = [five, usage.weekly].compactMap { $0 }.filter { $0.usedPercent >= 100 }
        let blockingReset = exhausted.map { $0.resetsAt }.max()
        let atNode = schedule.currentNode(at: now, calendar: calendar) != nil
        let nextNode = schedule.nextNode(after: now, calendar: calendar)
        if let target {
            if let reset = blockingReset {
                guard reset > now else { return wait("等待额度恢复确认") }
                let date: Date
                if heldForPlan { date = schedule.firstNode(onOrAfter: reset, calendar: calendar) }
                else if schedule.isInAnchorProtection(at: reset, calendar: calendar), earlyRecoveryPolicy != "immediately" {
                    date = schedule.anchorProtection(at: reset, calendar: calendar).anchor
                } else { date = reset }
                return wait(date == reset ? "额度恢复并确认后续跑" : "恢复后顺延至计划时间", at: date)
            }
            if atNode { return NextAction(mode: .resume, date: now, decision: .resume(project: target.project, reason: "计划节点，额度已确认可用"), note: "额度已确认可用") }
            let inProtection = schedule.isInAnchorProtection(at: now, calendar: calendar)
            if observedRecovery && !inProtection && !heldForPlan {
                return NextAction(mode: .resume, date: now, decision: .resume(project: target.project, reason: "额度恢复已确认"), note: "额度恢复已确认")
            }
            switch heldForPlan ? "keepPlan" : earlyRecoveryPolicy {
            case "immediately":
                return NextAction(mode: .resume, date: now, decision: .resume(project: target.project, reason: "按选择立即继续"), note: "额度已恢复")
            default: return wait("按计划自动继续", at: nextNode)
            }
        }
        if let reset = blockingReset {
            guard reset > now else { return wait("等待额度恢复确认") }
            return wait("额度恢复后按计划保活", at: schedule.firstNode(onOrAfter: reset, calendar: calendar))
        }
        guard let five else { return wait("当前无需保活") }
        guard let active = usage.activeFiveHourWindow else { return wait("正在同步窗口状态") }
        if atNode && !active {
            return NextAction(mode: .keepAlive, date: now, decision: .ping(reason: "计划节点，当前无窗口"), note: "")
        }
        let date = schedule.firstNode(onOrAfter: active ? five.resetsAt : nextNode, calendar: calendar)
        return NextAction(mode: .keepAlive, date: date,
            decision: atNode ? .skip(reason: "已有有效 5 小时窗口") : .wait(reason: "等待下一可行计划节点"), note: "")
    }
}

/// Distinguish an observed scheduled reset from an early/manual quota reset.
enum UsageRecovery {
    /// A known quota stop keeps its scheduled deadline through missed polls or environment invalidation.
    /// Historical evidence never replaces fresh quota or the executor's task/account checks.
    static func canResumeAfterScheduledReset(_ target: BlockedSession, usage: UsageSnapshot?, boundAccount: String?, now: Date) -> Bool {
        guard let account = boundAccount, !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let usage, usage.accountID == account, usage.isFresh(at: now),
              (usage.fiveHour?.usedPercent ?? 0) < 100, (usage.weekly?.usedPercent ?? 0) < 100,
              let reset = [target.fiveHourResetAt, target.weeklyResetAt].compactMap({ $0 }).max(),
              reset > target.blockedAt, reset <= now, usage.capturedAt >= reset else { return false }
        if target.fiveHourResetAt != nil && usage.fiveHour == nil { return false }
        if target.weeklyResetAt != nil && usage.weekly == nil { return false }
        return true
    }

    static func isNatural(from old: UsageSnapshot, to new: UsageSnapshot, now: Date) -> Bool {
        guard let account = old.accountID, account == new.accountID,
              old.sourceFile == "app-server", new.isFresh(at: now),
              (old.fiveHour?.usedPercent ?? 0) >= 100 || (old.weekly?.usedPercent ?? 0) >= 100,
              (new.fiveHour?.usedPercent ?? 0) < 100, (new.weekly?.usedPercent ?? 0) < 100 else { return false }
        if (old.fiveHour?.usedPercent ?? 0) >= 100 && new.fiveHour == nil { return false }
        if (old.weekly?.usedPercent ?? 0) >= 100 && new.weekly == nil { return false }
        let exhausted = [old.fiveHour, old.weekly].compactMap { $0 }.filter { $0.usedPercent >= 100 }
        guard let reset = exhausted.map(\.resetsAt).max() else { return false }
        // The exhausted reading is historical evidence, not permission to send.
        // Bound each side of the expected reset independently; execution still requires fresh quota.
        return old.capturedAt < reset && reset.timeIntervalSince(old.capturedAt) <= 90 &&
            new.capturedAt >= reset && new.capturedAt.timeIntervalSince(reset) <= 90
    }
}
