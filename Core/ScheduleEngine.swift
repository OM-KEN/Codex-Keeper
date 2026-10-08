import Foundation

/// 目标节奏计算（方案 §3/§4/§20）。
/// 用户只设「每日开始时间」，目标节点 = anchor / +5h / +10h / +15h。
/// 节点不是瞬间：reset 漂移几十秒仍属同一轮（宽限区，§4）。
/// 日锚点保护区 = 下一日锚点 - 5h 起（§20），防止新窗口跨过锚点。
struct ScheduleEngine {
    /// 自动续跑保留节点后的三分钟宽限。
    static let alignmentTolerance: TimeInterval = 180
    /// 保活容纳四轮窗口建立及额度核实的累计延迟；超过十分钟不补发。
    static let keepAliveTolerance: TimeInterval = 600
    /// 5h 窗口时长
    static let windowDuration: TimeInterval = 5 * 3600

    /// 每日开始时间，分钟数（08:00 = 480）
    let anchorMinutes: Int

    /// 当日四个目标节点（本地时间，可能跨到次日凌晨）
    func nodes(on day: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let anchor = calendar.date(
            bySettingHour: anchorMinutes / 60,
            minute: anchorMinutes % 60,
            second: 0,
            of: day
        ) ?? day
        return (0..<4).map { anchor.addingTimeInterval(Double($0) * Self.windowDuration) }
    }

    /// 当前时刻之后的下一个节点（今日没有则取明日锚点）
    func nextNode(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let candidates = adjacentNodes(at: now, calendar: calendar)
        return candidates.first(where: { $0 > now }) ?? now
    }

    /// First schedule opportunity at or after a quota boundary, including later weeks.
    func firstNode(onOrAfter date: Date, calendar: Calendar = .current) -> Date {
        if currentNode(at: date, calendar: calendar) != nil { return date }
        return adjacentNodes(at: date, calendar: calendar).first { $0 >= date } ?? date
    }

    func firstKeepAliveNode(onOrAfter date: Date, calendar: Calendar = .current) -> Date {
        if currentKeepAliveNode(at: date, calendar: calendar) != nil { return date }
        return adjacentNodes(at: date, calendar: calendar).first { $0 >= date } ?? date
    }

    private func adjacentNodes(at now: Date, calendar: Calendar) -> [Date] {
        (-1...1).flatMap { offset in
            nodes(on: calendar.date(byAdding: .day, value: offset, to: now) ?? now, calendar: calendar)
        }.sorted()
    }

    /// Grace is only after a node: never launch a request before the user's time.
    func currentNode(at now: Date = Date(), calendar: Calendar = .current) -> Date? {
        currentNode(at: now, calendar: calendar, tolerance: Self.alignmentTolerance)
    }

    func currentKeepAliveNode(at now: Date = Date(), calendar: Calendar = .current) -> Date? {
        currentNode(at: now, calendar: calendar, tolerance: Self.keepAliveTolerance)
    }

    private func currentNode(at now: Date, calendar: Calendar, tolerance: TimeInterval) -> Date? {
        adjacentNodes(at: now, calendar: calendar).last {
            now >= $0 && now.timeIntervalSince($0) <= tolerance
        }
    }

    /// 日锚点保护区：从「下一日锚点 - 5h」到锚点
    func anchorProtection(at now: Date = Date(), calendar: Calendar = .current) -> (start: Date, anchor: Date) {
        let todayAnchor = nodes(on: now, calendar: calendar)[0]
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let anchor = now < todayAnchor ? todayAnchor : nodes(on: tomorrow, calendar: calendar)[0]
        return (anchor.addingTimeInterval(-Self.windowDuration), anchor)
    }

    func isInAnchorProtection(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let (start, anchor) = anchorProtection(at: now, calendar: calendar)
        return now >= start && now < anchor
    }
}
