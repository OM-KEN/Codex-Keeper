import Foundation

func checkTokenUsageHistoryStore(_ check: (Bool, String) -> Void, root: URL) throws {
    let home = root.appendingPathComponent("home")
    let sessions = home.appendingPathComponent("sessions")
    let archived = home.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    let auth = home.appendingPathComponent("auth.json")
    try Data("{\"tokens\":{\"account_id\":\"a\"}}".utf8).write(to: auth)
    let legacyURL = root.appendingPathComponent("token-usage-cache-v1.json")
    let databaseURL = root.appendingPathComponent("token-usage.sqlite")
    let primary = sessions.appendingPathComponent("main-\"escaped\"-用量.jsonl")
    let shadow = archived.appendingPathComponent("main.jsonl")
    let first = Date(timeIntervalSince1970: 1_790_000_000)
    let next = first.addingTimeInterval(60)
    let now = first.addingTimeInterval(120)
    let iso = ISO8601DateFormatter()
    func line(_ type: String, _ payload: [String: Any], at: Date) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["timestamp": iso.string(from: at), "type": type, "payload": payload],
            options: .sortedKeys) + Data([10])
    }
    func tokens(_ total: Int, at: Date) throws -> Data {
        try line("event_msg", ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": total, "total_tokens": total],
            "last_token_usage": ["input_tokens": 10, "total_tokens": 10]],
            "rate_limits": ["plan_type": "plus", "primary": ["used_percent": total,
                "window_minutes": 300, "resets_at": first.addingTimeInterval(3600).timeIntervalSince1970]]], at: at)
    }
    let context = try line("turn_context", ["model": "gpt-6.1-sol", "service_tier": "default"], at: first)
    let record = try tokens(10, at: first)
    let ordinary = try line("session_meta", ["id": "thread", "creator_account_id": "a"], at: first) + context + record
    let duplicate = try line("session_meta", ["id": "thread", "creator_account_id": "b"], at: first) + context + record
    try ordinary.write(to: primary)
    try duplicate.write(to: shadow)

    let legacy = TokenUsageHistoryReader(home: home, cacheURL: legacyURL)
    let expected = legacy.read(now: now)
    let legacyFile = try FileHandle(forWritingTo: legacyURL)
    try legacyFile.seekToEnd()
    try legacyFile.write(contentsOf: Data(repeating: 32, count: 9 * 1024 * 1024))
    try legacyFile.close()
    let legacyBytes = try Data(contentsOf: legacyURL)
    func makeReader() -> TokenUsageHistoryReader {
        TokenUsageHistoryReader(home: home, cacheURL: legacyURL, databaseURL: databaseURL)
    }
    let reader = makeReader()
    let migrated = try reader.synchronizeDatabase(now: now)
    let migratedSnapshot = try reader.readDatabaseSnapshot(state: migrated, from: nil, through: now)
    check(reader.bytesRead == 0 && migratedSnapshot == expected && migratedSnapshot.records.isEmpty,
        "SQLite migrates a large legacy cache and deduplicates the first archive path before filtering by account")
    try FileManager.default.removeItem(at: shadow)
    let afterRemoval = try reader.synchronizeDatabase(now: now)
    let afterRemovalSnapshot = try reader.readDatabaseSnapshot(state: afterRemoval, from: nil, through: now)
    let windowCrossing = try reader.databaseWindowCrossing(state: afterRemoval, before: next, includeWeekly: false)
    check(afterRemovalSnapshot == legacy.read(now: now, persistCache: false) && reader.bytesRead == 0 && windowCrossing == first,
        "removing a duplicate restores the next path with a seekable window boundary and no rollout reads")

    let handle = try FileHandle(forWritingTo: primary)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: tokens(20, at: next))
    var checkpoints = 0
    do {
        _ = try reader.synchronizeDatabase(now: now, isCancelled: { checkpoints += 1; return checkpoints == 4 })
        check(false, "SQLite synchronization reports a cancellation before committing draft rows")
    } catch is CancellationError {
        let snapshot = try reader.readDatabaseSnapshot(state: afterRemoval, from: nil, through: now)
        check(snapshot == afterRemovalSnapshot, "cancellation rolls back parsed rows and their cursor together")
    }
    let restarted = makeReader()
    let retried = try restarted.synchronizeDatabase(now: now)
    let full = try restarted.readDatabaseSnapshot(state: retried, from: nil, through: now)
    let range = try restarted.readDatabaseSnapshot(state: retried, from: next, through: next)
    let hasRecord = try restarted.databaseHasRecords(state: retried, after: first, through: next)
    let unchanged = try restarted.synchronizeDatabase(now: now.addingTimeInterval(60))
    let preservedBytes = try Data(contentsOf: legacyURL)
    check(full == legacy.read(now: now, persistCache: false) && range.records == Array(full.records.suffix(1)) &&
        range.currentPlan == "plus" && hasRecord && unchanged.revision == retried.revision && legacyBytes == preservedBytes,
        "retry is exact across processes, supports inclusive range queries and leaves rollback cache intact")

    try Data("{\"tokens\":{\"account_id\":\"b\"}}".utf8).write(to: auth)
    do {
        _ = try restarted.readDatabaseSnapshot(state: retried, from: nil, through: now)
        check(false, "an old account cannot read detail after authentication changes")
    } catch TokenUsageHistoryStore.Failure.stale {
        check(true, "an old account cannot read detail after authentication changes")
    }
}
