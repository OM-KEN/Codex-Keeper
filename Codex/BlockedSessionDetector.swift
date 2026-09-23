import Foundation

/// 因额度耗尽而停下的 session（方案 §9）
struct BlockedSession: Equatable, Codable {
    var episodeKey: String { "\(id):\(blockedAt.timeIntervalSince1970)" }
    let id: String
    let project: String
    let cwd: String
    let blockedAt: Date
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let fileURL: URL
    var title: String? = nil
    var displayName: String { title ?? "\(project) · \(id.prefix(8))" }

    /// Polling may observe actual exhaustion after the rollout's final (rounded) usage event.
    /// Preserve evidence only for this stop; a later episode cannot inherit its deadline.
    func withRecoveryEvidence(from previous: BlockedSession?, usage: UsageSnapshot?, boundAccount: String?, now: Date) -> BlockedSession {
        let previous = previous?.episodeKey == episodeKey && previous?.cwd == cwd ? previous : nil
        var five = fiveHourResetAt ?? previous?.fiveHourResetAt
        var weekly = weeklyResetAt ?? previous?.weeklyResetAt
        if let account = boundAccount, !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let usage, usage.accountID == account, usage.isFresh(at: now) {
            if five == nil, let window = usage.fiveHour, window.usedPercent >= 100, window.resetsAt > blockedAt {
                five = window.resetsAt
            }
            if weekly == nil, let window = usage.weekly, window.usedPercent >= 100, window.resetsAt > blockedAt {
                weekly = window.resetsAt
            }
        }
        return BlockedSession(id: id, project: project, cwd: cwd, blockedAt: blockedAt,
            fiveHourResetAt: five, weeklyResetAt: weekly, fileURL: fileURL, title: title)
    }
}

/// Only explicit quota-stop evidence is eligible for unattended resume.
/// A 100% snapshot followed by normal completion is never sufficient.
enum BlockedSessionDetector {
    static func detect(in sessions: [SessionActivity], now: Date = Date()) -> [BlockedSession] {
        sessions.compactMap { s in
            guard let blockedAt = s.quotaBlockedAt, !s.taskRunning, !s.isSubagent else { return nil }
            return BlockedSession(id: s.id, project: s.project, cwd: s.cwd, blockedAt: blockedAt,
                fiveHourResetAt: s.blockingFiveReset, weeklyResetAt: s.blockingWeeklyReset, fileURL: s.fileURL, title: s.title)
        }.sorted { $0.blockedAt > $1.blockedAt }
    }
}
