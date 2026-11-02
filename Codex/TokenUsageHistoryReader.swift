import Foundation
import Combine
import CryptoKit
import SQLite3
import Darwin

/// A separate local ledger: never calls the provider, scheduler or a model.
final class TokenUsageHistoryReader: @unchecked Sendable {
    private struct Parser: Codable {
        var threadID = ""
        var accountID: String?
        var createdAt: Date?
        var inherited = false
        var isSubagent = false
        var ownEvidenceAt: Date?
        var requestStartedAt: Date?
        var toolStarts: [String: Date] = [:]
        var toolWaits: [DateInterval] = []
        var turnID: String?
        var model: String?
        var serviceTier: String?
        var configuredServiceTier: String?
        var cacheRetention: String?
        var total: TokenUsageCounts?
        var records: [TokenUsageRecord] = []
        var omittedBaselines = 0
        var malformed = false
        var sawHeader = false

        mutating func append(_ line: Data) {
            if !sawHeader {
                sawHeader = true
                guard let header = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      header["type"] as? String == "session_meta" else { malformed = true; return }
            }
            // Decode only boundary metadata, never the potentially large tool arguments or output.
            if line.range(of: Data("\"response_item\"".utf8)) != nil,
               ["function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output"].contains(where: {
                   line.range(of: Data(("\"" + $0 + "\"").utf8)) != nil
               }), let event = try? JSONDecoder().decode(ToolBoundary.self, from: line), event.type == "response_item",
               ["function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output"].contains(event.payload.type),
               ownEvidenceAt != nil {
                guard let at = UsageDecoder.timestamp(event.timestamp), let call = event.payload.call_id else {
                    requestStartedAt = nil; return
                }
                guard !inherited || createdAt.map({ at > $0 }) == true else { return }
                switch event.payload.type {
                case "function_call", "custom_tool_call": toolStarts[call] = at
                case "function_call_output", "custom_tool_call_output":
                    if let start = toolStarts.removeValue(forKey: call), at >= start {
                        toolWaits.append(DateInterval(start: start, end: at))
                    } else { requestStartedAt = nil }
                default: break
                }
                return
            }
            // Most rollout bytes are messages/tool output. Do not decode those large JSON objects.
            guard line.range(of: Data("\"session_meta\"".utf8)) != nil ||
                    line.range(of: Data("\"turn_context\"".utf8)) != nil ||
                    line.range(of: Data("\"token_count\"".utf8)) != nil ||
                    line.range(of: Data("\"task_started\"".utf8)) != nil ||
                    line.range(of: Data("\"task_complete\"".utf8)) != nil ||
                    line.range(of: Data("\"thread_settings_applied\"".utf8)) != nil ||
                    line.range(of: Data("\"turn_aborted\"".utf8)) != nil else { return }
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any] else { malformed = true; return }
            let at = UsageDecoder.timestamp(entry["timestamp"] as? String)
            if entry["type"] as? String == "session_meta" {
                guard threadID.isEmpty, let id = payload["id"] as? String, !id.isEmpty else { return }
                threadID = id
                accountID = payload["creator_account_id"] as? String
                createdAt = at ?? UsageDecoder.timestamp(payload["timestamp"] as? String)
                isSubagent = (payload["source"] as? [String: Any])?["subagent"] != nil
                inherited = ["forked_from_id", "history_base", "parent_thread_id"].contains { payload[$0] != nil && !(payload[$0] is NSNull) } || isSubagent
                return
            }
            guard !threadID.isEmpty else { return }
            if let explicit = (payload["thread_id"] ?? payload["threadId"]) as? String, explicit != threadID { return }
            if inherited, let at, let createdAt, at <= createdAt { return }
            let type = payload["type"] as? String
            if type == "thread_settings_applied", let settings = payload["thread_settings"] as? [String: Any] {
                configuredServiceTier = Self.tier(settings)
                serviceTier = configuredServiceTier
                return
            }
            if entry["type"] as? String == "turn_context" {
                guard let at, !inherited || createdAt.map({ at > $0 }) == true else { return }
                ownEvidenceAt = at
                requestStartedAt = at; toolStarts = [:]; toolWaits = []
                turnID = (payload["turn_id"] ?? payload["turnId"]) as? String
                // Missing context is unknown; never carry the last model across a context change.
                model = payload["model"] as? String
                serviceTier = Self.tier(payload) ?? configuredServiceTier
                cacheRetention = (payload["prompt_cache_retention"] ?? payload["cache_retention"]) as? String
                return
            }
            if type == "task_started" {
                if let at, !inherited || createdAt.map({ at > $0 }) == true {
                    ownEvidenceAt = at
                    requestStartedAt = at; toolStarts = [:]; toolWaits = []
                    let nextTurn = (payload["turn_id"] ?? payload["turnId"]) as? String
                    if nextTurn != turnID { model = nil; serviceTier = configuredServiceTier; cacheRetention = nil }
                    turnID = nextTurn
                }
                return
            }
            if type == "task_complete" || type == "turn_aborted" {
                ownEvidenceAt = nil; requestStartedAt = nil; toolStarts = [:]; toolWaits = []; return
            }
            guard type == "token_count" else { return }
            if inherited && ownEvidenceAt == nil { return }
            let info = payload["info"] as? [String: Any]
            let cumulative = Self.counts(info?["total_token_usage"] as? [String: Any])
            let last = Self.counts(info?["last_token_usage"] as? [String: Any])
            let limits = payload["rate_limits"] as? [String: Any]
            let isCodex = limits.map {
                let id = ($0["limit_id"] ?? $0["limitId"]) as? String
                return id == nil || id == "codex"
            } ?? false
            let quotas = isCodex ? UsageDecoder.windows(limits!) : (nil, nil)
            let plan = isCodex ? (limits?["plan_type"] as? String)?.lowercased() : nil
            let evidence = ownEvidenceAt.map { evidence in at.map { $0 >= evidence } ?? true } ?? false
            var increment: TokenUsageCounts?
            var unknown: TokenUsageCounts?
            if let cumulative {
                if let previous = total {
                    if cumulative.total > previous.total {
                        if let delta = cumulative.subtracting(previous) {
                            if let last, last.total > 0, delta == last { increment = delta }
                            else if let last, evidence, let gap = delta.subtracting(last), last.total > 0 {
                                increment = last; if gap.total > 0 { unknown = gap }
                            } else { unknown = delta }
                        } else {
                            // A breakdown correction cannot establish input/output deltas.
                            unknown = TokenUsageCounts(input: 0, cachedInput: 0, cacheWriteInput: 0, output: 0,
                                reasoningOutput: 0, total: cumulative.total - previous.total)
                        }
                    } else if cumulative.total < previous.total, evidence, let last, last.total > 0, cumulative.subtracting(last) != nil {
                        // The counter was reset; last is the new request, not a negative delta.
                        increment = last
                        if let gap = cumulative.subtracting(last), gap.total > 0 { unknown = gap }
                    }
                } else if evidence, let last, last.total > 0, cumulative.subtracting(last) != nil {
                    increment = last
                    if cumulative != last { omittedBaselines += 1 }
                } else if cumulative.total > 0 { omittedBaselines += 1 }
                // Equal total snapshots can correct cached/reasoning metadata, but add no usage.
                total = cumulative
            }
            let digest = SHA256.hash(data: line).prefix(12).map { String(format: "%02x", $0) }.joined()
            let id = threadID + ":" + digest
            // An event timestamp is the only time authority; filesystem modification time is never substituted.
            let eventModel = (payload["model"] as? String) ?? model
            var samplingSeconds: Double?
            if let increment, increment.total > 0 {
                if increment == last, evidence, let start = requestStartedAt, let at, at > start, toolStarts.isEmpty {
                    var coveredUntil = start, waiting = 0.0
                    for interval in toolWaits.sorted(by: { $0.start < $1.start }) {
                        let from = max(start, coveredUntil, interval.start), to = min(at, interval.end)
                        if to > from { waiting += to.timeIntervalSince(from); coveredUntil = to }
                    }
                    let elapsed = at.timeIntervalSince(start) - waiting
                    if elapsed > 0, increment.output > 0 { samplingSeconds = elapsed }
                }
                requestStartedAt = evidence ? at : nil; toolWaits = []
            }
            records.append(TokenUsageRecord(id: id, threadID: threadID, accountID: accountID,
                timestamp: at, model: evidence ? eventModel : nil, counts: increment,
                requestInput: increment == last ? last?.input : nil, serviceTier: serviceTier,
                cacheRetention: cacheRetention, samplingSeconds: samplingSeconds,
                fiveHour: quotas.0, weekly: quotas.1, planType: plan))
            if let unknown {
                records.append(TokenUsageRecord(id: id + ":gap", threadID: threadID, accountID: accountID,
                    timestamp: nil, model: nil, counts: unknown, requestInput: nil,
                    fiveHour: nil, weekly: nil, planType: nil))
            }
        }

