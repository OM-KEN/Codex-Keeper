import Foundation

/// Polling cadence never grants permission to resume a user task.
struct UsagePollingPolicy: Equatable {
    static let activeInterval: TimeInterval = 20
    static let idleInterval: TimeInterval = 300
    static let preparation: TimeInterval = 120

    let interval: TimeInterval
    let wakeAt: Date?

    static func evaluate(now: Date, schedule: ScheduleEngine, enabled: Bool,
                         scanned: Bool, scanError: String?, reliableUsage: Bool,
                         usage: UsageSnapshot?, runningTask: Bool, resumeDemand: Bool,
                         executing: Bool, criticalRefresh: Bool, recoveryDates: [Date] = []) -> UsagePollingPolicy {
        let fast = UsagePollingPolicy(interval: activeInterval, wakeAt: nil)
        guard reliableUsage, let usage, usage.accountID?.isEmpty == false,
              usage.capturedAt <= now.addingTimeInterval(5),
              usage.fiveHour != nil || usage.weekly != nil,
              usage.activeFiveHourWindow != nil, !criticalRefresh else { return fast }
        // Task activity and recovery demand are local facts, not reasons to poll the network.
        var boundaries = recoveryDates.filter { $0 > now }
        if enabled {
            for opportunity in schedule.keepAliveOpportunities(at: now) {
                if now >= opportunity.node.addingTimeInterval(-preparation), now <= opportunity.deadline { return fast }
                boundaries.append(opportunity.node)
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


}

/// The provider uses the original node as the identity of a bounded retry opportunity.
struct UsageRetryOpportunity: Equatable {
    let node: Date
    let end: Date
}
