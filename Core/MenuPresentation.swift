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
    var quotaAccountID: String?
    var tasks: [String] = []
    var taskCount = 0
    var taskProgress = ""
    var tasksNeedAttention = false
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
    var statusQuota: MenuQuota? { quotas.first { $0.name == "5小时" } }
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
            let syncNote = refreshing ? "正在重新同步额度…" : "正在自动重试额度读取。"
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
    enum Kind { case start, keepAliveNotNeeded, reset, keepAlive, resume, scheduled, completedKeepAlive, completedResume, resumeRecord }
    let date: Date
    let time: String
    let day: String
    let label: String
    let kind: Kind
    let solidBefore: Bool
    var operationIDs: Set<String> = []
    var timeLabel: String { [day, time].filter { !$0.isEmpty }.joined(separator: " ") }
    var symbol: String {
        switch kind {
        case .start, .keepAliveNotNeeded: return "circle.fill"
        case .reset: return "arrow.clockwise.circle.fill"
        case .keepAlive: return "waveform.path.ecg"
        case .resume: return "paperplane"
        case .scheduled: return "circle"
        case .resumeRecord: return "text.bubble"
        case .completedKeepAlive, .completedResume: return "checkmark.circle.fill"
        }
    }
    var isHistory: Bool { [.completedKeepAlive, .completedResume, .resumeRecord].contains(kind) }
    var isAction: Bool { [.keepAlive, .resume, .completedKeepAlive, .completedResume].contains(kind) }
}

struct MenuQuota: Identifiable {
    enum StatusLevel { case normal, critical }
    let name: String
    let remaining: Double
    let detail: String
    var id: String { name }
    var barRemaining: Double { remaining.rounded() <= 0 ? 0 : max(0, min(100, remaining)) }
    var statusLevel: StatusLevel {
        remaining.rounded() <= 10 ? .critical : .normal
    }
}

/// Remembers only visible bar lengths; quota labels always use the newest reading.
struct MenuQuotaPresentation {
    private(set) var quotas: [MenuQuota] = []
    private(set) var displayedRemaining: [String: Double] = [:]
    private(set) var animatesChanges = false
    private var accountID: String?
    private var lastSeen: [String: Double] = [:]
    private var isOpen = false
    private var isVisible = false

    private var currentRemaining: [String: Double] {
        Dictionary(uniqueKeysWithValues: quotas.map { ($0.id, $0.barRemaining) })
    }

    mutating func update(quotas: [MenuQuota], accountID: String?) {
        let changedAccount = self.accountID != accountID
        if changedAccount { lastSeen = [:] }
        self.accountID = accountID
        self.quotas = quotas
        let ids = Set(quotas.map(\.id))
        lastSeen = lastSeen.filter { ids.contains($0.key) }
        displayedRemaining = isVisible ? currentRemaining :
            Dictionary(uniqueKeysWithValues: quotas.map { ($0.id, lastSeen[$0.id] ?? $0.barRemaining) })
        animatesChanges = isVisible && !changedAccount
        if isVisible { lastSeen = displayedRemaining }
    }

    mutating func menuWillOpen() {
        isOpen = true
        isVisible = false
        animatesChanges = false
    }

    mutating func menuBecameVisible() {
        guard isOpen else { return }
        isVisible = true
        animatesChanges = displayedRemaining != currentRemaining
        displayedRemaining = currentRemaining
        lastSeen = displayedRemaining
    }

    mutating func menuDidClose() {
        isOpen = false
        isVisible = false
        animatesChanges = false
    }
}

private func menuPlanCycleStart(schedule: ScheduleEngine, now: Date) -> Date {
    let anchor = schedule.nodes(on: now)[0]
    guard now < anchor else { return anchor }
    let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
    return schedule.nodes(on: previousDay)[0]
}