        private struct ToolBoundary: Decodable {
            struct Payload: Decodable { var type: String; var call_id: String? }
            var type: String
            var timestamp: String?
            var payload: Payload
        }

        private static func tier(_ object: [String: Any]) -> String? {
            guard let value = object["service_tier"] ?? object["serviceTier"] else { return nil }
            return value is NSNull ? "standard" : value as? String
        }

        private static func counts(_ object: [String: Any]?) -> TokenUsageCounts? {
            guard let object, let total = (object["total_tokens"] as? NSNumber)?.intValue, total >= 0 else { return nil }
            func n(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
            let value = TokenUsageCounts(input: n("input_tokens"), cachedInput: n("cached_input_tokens"),
                cacheWriteInput: n("cache_write_input_tokens"), output: n("output_tokens"),
                reasoningOutput: n("reasoning_output_tokens"), total: total)
            guard [value.input, value.cachedInput, value.cacheWriteInput, value.output, value.reasoningOutput].allSatisfy({ $0 >= 0 }) else { return nil }
            return value
        }
    }

    private struct Cursor: Codable {
        var inode: UInt64
        var offset: UInt64 = 0
        var modified: Date
        var pending = Data()
        var anchor = Data()
        var prefixHash = Data()
        var prefixLength = 0
        var discarding = false
        var compressedSize: UInt64?
        var parser = Parser()

