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
    var hasStatusIssue = false
    var isTime = false
    var isSyncing = false
    var isRefreshing = false
    var refreshMessage = ""
    var quotas: [MenuQuota] = []
    var tasks: [String] = []
    var taskCount = 0
    var timeline: [MenuTimelinePoint] = []
    var statusDatePrefix = ""
    var reminderTitle = ""
    var reminderBody = ""

    mutating func applyRecoveryReminder(tasks: [BlockedSession], choices: ResumeChoices) {
        let pending = tasks.compactMap { task -> (BlockedSession, RecoveryDecision)? in
            choices.recoveryDecisions?[task.episodeKey].flatMap { $0.phase == .responded ? nil : (task, $0) }
        }.sorted { $0.0.blockedAt > $1.0.blockedAt }
        guard let first = pending.first else { return }
        reminderTitle = pending.count == 1 ? L10n.text("有暂停的任务等你处理") : L10n.format("有%d个暂停的任务等你处理", pending.count)
        reminderBody = first.0.displayName + "\n" + first.1.message
    }

    var statusText: String {
        if isTime { return [statusDatePrefix, headline].filter { !$0.isEmpty }.joined(separator: " ") }
        if headline == "等待续跑决定" { return L10n.text("待决定") }
        if headline == "待同步" { return L10n.text("待同步") }
        if isSyncing { return L10n.text("同步中") }
        return "–"
    }
    mutating func applyIssues(usageError: String?, sessionError: String?, executionFailure: String?, executionAction: String,
                             usageErrorIsTransient: Bool = false, executionFailureIsCurrent: Bool = false) {
        error = [sessionError, usageError].compactMap { $0 }.joined(separator: "\n")
        hasStatusIssue = sessionError != nil || (usageError != nil && !usageErrorIsTransient)
        if let executionFailure {
            let previous = L10n.format("上次%@失败：%@", L10n.text(executionAction), executionFailure)
            note = [note, previous].filter { !$0.isEmpty }.joined(separator: "\n")
            if executionFailureIsCurrent { warning = previous }
        }
    }
    mutating func applyUsageRefreshState(refreshing: Bool, error: String?) {
        guard isSyncing else { return }
        headline = refreshing ? "正在同步" : "待同步"
        action = ""; isSyncing = refreshing
        if error != nil {
            let syncNote = refreshing ? "正在重新同步额度…" : "网络恢复后打开菜单，或点击“重新同步”重试。"
            note = [note, syncNote].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
    var statusSymbol: String {
        if headline == "已停用" { return "pause.circle" }
        if hasStatusIssue || !warning.isEmpty { return "exclamationmark.circle" }
        if isSyncing || headline == "待同步" { return "arrow.triangle.2.circlepath" }
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
        if plan.mode == .keepAlive && usage.fiveHour != nil && usage.activeFiveHourWindow == nil {
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
        if plan.mode == .resume || plan.needsRecoveryDecision {
            result.tasks = tasks.sorted { $0.blockedAt > $1.blockedAt }.prefix(1).map(\.displayName)
            result.taskCount = tasks.count
        }
        func confirmation(for start: Date) -> ExecutionConfirmation? {
            confirmations.filter {
                $0.confirmedAt <= now && abs(($0.windowStart ?? $0.actionAt).timeIntervalSince(start)) <= ScheduleEngine.alignmentTolerance
            }.max { $0.confirmedAt < $1.confirmedAt }
        }
        if let five = usage.fiveHour, usage.activeFiveHourWindow == true, five.resetsAt > now {
            let start = five.resetsAt.addingTimeInterval(-Double(five.windowMinutes) * 60)
            let confirmed = confirmation(for: start)
            let confirmedOnPlan = confirmed?.kind == .keepAlive && confirmed.flatMap {
                schedule.currentKeepAliveNode(at: $0.actionAt)
            } != nil
            let windowOnPlan = (confirmed?.kind ?? plan.mode) == .keepAlive ? schedule.currentKeepAliveNode(at: start) != nil :
                schedule.currentNode(at: start) != nil
            result.badge = windowOnPlan || confirmedOnPlan ? "计划内" : "计划外"
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
                    let confirmed = confirmation(for: start)
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

/// Display continuity only. Cached summaries never supply quota or plans to the executor.
struct MenuPresentation {
    private struct Configuration: Equatable {
        let anchorMinutes: Int
        let autoResume: Bool
        let earlyRecoveryPolicy: String
        let choices: ResumeChoices
        let timeZone: String
        let day: Date
    }
    private struct CachedSummary {
        let summary: MenuSummary
        let capturedAt: Date
        let accountID: String?
        let plan: NextAction
        let tasks: [BlockedSession]
        let availableTasks: [BlockedSession]
        let choices: ResumeChoices
    }
    private var configuration: Configuration?
    private var cached: CachedSummary?
    private var executionBase: (summary: MenuSummary, capturedAt: Date?, accountID: String?)?
    private var wasRunning = false
    private var wasRefreshing = false
    private var refreshRequested = false
    private var showsRefreshFeedback = false

    mutating func requestRefreshFeedback() {
        refreshRequested = true
        showsRefreshFeedback = true
    }

    mutating func build(plan: NextAction?, usage: UsageSnapshot?, schedule: ScheduleEngine,
                        tasks: [BlockedSession], availableTasks: [BlockedSession], choices: ResumeChoices,
                        enabled: Bool = true, autoResume: Bool = true, earlyRecoveryPolicy: String = "ask",
                        confirmations: [ExecutionConfirmation] = [], usageError: String? = nil,
                        usageErrorIsTransient: Bool = false, sessionError: String? = nil,
                        running: Bool = false, executionMode: NextActionMode? = nil,
                        executionFailure: String? = nil, executionFailureIsCurrent: Bool = false,
                        executionWarning: String? = nil, refreshing: Bool = false,
                        refreshMessage: String = "", now: Date = Date()) -> MenuSummary {
        // Notification delivery and retired deadlines do not change the user's action plan.
        var currentChoices = choices
        for key in currentChoices.recoveryDecisions?.keys.map({ $0 }) ?? [] {
            currentChoices.recoveryDecisions?[key]?.notification = .pending
            currentChoices.recoveryDecisions?[key]?.deadline = nil
        }
        var configuredChoices = currentChoices
        configuredChoices.recoveryDecisions = nil
        let currentConfiguration = Configuration(anchorMinutes: schedule.anchorMinutes, autoResume: autoResume,
            earlyRecoveryPolicy: earlyRecoveryPolicy, choices: configuredChoices,
            timeZone: TimeZone.current.identifier, day: Calendar.current.startOfDay(for: now))
        let fatalIssue = sessionError != nil || (usageError != nil && !usageErrorIsTransient) || plan?.note == "账户已改变"
        let changedAccount = usage?.sourceFile == "app-server" && (cached != nil || executionBase != nil) &&
            usage?.accountID != (cached?.accountID ?? executionBase?.accountID)
        if !enabled || fatalIssue || changedAccount || configuration != currentConfiguration {
            cached = nil
            executionBase = nil
        }
        configuration = currentConfiguration
        let selected = tasks.sorted { $0.episodeKey < $1.episodeKey }
        let available = availableTasks.sorted { $0.episodeKey < $1.episodeKey }
        if let previous = cached, previous.tasks != selected || previous.availableTasks != available || previous.choices != currentChoices {
            cached = nil
        }
        if refreshing && !wasRefreshing && !refreshRequested { showsRefreshFeedback = false }
        defer {
            wasRunning = running
            wasRefreshing = refreshing
            if !refreshing { refreshRequested = false }
            if !running { executionBase = nil }
        }

        var summary = enabled ? MenuSummary.build(plan: plan, usage: fatalIssue ? nil : usage,
            schedule: schedule, tasks: tasks, confirmations: confirmations, now: now) : MenuSummary(headline: "已停用")
        var capturedAt: Date?
        var restoredCache = false
        if enabled && !fatalIssue {
            if let usage, usage.isFresh(at: now), let plan {
                // Every real new reading replaces the previous display, including absent or unknown windows.
                capturedAt = usage.capturedAt
                cached = CachedSummary(summary: summary, capturedAt: usage.capturedAt, accountID: usage.accountID,
                    plan: plan, tasks: selected, availableTasks: available, choices: currentChoices)
            } else if let previous = cached {
                let syncNotes = ["等待额度同步", "额度已过期，等待实时确认", "等待额度恢复确认", "正在同步窗口状态"]
                let compatiblePlan = plan.map { syncNotes.contains($0.note) ||
                    ($0.mode == previous.plan.mode && $0.date == previous.plan.date && $0.note == previous.plan.note) } ?? true
                if compatiblePlan {
                    summary = previous.summary; capturedAt = previous.capturedAt
                    restoredCache = true
                } else { cached = nil }
            }
            if running, !restoredCache, usage?.isFresh(at: now) != true, let previous = executionBase {
                summary = previous.summary
                capturedAt = previous.capturedAt
            }
        }
        if enabled, summary.tasks.isEmpty, !availableTasks.isEmpty {
            summary.tasks = availableTasks.sorted { $0.blockedAt > $1.blockedAt }.prefix(1).map(\.displayName)
            summary.taskCount = availableTasks.count
        }
        if enabled {
            if running && !wasRunning { executionBase = (summary, capturedAt, cached?.accountID ?? usage?.accountID) }
            summary.applyIssues(usageError: usageError, sessionError: sessionError, executionFailure: executionFailure,
                executionAction: executionMode == .resume ? "自动继续" : "保活", usageErrorIsTransient: usageErrorIsTransient,
                executionFailureIsCurrent: executionFailureIsCurrent)
            if plan?.note == "账户已改变" {
                summary.headline = "账户已改变"
                summary.isSyncing = false
                summary.hasStatusIssue = true
            }
            if running {
                if let previous = executionBase {
                    summary.timeline = previous.summary.timeline
                    summary.tasks = previous.summary.tasks
                    summary.taskCount = previous.summary.taskCount
                }
                summary.headline = executionMode == .resume ? "正在继续" : "正在保活"
                summary.action = ""; summary.isTime = false; summary.eyebrow = ""; summary.isSyncing = false
                if let executionWarning {
                    summary.warning = executionWarning
                    summary.note = executionWarning
                    summary.headline = "保活等待中"
                }
            } else {
                summary.applyUsageRefreshState(refreshing: refreshing, error: usageError)
            }
        }
        summary.applyRecoveryReminder(tasks: availableTasks, choices: choices)
        summary.isRefreshing = refreshing
        if let capturedAt {
            let clock = DateFormatter()
            clock.dateFormat = Calendar.current.isDate(capturedAt, inSameDayAs: now) ? "HH:mm:ss" : L10n.text("M月d日 HH:mm:ss")
            summary.refreshMessage = L10n.format("上次更新 · %@", clock.string(from: capturedAt))
        }
        if showsRefreshFeedback && !refreshMessage.isEmpty { summary.refreshMessage = refreshMessage }
        return summary
    }
}
