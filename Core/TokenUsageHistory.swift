import Foundation

/// Cached input and reasoning output are subsets, never additional tokens.
struct TokenUsageCounts: Codable, Equatable {
    var input: Int
    var cachedInput: Int
    var cacheWriteInput: Int
    var output: Int
    var reasoningOutput: Int
    var total: Int

    static let zero = TokenUsageCounts(input: 0, cachedInput: 0, cacheWriteInput: 0, output: 0, reasoningOutput: 0, total: 0)
    var hasCompleteBreakdown: Bool {
        input >= 0 && output >= 0 && cachedInput >= 0 && cacheWriteInput >= 0 && reasoningOutput >= 0 &&
            cachedInput + cacheWriteInput <= input && reasoningOutput <= output && total == input + output
    }
    static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cachedInput: lhs.cachedInput + rhs.cachedInput,
            cacheWriteInput: lhs.cacheWriteInput + rhs.cacheWriteInput, output: lhs.output + rhs.output,
            reasoningOutput: lhs.reasoningOutput + rhs.reasoningOutput, total: lhs.total + rhs.total)
    }
    func subtracting(_ old: Self) -> Self? {
        let result = Self(input: input - old.input, cachedInput: cachedInput - old.cachedInput,
            cacheWriteInput: cacheWriteInput - old.cacheWriteInput, output: output - old.output,
            reasoningOutput: reasoningOutput - old.reasoningOutput, total: total - old.total)
        return [result.input, result.cachedInput, result.cacheWriteInput, result.output, result.reasoningOutput, result.total]
            .allSatisfy { $0 >= 0 } ? result : nil
    }
}

enum TokenUsagePrices {
    static let version = "2026-10-30"
    static let source = URL(string: "https://developers.openai.com/api/docs/pricing")!
    // USD per million tokens, standard processing. Historical usage uses this price version.
    private static let prices: [String: (Double, Double, Double)] = [
        "gpt-6-astra": (10, 1, 50), "gpt-6.1-sol": (2, 0.1, 10),
        "gpt-6.1-terra": (1, 0.05, 5), "gpt-6-luna": (0.1, 0.01, 0.5),
        "gpt-6-sol": (2, 0.2, 10), "gpt-5.6-sol": (4, 0.4, 20),
        "gpt-5.6-terra": (2, 0.2, 12), "gpt-5.6-luna": (0.2, 0.02, 1.2),
        "gpt-5.5": (5, 0.5, 30), "gpt-5.4": (2.5, 0.25, 15),
        "gpt-5.3-codex": (1.75, 0.175, 14)
    ]

    static func normalizedServiceTier(_ value: String?) -> String? {
        switch value?.lowercased() {
        case "default", "standard": return "standard"
        case "priority", "fast": return "fast"
        case "flex": return "flex"
        case "ultrafast": return "ultrafast"
        default: return nil
        }
    }

    static func cost(_ counts: TokenUsageCounts, model: String?, requestInput: Int?, serviceTier: String? = nil,
                     cacheRetention: String? = nil) -> Double? {
        guard counts.hasCompleteBreakdown, let model, let price = prices[model] else { return nil }
        // An aggregate delta cannot establish the long-context tier of its constituent requests.
        guard requestInput != nil || counts.input <= 272_000 else { return nil }
        let long = (requestInput ?? counts.input) > 272_000
        let supportsLong = model.hasPrefix("gpt-6") || model.hasPrefix("gpt-5.6") || ["gpt-5.5", "gpt-5.4"].contains(model)
        let inputMultiplier = long && supportsLong ? 2.0 : 1.0
        let outputMultiplier = long && supportsLong ? 1.5 : 1.0
        var speed = 1.0
        switch normalizedServiceTier(serviceTier) ?? (serviceTier == nil ? "standard" : "unknown") {
        case "standard": break
        case "fast":
            if model.hasPrefix("gpt-6") || model.hasPrefix("gpt-5.6") { speed = 2 }
            else if model == "gpt-5.5", !long { speed = 2.5 }
            else if model == "gpt-5.4", !long { speed = 2 }
            else { return nil }
        case "flex":
            guard model.hasPrefix("gpt-6") || model.hasPrefix("gpt-5.6") ||
                ["gpt-5.5", "gpt-5.4"].contains(model) else { return nil }; speed = 0.5
        case "ultrafast":
            guard model == "gpt-6-astra" || model == "gpt-6.1-sol" else { return nil }; speed = 6
        default: return nil
        }
        var writeMultiplier = 1.0
        if counts.cacheWriteInput > 0 {
            guard model.hasPrefix("gpt-6") || model.hasPrefix("gpt-5.6") else { return nil }
            switch cacheRetention {
            case "30m": writeMultiplier = 1.25
            case "12h": writeMultiplier = 2.5
            default: return nil
            }
        }
        return (Double(counts.input - counts.cachedInput - counts.cacheWriteInput) * price.0 * inputMultiplier +
            Double(counts.cachedInput) * price.1 * inputMultiplier +
            Double(counts.cacheWriteInput) * price.0 * inputMultiplier * writeMultiplier +
            Double(counts.output) * price.2 * outputMultiplier) * speed / 1_000_000
    }
}