        mutating func append(_ data: Data) {
            offset += UInt64(data.count); pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                if !discarding { parser.append(Data(pending.prefix(upTo: end))) }
                pending.removeSubrange(...end); discarding = false
            }
            if pending.count > 4 * 1024 * 1024 {
                // A single oversized message is not a token event. Bound memory while discarding its rest.
                pending.removeAll(); discarding = true
            }
        }
    }
    private struct Cache: Codable {
        var version = 3
        var roots: [String]
        var files: [String: Cursor]
    }
    private struct Binding { var thread: String; var account: String? }
    private let home: URL
    private let homes: [URL]
    private let cacheURL: URL?
    private var cursors: [String: Cursor] = [:]
    private var loadedCache = false
    private(set) var bytesRead: UInt64 = 0

    init(home: URL, cacheURL: URL? = nil, additionalHomes: [URL] = []) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.homes = ([home] + additionalHomes).map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.cacheURL = cacheURL
    }

    func read(now: Date = Date()) -> TokenUsageHistorySnapshot {
        if !loadedCache {
            loadedCache = true
            if let cacheURL, let data = try? Data(contentsOf: cacheURL),
               let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 3,
               cache.roots == homes.map(\.path) { cursors = cache.files }
        }
        let identity = try? AppServerUsageProvider.authenticationIdentity(home: home)
        let account = try? AppServerUsageProvider.authenticationAccountID(home: home)
        var result = TokenUsageHistorySnapshot(accountID: account, capturedAt: now, isLoaded: true)
        var files = Set<String>()
        var bindings: [String: Binding] = [:]
        var changed = false
        for root in homes {
            do { bindings.merge(try Self.bindings(root)) { _, _ in Binding(thread: "", account: nil) } }
            catch { result.unreadableFiles += 1 }
            for folder in ["sessions", "archived_sessions"] {
                let directory = root.appendingPathComponent(folder)
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                guard let enumerator = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in result.unreadableFiles += 1; return true }) else {
                    result.unreadableFiles += 1; continue
                }
                for case let url as URL in enumerator where url.pathExtension == "jsonl" || (url.pathExtension == "zst" && url.deletingPathExtension().pathExtension == "jsonl") {
                    guard RolloutFile.resolvedURL(url) == url else { continue }
                    let path = RolloutFile.logicalURL(url).path
                    files.insert(path)
                    do { changed = try readFile(url, path: path) || changed }
                    catch { result.unreadableFiles += 1 }
                }
            }
        }
        // Removed/replaced files are not a second source of the same rollout. Moves are parsed once at the new path.
        if cursors.keys.contains(where: { !files.contains($0) }) { cursors = cursors.filter { files.contains($0.key) }; changed = true }
        var seen = Set<String>()
        for path in files.sorted() {
            guard let cursor = cursors[path] else { continue }
            let parser = cursor.parser
            if parser.malformed || parser.threadID.isEmpty { result.unreadableFiles += 1 }
            result.omittedBaselines += parser.omittedBaselines
            let binding = bindings[path]
            let owner: String?
            if let binding, binding.thread != parser.threadID ||
                (parser.accountID != nil && binding.account != parser.accountID) { owner = nil }
            else { owner = parser.accountID ?? binding?.account }
            for var record in parser.records where seen.insert(record.id).inserted {
                record.accountID = owner
                record.isAuxiliary = parser.isSubagent || homes.dropFirst().contains { path.hasPrefix($0.path + "/") }
                if let owner, owner == account { result.records.append(record) }
                else if owner == nil, let counts = record.counts, counts.total > 0 {
                    result.unboundTokens += counts.total
                    result.unboundRecords.append(record)
                }
            }
        }
        result.records.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        result.currentPlan = result.records.last(where: {
            $0.planType != nil && $0.timestamp.map { $0 <= now && now.timeIntervalSince($0) <= 86400 } == true
        })?.planType
        // Account changes during a scan invalidate the presentation, without changing any user file.
        if (try? AppServerUsageProvider.authenticationIdentity(home: home)) != identity ||
            (try? AppServerUsageProvider.authenticationAccountID(home: home)) != account {
            result = TokenUsageHistorySnapshot(accountID: nil, capturedAt: now, isLoaded: true)
        }
        if changed, let cacheURL {
            let cache = Cache(roots: homes.map(\.path), files: cursors)
            if let data = try? JSONEncoder().encode(cache) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
        return result
    }

    private func readFile(_ url: URL, path: String) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let compressed = url.pathExtension == "zst"
        if let cursor = cursors[path], cursor.inode == inode, cursor.modified == modified,
           (cursor.compressedSize != nil) == compressed, (cursor.compressedSize ?? cursor.offset) == size { return false }
        if compressed {
            let data = try RolloutFile.read(url)
            var cursor = Cursor(inode: inode, modified: modified)
            cursor.compressedSize = size
            for offset in stride(from: 0, to: data.count, by: 64 * 1024) {
                autoreleasepool { cursor.append(data.subdata(in: offset..<min(offset + 64 * 1024, data.count))) }
            }
            bytesRead += UInt64(data.count)
            cursors[path] = cursor
            return true
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var cursor = cursors[path] ?? Cursor(inode: inode, modified: modified)
        var replaced = cursor.compressedSize != nil || cursor.inode != inode || size < cursor.offset
        if !replaced, cursor.prefixLength > 0 {
            let prefix = try handle.read(upToCount: cursor.prefixLength) ?? Data()
            replaced = Data(SHA256.hash(data: prefix)) != cursor.prefixHash
        }
        if !replaced, !cursor.anchor.isEmpty {
            try handle.seek(toOffset: cursor.offset - UInt64(cursor.anchor.count))
            replaced = try handle.read(upToCount: cursor.anchor.count) != cursor.anchor
        }
        if replaced { cursor = Cursor(inode: inode, modified: modified) }
        try handle.seek(toOffset: cursor.offset)
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            bytesRead += UInt64(data.count); cursor.append(data)
        }
        cursor.modified = modified
        cursor.prefixLength = Int(min(4096, cursor.offset))
        try handle.seek(toOffset: 0)
        cursor.prefixHash = Data(SHA256.hash(data: try handle.read(upToCount: cursor.prefixLength) ?? Data()))
        try handle.seek(toOffset: cursor.offset - min(64, cursor.offset))
        cursor.anchor = try handle.read(upToCount: Int(min(64, cursor.offset))) ?? Data()
        cursors[path] = cursor
        return true
    }

    private static func bindings(_ home: URL) throws -> [String: Binding] {
        let files = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        func modified(_ url: URL) -> Date {
            [url, URL(fileURLWithPath: url.path + "-wal")].compactMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
            }.max() ?? .distantPast
        }
        guard let database = files.filter({ $0.lastPathComponent.range(of: #"^state(?:_[0-9]+)?\.sqlite$"#, options: .regularExpression) != nil })
            .sorted(by: { modified($0) == modified($1) ? $0.path > $1.path : modified($0) > modified($1) }).first else { return [:] }
        let reader = try ReadOnlyDatabase(url: database, kind: "state")
        let statement = try reader.prepare("SELECT rollout_path, creator_account_id, id FROM threads")
        defer { sqlite3_finalize(statement) }
        var result: [String: Binding] = [:]
        while try reader.step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let id = sqlite3_column_text(statement, 2) else { continue }
            let path = RolloutFile.logicalURL(URL(fileURLWithPath: String(cString: raw))).path
            let account = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let binding = Binding(thread: String(cString: id), account: account)
            if let previous = result[path], previous.thread != binding.thread || previous.account != binding.account {
                result[path] = Binding(thread: "", account: nil)
            } else { result[path] = binding }
        }
        return result
    }
}

