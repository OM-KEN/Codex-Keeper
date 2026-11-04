import Foundation
import AppKit
import SQLite3
import Combine

@MainActor private final class UsageMenuTrackingCheck: NSObject, NSMenuDelegate {
    let menu: NSMenu
    let view: TokenUsageMenuView
    let chart: TokenUsageChartView
    let followingView: NSView
    let availableAnalysis: TokenUsageHistoryAnalysis
    let unavailableAnalysis: TokenUsageHistoryAnalysis
    let weeklyOnlyAnalysis: TokenUsageHistoryAnalysis
    var results: [(Bool, String)] = []
    private var ticks = 0
    private var step = 0
    private var pointer = NSPoint.zero
    private var expandedHeight: CGFloat = 0
    private var expandedChartY: CGFloat = 0
    private var expandedMenuHeight: CGFloat = 0
    private var expandedFollowingOffset: CGFloat = 0

    init(menu: NSMenu, view: TokenUsageMenuView, followingView: NSView, availableAnalysis: TokenUsageHistoryAnalysis,
         unavailableAnalysis: TokenUsageHistoryAnalysis, weeklyOnlyAnalysis: TokenUsageHistoryAnalysis) {
        self.menu = menu; self.view = view; self.chart = view.chart
        self.followingView = followingView; self.availableAnalysis = availableAnalysis
        self.unavailableAnalysis = unavailableAnalysis
        self.weeklyOnlyAnalysis = weeklyOnlyAnalysis
        super.init()
        menu.delegate = self
        view.pointerLocation = { [weak self] in self?.pointer ?? .zero }
    }
    private var followingOffset: CGFloat {
        view.convert(view.bounds, to: nil).maxY - followingView.convert(followingView.bounds, to: nil).maxY
    }
    private func moveToMetric(_ point: NSPoint) {
        if let window = view.window, let metrics = view.subviews.first {
            pointer = window.convertPoint(toScreen: metrics.convert(point, to: nil))
        }
    }
    func menuWillOpen(_ menu: NSMenu) { view.menuWillOpen() }
    func menuDidClose(_ menu: NSMenu) { view.menuDidClose() }
    func run() {
        let policy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(policy) }
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(checkHover(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking)
        NSApp.setActivationPolicy(.accessory); NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSPoint(x: 100, y: 600), in: nil)
        timer.invalidate()
        view.menuDidClose(); view.pointerLocation = { NSEvent.mouseLocation }; menu.delegate = nil
    }
    @objc private func checkHover(_ timer: Timer) {
        guard let window = chart.window, window.isVisible else {
            ticks += 1
            if ticks >= 80 { timer.invalidate(); menu.cancelTracking() }
            return
        }
        if step == 0 {
            expandedHeight = view.frame.height; expandedChartY = chart.frame.minY
            expandedMenuHeight = window.frame.height; expandedFollowingOffset = followingOffset
            let bitmap = chart.bitmapImageRepForCachingDisplay(in: chart.bounds)!
            chart.cacheDisplay(in: chart.bounds, to: bitmap)
            let point = NSPoint(x: chart.plotRect.minX + chart.plotRect.width * 6.5 / 7, y: 24)
            pointer = window.convertPoint(toScreen: chart.convert(point, to: nil))
        } else if step == 1 {
            results.append((chart.visibleHoverText?.contains(TokenUsageFormat.compact(1500)) == true &&
                chart.visibleHoverText?.contains(TokenUsageFormat.compact(10500)) == true && chart.highlightedSegment != nil,
                "the actual menu loop shows compact window and day totals and highlights the hovered stack"))
            let panels = NSApp.windows.filter { $0.isVisible && $0.level.rawValue == NSWindow.Level.popUpMenu.rawValue + 1 }
            results.append((!panels.isEmpty && panels.allSatisfy { !$0.isKeyWindow && !$0.isMainWindow && !$0.canBecomeKey && !$0.canBecomeMain },
                "visible hover panels cannot take key-window or main-window focus during menu tracking"))
            pointer = window.convertPoint(toScreen: NSPoint(x: -40, y: -40))
        } else if step == 2 {
            results.append((chart.visibleHoverText == nil && chart.highlightedSegment == nil,
                "moving the tracked pointer outside the chart dismisses its panel and highlight"))
            let point = NSPoint(x: chart.plotRect.minX + chart.plotRect.width * 6.5 / 7, y: 60)
            pointer = window.convertPoint(toScreen: chart.convert(point, to: nil))
        } else if step == 3 {
            results.append((chart.visibleHoverText?.contains(TokenUsageFormat.compact(9000)) == true,
                "pointer tracking selects another five-hour stack without direct hover callbacks"))
            let tpsFrame = view.metricTPSFrame
            if let metrics = view.subviews.first {
                pointer = window.convertPoint(toScreen: metrics.convert(NSPoint(x: tpsFrame.midX, y: tpsFrame.midY), to: nil))
            }
        } else if step == 4 {
            results.append((chart.visibleHoverText == nil && view.visibleMetricHoverText ==
                L10n.text("tps 表示平均每秒生成的 Token 数，用来衡量输出速度。"),
                "actual menu pointer tracking follows the left-aligned tps text and shows its plain definition"))
            if let metrics = view.subviews.first {
                pointer = window.convertPoint(toScreen: metrics.convert(NSPoint(x: 20, y: 70), to: nil))
            }
        } else if step == 5 {
            results.append((view.visibleMetricHoverText == L10n.text("5小时真实额度估算") + "\n8.8K Token",
                "actual menu tracking preserves the existing hint when an estimate is available"))
            view.update(unavailableAnalysis)
        } else if step == 6 {
            let reduction = expandedHeight - view.frame.height
            results.append((reduction > 0 && abs(expandedChartY - chart.frame.minY - reduction) < 0.1,
                "hiding both estimates contracts the custom view and moves its chart up by \(reduction) points"))
            results.append((abs(expandedMenuHeight - window.frame.height - reduction) < 0.1 &&
                abs(expandedFollowingOffset - followingOffset - reduction) < 0.1,
                "the live menu and following row move up with the hidden estimates: menu \(expandedMenuHeight)->\(window.frame.height), row \(expandedFollowingOffset)->\(followingOffset)"))
            view.hoverMetric(at: NSPoint(x: 20, y: 70))
            results.append((view.visibleMetricHoverText == nil,
                "the removed estimate row has no invisible metric tooltip at its former position"))
            let tpsFrame = view.metricTPSFrame
            moveToMetric(NSPoint(x: tpsFrame.midX, y: tpsFrame.midY))
        } else if step == 7 {
            results.append((view.visibleMetricHoverText == L10n.text("tps 表示平均每秒生成的 Token 数，用来衡量输出速度。"),
                "TPS pointer tracking still works after the estimate row is removed"))
            view.update(weeklyOnlyAnalysis)
            moveToMetric(NSPoint(x: 20, y: 70))
        } else if step == 8 {
            results.append((view.frame.height == expandedHeight && chart.frame.minY == expandedChartY &&
                abs(followingOffset - expandedFollowingOffset) < 0.1,
                "a single weekly estimate restores one row and the live menu's following-item position"))
            results.append((view.visibleMetricHoverText == L10n.text("每周真实额度估算") + "\n" +
                (weeklyOnlyAnalysis.weeklyEstimate.tokens.map(TokenUsageFormat.compact) ?? "—") + " Token",
                "a weekly-only row maps its left-hand hover to the weekly estimate"))
            moveToMetric(NSPoint(x: 240, y: 70))
        } else if step == 9 {
            results.append((view.visibleMetricHoverText == L10n.text("每周真实额度估算") + "\n" +
                (weeklyOnlyAnalysis.weeklyEstimate.tokens.map(TokenUsageFormat.compact) ?? "—") + " Token",
                "a weekly-only row uses the same weekly hover across its available width"))
            view.update(availableAnalysis)
            moveToMetric(NSPoint(x: 20, y: 70))
        } else if step == 10 {
            results.append((view.frame.height == expandedHeight && chart.frame.minY == expandedChartY &&
                abs(window.frame.height - expandedMenuHeight) < 0.1 && abs(followingOffset - expandedFollowingOffset) < 0.1,
                "restoring both estimates preserves the original chart, menu and following-row layout"))
            results.append((view.visibleMetricHoverText == L10n.text("5小时真实额度估算") + "\n8.8K Token",
                "restoring both estimates restores the left-hand five-hour hover"))
            moveToMetric(NSPoint(x: 240, y: 70))
        } else {
            results.append((view.visibleMetricHoverText == L10n.text("每周真实额度估算") + "\n" +
                (availableAnalysis.weeklyEstimate.tokens.map(TokenUsageFormat.compact) ?? "—") + " Token",
                "restoring both estimates restores the right-hand weekly hover"))
            timer.invalidate(); menu.cancelTracking()
        }
        step += 1
    }
}