extension MenuSummary {
    static func build(plan: NextAction?, usage: UsageSnapshot?, schedule: ScheduleEngine, tasks: [BlockedSession], confirmations: [ExecutionConfirmation] = [], observedWindows: [QuotaWindow] = [], observedResets: [Date] = [], now: Date = Date(), requireFresh: Bool = true) -> MenuSummary {
        if plan?.note == "已停用" { return MenuSummary(headline: "已停用") }
        guard let usage, (!requireFresh || usage.isFresh(at: now)), let plan else { return MenuSummary(headline: "正在同步", isSyncing: true) }
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        let day = DateFormatter(); day.dateFormat = L10n.text("M月d日")
        func dayText(_ date: Date) -> String {
            if Calendar.current.isDate(date, inSameDayAs: now) { return L10n.text("今天") }
            if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now), Calendar.current.isDate(date, inSameDayAs: tomorrow) { return L10n.text("明天") }
            return day.string(from: date)
        }
        var result = MenuSummary(action: plan.mode.title)
        result.quotaAccountID = usage.accountID
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
        if let date = plan.date, date >= now {
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
                $0.accountID != nil && $0.accountID == usage.accountID && $0.confirmedAt <= now &&
                abs(($0.windowStart ?? $0.actionAt).timeIntervalSince(start)) <= ScheduleEngine.alignmentTolerance
            }.max { $0.confirmedAt < $1.confirmedAt }
        }
        if let five = usage.fiveHour, usage.activeFiveHourWindow == true, five.resetsAt > now {
            let start = five.resetsAt.addingTimeInterval(-Double(five.windowMinutes) * 60)
            let confirmed = confirmation(for: start)
            let confirmedOnPlan = confirmed.flatMap { schedule.currentKeepAliveNode(at: $0.actionAt) } != nil
            let windowOnPlan = schedule.currentKeepAliveNode(at: start) != nil
            result.badge = windowOnPlan || confirmedOnPlan ? "计划内" : "计划外"
            if plan.date == nil, plan.mode != .resume, usage.nextResetDate(at: now) == five.resetsAt {
                result.headline = clock.string(from: five.resetsAt)
                result.statusDatePrefix = Calendar.current.isDate(five.resetsAt, inSameDayAs: now) ? "" : dayText(five.resetsAt)
                result.eyebrow = L10n.format("当前额度 · %@", dayText(five.resetsAt))
                result.action = "额度重置"
                result.isTime = true
            }
        }
        if let actionDate = plan.date, actionDate >= now {
            func point(_ date: Date, _ label: String, _ kind: MenuTimelinePoint.Kind, solid: Bool = false) -> MenuTimelinePoint {
                MenuTimelinePoint(date: date, time: clock.string(from: date),
                    day: Calendar.current.isDate(date, inSameDayAs: now) ? "" : dayText(date),
                    label: label, kind: kind, solidBefore: solid)
            }
            func observedWindow(_ window: QuotaWindow) -> MenuTimelinePoint {
                let start = window.resetsAt.addingTimeInterval(-Double(window.windowMinutes) * 60)
                if let reset = observedResets.filter({ $0 <= now && abs($0.timeIntervalSince(start)) <= ScheduleEngine.alignmentTolerance })
                    .min(by: { abs($0.timeIntervalSince(start)) < abs($1.timeIntervalSince(start)) }) {
                    return point(reset, "已重置", .reset)
                }
                return point(start, plan.mode == .keepAlive ? "窗口开始" : "开始", plan.mode == .keepAlive ? .keepAliveNotNeeded : .start)
            }
            var joinsCurrentWindow = false
            if let five = usage.fiveHour, usage.activeFiveHourWindow == true, five.resetsAt > now {
                let start = five.resetsAt.addingTimeInterval(-Double(five.windowMinutes) * 60)
                if start <= now {
                    // Only a confirmed operation matching this real window can claim completion.
                    let confirmed = confirmation(for: start)
                    if let confirmed {
                        result.timeline.append(point(start, confirmed.kind == .resume ? "已继续" : "已保活",
                            confirmed.kind == .resume ? .completedResume : .completedKeepAlive))
                    } else { result.timeline.append(observedWindow(five)) }
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
            if result.timeline.count < 3, let first = result.timeline.first?.date,
               let accountID = usage.accountID, !accountID.isEmpty {
                let cycleStart = menuPlanCycleStart(schedule: schedule, now: now)
                let completed = confirmations.compactMap { confirmation -> MenuTimelinePoint? in
                    let date = confirmation.windowStart ?? confirmation.actionAt
                    guard confirmation.accountID == accountID, confirmation.confirmedAt <= now,
                          confirmation.actionAt <= confirmation.confirmedAt, date <= confirmation.confirmedAt,
                          date >= cycleStart, date < first else { return nil }
                    return point(date,
                        confirmation.kind == .resume ? "已继续" : "已保活",
                        confirmation.kind == .resume ? .completedResume : .completedKeepAlive)
                }
                let observed = observedWindows.map(observedWindow) + observedResets.map { point($0, "已重置", .reset) }
                // A confirmed action takes precedence over an observation of the same window.
                let history = completed + observed.filter { observation in
                    !completed.contains { abs($0.date.timeIntervalSince(observation.date)) <= ScheduleEngine.alignmentTolerance }
                }
                var added: [MenuTimelinePoint] = []
                for candidate in history.sorted(by: { $0.date > $1.date }) where
                    candidate.date >= cycleStart && candidate.date < first && candidate.date <= now {
                    guard result.timeline.count + added.count < 3 else { break }
                    guard !(result.timeline + added).contains(where: {
                        abs($0.date.timeIntervalSince(candidate.date)) <= ScheduleEngine.alignmentTolerance
                    }) else { continue }
                    added.append(candidate)
                }
                result.timeline.insert(contentsOf: added.reversed(), at: 0)
            }
        }
        return result
    }
}

