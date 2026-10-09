import Foundation

/// Reservations may use an older successful reading; they never authorize execution.
struct UsagePollingPolicy: Equatable {
    static let activeInterval: TimeInterval = 20
    static let idleInterval: TimeInterval = 300
    static let preparation: TimeInterval = 120

    let interval: TimeInterval
    let wakeAt: Date?

    static func evaluate(now: Date, schedule: ScheduleEngine, enabled: Bool,
                         scanned: Bool, scanError: String?, reliableUsage: Bool,
                         usage: UsageSnapshot?, runningTask: Bool, resumeDemand: Bool,
                         executing: Bool, criticalRefresh: Bool) -> UsagePollingPolicy {
        let fast = UsagePollingPolicy(interval: activeInterval, wakeAt: nil)
        guard scanned, scanError == nil, reliableUsage, let usage,
              usage.sourceFile == "app-server", usage.accountID?.isEmpty == false,
              usage.capturedAt <= now.addingTimeInterval(5),
              usage.fiveHour != nil || usage.weekly != nil,
              usage.activeFiveHourWindow != nil,
              !runningTask, !resumeDemand, !executing, !criticalRefresh else { return fast }
        var boundaries: [Date] = []
        if enabled {
            for opportunity in schedule.keepAliveOpportunities(at: now) {
                if now >= opportunity.node.addingTimeInterval(-preparation), now <= opportunity.deadline { return fast }
                boundaries += [opportunity.node, opportunity.date]
            }
        }
        for window in [usage.fiveHour, usage.weekly].compactMap({ $0 }) {
            if window.resetsAt <= now {
                if usage.capturedAt < window.resetsAt || window.usedPercent >= 100 { return fast }
            } else {
                boundaries.append(window.resetsAt)
            }
        }
        if boundaries.contains(where: { $0 > now && $0.timeIntervalSince(now) <= preparation }) { return fast }
        let wake = boundaries.filter { $0 > now }.min()?.addingTimeInterval(-preparation)
        return UsagePollingPolicy(interval: idleInterval, wakeAt: wake)
    }

    static func reservedKeepAliveDate(now: Date, schedule: ScheduleEngine, usage: UsageSnapshot, calendar: Calendar = .current) -> Date? {
        let exhausted = [usage.fiveHour, usage.weekly].compactMap { $0 }.filter { $0.usedPercent >= 100 }
        if let reset = exhausted.map(\.resetsAt).max() {
            return reset > now ? schedule.firstKeepAliveNode(onOrAfter: reset, calendar: calendar) : nil
        }
        guard let five = usage.fiveHour, let active = usage.activeFiveHourWindow else { return nil }
        return schedule.firstKeepAliveNode(onOrAfter: active && five.resetsAt > now ? five.resetsAt : schedule.nextKeepAliveNode(after: now, calendar: calendar), calendar: calendar)
    }
}

/// The provider uses the original node as the identity of a bounded retry opportunity.
struct UsageRetryOpportunity: Equatable {
    let node: Date
    let end: Date
}

enum SessionUsageActivity {
    static func latestRefreshEvent(previous: [SessionActivity], current: [SessionActivity]) -> Date? {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.flatMap { activity -> [Date] in
            guard let before = old[activity.id] else { return [activity.lastActivityAt] }
            var events: [Date] = []
            if !before.taskRunning && activity.taskRunning { events.append(activity.lastTaskStartedAt ?? activity.lastActivityAt) }
            for (current, previous) in [(activity.lastUserMessageAt, before.lastUserMessageAt),
                (activity.lastTaskStartedAt, before.lastTaskStartedAt),
                (activity.lastAssistantMessageAt, before.lastAssistantMessageAt),
                (activity.quotaBlockedAt, before.quotaBlockedAt)] {
                if let current, current > (previous ?? .distantPast) { events.append(current) }
            }
            return events
        }.max()
    }
}