@MainActor func checkTokenUsageHistory(_ check: (Bool, String) -> Void, root: URL) throws {
    try checkTokenUsageHistoryStore(check, root: root.appendingPathComponent("sqlite-store"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
    let start = calendar.startOfDay(for: now)
    try checkTokenHistoryCacheCoalescing(check, root: root.appendingPathComponent("cache-coalescing"), now: now)
    try checkCompressedTokenHistory(check, root: root.appendingPathComponent("compressed"), now: now, calendar: calendar)
    check(TokenUsageFormat.compact(999) == "999.0" && TokenUsageFormat.compact(1_234) == "1.2K" &&
        TokenUsageFormat.compact(1_234_567) == "1.2M" && TokenUsageFormat.compact(1_234_567_890) == "1.2B",
        "token totals use K, M and B with exactly one fractional digit")
    check(TokenUsageFormat.compact(999_949) == "999.9K" && TokenUsageFormat.compact(999_950) == "1.0M" &&
        TokenUsageFormat.compact(999_950_000) == "1.0B",
        "rounding promotes units without showing 1000.0K or 1000.0M")
    check(TokenUsageFormat.dollars(12.34) == "$12.3" && TokenUsageFormat.change(2) == "↑2.0%" &&
        TokenUsageFormat.tps(12.34) == "12.3", "currency, change percentages and tps also use one fractional digit")
    check(TokenUsageFormat.compact(63_560_000, fractionDigits: 0) == "64M" &&
        TokenUsageFormat.compact(31_780_000, fractionDigits: 0) == "32M",
        "chart axes use integer KMB values")
    let counts = TokenUsageCounts(input: 1_000_000, cachedInput: 200_000, cacheWriteInput: 0,
        output: 100_000, reasoningOutput: 40_000, total: 1_100_000)
    let sol = TokenUsagePrices.cost(counts, model: "gpt-6.1-sol", requestInput: 100_000)
    check(abs((sol ?? 0) - 2.62) < 0.000001, "API equivalent excludes cached input from ordinary input and reasoning from extra output")
    check(abs((TokenUsagePrices.cost(counts, model: "gpt-6.1-sol", requestInput: 100_000,
        serviceTier: "priority") ?? 0) - 5.24) < 0.000001,
        "recorded priority is priced as Fast API usage")
    check(abs((TokenUsagePrices.cost(counts, model: "gpt-6.1-sol", requestInput: 100_000,
        serviceTier: "flex") ?? 0) - 1.31) < 0.000001,
        "recorded Flex uses its published discounted API price")
    check(abs((TokenUsagePrices.cost(counts, model: "gpt-6.1-sol", requestInput: counts.input) ?? 0) - 4.74) < 0.000001,
        "long context uses the reliable single request input for the higher price tier")
    check(abs((TokenUsagePrices.cost(counts, model: "gpt-5.6-sol", requestInput: counts.input) ?? 0) - 9.56) < 0.000001,
        "5.6 pricing also supports the documented long-context tier")
    check(TokenUsagePrices.cost(counts, model: "unknown", requestInput: counts.input) == nil,
        "unknown models retain tokens without borrowing another model's API price")
    var cacheWrite = counts; cacheWrite.cacheWriteInput = 2
    check(TokenUsagePrices.cost(cacheWrite, model: "gpt-6.1-sol", requestInput: cacheWrite.input) == nil,
        "cache writes with unknown retention do not silently use a made-up price")

    let home = root.appendingPathComponent("home")
    let sessions = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try Data("{\"tokens\":{\"account_id\":\"account-a\"}}".utf8).write(to: home.appendingPathComponent("auth.json"))
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func line(_ type: String, _ payload: [String: Any], _ date: Date?) throws -> Data {
        var entry: [String: Any] = ["type": type, "payload": payload]
        if let date { entry["timestamp"] = iso.string(from: date) }
        var data = try JSONSerialization.data(withJSONObject: entry); data.append(10); return data
    }
    func tokens(_ total: Int, last: Int, used: Double, reset: Date, model: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": total, "cached_input_tokens": 0, "cache_write_input_tokens": 0,
                "output_tokens": 0, "reasoning_output_tokens": 0, "total_tokens": total],
            "last_token_usage": ["input_tokens": last, "cached_input_tokens": 0, "cache_write_input_tokens": 0,
                "output_tokens": 0, "reasoning_output_tokens": 0, "total_tokens": last]],
            "rate_limits": ["limit_id": "codex", "plan_type": "plus",
                "primary": ["used_percent": used, "window_minutes": 300, "resets_at": reset.timeIntervalSince1970],
                "secondary": ["used_percent": used, "window_minutes": 10080, "resets_at": reset.addingTimeInterval(6 * 86400).timeIntervalSince1970]]]
        if let model { payload["model"] = model }; return payload
    }
    let timingHome = root.appendingPathComponent("timing-home")
    let timingSessions = timingHome.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: timingSessions, withIntermediateDirectories: true)
    try Data("{\"tokens\":{\"account_id\":\"account-a\"}}".utf8).write(to: timingHome.appendingPathComponent("auth.json"))
    var timingData = try line("session_meta", ["id": "timing", "creator_account_id": "account-a"], start)
    timingData += try line("turn_context", ["turn_id": "timing-turn", "model": "gpt-6.1-sol"], start)
    for (kind, call, second) in [("function_call", "a", 2), ("custom_tool_call", "b", 3),
                                 ("function_call_output", "a", 6), ("custom_tool_call_output", "b", 7)] {
        timingData += try line("response_item", ["type": kind, "call_id": call], start.addingTimeInterval(Double(second)))
    }
    func outputTokens(_ total: Int, _ output: Int) -> [String: Any] {
        var payload = tokens(total, last: output, used: 30, reset: start.addingTimeInterval(18000))
        payload["info"] = ["total_token_usage": ["input_tokens": 0, "output_tokens": total,
            "reasoning_output_tokens": total / 2, "total_tokens": total],
            "last_token_usage": ["input_tokens": 0, "output_tokens": output,
                "reasoning_output_tokens": output / 2, "total_tokens": output]]
        return payload
    }
    timingData += try line("event_msg", outputTokens(10, 10), start.addingTimeInterval(10))
    timingData += try line("event_msg", outputTokens(10, 10), start.addingTimeInterval(12))
    timingData += try line("event_msg", outputTokens(30, 20), start.addingTimeInterval(15))
    timingData += try line("event_msg", ["type": "task_complete"], start.addingTimeInterval(16))
    timingData += try line("event_msg", outputTokens(40, 10), start.addingTimeInterval(100))
    try timingData.write(to: timingSessions.appendingPathComponent("timing.jsonl"))
    let timingCache = root.appendingPathComponent("timing-cache.json")
    let timingReader = TokenUsageHistoryReader(home: timingHome, cacheURL: timingCache)
    let timing = timingReader.read(now: now)
    let timed = timing.records.filter { $0.samplingSeconds != nil }
    check(timed.count == 2 && timed.allSatisfy { abs($0.samplingSeconds! - 5) < 0.0001 },
        "TPS subtracts overlapping tool waits once and quota-only snapshots do not restart timing")
    check(abs((TokenUsageSpeed(timing.records).value ?? 0) - 3) < 0.0001,
        "TPS weights output including reasoning by measured request time and excludes untimed output")
    check(TokenUsageSpeed([]).value == nil && timing.records.last?.samplingSeconds == nil,
        "missing timing and idle time after turn completion never become a guessed TPS")
    let restoredTiming = TokenUsageHistoryReader(home: timingHome, cacheURL: timingCache)
    check(restoredTiming.read(now: now).records == timing.records && restoredTiming.bytesRead == 0,
        "request timing and TPS survive a warm cache load without rescanning history")
    var moreTiming = try line("turn_context", ["turn_id": "missing-tool-start", "model": "gpt-6.1-sol"], start.addingTimeInterval(110))
    moreTiming += try line("response_item", ["type": "function_call_output", "call_id": "missing"], start.addingTimeInterval(111))
    moreTiming += try line("event_msg", outputTokens(50, 10), start.addingTimeInterval(112))
    moreTiming += try line("turn_context", ["turn_id": "incremental", "model": "gpt-6.1-sol"], start.addingTimeInterval(120))
    moreTiming += try line("response_item", ["type": "function_call", "call_id": "pending"], start.addingTimeInterval(122))
    let timingHandle = try FileHandle(forWritingTo: timingSessions.appendingPathComponent("timing.jsonl"))
    try timingHandle.seekToEnd(); try timingHandle.write(contentsOf: moreTiming)
    check(timingReader.read(now: now).records.last?.samplingSeconds == nil,
        "an unmatched tool output cannot produce a speed from incomplete timing")
    var toolEnd = try line("response_item", ["type": "function_call_output", "call_id": "pending"], start.addingTimeInterval(132))
    toolEnd += try line("event_msg", outputTokens(60, 10), start.addingTimeInterval(140))
    try timingHandle.write(contentsOf: toolEnd); try timingHandle.close()
    check(abs((timingReader.read(now: now).records.last?.samplingSeconds ?? 0) - 10) < 0.0001,
        "incremental reads retain an open tool interval and exclude its wait when it completes")
    check(TokenUsageFormat.range(start.addingTimeInterval(8 * 3600), start.addingTimeInterval(13 * 3600),
        relativeTo: start, calendar: calendar) == "08:00 – 13:00" &&
        TokenUsageFormat.range(start.addingTimeInterval(22 * 3600), start.addingTimeInterval(27 * 3600),
            relativeTo: start, calendar: calendar).contains(L10n.format("次日 %@", "03:00")),
        "window rows omit repeated dates and label a cross-midnight end as the next day")
    let url = sessions.appendingPathComponent("test.jsonl")
    let created = start.addingTimeInterval(-3600)
    let reset = start.addingTimeInterval(4 * 3600)
    var data = try line("session_meta", ["id": "thread-a", "creator_account_id": "account-a"], created)
    data += try line("event_msg", ["type": "thread_settings_applied", "thread_id": "thread-a",
        "thread_settings": ["service_tier": "default"]], created.addingTimeInterval(0.5))
    data += try line("turn_context", ["turn_id": "turn-a", "model": "gpt-6.1-sol"], created.addingTimeInterval(1))
    data += try line("event_msg", tokens(100, last: 100, used: 10, reset: reset), start.addingTimeInterval(-600))
    data += try line("event_msg", tokens(100, last: 100, used: 10, reset: reset), start.addingTimeInterval(-599))
    data += try line("turn_context", ["turn_id": "turn-b", "model": "gpt-6-astra"], start.addingTimeInterval(1))
    data += try line("event_msg", tokens(300, last: 200, used: 40, reset: reset.addingTimeInterval(90)), start.addingTimeInterval(60))
    var correction = tokens(300, last: 200, used: 40, reset: reset)
    var correctionInfo = correction["info"] as! [String: Any]
    var correctionTotal = correctionInfo["total_token_usage"] as! [String: Any]
    correctionTotal["cached_input_tokens"] = 10; correctionInfo["total_token_usage"] = correctionTotal; correction["info"] = correctionInfo
    data += try line("event_msg", correction, start.addingTimeInterval(61))
    try data.write(to: url)
    let reader = TokenUsageHistoryReader(home: home, cacheURL: root.appendingPathComponent("cache.json"))
    let first = reader.read(now: now)
    check(first.records.compactMap(\.counts).reduce(0) { $0 + $1.total } == 300,
        "production history reader ignores duplicate totals including corrected cached-input subfields")
    check(first.records.first { $0.counts?.total == 200 }?.model == "gpt-6-astra",
        "model switches use the current turn context instead of the final model for the whole task")
    check(first.records.filter { $0.counts != nil }.allSatisfy { $0.calibrationGroup?.serviceTier == "standard" },
        "a recorded thread speed setting remains effective across later turn contexts")
    let beforeBytes = reader.bytesRead
    _ = reader.read(now: now)
    check(reader.bytesRead == beforeBytes, "unchanged rollouts are not reparsed by the incremental reader")
    let analysis = TokenUsageHistoryAnalysis(snapshot: first, now: now, calendar: calendar)
    let reuse = reader.readAnalysis(now: now, calendar: calendar)
    let beforePlanExpiry = reader.summaryBuildCount
    let expired = reader.readAnalysis(now: start.addingTimeInterval(86462), calendar: calendar)
    check(reuse.fiveHourEstimate.value != nil && expired.snapshot.currentPlan == nil && expired.fiveHourEstimate.value == nil &&
        reader.summaryBuildCount == beforePlanExpiry,
        "Plus plan evidence expires after twenty-four hours without rebuilding unchanged historical windows")
    let returned = reader.readAnalysis(now: now, calendar: calendar)
    check(returned.fiveHourEstimate.value == reuse.fiveHourEstimate.value,
        "clock rollback restores still-current Plus evidence and its original estimate")
    check(analysis.days.suffix(2).map(\.total) == [300, 0] && analysis.todayTokens == nil,
        "all tokens of a cross-midnight window belong to its local start day; missing today is not zero")
    check(analysis.days[5].segments.count == 1 && analysis.days[5].segments.first?.records.count == 2,
        "reset drift within three minutes retains one actual window and one stack segment")
    check(abs((analysis.fiveHourEstimate.value ?? 0) - (200.0 * 10 / 1_000_000 / 0.3)) < 0.000001,
        "full window estimate divides paired API equivalent by observed percent consumption")
    check(analysis.days.allSatisfy { day in day.segments.reduce(0) { $0 + $1.total } == day.total },
        "stacked chart segments sum exactly to their daily token totals")

    var appended = try line("turn_context", ["turn_id": "turn-c", "model": "gpt-6.1-sol"], start.addingTimeInterval(100))
    appended += try line("event_msg", tokens(50, last: 50, used: 5, reset: reset.addingTimeInterval(-1800)), start.addingTimeInterval(101))
    let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: appended); try handle.close()
    let updated = reader.read(now: now)
    check(updated.records.compactMap(\.counts).reduce(0) { $0 + $1.total } == 350,
        "a cumulative reset counts new request usage without subtracting or replaying older history")
    let updatedAnalysis = TokenUsageHistoryAnalysis(snapshot: updated, now: now, calendar: calendar)
    check(Set(updatedAnalysis.windows.filter { $0.kind == .fiveHour }.map(\.id)).count == 2,
        "an early reset starts a separate actual quota window")
    reader.flushCache(now: now)
    let cached = TokenUsageHistoryReader(home: home, cacheURL: root.appendingPathComponent("cache.json"))
    let restored = cached.read(now: now)
    check(restored.records == updated.records && cached.bytesRead == 0,
        "persistent cursors restore history without rescanning old JSONL bytes")

    let gapHome = root.appendingPathComponent("gap-home"), gapCache = root.appendingPathComponent("gap-cache.json")
    let gapSessions = gapHome.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: gapSessions, withIntermediateDirectories: true)
    try Data("{\"tokens\":{\"account_id\":\"account-a\"}}".utf8).write(to: gapHome.appendingPathComponent("auth.json"))
    let oldGapAt = start.addingTimeInterval(-20 * 86400)
    for boundAccount in [true, false] {
        let id = boundAccount ? "owned-gap" : "unbound-gap"
        var header = ["id": id]
        if boundAccount { header["creator_account_id"] = "account-a" }
        var gapData = try line("session_meta", header, oldGapAt.addingTimeInterval(-2))
        gapData += try line("turn_context", ["model": "gpt-6.1-sol", "service_tier": "standard"], oldGapAt.addingTimeInterval(-1))
        gapData += try line("event_msg", tokens(100, last: 100, used: 0, reset: reset), oldGapAt)
        gapData += try line("event_msg", tokens(900, last: 100, used: 30, reset: reset), oldGapAt.addingTimeInterval(1))
        try gapData.write(to: gapSessions.appendingPathComponent(id + ".jsonl"))
    }
    let gapReader = TokenUsageHistoryReader(home: gapHome, cacheURL: gapCache)
    let gaps = gapReader.read(now: now)
    let ownedGap = gaps.records.first { $0.id.hasSuffix(":gap") }
    let unboundGap = gaps.unboundRecords.first { $0.id.hasSuffix(":gap") }
    check(ownedGap?.usageUpperBound == oldGapAt.addingTimeInterval(1) && ownedGap?.timestamp == nil &&
        ownedGap?.model == nil && ownedGap?.counts?.total == 700 && unboundGap?.usageUpperBound == ownedGap?.usageUpperBound &&
        unboundGap?.accountID == nil && unboundGap?.model == nil && unboundGap?.timestamp == nil,
        "cumulative gaps keep only their snapshot time bound without inventing usage time, model or account")
    let warmGapReader = TokenUsageHistoryReader(home: gapHome, cacheURL: gapCache)
    let warmGaps = warmGapReader.read(now: now)
    check(warmGaps.records == gaps.records && warmGaps.unboundRecords == gaps.unboundRecords && warmGapReader.bytesRead == 0,
        "owned and unknown-account gap bounds survive warm cache loading without reading rollout bytes")
    var oldCache = try JSONSerialization.jsonObject(with: Data(contentsOf: gapCache)) as! [String: Any]
    oldCache["version"] = 3
    var oldFiles = oldCache["files"] as! [String: [String: Any]]
    for (path, var file) in oldFiles {
        var parser = file["parser"] as! [String: Any]
        parser["records"] = (parser["records"] as! [[String: Any]]).map { record in
            var record = record; record.removeValue(forKey: "usageUpperBound"); return record
        }
        file["parser"] = parser; oldFiles[path] = file
    }
    oldCache["files"] = oldFiles
    try JSONSerialization.data(withJSONObject: oldCache).write(to: gapCache)
    let rebuiltGapReader = TokenUsageHistoryReader(home: gapHome, cacheURL: gapCache)
    let rebuiltGaps = rebuiltGapReader.read(now: now)
    let rebuiltCache = try JSONSerialization.jsonObject(with: Data(contentsOf: gapCache)) as! [String: Any]
    check(rebuiltGapReader.bytesRead > 0 && rebuiltGaps.records == gaps.records && rebuiltGaps.unboundRecords == gaps.unboundRecords &&
        rebuiltCache["version"] as? Int == 4,
        "version-three caches are rebuilt from rollout snapshots to recover cumulative gap bounds")
    var noTimeData = try line("session_meta", ["id": "undated-gap", "creator_account_id": "account-a"], oldGapAt)
    noTimeData += try line("turn_context", ["model": "gpt-6.1-sol"], oldGapAt)
    noTimeData += try line("event_msg", tokens(100, last: 100, used: 0, reset: reset), oldGapAt)
    noTimeData += try line("event_msg", tokens(900, last: 100, used: 30, reset: reset), nil)
    try noTimeData.write(to: gapSessions.appendingPathComponent("undated-gap.jsonl"))
    let undatedGap = rebuiltGapReader.read(now: now).records.first { $0.threadID == "undated-gap" && $0.id.hasSuffix(":gap") }
    check(undatedGap?.counts?.total == 700 && undatedGap?.timestamp == nil && undatedGap?.usageUpperBound == nil,
        "a cumulative snapshot without an event timestamp never borrows a filesystem or session time bound")

    let fork = sessions.appendingPathComponent("fork.jsonl")
    var copied = try line("session_meta", ["id": "thread-fork", "creator_account_id": "account-a", "forked_from_id": "thread-a"], start)
    copied += try line("session_meta", ["id": "thread-a", "creator_account_id": "account-b"], created)
    copied += try line("turn_context", ["model": "gpt-6-astra", "turn_id": "copied"], start)
    copied += try line("event_msg", tokens(300, last: 200, used: 40, reset: reset), start)
    copied += try line("event_msg", ["type": "thread_settings_applied", "thread_id": "thread-a",
        "thread_settings": ["service_tier": "priority"]], start)
    copied += try line("turn_context", ["model": "gpt-6.1-sol", "turn_id": "own"], start.addingTimeInterval(200))
    copied += try line("event_msg", tokens(370, last: 70, used: 41, reset: reset), start.addingTimeInterval(201))
    try copied.write(to: fork)
    let forked = reader.read(now: now)
    check(forked.records.filter { $0.threadID == "thread-fork" }.compactMap(\.counts).reduce(0) { $0 + $1.total } == 70,
        "fork copies and embedded parent metadata are skipped while independent new consumption is retained")
    check(forked.records.filter { $0.threadID == "thread-fork" }.allSatisfy { $0.serviceTier == nil },
        "a copied parent's service tier is never assigned to a fork's own usage")
    var childData = try line("session_meta", ["id": "child", "creator_account_id": "account-a",
        "source": ["subagent": ["parent_thread_id": "thread-a"]]], start)
    childData += try line("turn_context", ["model": "gpt-6.1-sol", "turn_id": "child-own", "service_tier": "default"],
        start.addingTimeInterval(200))
    childData += try line("event_msg", tokens(50, last: 50, used: 41, reset: reset), start.addingTimeInterval(201))
    try childData.write(to: sessions.appendingPathComponent("child.jsonl"))
    check(reader.read(now: now).records.first { $0.threadID == "child" && $0.counts != nil }?.isAuxiliary == true,
        "a subagent's real new usage stays counted without becoming the current user model")

    let tierHome = root.appendingPathComponent("tier-home"), tierSessions = tierHome.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: tierSessions, withIntermediateDirectories: true)
    try Data("{\"tokens\":{\"account_id\":\"account-a\"}}".utf8).write(to: tierHome.appendingPathComponent("auth.json"))
    let tierURL = tierSessions.appendingPathComponent("tier.jsonl"), tierCache = root.appendingPathComponent("tier-cache.json")
    var tierData = try line("session_meta", ["id": "tier-thread", "creator_account_id": "account-a"], start)
    tierData += try line("turn_context", ["turn_id": "tier-a", "model": "gpt-6.1-sol"], start.addingTimeInterval(1))
    tierData += try line("event_msg", tokens(100, last: 100, used: 0, reset: reset), start.addingTimeInterval(10))
    for (tier, total, second) in [("priority", 200, 20), ("flex", 300, 40)] {
        tierData += try line("event_msg", ["type": "thread_settings_applied", "thread_id": "tier-thread",
            "thread_settings": ["service_tier": tier]], start.addingTimeInterval(Double(second)))
        tierData += try line("event_msg", tokens(total, last: 100, used: Double(total / 10), reset: reset),
            start.addingTimeInterval(Double(second + 10)))
    }
    tierData += try line("event_msg", ["type": "thread_settings_applied", "thread_id": "tier-thread",
        "thread_settings": ["service_tier": NSNull()]], start.addingTimeInterval(60))
    tierData += try line("event_msg", ["type": "task_started", "turn_id": "tier-b"], start.addingTimeInterval(70))
    tierData += try line("turn_context", ["turn_id": "tier-b", "model": "gpt-6.1-sol"], start.addingTimeInterval(71))
    tierData += try line("event_msg", tokens(400, last: 100, used: 40, reset: reset), start.addingTimeInterval(80))
    try tierData.write(to: tierURL)
    let tierReader = TokenUsageHistoryReader(home: tierHome, cacheURL: tierCache)
    let tierSnapshot = tierReader.read(now: now), tierUsage = tierSnapshot.records.filter { $0.counts != nil }
    check(tierUsage.map { $0.calibrationGroup?.serviceTier ?? "unknown" } == ["unknown", "fast", "flex", "standard"],
        "history parses chronological priority, Flex and explicit default settings without guessing earlier tiers")
    check(tierUsage.first?.cost != nil && tierUsage.first?.calibrationGroup == nil,
        "legacy API cost stays visible while its unrecorded tier is excluded from quota calibration")
    let restoredTiers = TokenUsageHistoryReader(home: tierHome, cacheURL: tierCache)
    check(restoredTiers.read(now: now).records == tierSnapshot.records && restoredTiers.bytesRead == 0,
        "known thread settings and calibration metadata survive a warm cache load")
    let tierHandle = try FileHandle(forWritingTo: tierURL); try tierHandle.seekToEnd()
    var nextTierTurn = try line("event_msg", ["type": "task_started", "turn_id": "tier-c"], start.addingTimeInterval(90))
    nextTierTurn += try line("turn_context", ["turn_id": "tier-c", "model": "gpt-6.1-sol"], start.addingTimeInterval(91))
    nextTierTurn += try line("event_msg", tokens(500, last: 100, used: 50, reset: reset), start.addingTimeInterval(100))
    try tierHandle.write(contentsOf: nextTierTurn); try tierHandle.close()
    check(restoredTiers.read(now: now).records.last?.calibrationGroup?.serviceTier == "standard",
        "an incremental new turn retains the last explicit thread speed instead of losing it")
    let auxiliary = TokenUsageHistoryReader(home: home, additionalHomes: [tierHome]).read(now: now)
    check(auxiliary.records.filter { $0.threadID == "tier-thread" }.allSatisfy(\.isAuxiliary) &&
        auxiliary.records.contains { $0.threadID == "thread-a" && !$0.isAuxiliary },
        "Keeper's isolated home is auxiliary and cannot select the current user calibration model")

    // Exercise the actual estimator with unequal windows, rather than mirroring its formula in a fixture.
    func record(_ id: String, at: Date?, input: Int?, used: Double?, reset: Date,
                model: String? = "gpt-6.1-sol", plan: String? = "plus", tier: String? = "standard") -> TokenUsageRecord {
        let counts = input.map { TokenUsageCounts(input: $0, cachedInput: 0, cacheWriteInput: 0, output: 0, reasoningOutput: 0, total: $0) }
        return TokenUsageRecord(id: id, threadID: "direct", accountID: "account-a", timestamp: at,
            model: model, counts: counts, requestInput: input, serviceTier: tier,
            fiveHour: used.map { QuotaWindow(usedPercent: $0, windowMinutes: 300, resetsAt: reset) },
            weekly: used.map { QuotaWindow(usedPercent: $0, windowMinutes: 10080, resetsAt: start.addingTimeInterval(6 * 86400)) },
            planType: plan)
    }
    func summarize(_ records: [TokenUsageRecord], plan: String? = "plus", cal: Calendar? = nil) -> TokenUsageHistoryAnalysis {
        TokenUsageHistoryAnalysis(snapshot: TokenUsageHistorySnapshot(accountID: "account-a", records: records,
            currentPlan: plan, capturedAt: now, isLoaded: true), now: now, calendar: cal ?? calendar)
    }
    let firstReset = start.addingTimeInterval(6 * 3600), secondReset = start.addingTimeInterval(11 * 3600)
    let pair = [
        record("baseline-1", at: start.addingTimeInterval(3600), input: nil, used: 0, reset: firstReset),
        record("cost-1", at: start.addingTimeInterval(7200), input: 1500, used: 30, reset: firstReset),
        record("baseline-2", at: start.addingTimeInterval(6 * 3600), input: nil, used: 0, reset: secondReset),
        record("cost-2", at: start.addingTimeInterval(7 * 3600), input: 9000, used: 90, reset: secondReset)
    ]
    let previousRecords = pair.map { record -> TokenUsageRecord in
        var old = record
        old.timestamp = record.timestamp.map { calendar.date(byAdding: .day, value: -7, to: $0)! }
        old.fiveHour?.resetsAt = calendar.date(byAdding: .day, value: -7, to: record.fiveHour!.resetsAt)!
        return old
    }
    let previousSnapshot = TokenUsageHistorySnapshot(accountID: "account-a", records: previousRecords, currentPlan: "plus", capturedAt: now, isLoaded: true)
    let previousCache = TokenUsageHistoryAnalysisCache()
    let beforeCutoff = previousCache.analysis(snapshot: previousSnapshot, revision: 1, recordsRevision: 1,
        now: start.addingTimeInterval(5400), calendar: calendar)
    let afterCutoff = previousCache.analysis(snapshot: previousSnapshot, revision: 1, recordsRevision: 1,
        now: start.addingTimeInterval(7500), calendar: calendar)
    check(beforeCutoff.fiveHourEstimate.previousValue == nil && afterCutoff.fiveHourEstimate.previousValue != nil &&
        previousCache.summaryBuildCount == 1 && previousCache.analysisBuildCount == 2,
        "the previous seven-day intraday sample cutoff refreshes estimates while reusing complete historical windows")
    check(afterCutoff.days.allSatisfy { $0.total == 0 } && afterCutoff.historicalDays.flatMap(\.records).count == 2,
        "records older than the seven-day chart remain available in full historical detail")
    let weighted = summarize(pair)
    check(abs((weighted.fiveHourEstimate.value ?? 0) - 0.0175) < 0.0000001 && weighted.fiveHourEstimate.sampleCount == 2,
        "eligible windows are weighted by consumed fraction, not an arithmetic average of window ratios")
    check(weighted.fiveHourEstimate.tokens == 8750,
        "full-window token estimate uses the same paired usage and consumed fraction as its dollar value")
    var twoModels = pair; twoModels[1].model = "gpt-6-astra"
    let latestModel = summarize(twoModels)
    check(abs((latestModel.fiveHourEstimate.value ?? 0) - 0.02) < 0.0000001 &&
        latestModel.fiveHourEstimate.tokens == 10_000 && latestModel.fiveHourEstimate.sampleCount == 1,
        "full allowance is calibrated against the latest normal model rather than mixing model capacities")
    var twoTiers = pair; twoTiers[1].serviceTier = "fast"
    check(abs((summarize(twoTiers).fiveHourEstimate.value ?? 0) - 0.02) < 0.0000001 &&
        summarize(twoTiers).fiveHourEstimate.sampleCount == 1,
        "Fast and Standard windows do not share a quota calibration")
    var foreignWindow = pair; foreignWindow[1].accountID = "account-b"
    check(summarize(foreignWindow).fiveHourEstimate.sampleCount == 1 &&
        abs((summarize(foreignWindow).fiveHourEstimate.value ?? 0) - 0.02) < 0.0000001,
        "a window with another account's observation is excluded from calibration")
    let mixedInterval = [
        record("mixed-base", at: start.addingTimeInterval(3600), input: nil, used: 0, reset: firstReset),
        record("mixed-astra", at: start.addingTimeInterval(4000), input: 1000, used: 0, reset: firstReset, model: "gpt-6-astra"),
        record("mixed-sol", at: start.addingTimeInterval(5000), input: 2000, used: 40, reset: firstReset),
        record("pure-sol", at: start.addingTimeInterval(6000), input: 1000, used: 80, reset: firstReset)
    ]
    check(abs((summarize(mixedInterval).fiveHourEstimate.value ?? 0) - 0.005) < 0.0000001 &&
        summarize(mixedInterval).fiveHourEstimate.tokens == 2500,
        "a quota step containing multiple models is excluded instead of allocating its percentage by token shares")
    var missingTier = pair; missingTier[3].serviceTier = nil
    check(summarize(missingTier).fiveHourEstimate.value == nil,
        "the latest normal request with unrecorded speed cannot silently select Standard calibration")
    var keeper = record("keeper-last", at: start.addingTimeInterval(10 * 3600), input: 1,
        used: 90, reset: secondReset, model: "gpt-6-luna")
    keeper.isAuxiliary = true
    let withKeeper = summarize(pair + [keeper])
    check(withKeeper.calibrationGroup == weighted.calibrationGroup &&
        withKeeper.fiveHourEstimate.value == weighted.fiveHourEstimate.value,
        "a later keepalive or subagent request cannot replace the latest normal model as calibration target")
    let previousDay = start.addingTimeInterval(-7 * 86400), previousReset = previousDay.addingTimeInterval(6 * 3600)
    let priorBase = record("prior-base", at: previousDay.addingTimeInterval(3600), input: nil, used: 0, reset: previousReset)
    var priorCost = record("prior-cost", at: previousDay.addingTimeInterval(7200), input: 1500,
        used: 30, reset: previousReset, model: "gpt-6-astra")
    check(summarize([priorBase, priorCost] + pair).fiveHourEstimate.change == nil,
        "comparison periods never compare the current model against another model's capacity")
    priorCost.model = "gpt-6.1-sol"
    check(abs((summarize([priorBase, priorCost] + pair).fiveHourEstimate.change ?? 0) - 75) < 0.0001,
        "period changes are computed from matching model and speed cohorts on both sides")
    let unmatchedTail = pair + [record("unpaired-tail", at: start.addingTimeInterval(9 * 3600),
        input: 100_000, used: 90, reset: secondReset)]
    check(summarize(unmatchedTail).fiveHourEstimate.tokens == weighted.fiveHourEstimate.tokens,
        "token estimates exclude trailing tokens that have no matching quota movement")
    check(weighted.windows.filter { $0.kind == .fiveHour }.count == 2 &&
        Set(weighted.days.last!.segments.map(\.colorIndex)).count == 2,
        "zero-percent baselines create real windows and same-day windows receive distinct deterministic colors")
    let threshold = [
        record("threshold-base", at: start.addingTimeInterval(3600), input: nil, used: 0, reset: firstReset),
        record("threshold-end", at: start.addingTimeInterval(7200), input: 1500, used: 25, reset: firstReset)
    ]
    check(summarize(threshold).fiveHourEstimate.value == nil, "exactly 25 percent is below the strict eligible-window threshold")
    var above = threshold; above[1].fiveHour?.usedPercent = 25.01
    check(summarize(above).fiveHourEstimate.value != nil, "more than 25 percent is eligible")
    var midstream = threshold; midstream[0].fiveHour?.usedPercent = 80; midstream[1].fiveHour?.usedPercent = 90
    check(summarize(midstream).fiveHourEstimate.value == nil, "an 80-to-90 observation counts ten points, never ninety")
    let highWater = [
        record("high-base", at: start.addingTimeInterval(3600), input: nil, used: 40, reset: firstReset),
        record("high-stale", at: start.addingTimeInterval(5000), input: 500, used: 39, reset: firstReset.addingTimeInterval(60)),
        record("high-end", at: start.addingTimeInterval(7200), input: 1000, used: 75, reset: firstReset)
    ]
    let high = summarize(highWater)
    check(high.windows.filter { $0.kind == .fiveHour }.count == 1 &&
        abs((high.fiveHourEstimate.value ?? 0) - 0.003 / 0.35) < 0.0000001,
        "same-reset stale percent readings keep their tokens while the denominator uses the high-water mark")
    var missingQuota = Array(pair.prefix(2))
    missingQuota.insert(record("missing-quota", at: start.addingTimeInterval(5000), input: 700, used: nil, reset: firstReset), at: 1)
    let missing = summarize(missingQuota)
    check(missing.fiveHourEstimate.value == nil && missing.unknownWindowTokens == 700,
        "a token event without paired quota remains visible and makes the intersecting estimate incomplete")
    var unpriced = Array(pair.prefix(2)); unpriced[1].model = "new-unpriced-model"
    let noPrice = summarize(unpriced)
    check(noPrice.todayTokens == 1500 && noPrice.pricedTokens == 0 && noPrice.fiveHourEstimate.value == nil,
        "unpriced model consumption stays in token totals without presenting a partial dollar estimate")
    let untimed = record("no-time", at: nil, input: 800, used: nil, reset: firstReset)
    let unknownTime = summarize(Array(pair.prefix(2)) + [untimed])
    check(unknownTime.unknownTimeTokens == 800 && unknownTime.todayTokens == 1500 && unknownTime.fiveHourEstimate.value == nil,
        "unknown timestamps never borrow file dates or silently enter a priced sample")
    check(summarize(pair, plan: "pro").fiveHourEstimate.value == nil,
        "non-Plus observations are never advertised as a measured Plus allowance")
    var sparsePlans = Array(pair.prefix(2)); sparsePlans[1].planType = nil
    check(summarize(sparsePlans).fiveHourEstimate.value != nil,
        "an omitted plan field does not contradict positive Plus evidence in the same account window")
    sparsePlans[0].planType = nil
    check(summarize(sparsePlans).fiveHourEstimate.value == nil,
        "a window with no positive Plus evidence is not used for Plus estimates")
    sparsePlans[0].planType = "plus"; sparsePlans[1].planType = "pro"
    check(summarize(sparsePlans).fiveHourEstimate.value == nil,
        "conflicting plan evidence disqualifies the entire sample")
    var scopedSnapshot = TokenUsageHistorySnapshot(accountID: "account-a", records: Array(pair.prefix(2)),
        unboundTokens: 700, unboundRecords: [record("old-unbound", at: start.addingTimeInterval(-20 * 86400),
            input: 700, used: nil, reset: firstReset)], currentPlan: "plus", capturedAt: now, isLoaded: true)
    check(TokenUsageHistoryAnalysis(snapshot: scopedSnapshot, now: now, calendar: calendar).fiveHourEstimate.value != nil,
        "old unknown-account records do not suppress unrelated complete recent windows")
    scopedSnapshot.unboundRecords[0].timestamp = start.addingTimeInterval(5000)
    check(TokenUsageHistoryAnalysis(snapshot: scopedSnapshot, now: now, calendar: calendar).fiveHourEstimate.value == nil,
        "unknown-account records overlapping a sample disqualify that window")
    scopedSnapshot.unboundRecords[0].timestamp = nil
    check(TokenUsageHistoryAnalysis(snapshot: scopedSnapshot, now: now, calendar: calendar).fiveHourEstimate.value == nil,
        "undated unknown ownership cannot be treated as unrelated history")
    for unknownAccount in [false, true] {
        for (bound, eligible) in [(start.addingTimeInterval(-20 * 86400), true),
            (pair[0].timestamp!.addingTimeInterval(-1), true), (pair[0].timestamp!, false),
            (start.addingTimeInterval(5000), false), (now.addingTimeInterval(3600), false), (nil, false)] as [(Date?, Bool)] {
            var gap = untimed
            gap.accountID = unknownAccount ? nil : "account-a"
            gap.model = nil; gap.serviceTier = nil; gap.usageUpperBound = bound
            let snapshot = TokenUsageHistorySnapshot(accountID: "account-a",
                records: Array(pair.prefix(2)) + (unknownAccount ? [] : [gap]),
                unboundTokens: unknownAccount ? 800 : 0, unboundRecords: unknownAccount ? [gap] : [],
                currentPlan: "plus", capturedAt: now, isLoaded: true)
            let scoped = TokenUsageHistoryAnalysis(snapshot: snapshot, now: now, calendar: calendar)
            let reason = unknownAccount ? "部分记录账户未知" : "部分 Token 时间未知"
            check((scoped.fiveHourEstimate.value != nil) == eligible && (scoped.weeklyEstimate.value != nil) == eligible &&
                scoped.fiveHourEstimate.reason == (eligible ? "" : reason) && scoped.weeklyEstimate.reason == (eligible ? "" : reason),
                "gap bounds scope both estimates conservatively: unknownAccount=\(unknownAccount), bound=\(String(describing: bound)), eligible=\(eligible)")
        }
    }
    scopedSnapshot.unboundRecords = []
    check(TokenUsageHistoryAnalysis(snapshot: scopedSnapshot, now: now, calendar: calendar).fiveHourEstimate.reason == "部分记录账户未知" &&
        TokenUsageHistoryAnalysis(snapshot: scopedSnapshot, now: now, calendar: calendar).weeklyEstimate.value == nil,
        "an aggregate unknown-account total without detailed records still blocks both estimates")
    var previousPair = [priorBase, priorCost]
    for index in previousPair.indices { previousPair[index].weekly?.resetsAt = previousDay.addingTimeInterval(6 * 86400) }
    var betweenPeriods = untimed
    betweenPeriods.usageUpperBound = pair[0].timestamp!.addingTimeInterval(-1)
    let scopedPeriods = summarize(previousPair + Array(pair.prefix(2)) + [betweenPeriods])
    check(scopedPeriods.fiveHourEstimate.value != nil && scopedPeriods.fiveHourEstimate.previousValue == nil &&
        scopedPeriods.weeklyEstimate.value != nil && scopedPeriods.weeklyEstimate.previousValue == nil &&
        scopedPeriods.fiveHourEstimate.reason.isEmpty && scopedPeriods.weeklyEstimate.reason.isEmpty,
        "a gap known before current samples may still invalidate previous samples independently")
    let insufficientCurrent = summarize(previousPair + threshold + [betweenPeriods])
    check(insufficientCurrent.fiveHourEstimate.value == nil && insufficientCurrent.weeklyEstimate.value == nil &&
        insufficientCurrent.fiveHourEstimate.reason == "有效样本不足" && insufficientCurrent.weeklyEstimate.reason == "有效样本不足",
        "previous-period gap failures do not replace the current reason after an old gap is excluded")
    var currentUnbound = untimed; currentUnbound.timestamp = start.addingTimeInterval(5000)
    let currentUnboundSnapshot = TokenUsageHistorySnapshot(accountID: "account-a", records: previousPair + Array(pair.prefix(2)),
        unboundTokens: 800, unboundRecords: [currentUnbound], currentPlan: "plus", capturedAt: now, isLoaded: true)
    let currentBlocked = TokenUsageHistoryAnalysis(snapshot: currentUnboundSnapshot, now: now, calendar: calendar)
    check(currentBlocked.fiveHourEstimate.value == nil && currentBlocked.fiveHourEstimate.previousValue != nil &&
        currentBlocked.weeklyEstimate.value == nil && currentBlocked.weeklyEstimate.previousValue != nil &&
        currentBlocked.fiveHourEstimate.reason == "部分记录账户未知" && currentBlocked.weeklyEstimate.reason == "部分记录账户未知",
        "a current unknown-account record does not suppress unrelated previous-period samples")
    let boundaryDay = calendar.date(byAdding: .day, value: -7, to: start)!
    let boundaryReset = boundaryDay.addingTimeInterval(28 * 3600)
    let boundary = record("cross-period", at: boundaryDay.addingTimeInterval(25 * 3600), input: 900,
        used: 20, reset: boundaryReset)
    let boundaryAnalysis = summarize([boundary])
    check(boundaryAnalysis.totalTimedTokens == 0 && boundaryAnalysis.days.allSatisfy { !$0.hasRecords },
        "a window starting before the seven-day boundary stays outside its token and price-coverage totals after midnight")
    let localReset = start.addingTimeInterval(5 * 3600 + 1800)
    let zoneRecord = record("timezone", at: start.addingTimeInterval(2 * 3600), input: 1000, used: 10, reset: localReset)
    var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
    check(summarize([zoneRecord]).todayTokens == 1000 && summarize([zoneRecord], cal: utc).todayTokens == nil,
        "window attribution uses the selected local calendar and is recomputed when timezone changes")
    let driftRecord = record("midnight-drift", at: start.addingTimeInterval(-60), input: 700, used: 10,
        reset: start.addingTimeInterval(5 * 3600 + 60))
    let driftAnalysis = summarize([driftRecord])
    check(driftAnalysis.todayTokens == nil && driftAnalysis.historicalDays.first?.date == start.addingTimeInterval(-86400),
        "midnight reset drift cannot put a window start in the future and move its tokens into tomorrow")

    // Prefix validation must invalidate cached ownership even when the tail is unchanged.
    let beforeRewrite = try Data(contentsOf: url)
    let rewritten = Data(String(decoding: beforeRewrite, as: UTF8.self).replacingOccurrences(of: "\"creator_account_id\":\"account-a\"",
        with: "\"creator_account_id\":\"account-b\"").utf8)
    check(rewritten.count == beforeRewrite.count, "header rewrite fixture preserves file size")
    let rewriteHandle = try FileHandle(forWritingTo: url); try rewriteHandle.write(contentsOf: rewritten); try rewriteHandle.close()
    let sameSize = reader.read(now: now)
    check(!sameSize.records.contains { $0.threadID == "thread-a" }, "same-size header rewrites cannot retain a cached prior account")
    let restoreHandle = try FileHandle(forWritingTo: url); try restoreHandle.write(contentsOf: beforeRewrite); try restoreHandle.close()
    _ = reader.read(now: now)
    let extra = try line("event_msg", tokens(80, last: 30, used: 6, reset: reset), start.addingTimeInterval(300))
    let appendHandle = try FileHandle(forWritingTo: url); try appendHandle.write(contentsOf: rewritten)
    try appendHandle.seekToEnd(); try appendHandle.write(contentsOf: extra); try appendHandle.close()
    check(!reader.read(now: now).records.contains { $0.threadID == "thread-a" },
        "a rewritten account header followed by appended data cannot leak usage into the old account")

    let orphan = sessions.appendingPathComponent("orphan.jsonl")
    try line("event_msg", tokens(100, last: 100, used: 10, reset: reset), start).write(to: orphan)
    check(reader.read(now: now).unreadableFiles > 0, "token evidence without a valid owner header is partial history, never a complete zero")

    _ = NSApplication.shared
    let menuView = TokenUsageMenuView(analysis: weighted)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: menuView.frame.size),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = menuView; window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    menuView.layoutSubtreeIfNeeded()
    menuView.display()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let chart = menuView.chart
    let chartBitmap = chart.bitmapImageRepForCachingDisplay(in: chart.bounds)!
    chart.cacheDisplay(in: chart.bounds, to: chartBitmap)
    var hover: String?
    chart.hoverChanged = { hover = $0 }
    let slot = chart.plotRect.width / 7
    chart.hover(at: NSPoint(x: chart.plotRect.minX + 6.5 * slot, y: 24))
    check(hover?.contains(TokenUsageFormat.compact(1500)) == true && hover?.contains("Token") == true,
        "native chart segment hover exposes compact token usage during menu tracking")
    check(chart.visibleHoverText?.contains(L10n.format("5小时用量：%@ Token", TokenUsageFormat.compact(1500))) == true &&
        chart.visibleHoverText?.contains(L10n.format("当日总量：%@ Token", TokenUsageFormat.compact(10500))) == true &&
        chart.visibleHoverText?.components(separatedBy: "\n").count == 3,
        "hovering a stack displays just its range, window usage and daily total")
    let firstHighlight = chart.highlightedSegment
    check(firstHighlight != nil, "the hovered five-hour segment has a native selection outline")
    chart.hover(at: NSPoint(x: chart.plotRect.minX + 6.5 * slot, y: 60))
    check(chart.visibleHoverText?.contains(L10n.format("5小时用量：%@ Token", TokenUsageFormat.compact(9000))) == true &&
        chart.highlightedSegment != nil && chart.highlightedSegment != firstHighlight,
        "moving to another stack replaces both its usage and selection outline")
    chart.hover(at: NSPoint(x: chart.plotRect.minX + 6 * slot + 1, y: 80))
    check(hover?.contains(TokenUsageFormat.compact(10500)) == true && chart.highlightedSegment == nil,
        "hovering a column outside its stacks shows the daily total without selecting a segment")
    var clicked = false; chart.openHistory = { clicked = true }
    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    chart.mouseDown(with: event)
    check(clicked, "native chart clicks invoke the independent-history entry point")
    check(chart.visibleHoverText == nil, "clicking into history dismisses the hover panel")
    menuView.hoverMetric(at: NSPoint(x: 20, y: 10))
    check(menuView.visibleMetricHoverText?.contains(TokenUsageFormat.compact(10500)) == true,
        "the total hover uses the same KMB units as the chart")
    let tpsFrame = menuView.metricTPSFrame
    check(tpsFrame.width > 0 && tpsFrame.minX > 0 && tpsFrame.maxX < 190,
        "the tps hover follows its laid-out value beside the token total: \(tpsFrame)")
    menuView.hoverMetric(at: NSPoint(x: tpsFrame.midX, y: tpsFrame.midY))
    check(menuView.visibleMetricHoverText == L10n.text("tps 表示平均每秒生成的 Token 数，用来衡量输出速度。"),
        "tps hover gives a single plain-language definition without calculation details")
    menuView.hoverMetric(at: NSPoint(x: 250, y: tpsFrame.midY))
    check(menuView.visibleMetricHoverText?.contains(TokenUsageFormat.compact(10500)) == true,
        "the former right-aligned tps area no longer shows a stale tps tooltip")
    menuView.hoverMetric(at: NSPoint(x: 20, y: 70))
    check(menuView.visibleMetricHoverText == L10n.text("5小时真实额度估算") + "\n8.8K Token",
        "five-hour metric hover contains its title and full-window token estimate")
    menuView.hoverMetric(at: NSPoint(x: 240, y: 70))
    check(menuView.visibleMetricHoverText == L10n.text("每周真实额度估算") + "\n" +
        (weighted.weeklyEstimate.tokens.map(TokenUsageFormat.compact) ?? "—") + " Token",
        "weekly metric hover uses its own full-window token estimate without extra copy")
    menuView.menuDidClose()
    check(menuView.visibleMetricHoverText == nil, "closing the menu hides metric hover panels")

    var fiveHourOnlyRecords = pair
    for index in fiveHourOnlyRecords.indices { fiveHourOnlyRecords[index].weekly = nil }
    let fiveHourOnly = summarize(fiveHourOnlyRecords)
    menuView.update(fiveHourOnly)
    menuView.hoverMetric(at: NSPoint(x: 240, y: 70))
    check(menuView.visibleMetricHoverText == L10n.text("5小时真实额度估算") + "\n8.8K Token",
        "a five-hour-only row uses the available width without leaving a hidden weekly hover")
    menuView.update(weighted)
    var weeklyOnlyRecords = pair
    for index in weeklyOnlyRecords.indices { weeklyOnlyRecords[index].fiveHour = nil }
    let weeklyOnly = summarize(weeklyOnlyRecords)
    check(weeklyOnly.fiveHourEstimate.value == nil && weeklyOnly.weeklyEstimate.value != nil,
        "the menu transition fixture has a weekly estimate and no five-hour estimate")
    let nativeMenu = NSMenu()
    let nativeItem = NSMenuItem(); nativeItem.view = menuView; nativeMenu.addItem(nativeItem)
    let followingItem = NSMenuItem()
    let followingView = NSTextField(labelWithString: L10n.text("设置…"))
    followingView.frame = NSRect(x: 0, y: 0, width: 304, height: 24)
    followingItem.view = followingView; nativeMenu.addItem(followingItem)
    let trackingCheck = UsageMenuTrackingCheck(menu: nativeMenu, view: menuView, followingView: followingView,
        availableAnalysis: weighted, unavailableAnalysis: summarize(threshold), weeklyOnlyAnalysis: weeklyOnly)
    trackingCheck.run()
    for (value, name) in trackingCheck.results { check(value, name) }
    check(trackingCheck.results.count == 16 && chart.visibleHoverText == nil,
        "actual menu tracking executes hover checks and closes its panel on dismissal")

    try Data("{\"tokens\":{\"account_id\":\"account-b\"}}".utf8).write(to: home.appendingPathComponent("auth.json"))
    let switched = reader.read(now: now)
    check(switched.records.allSatisfy { $0.accountID == "account-b" } && !switched.records.contains { $0.threadID == "thread-fork" },
        "switching accounts never shows another account's token or dollar history")
}

