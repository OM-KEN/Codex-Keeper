import Foundation

/// One primary message; quota and controls stay secondary.
struct MenuSummary {
    var badge = ""
    var eyebrow = ""
    var headline = ""
    var action = ""
    var note = ""
    var error = ""
    var warning = ""
    var isTime = false
    var isSyncing = false
    var isRefreshing = false
    var refreshMessage = ""
    var quotas: [MenuQuota] = []
    var tasks: [String] = []
    var taskCount = 0
    var timeline: [MenuTimelinePoint] = []
    var statusDatePrefix = ""

    var statusText: String { isTime ? [statusDatePrefix, headline].filter { !$0.isEmpty }.joined(separator: " ") : "–" }
    mutating func applyIssues(usageError: String?, sessionError: String?, executionFailure: String?, executionAction: String) {
        error = usageError ?? sessionError ?? ""
        if error.isEmpty, let executionFailure {
            let previous = L10n.format("上次%@失败：%@", L10n.text(executionAction), executionFailure)
            note = [note, previous].filter { !$0.isEmpty }.joined(separator: "\n")
            warning = previous
        }
    }
    mutating func applyUsageRefreshState(refreshing: Bool, error: String?) {
        guard isSyncing, error != nil else { return }
        if refreshing {
            note = "正在重新同步额度…"
        } else {
            headline = "同步失败"; action = ""; isSyncing = false
            note = "网络恢复后打开菜单，或点击“重新同步”重试。"
        }
    }
    var statusSymbol: String {
        if headline == "已停用" { return "pause.circle" }
        if !error.isEmpty || !warning.isEmpty { return "exclamationmark.circle" }
        if isSyncing { return "arrow.triangle.2.circlepath" }
        switch action.isEmpty ? headline : action {
        case "保持活动", "正在保活": return "waveform.path.ecg"
        case "自动继续", "正在继续": return "paperplane"
        case "额度重置": return "arrow.clockwise.circle.fill"
        default: return "clock"
        }
    }
}

struct MenuTimelinePoint {
    enum Kind { case start, reset, keepAlive, resume, scheduled, completedKeepAlive, completedResume }
    let date: Date
    let time: String
    let day: String
    let label: String
    let kind: Kind
    let solidBefore: Bool
    var timeLabel: String { [day, time].filter { !$0.isEmpty }.joined(separator: " ") }
    var symbol: String {
        switch kind {
        case .start: return "circle.fill"
        case .reset: return "arrow.clockwise.circle.fill"
        case .keepAlive: return "waveform.path.ecg"
        case .resume: return "paperplane"
        case .scheduled: return "circle"
        case .completedKeepAlive, .completedResume: return "checkmark.circle.fill"
        }
    }
    var isAction: Bool { [.keepAlive, .resume, .completedKeepAlive, .completedResume].contains(kind) }
}

struct MenuQuota: Identifiable {
    let name: String
    let remaining: Double
    let detail: String
    var id: String { name }
}