/// Display continuity only. Cached summaries never supply quota or plans to the executor.
struct MenuPresentation {
    private struct Configuration: Codable, Equatable {
        let anchorMinutes: Int
        let autoResume: Bool
        let earlyRecoveryPolicy: String
        let choices: ResumeChoices
        let timeZone: String
    }
    private struct ObservedHistory: Codable, Equatable {
        let version: Int
        let configuration: Configuration
        let cycle: Date
        let accountID: String
        let windows: [QuotaWindow]
        let resets: [Date]
        var accounts: [String: AccountObservedHistory]? = nil
    }
    private struct AccountObservedHistory: Codable, Equatable {
        let configuration: Configuration
        let cycle: Date
        let windows: [QuotaWindow]
        let resets: [Date]
    }
    private struct CachedSummary {
        let summary: MenuSummary
        let usage: UsageSnapshot
        let confirmations: [ExecutionConfirmation]
        let capturedAt: Date
        let accountID: String?
        let plan: NextAction
        let tasks: [BlockedSession]
        let availableTasks: [BlockedSession]
        let choices: ResumeChoices
    }
    private var configuration: Configuration?
    private var observedCycle: Date?
    private var observedAccountID: String?
    private var accountHistory: [String: AccountObservedHistory] = [:]
    private var observedWindows: [QuotaWindow] = []
    private var observedResets: [Date] = []
    private var cached: CachedSummary?
    private var executionBase: (summary: MenuSummary, capturedAt: Date?, accountID: String?)?
    private var wasRunning = false
    private var wasRefreshing = false
    private var refreshRequested = false
    private var showsRefreshFeedback = false
    private let historyURL: URL?
    private var savedHistory: ObservedHistory?

    init(historyURL: URL? = nil) {
        self.historyURL = historyURL
        if let historyURL, let data = try? Data(contentsOf: historyURL),
           let history = try? JSONDecoder().decode(ObservedHistory.self, from: data), history.version == 1 {
            configuration = history.configuration
            observedCycle = history.cycle
            observedAccountID = history.accountID
            observedWindows = history.windows
            observedResets = history.resets
            accountHistory = history.accounts ?? [:]
            savedHistory = history
        }
    }