private func checkTokenHistoryCacheCoalescing(_ check: (Bool, String) -> Void, root: URL, now: Date) throws {
    let home = root.appendingPathComponent("home")
    let sessions = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try Data("{\"tokens\":{\"account_id\":\"account-a\"}}".utf8).write(to: home.appendingPathComponent("auth.json"))
    let file = sessions.appendingPathComponent("usage.jsonl")
    let cache = root.appendingPathComponent("cache.json")
    let iso = ISO8601DateFormatter()
    func row(_ type: String, _ payload: [String: Any], _ at: Date) throws -> Data {
        var value = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": iso.string(from: at), "payload": payload])
        value.append(10); return value
    }
    func usage(_ total: Int) throws -> Data {
        try row("event_msg", ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "total_tokens": total],
            "last_token_usage": ["input_tokens": 10, "total_tokens": 10]]], now.addingTimeInterval(Double(total)))
    }
    var trace = try row("session_meta", ["id": "coalesced", "creator_account_id": "account-a"], now)
    trace += try row("turn_context", ["turn_id": "one", "model": "gpt-6.1-sol"], now)
    trace += try usage(10)
    try trace.write(to: file)
    let reader = TokenUsageHistoryReader(home: home, cacheURL: cache)
    _ = reader.read(now: now.addingTimeInterval(10))
    let saved = try Data(contentsOf: cache)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd(); try handle.write(contentsOf: usage(20)); try handle.close()
    let latest = reader.read(now: now.addingTimeInterval(30))
    check(latest.records.reduce(0) { $0 + ($1.counts?.total ?? 0) } == 20,
        "new token usage reaches the production snapshot while its rebuildable cache is pending")
    check(try Data(contentsOf: cache) == saved,
        "small token appends within twenty seconds do not rewrite the full statistics cache")
    let restarted = TokenUsageHistoryReader(home: home, cacheURL: cache)
    check(restarted.read(now: now.addingTimeInterval(40)).records == latest.records && restarted.bytesRead > 0,
        "an unflushed statistics cache recovers the exact missing tail after an abnormal exit")
    _ = reader.read(now: now.addingTimeInterval(150))
    check(try Data(contentsOf: cache) != saved,
        "pending statistics are persisted within the bounded two-minute write interval")
    check(reader.cacheWriteCount == 2, "several local reads coalesce to one pending statistics write")
    reader.flushCache(now: now.addingTimeInterval(151)); reader.flushCache(now: now.addingTimeInterval(152))
    check(reader.cacheWriteCount == 2, "flushing a clean statistics cache performs no encoding or write")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let analysis = reader.readAnalysis(now: now.addingTimeInterval(160), calendar: calendar)
    let builds = reader.analysisBuildCount, summaries = reader.summaryBuildCount
    _ = reader.readAnalysis(now: now.addingTimeInterval(180), calendar: calendar)
    check(reader.analysisBuildCount == builds && reader.summaryBuildCount == summaries,
        "unchanged production history refreshes reuse analysis and every historical day/window")
    let messages = try FileHandle(forWritingTo: file)
    try messages.seekToEnd(); try messages.write(contentsOf: row("response_item", ["type": "message", "content": "ordinary output"], now))
    try messages.close()
    _ = reader.readAnalysis(now: now.addingTimeInterval(181), calendar: calendar)
    check(reader.analysisBuildCount == builds && reader.summaryBuildCount == summaries,
        "new non-token rollout bytes do not rebuild identical history summaries")
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
    let nextDay = reader.readAnalysis(now: tomorrow, calendar: calendar)
    check(nextDay.days.last?.date == calendar.startOfDay(for: tomorrow) && reader.analysisBuildCount == builds + 1 &&
        reader.summaryBuildCount == summaries && nextDay.historicalDays.flatMap(\.records).count == analysis.historicalDays.flatMap(\.records).count,
        "crossing midnight refreshes the seven-day presentation while reusing all historical details")
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let changedZone = reader.readAnalysis(now: tomorrow, calendar: calendar)
    check(changedZone.days.last?.date == calendar.startOfDay(for: tomorrow) && reader.summaryBuildCount == summaries + 1,
        "a calendar/time-zone change invalidates historical window/day attribution")
    let rollback = reader.readAnalysis(now: now.addingTimeInterval(15), calendar: calendar)
    check(rollback.totalTimedTokens == 10 && rollback.snapshot.records.count == latest.records.count,
        "clock rollback hides future usage in analysis without dropping records from history")
    let future = reader.readAnalysis(now: now.addingTimeInterval(20), calendar: calendar)
    check(future.totalTimedTokens == 20 && future.now == now.addingTimeInterval(20),
        "an already-read future token event enters the analysis at its actual timestamp")
    try Data("{\"tokens\":{\"account_id\":\"account-b\"}}".utf8).write(to: home.appendingPathComponent("auth.json"))
    check(reader.readAnalysis(now: tomorrow, calendar: calendar).historicalDays.isEmpty,
        "a changed account cannot reuse the previous account's history summaries")
    let original = try String(contentsOf: file, encoding: .utf8)
    let rewritten = original.replacingOccurrences(of: "\"total_tokens\":20", with: "\"total_tokens\":30")
        .replacingOccurrences(of: "\"input_tokens\":20", with: "\"input_tokens\":30")
    check(original != rewritten && original.utf8.count == rewritten.utf8.count, "token rewrite fixture preserves its exact byte size")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let rewrite = try FileHandle(forWritingTo: file)
    try rewrite.truncate(atOffset: 0); try rewrite.write(contentsOf: Data(rewritten.utf8)); try rewrite.close()
    try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
    try Data("{\"tokens\":{\"account_id\":\"account-a\"}}".utf8).write(to: home.appendingPathComponent("auth.json"))
    check(reader.read(now: now.addingTimeInterval(200)).records.reduce(0) { $0 + ($1.counts?.total ?? 0) } == 30,
        "same-inode/size/mtime token-history rewrites invalidate persistent cursor facts through ctime")
}