@MainActor final class TokenUsageHistoryObserver: ObservableObject {
    @Published private(set) var analysis = TokenUsageHistoryAnalysis(snapshot: TokenUsageHistorySnapshot(accountID: nil))
    var snapshot: TokenUsageHistorySnapshot { analysis.snapshot }
    private let queue = DispatchQueue(label: "keeper.token-history", qos: .utility)
    private let reader: TokenUsageHistoryReader
    private var timer: Timer?
    private var refreshing = false
    private var active = false
    private var generation = 0

    init(home: URL, support: URL, initial: TokenUsageHistoryAnalysis? = nil) {
        if let initial { analysis = initial }
        reader = TokenUsageHistoryReader(home: home, cacheURL: support.appendingPathComponent("token-usage-cache-v1.json"),
            additionalHomes: [support.appendingPathComponent("ping/home")])
    }
    func start() {
        guard !active else { return }; active = true
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { active = false; generation += 1; timer?.invalidate(); timer = nil }
    func refresh() {
        guard active, !refreshing else { return }; refreshing = true
        let generation = self.generation
        queue.async { [weak self, reader] in
            let result = reader.read()
            let analysis = TokenUsageHistoryAnalysis(snapshot: result)
            Task { @MainActor [weak self] in
                guard let self else { return }; self.refreshing = false
                guard self.active else { return }
                if self.generation != generation { self.refresh(); return }
                self.analysis = analysis
            }
        }
    }
}