    private mutating func persistObservedHistory() {
        guard let historyURL else { return }
        let history: ObservedHistory?
        if let configuration, let observedCycle, let observedAccountID {
            accountHistory[observedAccountID] = AccountObservedHistory(configuration: configuration, cycle: observedCycle, windows: observedWindows, resets: observedResets)
            history = ObservedHistory(version: 1, configuration: configuration, cycle: observedCycle,
                accountID: observedAccountID, windows: observedWindows, resets: observedResets, accounts: accountHistory)
        } else { history = nil }
        guard history != savedHistory else { return }
        do {
            if let history {
                try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
            } else { return }
            savedHistory = history
        } catch {
            // Optional display history never blocks fresh quota or execution checks.
        }
    }

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
        currentChoices.readManualEvents = nil
        for key in currentChoices.recoveryDecisions?.keys.map({ $0 }) ?? [] {
            currentChoices.recoveryDecisions?[key]?.notification = .pending
            currentChoices.recoveryDecisions?[key]?.deadline = nil
        }
        var configuredChoices = currentChoices
        configuredChoices.recoveryDecisions = nil
        let currentConfiguration = Configuration(anchorMinutes: schedule.anchorMinutes, autoResume: autoResume,
            earlyRecoveryPolicy: earlyRecoveryPolicy, choices: configuredChoices,
            timeZone: TimeZone.current.identifier)
        let cycleStart = menuPlanCycleStart(schedule: schedule, now: now)
        let fatalIssue = sessionError != nil || (usageError != nil && !usageErrorIsTransient) || plan?.note == "账户已改变"
        let changedAccount = usage?.sourceFile == "app-server" && usage?.accountID != nil && usage?.isFresh(at: now) == true && (cached != nil || executionBase != nil || observedAccountID != nil) &&
            usage?.accountID != (cached?.accountID ?? executionBase?.accountID ?? observedAccountID)
        if !enabled || fatalIssue || changedAccount || configuration != currentConfiguration {
            cached = nil
            executionBase = nil
        }
        if changedAccount || configuration != currentConfiguration || observedCycle != cycleStart {
            if let account = observedAccountID, let configuration, let observedCycle {
                accountHistory[account] = AccountObservedHistory(configuration: configuration, cycle: observedCycle, windows: observedWindows, resets: observedResets)
            }
            observedWindows = []
            observedResets = []
            observedAccountID = nil
        }
        if changedAccount, let account = usage?.accountID, let history = accountHistory[account],
           history.configuration == currentConfiguration, history.cycle == cycleStart {
            observedWindows = history.windows; observedResets = history.resets; observedAccountID = account
        }
        configuration = currentConfiguration
        observedCycle = cycleStart
        let selected = tasks.sorted { $0.episodeKey < $1.episodeKey }
        let available = availableTasks.sorted { $0.episodeKey < $1.episodeKey }
        if let previous = cached, previous.choices != currentChoices {
            cached = nil
        }
        if refreshing && !wasRefreshing && !refreshRequested { showsRefreshFeedback = false }
        defer {
            wasRunning = running
            wasRefreshing = refreshing
            if !refreshing { refreshRequested = false }
            if !running { executionBase = nil }
        }

