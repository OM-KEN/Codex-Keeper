import Foundation

/// 因额度耗尽而停下的 session（方案 §9）
struct BlockedSession: Equatable, Codable {
    var episodeKey: String { pauseID ?? "\(id):\(blockedAt.timeIntervalSince1970)" }
    let id: String
    let project: String
    let cwd: String
    let blockedAt: Date
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let fileURL: URL
    var pauseID: String? = nil
    var stoppedTurnID: String? = nil
    var startedBarrierAt: Date? = nil
    var retryQuota: ResumeQuotaEvidence? = nil
    var identityUncertain: Bool? = nil
    var title: String? = nil
    var displayName: String { title ?? "\(project) · \(id.prefix(8))" }

    /// A new timestamp/source is not a new pause. Only a real intervening start creates one.
    func stabilized(from previous: BlockedSession?) -> BlockedSession {
        guard let previous, previous.id == id, previous.cwd == cwd else {
            var result = self
            result.pauseID = pauseID ?? stoppedTurnID.map { "\(id):turn:\($0)" } ?? episodeKey
            return result
        }
        let newStart = startedBarrierAt.map { $0 > previous.blockedAt && $0 != previous.startedBarrierAt } == true
        if newStart && (stoppedTurnID == nil || stoppedTurnID != previous.stoppedTurnID) {
            var result = self
            result.pauseID = stoppedTurnID.map { "\(id):turn:\($0)" } ?? "\(id):start:\(startedBarrierAt!.timeIntervalSince1970)"
            return result
        }
        if let oldTurn = previous.stoppedTurnID, let newTurn = stoppedTurnID, oldTurn != newTurn {
            var retained = previous; retained.identityUncertain = true; return retained
        }
        return BlockedSession(id: id, project: project, cwd: cwd, blockedAt: previous.blockedAt,
            fiveHourResetAt: fiveHourResetAt ?? previous.fiveHourResetAt,
            weeklyResetAt: weeklyResetAt ?? previous.weeklyResetAt, fileURL: fileURL,
            pauseID: previous.episodeKey, stoppedTurnID: stoppedTurnID ?? previous.stoppedTurnID,
            startedBarrierAt: startedBarrierAt ?? previous.startedBarrierAt, retryQuota: retryQuota ?? previous.retryQuota, identityUncertain: identityUncertain ?? previous.identityUncertain, title: title)
    }

    func matchesPause(_ other: BlockedSession) -> Bool {
        guard identityUncertain != true, id == other.id, cwd == other.cwd else { return false }
        if let turn = stoppedTurnID { return turn == other.stoppedTurnID }
        if pauseID != nil, let barrier = startedBarrierAt { return barrier == other.startedBarrierAt }
        if pauseID != nil, startedBarrierAt == nil { return other.startedBarrierAt == nil && other.stoppedTurnID == nil }
        return blockedAt == other.blockedAt
    }

    /// Polling may observe actual exhaustion after the rollout's final (rounded) usage event.
    /// Preserve evidence only for this stop; a later episode cannot inherit its deadline.
    func withRecoveryEvidence(from previous: BlockedSession?, usage: UsageSnapshot?, boundAccount: String?, now: Date) -> BlockedSession {
        let previous = previous?.episodeKey == episodeKey && previous?.cwd == cwd ? previous : nil
        var five = previous?.fiveHourResetAt ?? fiveHourResetAt
        var weekly = previous?.weeklyResetAt ?? weeklyResetAt
        if let account = boundAccount, !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let usage, usage.accountID == account, usage.isFresh(at: now), usage.capturedAt > blockedAt {
            if let window = usage.fiveHour, window.usedPercent >= 100, window.resetsAt > blockedAt {
                five = window.resetsAt
            }
            if let window = usage.weekly, window.usedPercent >= 100, window.resetsAt > blockedAt {
                weekly = window.resetsAt
            }
        }
        return BlockedSession(id: id, project: project, cwd: cwd, blockedAt: blockedAt,
            fiveHourResetAt: five, weeklyResetAt: weekly, fileURL: fileURL, pauseID: pauseID, stoppedTurnID: stoppedTurnID, startedBarrierAt: startedBarrierAt, retryQuota: retryQuota, identityUncertain: identityUncertain, title: title)
    }
}

/// Only explicit quota-stop evidence is eligible for unattended resume.
/// A 100% snapshot followed by normal completion is never sufficient.
enum BlockedSessionDetector {
    static func detect(in sessions: [SessionActivity], now: Date = Date()) -> [BlockedSession] {
        sessions.compactMap { s in
            guard let blockedAt = s.quotaBlockedAt, !s.taskRunning, !s.isSubagent else { return nil }
            return BlockedSession(id: s.id, project: s.project, cwd: s.cwd, blockedAt: blockedAt,
                fiveHourResetAt: s.blockingFiveReset, weeklyResetAt: s.blockingWeeklyReset, fileURL: s.fileURL, stoppedTurnID: s.quotaTurnID, startedBarrierAt: s.lastTaskStartedAt, title: s.title)
        }.sorted { $0.blockedAt > $1.blockedAt }
    }
}