private func checkCompressedTokenHistory(_ check: (Bool, String) -> Void, root: URL, now: Date, calendar: Calendar) throws {
    let home = root.appendingPathComponent("home")
    let sessions = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let auth = home.appendingPathComponent("auth.json")
    try Data("{\"tokens\":{\"account_id\":\"account-a\"}}".utf8).write(to: auth)
    let start = calendar.startOfDay(for: now)
    func line(_ type: String, _ payload: [String: Any], _ seconds: Double) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type,
            "timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)), "payload": payload])
        data.append(10); return data
    }
    func tokens(_ total: Int, last: Int, used: Double) -> [String: Any] {
        ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": total, "total_tokens": total],
            "last_token_usage": ["input_tokens": last, "total_tokens": last]],
         "rate_limits": ["limit_id": "codex", "plan_type": "plus",
            "primary": ["used_percent": used, "window_minutes": 300, "resets_at": start.addingTimeInterval(18000).timeIntervalSince1970]]]
    }
    func trace(_ id: String, total: Int, account: String? = nil) throws -> Data {
        var header = ["id": id]
        if let account { header["creator_account_id"] = account }
        var data = try line("session_meta", header, 0)
        data += try line("turn_context", ["turn_id": "one", "model": "gpt-6.1-sol", "service_tier": "standard"], 1)
        data += try line("event_msg", tokens(0, last: 0, used: 0), 2)
        data += try line("event_msg", tokens(total, last: total, used: 40), 3)
        return data
    }
    func total(_ snapshot: TokenUsageHistorySnapshot) -> Int { snapshot.records.reduce(0) { $0 + ($1.counts?.total ?? 0) } }
    let id = UUID().uuidString
    let plain = sessions.appendingPathComponent("rollout-\(id).jsonl")
    let zipped = plain.appendingPathExtension("zst")
    var data = try trace(id, total: 100)
    var oversized = tokens(900, last: 800, used: 99)
    oversized["unused"] = String(repeating: "x", count: 5 * 1024 * 1024)
    data += try line("event_msg", oversized, 3)
    try data.write(to: plain)
    var state: OpaquePointer?
    guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &state) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    defer { sqlite3_close(state) }
    guard sqlite3_exec(state, "CREATE TABLE threads(id TEXT, rollout_path TEXT, creator_account_id TEXT); INSERT INTO threads VALUES('\(id)', '\(plain.path)', 'account-a')", nil, nil, nil) == SQLITE_OK else {
        throw CodexConnectionError.invalidResponse
    }
    let cache = root.appendingPathComponent("cache.json")
    let reader = TokenUsageHistoryReader(home: home, cacheURL: cache)
    let baseline = reader.read(now: now)
    check(total(baseline) == 100 && baseline.unboundTokens == 0, "plain history uses the state database's reliable account binding")
    let legacy = TokenUsageHistoryReader(home: home, cacheURL: cache)
    check(legacy.read(now: now).records == baseline.records && legacy.bytesRead == 0, "existing plain history cache remains compatible")
    try compressedRolloutFixture(data).write(to: zipped)
    try FileManager.default.removeItem(at: plain)
    let cold = reader.read(now: now)
    check(cold.records == baseline.records && total(cold) == 100 && cold.unreadableFiles == 0 && cold.unboundTokens == 0,
        "plain-to-compressed history keeps tokens and a state binding that still names the plain path")
    let before = reader.bytesRead
    check(reader.read(now: now).records == baseline.records && reader.bytesRead == before,
        "unchanged compressed history is not decompressed again")
    reader.flushCache(now: now)
    let restored = TokenUsageHistoryReader(home: home, cacheURL: cache)
    check(restored.read(now: now).records == baseline.records && restored.bytesRead == 0,
        "a new reader reuses persistent compressed history without decompression")
    var oldCache = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
    var oldFiles = oldCache["files"] as! [String: [String: Any]]
    for path in oldFiles.keys { oldFiles[path]?.removeValue(forKey: "changedSeconds"); oldFiles[path]?.removeValue(forKey: "changedNanoseconds") }
    oldCache["files"] = oldFiles
    try JSONSerialization.data(withJSONObject: oldCache).write(to: cache)
    let migrated = TokenUsageHistoryReader(home: home, cacheURL: cache)
    check(migrated.read(now: now).records == baseline.records && migrated.bytesRead == 0,
        "an existing version-four cache without ctime retains warm compressed history without decompression")
    data += try line("event_msg", tokens(150, last: 50, used: 60), 4)
    try data.write(to: plain)
    let materialized = reader.read(now: now)
    check(total(materialized) == 150 && Set(materialized.records.map(\.id)).count == materialized.records.count && materialized.unreadableFiles == 0,
        "materialized plain history wins over the compressed sibling without double counting")
    let append = try line("event_msg", tokens(200, last: 50, used: 80), 5)
    let handle = try FileHandle(forWritingTo: plain)
    try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.close()
    data += append
    check(total(reader.read(now: now)) == 200, "materialized history resumes incremental accounting from its own cursor")
    try Data([0xff]).write(to: zipped)
    check(reader.read(now: now).unreadableFiles == 0, "a damaged compressed sibling cannot override valid plain history")
    try FileManager.default.removeItem(at: plain)
    let damaged = reader.read(now: now)
    check(damaged.unreadableFiles > 0 && TokenUsageHistoryAnalysis(snapshot: damaged, now: now, calendar: calendar).fiveHourEstimate.value == nil,
        "damaged compressed history reports incomplete reads and cannot authorize an allowance estimate")
    try compressedRolloutFixture(data).dropLast().write(to: zipped)
    check(reader.read(now: now).unreadableFiles > 0, "a truncated compressed history frame is reported as unreadable")
    try compressedRolloutFixture(data).write(to: zipped)
    let repaired = reader.read(now: now)
    check(total(repaired) == 200 && repaired.unreadableFiles == 0 && TokenUsageHistoryAnalysis(snapshot: repaired, now: now, calendar: calendar).fiveHourEstimate.value != nil,
        "a repaired compressed history recovers exact counts and eligible estimation")
    let archived = home.appendingPathComponent("archived_sessions")
    let auxiliary = root.appendingPathComponent("ping-home")
    let auxiliarySessions = auxiliary.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: auxiliarySessions, withIntermediateDirectories: true)
    try compressedRolloutFixture(trace("archived", total: 70, account: "account-a")).write(to: archived.appendingPathComponent("old.jsonl.zst"))
    try compressedRolloutFixture(trace("auxiliary", total: 30, account: "account-a")).write(to: auxiliarySessions.appendingPathComponent("ping.jsonl.zst"))
    let combinedReader = TokenUsageHistoryReader(home: home, additionalHomes: [auxiliary])
    let combined = combinedReader.read(now: now)
    check(total(combined) == 300 && combined.records.contains { $0.threadID == "archived" } &&
        combined.records.filter { $0.threadID == "auxiliary" }.allSatisfy(\.isAuxiliary),
        "compressed archived and additional-home histories retain tokens and auxiliary attribution")
    try Data("{\"tokens\":{\"account_id\":\"account-b\"}}".utf8).write(to: auth)
    let switched = combinedReader.read(now: now)
    check(switched.accountID == "account-b" && switched.records.isEmpty && switched.unboundTokens == 0,
        "compressed history and its cached state binding remain isolated when accounts change")
    try Data("{\"tokens\":{\"account_id\":\"account-a\"}}".utf8).write(to: auth)
    check(total(combinedReader.read(now: now)) == 300, "returning to the original account restores compressed history without duplication")
}