struct TokenUsageCalibrationGroup: Equatable {
    var model: String
    var serviceTier: String
}

struct TokenUsageRecord: Codable, Equatable, Identifiable {
    var id: String
    var threadID: String
    var accountID: String?
    var timestamp: Date?
    // Cumulative usage already existed by this snapshot; this is not its exact usage time.
    var usageUpperBound: Date? = nil
    var model: String?
    var counts: TokenUsageCounts?
    var requestInput: Int?
    var serviceTier: String? = nil
    var cacheRetention: String? = nil
    var samplingSeconds: Double? = nil
    var isAuxiliary = false
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    var planType: String?

    var cost: Double? {
        counts.flatMap { TokenUsagePrices.cost($0, model: model, requestInput: requestInput,
            serviceTier: serviceTier, cacheRetention: cacheRetention) }
    }
    var calibrationGroup: TokenUsageCalibrationGroup? {
        guard let model, let tier = TokenUsagePrices.normalizedServiceTier(serviceTier) else { return nil }
        return TokenUsageCalibrationGroup(model: model, serviceTier: tier)
    }
}

struct TokenUsageSpeed {
    var outputTokens = 0
    var seconds = 0.0
    var value: Double? { seconds > 0 ? Double(outputTokens) / seconds : nil }

    init(_ records: [TokenUsageRecord]) {
        for record in records {
            guard let counts = record.counts, counts.hasCompleteBreakdown, counts.output > 0,
                  let elapsed = record.samplingSeconds, elapsed.isFinite, elapsed > 0 else { continue }
            outputTokens += counts.output; seconds += elapsed
        }
    }
}

struct TokenUsageHistorySnapshot: Equatable {
    var accountID: String?
    var records: [TokenUsageRecord] = []
    var unboundTokens = 0
    var unboundRecords: [TokenUsageRecord] = []
    var unreadableFiles = 0
    var omittedBaselines = 0
    var currentPlan: String?
    var capturedAt = Date()
    var isLoaded = false
}

enum TokenUsageWindowKind: String, Codable { case fiveHour, weekly }

struct TokenUsageWindow: Identifiable {
    var id: String
    var kind: TokenUsageWindowKind
    var start: Date
    var reset: Date
    var observations: [TokenUsageRecord]
    var observedPercent: Double = 0
    var earlyReset = false
    var complete = true
    var colorIndex = 0
}

struct TokenUsageSegment: Identifiable {
    var id: String { windowID ?? "unknown" }
    var windowID: String?
    var start: Date?
    var reset: Date?
    var total: Int
    var windowPercent: Double?
    var records: [TokenUsageRecord]
    var colorIndex: Int = -1
}

struct TokenUsageDay: Identifiable {
    var id: Date { date }
    var date: Date
    var segments: [TokenUsageSegment]
    var total: Int { segments.reduce(0) { $0 + $1.total } }
    var hasRecords: Bool { !segments.isEmpty }
    var records: [TokenUsageRecord] { segments.flatMap(\.records) }
}

struct TokenUsageEstimate {
    var value: Double?
    var previousValue: Double?
    var tokens: Int?
    var sampleCount = 0
    var previousSampleCount = 0
    var reason: String = "有效样本不足"
    var change: Double? {
        guard let value, let previousValue, previousValue > 0 else { return nil }
        return (value / previousValue - 1) * 100
    }
}