        if enabled, !fatalIssue, let usage, usage.isFresh(at: now), let accountID = usage.accountID, !accountID.isEmpty,
           let five = usage.fiveHour, usage.activeFiveHourWindow == true, five.resetsAt > now, five.windowMinutes > 0 {
            let start = five.resetsAt.addingTimeInterval(-Double(five.windowMinutes) * 60)
            let latestStart = observedWindows.map { $0.resetsAt.addingTimeInterval(-Double($0.windowMinutes) * 60) }.max() ?? start
            if start <= now && start <= usage.capturedAt && start >= latestStart.addingTimeInterval(-ScheduleEngine.alignmentTolerance) {
                observedAccountID = accountID
                if let previous = observedWindows.filter({ $0.windowMinutes == five.windowMinutes &&
                    five.resetsAt.timeIntervalSince($0.resetsAt) > ScheduleEngine.alignmentTolerance }).max(by: { $0.resetsAt < $1.resetsAt }) {
                    // A later real window verifies expiry, or replaces an unexpired window after an early reset.
                    let reset = start >= previous.resetsAt ? previous.resetsAt : start
                    if !observedResets.contains(where: { abs($0.timeIntervalSince(reset)) <= ScheduleEngine.alignmentTolerance }) {
                        observedResets.append(reset)
                    }
                }
                if !observedWindows.contains(where: { $0.resetsAt == five.resetsAt && $0.windowMinutes == five.windowMinutes }) {
                    observedWindows.append(five)
                }
            }
        }
        persistObservedHistory()
        var summary = enabled ? MenuSummary.build(plan: plan, usage: fatalIssue ? nil : usage,
            schedule: schedule, tasks: tasks, confirmations: confirmations,
            observedWindows: observedWindows, observedResets: observedResets, now: now) : MenuSummary(headline: "已停用")
        var capturedAt: Date?
        var restoredCache = false
        if enabled && !fatalIssue {
            if let usage, usage.isFresh(at: now), usage.accountID != nil, let plan {
                // Every real new reading replaces the previous display, including absent or unknown windows.
                capturedAt = usage.capturedAt
                cached = CachedSummary(summary: summary, usage: usage, confirmations: confirmations, capturedAt: usage.capturedAt, accountID: usage.accountID,
                    plan: plan, tasks: selected, availableTasks: available, choices: currentChoices)
            } else if let previous = cached {
                let syncNotes = ["等待额度同步", "额度已过期，等待实时确认", "等待额度恢复确认", "正在同步窗口状态"]
                let compatiblePlan = plan.map { syncNotes.contains($0.note) ||
                    ($0.mode == previous.plan.mode && $0.date == previous.plan.date && $0.note == previous.plan.note) } ?? true
                if compatiblePlan {
                    let displayPlan: NextAction
                    if previous.tasks != selected || previous.availableTasks != available {
                        var current = DecisionEngine(schedule: schedule).plan(now: now, enabled: enabled, autoResume: autoResume,
                            earlyRecoveryPolicy: earlyRecoveryPolicy, usage: previous.usage, blocked: tasks, reserveIdleDate: tasks.isEmpty)
                        if case .ping = current.decision {
                            current.date = schedule.nextKeepAliveNode(after: now)
                            current.decision = .wait(reason: "等待下一可行计划节点")
                        }
                        displayPlan = current
                    }
                    else if let date = previous.plan.date, date >= now { displayPlan = previous.plan }
                    else if let plan, let date = plan.date, date >= now { displayPlan = plan }
                    else { displayPlan = DecisionEngine(schedule: schedule).plan(now: now, enabled: enabled, autoResume: autoResume,
                        earlyRecoveryPolicy: earlyRecoveryPolicy, usage: previous.usage, blocked: tasks, reserveIdleDate: tasks.isEmpty) }
                    summary = MenuSummary.build(plan: displayPlan, usage: previous.usage, schedule: schedule, tasks: tasks,
                        confirmations: confirmations.isEmpty ? previous.confirmations : confirmations, observedWindows: observedWindows, observedResets: observedResets, now: now, requireFresh: false)
                    capturedAt = previous.capturedAt; restoredCache = true
                } else { cached = nil }
            }
            if running, executionMode != .resume, !restoredCache, usage?.isFresh(at: now) != true, let previous = executionBase {
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
                if executionMode != .resume, let previous = executionBase {
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

extension MenuSummary {
    mutating func applyResumeTasks(operations: [ResumeOperation], pending: [BlockedSession], choices: ResumeChoices) {
        let operations = operations.filter { !(choices.ignoredEpisodes?.contains($0.target.episodeKey) ?? false) }
        let recordedKeys = Set(operations.map { $0.target.episodeKey })
        var counts: [String: Int] = [:]
        for operation in operations {
            if operation.needsManualContinuation, !(choices.readManualEvents?.contains(operation.id) ?? false) {
                counts["%d 个任务需到 Codex 手动继续", default: 0] += 1
            } else if operation.respondedAt == nil {
                switch operation.phase {
                case .preparing, .sending: counts["%d 个任务正在发送", default: 0] += 1
                case .confirming, .checking: counts["%d 个任务确认中", default: 0] += 1
                case .notSubmitted: counts["%d 个任务发送失败", default: 0] += 1
                case .stopped: counts[operation.terminal == .quotaStopped ? "%d 个任务等待自动继续" : "%d 个任务续跑已停止", default: 0] += 1
                default: break
                }
            }
        }
        for target in pending where !recordedKeys.contains(target.episodeKey) {
            let choice = choices.recoveryDecisions?[target.episodeKey]
            let key = target.identityUncertain == true ? "%d 个任务确认中" : choice != nil && choice?.phase != .responded ? "%d 个任务待选择" : "%d 个任务等待自动继续"
            counts[key, default: 0] += 1
        }
        let order = ["%d 个任务正在发送", "%d 个任务确认中", "%d 个任务发送失败", "%d 个任务续跑已停止", "%d 个任务需到 Codex 手动继续", "%d 个任务待选择", "%d 个任务等待自动继续"]
        let labels = order.compactMap { key in counts[key].map { L10n.format(key, $0) } }
        tasks = labels.isEmpty ? [] : [labels.joined(separator: " · ")]
        taskCount = counts.values.reduce(0, +)
        tasksNeedAttention = ["%d 个任务发送失败", "%d 个任务续跑已停止", "%d 个任务需到 Codex 手动继续", "%d 个任务待选择"].contains { counts[$0] != nil }
        let confirmed = operations.filter { $0.respondedAt != nil }.count
        taskProgress = !operations.isEmpty && confirmed < operations.count ? L10n.format("已继续 %d/%d", confirmed, operations.count) : ""
        reminderTitle = ""; reminderBody = ""
        if counts["%d 个任务需到 Codex 手动继续"] != nil {
            headline = "需要手动继续"; action = ""; eyebrow = ""; isTime = false; isSyncing = false
            warning = L10n.text("需要手动继续")
        }
    }

    mutating func applyResumeHistory(_ operations: [ResumeOperation], accountID: String?, confirmations: [ExecutionConfirmation] = [], now: Date = Date()) {
        let visible = operations.filter { $0.accountID == accountID }
        for index in timeline.indices where timeline[index].isHistory {
            guard timeline[index].kind != .completedKeepAlive else { timeline[index].operationIDs = []; continue }
            let date = timeline[index].date
            let ids = Set(confirmations.filter { $0.kind == .resume && $0.accountID == accountID &&
                abs(($0.windowStart ?? $0.actionAt).timeIntervalSince(date)) <= ScheduleEngine.alignmentTolerance
            }.compactMap(\.operationID))
            let batches = Set(visible.filter { ids.contains($0.id) }.map(\.batchID))
            timeline[index].operationIDs = Set(visible.filter { ids.contains($0.id) || batches.contains($0.batchID) }.map(\.id))
        }
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        let day = DateFormatter(); day.dateFormat = L10n.text("M月d日")
        let represented = Set(timeline.flatMap(\.operationIDs))
        let missing = visible.filter { operation in
            !represented.contains(operation.id) && operation.actionAt <= now && (operation.respondedAt != nil ||
                (operation.receivedAt != nil && operation.endedAt != nil) || (operation.phase == .checking && !operation.protectsThread))
        }.sorted { $0.actionAt > $1.actionAt }.prefix(2)
        for operation in missing {
            guard !timeline.contains(where: { $0.operationIDs.contains(operation.id) }) else { continue }
            timeline.append(MenuTimelinePoint(date: operation.actionAt, time: clock.string(from: operation.actionAt),
                day: Calendar.current.isDate(operation.actionAt, inSameDayAs: now) ? "" : day.string(from: operation.actionAt),
                label: operation.respondedAt == nil ? "续跑记录" : "已继续", kind: operation.respondedAt == nil ? .resumeRecord : .completedResume,
                solidBefore: false, operationIDs: Set(visible.filter { $0.batchID == operation.batchID }.map(\.id))))
        }
        timeline.sort { $0.date < $1.date }
    }
}