@MainActor func checkTokenHistoryObserverGeneration(_ check: (Bool, String) -> Void, root: URL) async throws {
    let home = root.appendingPathComponent("home"), support = root.appendingPathComponent("support")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let auth = home.appendingPathComponent("auth.json")
    try Data("{\"tokens\":{\"account_id\":\"account-a\"}}".utf8).write(to: auth)
    let observer = TokenUsageHistoryObserver(home: home, support: support)
    observer.start(); observer.stop()
    try Data("{\"tokens\":{\"account_id\":\"account-b\"}}".utf8).write(to: auth)
    var publication: AnyCancellable?
    var accounts: [String?] = []
    let completed: Bool = await withCheckedContinuation { continuation in
        var resumed = false
        func finish(_ value: Bool) {
            guard !resumed else { return }; resumed = true
            continuation.resume(returning: value)
        }
        publication = observer.$analysis.dropFirst().sink { value in
            accounts.append(value.snapshot.accountID)
            if value.snapshot.accountID == "account-b" { finish(true) }
        }
        observer.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false) }
    }
    publication?.cancel(); observer.stop()
    check(completed && accounts == ["account-b"],
        "stop/start during a history refresh rejects the old generation and publishes only the new account")
    try await checkHourlyTokenHistory(check, root: root.appendingPathComponent("hourly"))
}