struct TokenUsageHistoryAnalysis {
    var snapshot: TokenUsageHistorySnapshot
    var now: Date
    let calendar: Calendar
    let periodStart: Date
    let previousStart: Date
    var previousEnd: Date
    let windows: [TokenUsageWindow]
    let days: [TokenUsageDay]
    let historicalDays: [TokenUsageDay]
    let fiveHourEstimate: TokenUsageEstimate
    let weeklyEstimate: TokenUsageEstimate
    let calibrationGroup: TokenUsageCalibrationGroup?
    let unknownTimeTokens: Int
    let unknownWindowTokens: Int
    let pricedTokens: Int
    let totalTimedTokens: Int

    fileprivate struct Summaries {
        var windows: [TokenUsageWindow]
        var days: [Date: TokenUsageDay]
        var historicalDays: [TokenUsageDay]
        var totals: [Date: Int]
        var priced: [Date: Int]
        var unknownWindow: [Date: Int]
        var unknownTimeTokens: Int
        var calibrationGroup: TokenUsageCalibrationGroup?
    }

    init(snapshot: TokenUsageHistorySnapshot, now: Date = Date(), calendar: Calendar = .current,
         calibrationGroup: TokenUsageCalibrationGroup? = nil) {
        let valid = snapshot.records.filter { $0.timestamp.map { $0 <= now } ?? false }
            .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp! < $1.timestamp! }
        var summaries = Self.summarize(snapshot: snapshot, valid: valid, calendar: calendar)
        if let calibrationGroup { summaries.calibrationGroup = calibrationGroup }
        self.init(snapshot: snapshot, summaries: summaries, now: now, calendar: calendar)
    }

    fileprivate init(snapshot: TokenUsageHistorySnapshot, summaries: Summaries, now: Date, calendar: Calendar) {
        self.snapshot = snapshot; self.now = now; self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        let periodStart = calendar.date(byAdding: .day, value: -6, to: today)!
        let previousStart = calendar.date(byAdding: .day, value: -7, to: periodStart)!
        let previousEnd = calendar.date(byAdding: .day, value: -7, to: now)!
        self.periodStart = periodStart; self.previousStart = previousStart; self.previousEnd = previousEnd
        let windows = summaries.windows, calibrationGroup = summaries.calibrationGroup
        self.windows = windows; historicalDays = summaries.historicalDays
        self.calibrationGroup = calibrationGroup
        days = (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: periodStart)!
            return summaries.days[date] ?? TokenUsageDay(date: date, segments: [])
        }
        unknownTimeTokens = summaries.unknownTimeTokens
        unknownWindowTokens = summaries.unknownWindow.reduce(0) { $0 + ($1.key >= periodStart ? $1.value : 0) }
        totalTimedTokens = summaries.totals.reduce(0) { $0 + ($1.key >= periodStart ? $1.value : 0) }
        pricedTokens = summaries.priced.reduce(0) { $0 + ($1.key >= periodStart ? $1.value : 0) }
        fiveHourEstimate = Self.estimate(windows: windows, kind: .fiveHour, snapshot: snapshot, group: calibrationGroup,
            start: periodStart, end: now, previousStart: previousStart, previousEnd: previousEnd, calendar: calendar)
        weeklyEstimate = Self.estimate(windows: windows, kind: .weekly, snapshot: snapshot, group: calibrationGroup,
            start: periodStart, end: now, previousStart: previousStart, previousEnd: previousEnd, calendar: calendar)
    }

    fileprivate static func summarize(snapshot: TokenUsageHistorySnapshot, valid: [TokenUsageRecord],
                                      calendar: Calendar, includeWeekly: Bool = true) -> Summaries {
        var windows = makeWindows(valid, kind: .fiveHour, calendar: calendar)
        if includeWeekly { windows += makeWindows(valid, kind: .weekly, calendar: calendar) }
        // Store window indices, not a value copy of a window for every observation.
        var byRecord: [String: Int] = [:]
        for index in windows.indices where windows[index].kind == .fiveHour {
            for record in windows[index].observations where byRecord[record.id] == nil { byRecord[record.id] = index }
        }
        var daily: [Date: [String: [TokenUsageRecord]]] = [:]
        var totals: [Date: Int] = [:], priced: [Date: Int] = [:], unknownWindow: [Date: Int] = [:]
        for record in valid {
            let window = byRecord[record.id].map { windows[$0] }
            let date = calendar.startOfDay(for: window?.start ?? record.timestamp!)
            let total = record.counts?.total ?? 0
            totals[date, default: 0] += total
            if record.cost != nil { priced[date, default: 0] += total }
            if window == nil { unknownWindow[date, default: 0] += total }
            if total > 0 { daily[date, default: [:]][window?.id ?? "unknown", default: []].append(record) }
        }
        var summaries: [Date: TokenUsageDay] = [:]
        for (date, groups) in daily { summaries[date] = day(date, groups: groups, windows: windows, byRecord: byRecord) }
        return Summaries(windows: windows, days: summaries,
            historicalDays: summaries.keys.sorted(by: >).map { summaries[$0]! }, totals: totals, priced: priced,
            unknownWindow: unknownWindow,
            unknownTimeTokens: snapshot.records.reduce(0) { $0 + ($1.timestamp == nil ? ($1.counts?.total ?? 0) : 0) },
            calibrationGroup: valid.last(where: {
                !$0.isAuxiliary && $0.accountID == snapshot.accountID && ($0.counts?.total ?? 0) > 0
            })?.calibrationGroup)
    }

    var todayTokens: Int? { days.last.flatMap { $0.hasRecords ? $0.total : nil } }
    var todaySpeed: TokenUsageSpeed { TokenUsageSpeed(days.last?.records ?? []) }
    private static func day(_ date: Date, groups: [String: [TokenUsageRecord]], windows: [TokenUsageWindow], byRecord: [String: Int]) -> TokenUsageDay {
        let segments = groups.map { id, records in
            let window = records.first.flatMap { byRecord[$0.id] }.map { windows[$0] }
            return TokenUsageSegment(windowID: id == "unknown" ? nil : id, start: window?.start, reset: window?.reset,
                total: records.reduce(0) { $0 + ($1.counts?.total ?? 0) },
                windowPercent: window?.observedPercent, records: records, colorIndex: window?.colorIndex ?? -1)
        }.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        return TokenUsageDay(date: date, segments: segments)
    }

    private static func makeWindows(_ records: [TokenUsageRecord], kind: TokenUsageWindowKind, calendar: Calendar) -> [TokenUsageWindow] {
        var result: [TokenUsageWindow] = []
        var highWater: Double = 0
        var includedPositive: [Int] = []
        var positivePrefix = [0]
        positivePrefix.reserveCapacity(records.count + 1)
        for record in records { positivePrefix.append(positivePrefix.last! + ((record.counts?.total ?? 0) > 0 ? 1 : 0)) }
        for record in records {
            guard let at = record.timestamp, let quota = kind == .fiveHour ? record.fiveHour : record.weekly,
                  quota.usedPercent >= 0, quota.usedPercent <= 100, quota.resetsAt > at,
                  quota.resetsAt.timeIntervalSince(at) <= Double(quota.windowMinutes * 60) + 180 else { continue }
            // Copy only the scalar reset. Copying the last window here shares its growing
            // observations array and forces a full copy on every append.
            let previousReset = result.last?.reset
            let drift = previousReset.map { abs($0.timeIntervalSince(quota.resetsAt)) } ?? .infinity
            let decreased = quota.usedPercent < highWater
            let continues = previousReset.map { drift <= 180 && at < $0.addingTimeInterval(180) } ?? false
            if continues {
                let index = result.count - 1
                result[index].observations.append(record)
                result[index].observedPercent += max(0, quota.usedPercent - highWater)
                includedPositive[index] += (record.counts?.total ?? 0) > 0 ? 1 : 0
                highWater = max(highWater, quota.usedPercent)
            } else {
                if let previousReset, highWater > 0, at < previousReset.addingTimeInterval(-180), !decreased {
                    result[result.count - 1].complete = false
                    continue
                }
                let start = min(at, quota.resetsAt.addingTimeInterval(-Double(quota.windowMinutes * 60)))
                let id = kind.rawValue + ":" + String(Int64(quota.resetsAt.timeIntervalSince1970)) + ":" + record.id
                result.append(TokenUsageWindow(id: id, kind: kind, start: start, reset: quota.resetsAt,
                    observations: [record], earlyReset: decreased && previousReset.map { at < $0.addingTimeInterval(-180) } == true))
                includedPositive.append((record.counts?.total ?? 0) > 0 ? 1 : 0)
                highWater = quota.usedPercent
            }
        }
        func boundary(_ date: Date, inclusive: Bool) -> Int {
            var low = 0, high = records.count
            while low < high {
                let middle = (low + high) / 2
                if records[middle].timestamp! < date || (inclusive && records[middle].timestamp! == date) { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        for index in result.indices {
            let first = result[index].observations.first!.timestamp!, last = result[index].observations.last!.timestamp!
            // Include timestamp ties on both edges, matching the original completeness rule.
            let positive = positivePrefix[boundary(last, inclusive: true)] - positivePrefix[boundary(first, inclusive: false)]
            if positive != includedPositive[index] { result[index].complete = false }
        }
        result = result.filter { window in window.observations.contains {
            ((kind == .fiveHour ? $0.fiveHour : $0.weekly)?.usedPercent ?? 0) > 0 || ($0.counts?.total ?? 0) > 0
        } }
        var usedByDay: [Date: Set<Int>] = [:]
        for index in result.indices {
            let dates = Set(result[index].observations.compactMap(\.timestamp).map { calendar.startOfDay(for: $0) })
            let used = dates.reduce(into: Set<Int>()) { $0.formUnion(usedByDay[$1] ?? []) }
            var color = TokenUsageFormat.colorIndex(result[index].id)
            for offset in 0..<8 where !used.contains((color + offset) % 8) { color = (color + offset) % 8; break }
            result[index].colorIndex = color
            for date in dates { usedByDay[date, default: []].insert(color) }
        }
        return result
    }

    private static func estimate(windows: [TokenUsageWindow], kind: TokenUsageWindowKind,
                                 snapshot: TokenUsageHistorySnapshot, group: TokenUsageCalibrationGroup?, start: Date, end: Date,
                                 previousStart: Date, previousEnd: Date, calendar: Calendar) -> TokenUsageEstimate {
        guard snapshot.accountID != nil else { return TokenUsageEstimate(reason: "尚未确认当前账户") }
        guard snapshot.currentPlan == "plus" else { return TokenUsageEstimate(reason: "尚未确认 Plus 套餐") }
        guard let group else { return TokenUsageEstimate(reason: "当前模型或速度档位未知") }
        guard snapshot.unreadableFiles == 0 else { return TokenUsageEstimate(reason: "部分本机记录无法读取") }
        guard snapshot.unboundTokens == 0 || !snapshot.unboundRecords.isEmpty else {
            return TokenUsageEstimate(reason: "部分记录账户未知")
        }
        func mayAffect(_ record: TokenUsageRecord, first: Date, last: Date) -> Bool {
            guard (record.counts?.total ?? 0) > 0 else { return false }
            if let at = record.timestamp { return at >= first && at <= last }
            // Only a snapshot strictly before the baseline can rule out overlap.
            return record.usageUpperBound.map { $0 >= first } ?? true
        }
        func sample(_ start: Date, _ end: Date) -> (value: Double?, tokens: Int?, count: Int, reason: String) {
            var cost = 0.0, tokens = 0.0, percent = 0.0, samples = 0
            var unknownAccount = false, unknownTime = false, unpriced = false, incomplete = false
            for window in windows where window.kind == kind {
                let observations: [TokenUsageRecord]
                if kind == .fiveHour {
                    let day = calendar.startOfDay(for: window.start)
                    guard day >= calendar.startOfDay(for: start), day <= calendar.startOfDay(for: end) else { continue }
                    observations = window.observations.filter { $0.timestamp! <= end }
                } else {
                    observations = window.observations.filter { $0.timestamp! >= start && $0.timestamp! <= end }
                }
                // The service may omit the plan on individual usage events. Require
                // positive Plus evidence for this window and reject conflicting plans.
                let plans = observations.compactMap(\.planType)
                guard observations.count >= 2, !plans.isEmpty,
                      plans.allSatisfy({ $0 == "plus" }),
                      observations.allSatisfy({ $0.accountID == snapshot.accountID }) else { continue }
                let first = observations.first!.timestamp!, lastAt = observations.last!.timestamp!
                if snapshot.unboundRecords.contains(where: { mayAffect($0, first: first, last: lastAt) }) {
                    unknownAccount = true; continue
                }
                if snapshot.records.contains(where: { $0.timestamp == nil && mayAffect($0, first: first, last: lastAt) }) {
                    unknownTime = true; continue
                }
                guard window.complete else { incomplete = true; continue }
                var pending = 0.0, pairedCost = 0.0, pendingTokens = 0.0, pairedTokens = 0.0, consumed = 0.0
                var pendingMatches = true
                var complete = true
                var last = kind == .fiveHour ? observations[0].fiveHour!.usedPercent : observations[0].weekly!.usedPercent
                // The first observation is a baseline, not a claim that all earlier quota use is local.
                for record in observations.dropFirst() {
                    if let tokens = record.counts, tokens.total > 0 {
                        if let price = record.cost { pending += price; pendingTokens += Double(tokens.total) }
                        else { complete = false; unpriced = true }
                        if record.calibrationGroup != group { pendingMatches = false }
                    }
                    let used = kind == .fiveHour ? record.fiveHour!.usedPercent : record.weekly!.usedPercent
                    let delta = max(0, used - last)
                    if delta > 0 {
                        if pending <= 0 { complete = false }
                        // An account-wide quota step has no per-model attribution. Use it
                        // only when every paired request belongs to the selected cohort.
                        if pendingMatches {
                            pairedCost += pending; pairedTokens += pendingTokens; consumed += delta
                        }
                        pending = 0; pendingTokens = 0; pendingMatches = true
                    }
                    last = max(last, used)
                }
                guard complete, consumed > 25, pairedCost > 0 else { continue }
                cost += pairedCost; tokens += pairedTokens; percent += consumed; samples += 1
            }
            let reason = unknownAccount ? "部分记录账户未知" : unknownTime ? "部分 Token 时间未知" :
                unpriced ? "部分 Token 未完整定价" : incomplete ? "窗口记录不完整" : "有效样本不足"
            return (percent > 0 ? cost / (percent / 100) : nil,
                percent > 0 ? Int((tokens / (percent / 100)).rounded()) : nil, samples, reason)
        }
        let current = sample(start, end), previous = sample(previousStart, previousEnd)
        return TokenUsageEstimate(value: current.value, previousValue: previous.value, tokens: current.tokens,
            sampleCount: current.count, previousSampleCount: previous.count, reason: current.value == nil ? current.reason : "")
    }
}


/// The only usage data retained by the menu. Chart segments carry totals, not records.
struct TokenUsageMenuSummary {
    let snapshot: TokenUsageHistorySnapshot
    let now: Date
    let calendar: Calendar
    let days: [TokenUsageDay]
    let todayTokens: Int?
    let todaySpeed: TokenUsageSpeed
    let fiveHourEstimate: TokenUsageEstimate
    let weeklyEstimate: TokenUsageEstimate
    let calibrationGroup: TokenUsageCalibrationGroup?
    let unknownTimeTokens: Int
    let pricedTokens: Int
    let totalTimedTokens: Int

    init(_ analysis: TokenUsageHistoryAnalysis, unboundTokens: Int? = nil) {
        var status = analysis.snapshot
        status.records = []
        status.unboundRecords = []
        if let unboundTokens { status.unboundTokens = unboundTokens }
        snapshot = status
        now = analysis.now; calendar = analysis.calendar
        days = analysis.days.map { day in
            TokenUsageDay(date: day.date, segments: day.segments.map { segment in
                var segment = segment
                segment.records = []
                return segment
            })
        }
        todayTokens = analysis.todayTokens; todaySpeed = analysis.todaySpeed
        fiveHourEstimate = analysis.fiveHourEstimate; weeklyEstimate = analysis.weeklyEstimate
        calibrationGroup = analysis.calibrationGroup; unknownTimeTokens = analysis.unknownTimeTokens
        pricedTokens = analysis.pricedTokens; totalTimedTokens = analysis.totalTimedTokens
    }
}

struct TokenUsageHistoryPage {
    var days: [TokenUsageDay]
    var untimed: [TokenUsageRecord]

    init(days: [TokenUsageDay] = [], untimed: [TokenUsageRecord] = []) {
        self.days = days; self.untimed = untimed
    }

    init(snapshot: TokenUsageHistorySnapshot, start: Date, end: Date, calendar: Calendar) {
        let visible = snapshot.records.filter { $0.timestamp != nil }
        let summaries = TokenUsageHistoryAnalysis.summarize(snapshot: snapshot, valid: visible, calendar: calendar,
            includeWeekly: false)
        days = summaries.historicalDays.filter { $0.date >= start && $0.date <= end }
        untimed = snapshot.records.filter { $0.timestamp == nil }
    }
}

/// Reuses all historical windows/days until their actual records, visibility or calendar change.
final class TokenUsageHistoryAnalysisCache {
    private var recordRevision: UInt64?
    private var sorted: [TokenUsageRecord] = []
    private var summaryCalendar: Calendar?
    private var summaryAccount: String?
    private var visibleCount = -1
    private var summaries: TokenUsageHistoryAnalysis.Summaries?
    private var snapshotRevision: UInt64?
    private var previousCount = -1
    private var cached: TokenUsageHistoryAnalysis?
    private(set) var analysisBuildCount = 0
    private(set) var summaryBuildCount = 0

    func analysis(snapshot: TokenUsageHistorySnapshot, revision: UInt64, recordsRevision: UInt64,
                  now: Date, calendar: Calendar) -> TokenUsageHistoryAnalysis {
        let recordsChanged = recordRevision != recordsRevision
        if recordsChanged {
            sorted = snapshot.records.filter { $0.timestamp != nil }
                .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp! < $1.timestamp! }
            recordRevision = recordsRevision
        }
        func count(through date: Date) -> Int {
            var low = 0, high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if sorted[middle].timestamp! <= date { low = middle + 1 } else { high = middle }
            }
            return low
        }
        let visible = count(through: now)
        let previousEnd = calendar.date(byAdding: .day, value: -7, to: now)!
        let previous = count(through: previousEnd)
        let summaryChanged = recordsChanged || summaries == nil || summaryCalendar != calendar ||
            summaryAccount != snapshot.accountID || visibleCount != visible
        if summaryChanged {
            summaries = TokenUsageHistoryAnalysis.summarize(snapshot: snapshot, valid: Array(sorted.prefix(visible)), calendar: calendar)
            summaryCalendar = calendar; summaryAccount = snapshot.accountID; visibleCount = visible
            summaryBuildCount += 1
        }
        if !summaryChanged, snapshotRevision == revision, previousCount == previous, var cached,
           calendar.startOfDay(for: cached.now) == calendar.startOfDay(for: now) {
            cached.snapshot = snapshot; cached.now = now; cached.previousEnd = previousEnd
            self.cached = cached
            return cached
        }
        let result = TokenUsageHistoryAnalysis(snapshot: snapshot, summaries: summaries!, now: now, calendar: calendar)
        cached = result; snapshotRevision = revision; previousCount = previous; analysisBuildCount += 1
        return result
    }
}