extension MenuSummary {
    static func build(plan: NextAction?, usage: UsageSnapshot?, schedule: ScheduleEngine, tasks: [BlockedSession], confirmations: [ExecutionConfirmation] = [], now: Date = Date()) -> MenuSummary {
        if plan?.note == "已停用" { return MenuSummary(headline: "已停用") }
        guard let usage, usage.isFresh(at: now), let plan else { return MenuSummary(headline: "正在同步", isSyncing: true) }
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        let day = DateFormatter(); day.dateFormat = L10n.text("M月d日")
        func dayText(_ date: Date) -> String {
            if Calendar.current.isDate(date, inSameDayAs: now) { return L10n.text("今天") }
            if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now), Calendar.current.isDate(date, inSameDayAs: tomorrow) { return L10n.text("明天") }
            return day.string(from: date)
        }
        var result = MenuSummary(action: plan.mode.title)
        result.quotas = [("5小时", usage.fiveHour), ("1周", usage.weekly)].compactMap { name, window in
            guard let window else { return nil }
            let detail: String
            if name == "5小时", usage.activeFiveHourWindow == false { detail = "尚未开启窗口" }
            else if name == "5小时", usage.activeFiveHourWindow == nil { detail = "—" }
            else { detail = dayText(window.resetsAt) + " " + clock.string(from: window.resetsAt) }
            return MenuQuota(name: name, remaining: 100 - window.usedPercent, detail: detail)
        }
        if usage.fiveHour != nil && usage.activeFiveHourWindow == nil {
            result.headline = "正在同步"; result.action = ""; result.isSyncing = true
            return result
        }
        if let date = plan.date {
            result.headline = clock.string(from: date)
            result.statusDatePrefix = Calendar.current.isDate(date, inSameDayAs: now) ? "" : dayText(date)
            result.eyebrow = L10n.format("下一次 · %@", dayText(date))
            result.isTime = true
        } else {
            let syncing = plan.note.contains("同步") || plan.note.contains("确认")
            result.headline = syncing ? "正在同步" : plan.note == "当前无需保活" ? "无需保活" : plan.note == "请选择要继续的任务" ? "未选择会话" : plan.note
            result.isSyncing = syncing
            result.action = ""
        }
        if plan.mode == .resume {
            result.tasks = tasks.sorted { $0.blockedAt > $1.blockedAt }.prefix(1).map(\.displayName)
            result.taskCount = tasks.count
        }
        if let five = usage.fiveHour, usage.activeFiveHourWindow == true, five.resetsAt > now {
            let start = five.resetsAt.addingTimeInterval(-Double(five.windowMinutes) * 60)
            result.badge = schedule.currentNode(at: start) != nil ? "计划内" : "计划外"
            if result.badge == "计划外", plan.mode != .resume {
                result.headline = clock.string(from: five.resetsAt)
                result.statusDatePrefix = Calendar.current.isDate(five.resetsAt, inSameDayAs: now) ? "" : dayText(five.resetsAt)
                result.eyebrow = L10n.format("当前额度 · %@", dayText(five.resetsAt))
                result.action = "额度重置"
                result.isTime = true
            }
        }
        if let actionDate = plan.date {
            func point(_ date: Date, _ label: String, _ kind: MenuTimelinePoint.Kind, solid: Bool = false) -> MenuTimelinePoint {
                MenuTimelinePoint(date: date, time: clock.string(from: date),
                    day: Calendar.current.isDate(date, inSameDayAs: now) ? "" : dayText(date),
                    label: label, kind: kind, solidBefore: solid)
            }
            var joinsCurrentWindow = false
            if let five = usage.fiveHour, usage.activeFiveHourWindow == true, five.resetsAt > now {
                let start = five.resetsAt.addingTimeInterval(-Double(five.windowMinutes) * 60)
                if start <= now {
                    // Only a confirmed operation matching this real window can claim completion.
                    let confirmed = confirmations.filter {
                        $0.confirmedAt <= now && abs(($0.windowStart ?? $0.actionAt).timeIntervalSince(start)) <= ScheduleEngine.alignmentTolerance
                    }.max { $0.confirmedAt < $1.confirmedAt }
                    let kind: MenuTimelinePoint.Kind = confirmed.map { $0.kind == .resume ? .completedResume : .completedKeepAlive } ?? .start
                    result.timeline.append(point(start, confirmed.map { $0.kind == .resume ? "已继续" : "已保活" } ?? "开始", kind))
                    if abs(actionDate.timeIntervalSince(five.resetsAt)) < ScheduleEngine.alignmentTolerance {
                        joinsCurrentWindow = true
                    } else if five.resetsAt < actionDate {
                        result.timeline.append(point(five.resetsAt, "重置", .reset, solid: true))
                    }
                }
            }
            result.timeline.append(point(actionDate, plan.mode == .resume ? "继续" : "保活",
                plan.mode == .resume ? .resume : .keepAlive, solid: joinsCurrentWindow))
            if result.badge == "计划内", plan.mode == .keepAlive {
                for date in schedule.nodes(on: actionDate) where date > actionDate && result.timeline.count < 4 {
                    result.timeline.append(point(date, "计划", .scheduled))
                }
            }
        }
        return result
    }
}