@MainActor private func checkHourlyTokenHistory(_ check: (Bool, String) -> Void, root: URL) async throws {
    let home = root.appendingPathComponent("home"), support = root.appendingPathComponent("support")
    let sessions = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try Data("{\"tokens\":{\"account_id\":\"account-a\"}}".utf8).write(to: home.appendingPathComponent("auth.json"))
    let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
    let start = today.addingTimeInterval(10 * 3600)
    let old = calendar.date(byAdding: .day, value: -20, to: start)!
    let iso = ISO8601DateFormatter()
    func row(_ type: String, _ payload: [String: Any], at: Date) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload, "timestamp": iso.string(from: at)],
            options: .sortedKeys) + Data([10])
    }
    func tokens(_ total: Int, at: Date) throws -> Data {
        try row("event_msg", ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": total, "total_tokens": total],
            "last_token_usage": ["input_tokens": 100, "total_tokens": 100]]], at: at)
    }
    func trace(_ id: String, at: Date) throws -> Data {
        try row("session_meta", ["id": id, "creator_account_id": "account-a"], at: at) +
            row("turn_context", ["model": "gpt-6.1-sol", "service_tier": "standard"], at: at) +
            tokens(100, at: at.addingTimeInterval(2))
    }
    let current = sessions.appendingPathComponent("current.jsonl")
    try trace("current", at: start).write(to: current)
    try trace("past", at: old).write(to: sessions.appendingPathComponent("past.jsonl"))
    var clock = start.addingTimeInterval(60)
    let observer = TokenUsageHistoryObserver(home: home, support: support, now: { clock })
    defer { observer.stop() }
    func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
    observer.start()
    let initial = await waitFor { observer.analysis.todayTokens == 100 }
    let menu = observer.analysis
    check(initial && menu.days.count == 7 && menu.snapshot.records.isEmpty &&
        menu.days.flatMap(\.segments).allSatisfy { $0.records.isEmpty },
        "the production menu publishes seven days of totals without retaining usage records")
    let historical = await observer.page(ending: old)
    check(historical?.days.map(\.total) == [100] &&
        historical?.days.flatMap(\.records).map(\.threadID) == ["past"],
        "historical detail queries its own dated page from disk")

    let handle = try FileHandle(forWritingTo: current)
    try handle.seekToEnd(); try handle.write(contentsOf: tokens(200, at: clock.addingTimeInterval(1))); try handle.close()
    let firstRevision = observer.pageRevision
    clock = clock.addingTimeInterval(3599)
    observer.refreshIfDue()
    let pageBeforeHour = await observer.page(ending: today)
    check(observer.pageRevision == firstRevision && observer.analysis.todayTokens == 100 &&
        pageBeforeHour?.days.last?.total == 100, "opening details and checking the clock before an hour do not ingest new usage")
    clock = clock.addingTimeInterval(1)
    observer.refreshIfDue()
    let updated = await waitFor { observer.analysis.todayTokens == 200 }
    check(updated && observer.pageRevision > firstRevision && observer.analysis.snapshot.records.isEmpty,
        "the hourly batch publishes newly appended usage as a compact menu summary")
}