enum TokenUsageFormat {
    static func compact(_ value: Int) -> String { compact(value, fractionDigits: 1) }
    static func compact(_ value: Int, fractionDigits: Int) -> String {
        guard value >= 1_000 else { return String(format: "%.*f", fractionDigits, Double(value)) }
        let units = ["K", "M", "B"]
        var number = Double(value) / 1_000, unit = 0
        let scale = pow(10, Double(fractionDigits))
        while unit < 2 && (number * scale).rounded() >= 1_000 * scale {
            number /= 1_000; unit += 1
        }
        return String(format: "%.*f%@", fractionDigits, number, units[unit])
    }
    static func tps(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
    static func dollars(_ value: Double?) -> String {
        value.map { String(format: "$%.1f", $0) } ?? L10n.text("暂无估算")
    }
    static func change(_ value: Double?) -> String {
        guard let value else { return "—" }
        return (value >= 0 ? "↑" : "↓") + String(format: "%.1f%%", abs(value))
    }
    static func range(_ start: Date?, _ end: Date?, relativeTo day: Date? = nil, calendar: Calendar = .current) -> String {
        guard let start, let end else { return L10n.text("窗口未知") }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = day == nil ? "M/d HH:mm" : "HH:mm"
        let first = f.string(from: start)
        if calendar.isDate(start, inSameDayAs: end) { f.dateFormat = "HH:mm" }
        else if day != nil { f.dateFormat = "HH:mm"; return first + " – " + L10n.format("次日 %@", f.string(from: end)) }
        return first + " – " + f.string(from: end)
    }
    static func colorIndex(_ id: String?) -> Int {
        guard let id else { return -1 }
        // FNV-1a is stable across process launches, unlike Swift's randomized Hasher.
        let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Int(hash % 8)
    }
}
