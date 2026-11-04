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
                    timestamp: nil, usageUpperBound: at, model: nil, counts: unknown, requestInput: nil,
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
        var changedSeconds: Int?
        var changedNanoseconds: Int?
        var parser = Parser()

        var stamp: TokenUsageHistoryStore.Stamp {
            TokenUsageHistoryStore.Stamp(inode: inode, size: compressedSize ?? offset, modified: modified,
                changedSeconds: changedSeconds, changedNanoseconds: changedNanoseconds, compressed: compressedSize != nil)
        }

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
        var version = 4
        var roots: [String]
        var files: [String: Cursor]
    }
    private struct Binding: Equatable { var thread: String; var account: String? }
    private let home: URL
    private let homes: [URL]
    private let cacheURL: URL?
    private let databaseURL: URL?
    private var store: TokenUsageHistoryStore?
    private var databaseState: TokenUsageHistoryDatabaseState?
    private var cursors: [String: Cursor] = [:]
    private var loadedCache = false
    private(set) var bytesRead: UInt64 = 0
    private(set) var cacheWriteCount = 0
    private(set) var snapshotRevision: UInt64 = 0
    private var recordsRevision: UInt64 = 0
    private let analysisCache = TokenUsageHistoryAnalysisCache()
    var analysisBuildCount: Int { analysisCache.analysisBuildCount }
    var summaryBuildCount: Int { analysisCache.summaryBuildCount }
    private var cacheDirty = false
    private var lastCacheWrite: Date?
    private var cachedSnapshot: TokenUsageHistorySnapshot?
    private var cachedBindings: [String: Binding] = [:]
    private var cachedFailures = -1
    private var cachedIdentity: Data?
    private var stableSnapshot = false
    private var plans: [(at: Date, value: String)] = []

    init(home: URL, cacheURL: URL? = nil, additionalHomes: [URL] = [], databaseURL: URL? = nil) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.homes = ([home] + additionalHomes).map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.cacheURL = cacheURL
        self.databaseURL = databaseURL
    }

    func read(now: Date = Date(), persistCache: Bool = true) -> TokenUsageHistorySnapshot {
        if !loadedCache {
            loadedCache = true
            if let cacheURL, let data = try? Data(contentsOf: cacheURL),
               let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 4,
               cache.roots == homes.map(\.path) { cursors = cache.files; lastCacheWrite = now }
        }
        let identity = try? AppServerUsageProvider.authenticationIdentity(home: home)
        let account = try? AppServerUsageProvider.authenticationAccountID(home: home)
        var result = TokenUsageHistorySnapshot(accountID: account, capturedAt: now, isLoaded: true)
        let sources = Self.sources(homes)
        let bindings = sources.bindings
        let files = Set(sources.rollouts.map(\.path))
        result.unreadableFiles = sources.failures
        var changed = false
        for (path, url) in sources.rollouts {
            do {
                if let stamp = try Self.fileStamp(url), let cursor = try readFile(url, stamp: stamp, previous: cursors[path]) {
                    cursors[path] = cursor
                    changed = true
                }
            } catch {
                result.unreadableFiles += 1
            }
        }
        // Removed/replaced files are not a second source of the same rollout. Moves are parsed once at the new path.
        if cursors.keys.contains(where: { !files.contains($0) }) { cursors = cursors.filter { files.contains($0.key) }; changed = true }
        let failures = result.unreadableFiles
        let canReuse = !changed && stableSnapshot && cachedSnapshot?.accountID == account &&
            cachedIdentity == identity && cachedBindings == bindings && cachedFailures == failures
        if canReuse, let saved = cachedSnapshot {
            result = saved; result.capturedAt = now
        } else {
            var seen = Set<String>()
            for path in files.sorted() {
                guard let cursor = cursors[path] else { continue }
                let parser = cursor.parser
                if parser.malformed || parser.threadID.isEmpty { result.unreadableFiles += 1 }
                result.omittedBaselines += parser.omittedBaselines
                let owner = Self.owner(thread: parser.threadID, creator: parser.accountID, binding: bindings[path])
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
            plans = result.records.compactMap { record in
                guard let at = record.timestamp, let plan = record.planType else { return nil }
                return (at, plan)
            }
        }
        result.currentPlan = plans.last(where: { $0.at <= now && now.timeIntervalSince($0.at) <= 86400 })?.value
        // Account changes during a scan invalidate the presentation, without changing any user file.
        stableSnapshot = (try? AppServerUsageProvider.authenticationIdentity(home: home)) == identity &&
            (try? AppServerUsageProvider.authenticationAccountID(home: home)) == account
        if !stableSnapshot { result = TokenUsageHistorySnapshot(accountID: nil, capturedAt: now, isLoaded: true) }
        if (!canReuse || !stableSnapshot) && cachedSnapshot?.records != result.records { recordsRevision += 1 }
        var comparable = result
        if let saved = cachedSnapshot { comparable.capturedAt = saved.capturedAt }
        if comparable != cachedSnapshot { snapshotRevision += 1 }
        cachedSnapshot = result; cachedBindings = bindings; cachedFailures = failures; cachedIdentity = identity
        cacheDirty = cacheDirty || changed
        if persistCache { flushCacheIfNeeded(now: now) }

        return result
    }

    func readAnalysis(now: Date = Date(), calendar: Calendar = .current, persistCache: Bool = true) -> TokenUsageHistoryAnalysis {
        let snapshot = read(now: now, persistCache: persistCache)
        return analysisCache.analysis(snapshot: snapshot, revision: snapshotRevision, recordsRevision: recordsRevision, now: now, calendar: calendar)
    }

    func synchronizeDatabase(now: Date, isCancelled: () -> Bool = { false }) throws -> TokenUsageHistoryDatabaseState {
        func checkCancellation() throws { if isCancelled() { throw CancellationError() } }
        try checkCancellation()
        let store = try database()
        let identity = try? AppServerUsageProvider.authenticationIdentity(home: home)
        let account = try? AppServerUsageProvider.authenticationAccountID(home: home)
        let roots = homes.map(\.path)
        let encodedRoots = try JSONEncoder().encode(roots)
        let state = try store.transaction {
            let saved = try store.metadata()
            var changed = saved?.roots != encodedRoots
            if changed {
                if saved != nil { try store.clearFiles() }
                try importLegacyCache(store, roots: roots, checkCancellation: checkCancellation)
            }
            let sources = Self.sources(homes)
            var failures = sources.failures
            var files = try store.files()
            var missing = Set(files.keys)
            for (path, url) in sources.rollouts {
                try checkCancellation()
                missing.remove(path)
                let previous = files[path]
                let binding = sources.bindings[path]
                do {
                    if let stamp = try Self.fileStamp(url), stamp != previous?.stamp {
                        let (updated, recordsChanged) = try updateDatabaseFile(store, path: path, url: url, stamp: stamp,
                            previous: previous, binding: binding, checkCancellation: checkCancellation)
                        files[path] = updated
                        changed = changed || recordsChanged
                        continue
                    }
                } catch let error as TokenUsageHistoryStore.Failure {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures += 1
                }
                if var previous {
                    let owner = Self.owner(thread: previous.thread, creator: previous.creator, binding: binding)
                    if previous.owner != owner {
                        try store.rebindFile(path, owner: owner)
                        previous.owner = owner; files[path] = previous
                        changed = true
                    }
                }
            }
            for path in missing { try store.deleteFile(path); changed = true }
            try checkCancellation()
            changed = changed || saved?.scanFailures != failures
            let storeRevision = (saved?.revision ?? 0) + (changed ? 1 : 0)
            if changed {
                try store.saveMetadata(.init(roots: encodedRoots, revision: storeRevision, scanFailures: failures))
            }
            let initiallyStable = authenticationMatches(identity: identity, account: account)
            let diagnostics = initiallyStable ? try store.diagnostics() : (unreadable: 0, omitted: 0)
            let unboundTokens: Int
            if !initiallyStable { unboundTokens = 0 }
            else if let databaseState, databaseState.stable, databaseState.storeRevision == storeRevision {
                unboundTokens = databaseState.unboundTokens
            } else { unboundTokens = try store.unboundTokens() }
            let plan = try store.currentPlan(account: initiallyStable ? account : nil, now: now)
            let calibrationGroup = try store.calibrationGroup(account: initiallyStable ? account : nil, now: now)
            let stable = initiallyStable && authenticationMatches(identity: identity, account: account)
            let verifiedAccount = stable ? account : nil
            let revisionChanged = databaseState?.storeRevision != storeRevision || databaseState?.accountID != verifiedAccount ||
                databaseState?.identity != identity || databaseState?.stable != stable
            try checkCancellation()
            return TokenUsageHistoryDatabaseState(accountID: verifiedAccount, capturedAt: now,
                revision: (databaseState?.revision ?? 0) + (revisionChanged ? 1 : 0),
                unreadableFiles: stable ? failures + diagnostics.unreadable : 0, omittedBaselines: stable ? diagnostics.omitted : 0,
                unboundTokens: stable ? unboundTokens : 0, currentPlan: stable ? plan : nil, calibrationGroup: stable ? calibrationGroup : nil,
                storeRevision: storeRevision, identity: identity, stable: stable)
        }
        databaseState = state
        return state
    }

    func readDatabaseSnapshot(state: TokenUsageHistoryDatabaseState, from: Date?, through: Date) throws -> TokenUsageHistorySnapshot {
        guard state.stable else {
            return TokenUsageHistorySnapshot(accountID: nil, capturedAt: state.capturedAt, isLoaded: true)
        }
        return try withDatabaseState(state) { try $0.snapshot(state: state, from: from, through: through) }
    }

    func databaseWindowCrossing(state: TokenUsageHistoryDatabaseState, before: Date, includeWeekly: Bool) throws -> Date? {
        guard let account = state.accountID else { return nil }
        return try withDatabaseState(state) { try $0.windowCrossing(account: account, before: before, includeWeekly: includeWeekly) }
    }

    func databaseHasRecords(state: TokenUsageHistoryDatabaseState, after: Date, through: Date) throws -> Bool {
        guard let account = state.accountID, after < through else { return false }
        return try withDatabaseState(state) { try $0.hasRecords(account: account, after: after, through: through) }
    }

    private func database() throws -> TokenUsageHistoryStore {
        if let store { return store }
        guard let databaseURL, databaseURL != cacheURL else { throw TokenUsageHistoryStore.Failure.invalidData }
        let opened = try TokenUsageHistoryStore(url: databaseURL)
        store = opened
        return opened
    }

    private func authenticationMatches(identity: Data?, account: String?) -> Bool {
        (try? AppServerUsageProvider.authenticationIdentity(home: home)) == identity &&
            (try? AppServerUsageProvider.authenticationAccountID(home: home)) == account
    }

    private func withDatabaseState<T>(_ state: TokenUsageHistoryDatabaseState,
                                      _ query: (TokenUsageHistoryStore) throws -> T) throws -> T {
        let store = try database()
        return try store.transaction(write: false) {
            guard try store.metadata()?.revision == state.storeRevision,
                  try AppServerUsageProvider.authenticationAccountID(home: home) == state.accountID else {
                throw TokenUsageHistoryStore.Failure.stale
            }
            let value = try query(store)
            guard try AppServerUsageProvider.authenticationAccountID(home: home) == state.accountID else {
                throw TokenUsageHistoryStore.Failure.stale
            }
            return value
        }
    }

    private func updateDatabaseFile(_ store: TokenUsageHistoryStore, path: String, url: URL, stamp: TokenUsageHistoryStore.Stamp,
                                    previous: TokenUsageHistoryStore.File?, binding: Binding?,
                                    checkCancellation: () throws -> Void) throws -> (TokenUsageHistoryStore.File, Bool) {
        try store.withFile {
            let saved = try previous.map { _ in try store.cursor(for: path, as: Cursor.self) }
            if saved == nil {
                let placeholder = Cursor(inode: stamp.inode, modified: stamp.modified)
                try store.saveFile(databaseFile(placeholder, path: path, binding: binding), path: path, cursor: placeholder)
            }
            var recordsChanged = false
            let updated = try readFile(url, stamp: stamp, previous: saved, replaceRecords: {
                recordsChanged = try store.deleteRecords(for: path) || recordsChanged
            }, appendRecords: { records in
                recordsChanged = try store.append(records, path: path) || recordsChanged
            }, checkCancellation: checkCancellation)
            guard let updated else { throw TokenUsageHistoryStore.Failure.invalidData }
            let file = databaseFile(updated, path: path, binding: binding)
            try store.saveFile(file, path: path, cursor: updated)
            let changed = recordsChanged || file.owner != previous?.owner || file.auxiliary != (previous?.auxiliary ?? false) ||
                file.unreadable != (previous?.unreadable ?? false) || file.omittedBaselines != (previous?.omittedBaselines ?? 0)
            return (file, changed)
        }
    }

    private func databaseFile(_ cursor: Cursor, path: String, binding: Binding?) -> TokenUsageHistoryStore.File {
        let parser = cursor.parser
        return TokenUsageHistoryStore.File(stamp: cursor.stamp, thread: parser.threadID, creator: parser.accountID,
            owner: Self.owner(thread: parser.threadID, creator: parser.accountID, binding: binding),
            auxiliary: parser.isSubagent || homes.dropFirst().contains { path.hasPrefix($0.path + "/") },
            unreadable: parser.malformed || parser.threadID.isEmpty, omittedBaselines: parser.omittedBaselines)
    }

    private func importLegacyCache(_ store: TokenUsageHistoryStore, roots: [String], checkCancellation: () throws -> Void) throws {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe) else { return }
        let decoder = JSONDecoder()
        do {
            try store.withFile {
                var json = LegacyCacheJSON(data: data)
                var version: Int?, savedRoots: [String]?, sawFiles = false
                try json.object { key, json in
                    try checkCancellation()
                    switch key {
                    case "version":
                        version = try decoder.decode(Int.self, from: json.value())
                    case "roots":
                        savedRoots = try decoder.decode([String].self, from: json.value())
                    case "files":
                        sawFiles = true
                        try json.object { path, json in
                            try checkCancellation()
                            let encoded = try json.value()
                            // Very large individual cursors are rebuilt with the bounded rollout reader.
                            guard encoded.count <= 8 * 1024 * 1024 else { return }
                            try autoreleasepool {
                                var cursor = try decoder.decode(Cursor.self, from: encoded)
                                let records = cursor.parser.records
                                cursor.parser.records = []
                                try store.saveFile(databaseFile(cursor, path: path, binding: nil), path: path, cursor: cursor)
                                _ = try store.append(records, path: path)
                            }
                        }
                    default: _ = try json.value()
                    }
                }
                guard json.finished, sawFiles, version == 4, savedRoots == roots else { throw LegacyCacheJSON.Invalid() }
            }
        } catch is LegacyCacheJSON.Invalid {
            // Invalid or incompatible legacy cache: the caller rebuilds from rollout files.
        } catch is DecodingError {
            // Do not let a partially decoded legacy cache become an authoritative cursor.
        }
    }

    /// Locate values in the legacy JSON envelope without decoding the entire file.
    /// Each cursor is still validated by the standard decoder before it can be used.
    private struct LegacyCacheJSON {
        struct Invalid: Error {}
        let data: Data
        private var offset = 0
        private var byte: UInt8? { offset < data.count ? data[offset] : nil }

        init(data: Data) { self.data = data }

        var finished: Bool {
            mutating get { skipWhitespace(); return offset == data.count }
        }

        private mutating func skipWhitespace() {
            while let byte, byte == 32 || byte == 9 || byte == 10 || byte == 13 { offset += 1 }
        }

        private mutating func consume(_ expected: UInt8) throws {
            skipWhitespace()
            guard byte == expected else { throw Invalid() }
            offset += 1
        }

        private mutating func string() throws -> Data {
            let start = offset
            try consume(34)
            while let byte {
                offset += 1
                if byte == 34 { return data[start..<offset] }
                if byte == 92 {
                    guard self.byte != nil else { throw Invalid() }
                    offset += 1
                }
            }
            throw Invalid()
        }

        mutating func object(_ visit: (String, inout Self) throws -> Void) throws {
            try consume(123)
            skipWhitespace()
            if byte == 125 { offset += 1; return }
            let decoder = JSONDecoder()
            while true {
                skipWhitespace()
                let key = try decoder.decode(String.self, from: string())
                try consume(58)
                try visit(key, &self)
                skipWhitespace()
                if byte == 125 { offset += 1; return }
                try consume(44)
            }
        }

        mutating func value() throws -> Data {
            skipWhitespace()
            let start = offset
            switch byte {
            case 34:
                return try string()
            case 123, 91:
                var depth = 0
                while let byte {
                    if byte == 34 { _ = try string(); continue }
                    if byte == 123 || byte == 91 { depth += 1 }
                    if byte == 125 || byte == 93 { depth -= 1 }
                    offset += 1
                    if depth == 0 { return data[start..<offset] }
                }
                throw Invalid()
            default:
                while let byte, byte != 44, byte != 125, byte != 93, byte != 32, byte != 9, byte != 10, byte != 13 {
                    offset += 1
                }
                guard offset > start else { throw Invalid() }
                return data[start..<offset]
            }
        }
    }

    /// Only the rebuildable statistics cache is delayed; runtime/attempt ledgers do not use this policy.
    func flushCacheIfNeeded(now: Date = Date()) {
        if lastCacheWrite.map({ now < $0 || now.timeIntervalSince($0) >= 120 }) ?? true { flushCache(now: now) }
    }

    func flushCache(now: Date = Date()) {
        guard cacheDirty, let cacheURL else { return }
        do {
            let cache = Cache(roots: homes.map(\.path), files: cursors)
            let data = try JSONEncoder().encode(cache)
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            cacheDirty = false; lastCacheWrite = now; cacheWriteCount += 1
        } catch { } // A failed cache write leaves the dirty state for the next bounded retry.
    }

    private static func fileStamp(_ url: URL) throws -> TokenUsageHistoryStore.Stamp? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let compressed = url.pathExtension == "zst"
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return TokenUsageHistoryStore.Stamp(inode: inode, size: size, modified: modified,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec, compressed: compressed)
    }

    private func readFile(_ url: URL, stamp: TokenUsageHistoryStore.Stamp, previous: Cursor?,
                          replaceRecords: (() throws -> Void)? = nil,
                          appendRecords: (([TokenUsageRecord]) throws -> Void)? = nil,
                          checkCancellation: () throws -> Void = {}) throws -> Cursor? {
        if previous?.stamp == stamp { return nil }
        let inode = stamp.inode, size = stamp.size, modified = stamp.modified
        let changedSeconds = stamp.changedSeconds, changedNanoseconds = stamp.changedNanoseconds
        if let cursor = previous, cursor.inode == inode, cursor.modified == modified,
           (cursor.compressedSize != nil) == stamp.compressed, (cursor.compressedSize ?? cursor.offset) == size {
            if cursor.changedSeconds == nil && cursor.changedNanoseconds == nil {
                // Current-schema caches can predate ctime tracking. Keep their warm-load
                // guarantees while adding the stronger stamp for subsequent changes.
                var migrated = cursor
                migrated.changedSeconds = changedSeconds; migrated.changedNanoseconds = changedNanoseconds
                return migrated
            }
        }
        func receive(_ data: Data, cursor: inout Cursor) throws {
            try checkCancellation()
            try autoreleasepool {
                cursor.append(data)
                if let appendRecords, !cursor.parser.records.isEmpty {
                    try appendRecords(cursor.parser.records)
                    cursor.parser.records.removeAll(keepingCapacity: true)
                }
            }
        }
        if stamp.compressed {
            try replaceRecords?()
            var cursor = Cursor(inode: inode, modified: modified)
            cursor.compressedSize = size
            cursor.changedSeconds = changedSeconds; cursor.changedNanoseconds = changedNanoseconds
            var decodedBytes: UInt64 = 0
            try RolloutFile.forEachChunk(url) { data in
                try receive(data, cursor: &cursor)
                decodedBytes += UInt64(data.count)
            }
            bytesRead += decodedBytes
            return cursor
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var cursor = previous ?? Cursor(inode: inode, modified: modified)
        var replaced = cursor.compressedSize != nil || cursor.inode != inode || size < cursor.offset ||
            (size == cursor.offset && cursor.changedSeconds != nil &&
                (cursor.changedSeconds != changedSeconds || cursor.changedNanoseconds != changedNanoseconds))
        if !replaced, cursor.prefixLength > 0 {
            let prefix = try handle.read(upToCount: cursor.prefixLength) ?? Data()
            replaced = Data(SHA256.hash(data: prefix)) != cursor.prefixHash
        }
        if !replaced, !cursor.anchor.isEmpty {
            try handle.seek(toOffset: cursor.offset - UInt64(cursor.anchor.count))
            replaced = try handle.read(upToCount: cursor.anchor.count) != cursor.anchor
        }
        if replaced {
            try replaceRecords?()
            cursor = Cursor(inode: inode, modified: modified)
        }
        try handle.seek(toOffset: cursor.offset)
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            bytesRead += UInt64(data.count)
            try receive(data, cursor: &cursor)
        }
        cursor.modified = modified
        cursor.changedSeconds = changedSeconds; cursor.changedNanoseconds = changedNanoseconds
        cursor.prefixLength = Int(min(4096, cursor.offset))
        try handle.seek(toOffset: 0)
        cursor.prefixHash = Data(SHA256.hash(data: try handle.read(upToCount: cursor.prefixLength) ?? Data()))
        try handle.seek(toOffset: cursor.offset - min(64, cursor.offset))
        cursor.anchor = try handle.read(upToCount: Int(min(64, cursor.offset))) ?? Data()
        return cursor
    }

    private static func sources(_ homes: [URL]) -> (rollouts: [(path: String, url: URL)], bindings: [String: Binding], failures: Int) {
        var rollouts: [(String, URL)] = []
        var bindings: [String: Binding] = [:]
        var failures = 0
        for root in homes {
            do { bindings.merge(try Self.bindings(root)) { _, _ in Binding(thread: "", account: nil) } }
            catch { failures += 1 }
            for folder in ["sessions", "archived_sessions"] {
                let directory = root.appendingPathComponent(folder)
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                guard let enumerator = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in failures += 1; return true }) else {
                    failures += 1; continue
                }
                for case let url as URL in enumerator where url.pathExtension == "jsonl" || (url.pathExtension == "zst" && url.deletingPathExtension().pathExtension == "jsonl") {
                    guard RolloutFile.resolvedURL(url) == url else { continue }
                    rollouts.append((RolloutFile.logicalURL(url).path, url))
                }
            }
        }
        return (rollouts, bindings, failures)
    }

    private static func owner(thread: String, creator: String?, binding: Binding?) -> String? {
        if let binding, binding.thread != thread || (creator != nil && binding.account != creator) { return nil }
        return creator ?? binding?.account
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
    @Published private(set) var analysis: TokenUsageMenuSummary
    private(set) var pageRevision: UInt64 = 0
    private let queue = DispatchQueue(label: "keeper.token-history", qos: .utility)
    private let pageQueue = DispatchQueue(label: "keeper.token-history.page", qos: .userInitiated)
    private let reader: TokenUsageHistoryReader
    private let pageReader: TokenUsageHistoryReader
    private let now: () -> Date
    private let preview: TokenUsageHistoryAnalysis?
    private var state: TokenUsageHistoryDatabaseState?
    private var timer: Timer?
    private var nextRefreshAt: Date?
    private var refreshing = false
    private var active = false
    private var observedAccount: String?
    private var hasObservedAccount = false
    private var generation = 0

    init(home: URL, support: URL, initial: TokenUsageHistoryAnalysis? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now; preview = initial
        analysis = TokenUsageMenuSummary(initial ?? TokenUsageHistoryAnalysis(snapshot: TokenUsageHistorySnapshot(accountID: nil)))
        let cache = support.appendingPathComponent("token-usage-cache-v1.json")
        let database = support.appendingPathComponent("token-usage.sqlite3")
        let additional = [support.appendingPathComponent("ping/home")]
        reader = TokenUsageHistoryReader(home: home, cacheURL: cache, additionalHomes: additional, databaseURL: database)
        pageReader = TokenUsageHistoryReader(home: home, additionalHomes: additional, databaseURL: database)
    }

    func start() {
        guard !active else { return }
        active = true
        refresh()
    }

    func stop() {
        active = false; generation += 1
        timer?.invalidate(); timer = nil; nextRefreshAt = nil
        if state != nil { clearPublished() }
    }

    func refreshIfDue() {
        guard active else { return }
        let date = now()
        let clockChanged = state.map { date < $0.capturedAt } ?? false
        if clockChanged || analysis.calendar.timeZone != Calendar.current.timeZone ||
            nextRefreshAt.map({ date >= $0 }) == true { refresh() }
    }

    func authenticationDidChange(to accountID: String?) {
        let changed = hasObservedAccount ? observedAccount != accountID :
            state.map { $0.accountID != accountID } ?? false
        observedAccount = accountID; hasObservedAccount = true
        guard active, changed else { return }
        generation += 1
        clearPublished()
        refresh()
    }

    private func clearPublished() {
        state = nil; pageRevision += 1
        analysis = TokenUsageMenuSummary(TokenUsageHistoryAnalysis(snapshot: TokenUsageHistorySnapshot(accountID: nil), now: now()))
    }

    private func refresh() {
        guard active, !refreshing else { return }
        refreshing = true
        let date = now(), calendar = Calendar.current, previous = state
        let priorCalendar = analysis.calendar, generation = self.generation
        let deadline = date.addingTimeInterval(3600)
        nextRefreshAt = deadline
        timer?.invalidate()
        let timer = Timer(timeInterval: 3600, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        queue.async { [weak self, reader] in
            let result = Result {
                try autoreleasepool {
                    let state = try reader.synchronizeDatabase(now: date)
                    let changed = try Self.needsSummary(reader, state, previous: previous, calendar: calendar, priorCalendar: priorCalendar)
                    let summary = changed ? try Self.makeSummary(reader, state, calendar: calendar) : nil
                    return (state, summary)
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshing = false
                guard self.active else { return }
                if self.generation != generation { self.refresh(); return }
                switch result {
                case let .success((state, summary)):
                    self.state = state
                    if let summary {
                        self.pageRevision += 1
                        self.analysis = summary
                    }
                case .failure where self.state == nil:
                    let failed = TokenUsageHistorySnapshot(accountID: nil, unreadableFiles: 1, capturedAt: date, isLoaded: true)
                    self.pageRevision += 1
                    self.analysis = TokenUsageMenuSummary(TokenUsageHistoryAnalysis(snapshot: failed, now: date, calendar: calendar))
                case .failure: break
                }
            }
        }
    }

    private nonisolated static func needsSummary(_ reader: TokenUsageHistoryReader, _ state: TokenUsageHistoryDatabaseState,
            previous: TokenUsageHistoryDatabaseState?, calendar: Calendar, priorCalendar: Calendar) throws -> Bool {
        guard let previous, previous.revision == state.revision, previous.accountID == state.accountID,
              previous.currentPlan == state.currentPlan, previous.calibrationGroup == state.calibrationGroup,
              calendar == priorCalendar, calendar.isDate(previous.capturedAt, inSameDayAs: state.capturedAt),
              state.capturedAt >= previous.capturedAt else { return true }
        let oldCutoff = calendar.date(byAdding: .day, value: -7, to: previous.capturedAt)!
        let cutoff = calendar.date(byAdding: .day, value: -7, to: state.capturedAt)!
        return try reader.databaseHasRecords(state: state, after: oldCutoff, through: cutoff) ||
            reader.databaseHasRecords(state: state, after: previous.capturedAt, through: state.capturedAt)
    }

    private nonisolated static func scopeStart(_ reader: TokenUsageHistoryReader, _ state: TokenUsageHistoryDatabaseState,
            day: Date, calendar: Calendar, includeWeekly: Bool) throws -> Date {
        var start = day
        // A quota window already in progress can change the ownership and color of a day's observations.
        // Back up to the day before each crossing until older records are independent.
        while let crossing = try reader.databaseWindowCrossing(state: state, before: start, includeWeekly: includeWeekly) {
            start = calendar.startOfDay(for: crossing)
        }
        return start
    }

    private nonisolated static func makeSummary(_ reader: TokenUsageHistoryReader, _ state: TokenUsageHistoryDatabaseState,
            calendar: Calendar) throws -> TokenUsageMenuSummary {
        let date = state.capturedAt
        let previousStart = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: date))!
        let from = try scopeStart(reader, state, day: previousStart, calendar: calendar, includeWeekly: true)
        let snapshot = try reader.readDatabaseSnapshot(state: state, from: from, through: date)
        let analysis = TokenUsageHistoryAnalysis(snapshot: snapshot, now: date, calendar: calendar,
            calibrationGroup: state.calibrationGroup)
        return TokenUsageMenuSummary(analysis, unboundTokens: state.unboundTokens)
    }

    func page(ending date: Date) async -> TokenUsageHistoryPage? {
        let calendar = analysis.calendar
        let end = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -6, to: end)!
        if let preview {
            return TokenUsageHistoryPage(days: preview.historicalDays.filter { $0.date >= start && $0.date <= end },
                untimed: preview.snapshot.records.filter { $0.timestamp == nil })
        }
        guard let state else { return nil }
        let generation = self.generation, revision = pageRevision
        let nextDay = calendar.date(byAdding: .day, value: 1, to: end)!
        // A valid five-hour observation may be up to six hours past its window's start.
        let through = min(state.capturedAt, nextDay.addingTimeInterval(6 * 3600 + 180))
        let result = await withCheckedContinuation { continuation in
            pageQueue.async { [pageReader] in
                let result = try? autoreleasepool {
                    let from = try Self.scopeStart(pageReader, state, day: start, calendar: calendar, includeWeekly: false)
                    let snapshot = try pageReader.readDatabaseSnapshot(state: state, from: from, through: through)
                    return TokenUsageHistoryPage(snapshot: snapshot, start: start, end: end, calendar: calendar)
                }
                continuation.resume(returning: result)
            }
        }
        guard self.generation == generation, pageRevision == revision, !Task.isCancelled else { return nil }
        return result
    }
}
