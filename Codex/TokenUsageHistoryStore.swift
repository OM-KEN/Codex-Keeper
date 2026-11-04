import Foundation
import SQLite3

struct TokenUsageHistoryDatabaseState: Equatable, Sendable {
    let accountID: String?
    let capturedAt: Date
    let revision: UInt64
    let unreadableFiles: Int
    let omittedBaselines: Int
    let unboundTokens: Int
    let currentPlan: String?
    let calibrationGroup: TokenUsageCalibrationGroup?
    let storeRevision: Int64
    let identity: Data?
    let stable: Bool
}

/// Rebuildable local statistics. The observer serializes access on its utility queue.
final class TokenUsageHistoryStore {
    enum Failure: Error {
        case sqlite(Int32)
        case incompatibleSchema
        case invalidData
        case stale
    }

    struct Stamp: Equatable {
        var inode: UInt64
        var size: UInt64
        var modified: Date
        var changedSeconds: Int?
        var changedNanoseconds: Int?
        var compressed: Bool
    }

    struct File: Equatable {
        var stamp: Stamp
        var thread: String
        var creator: String?
        var owner: String?
        var auxiliary: Bool
        var unreadable: Bool
        var omittedBaselines: Int
    }

    struct Metadata {
        var roots: Data
        var revision: Int64
        var scanFailures: Int
    }

    private enum Value {
        case text(String), integer(Int64), real(Double), blob(Data), null

        init(_ text: String?) { self = text.map(Self.text) ?? .null }
        init(_ integer: Int?) { self = integer.map { .integer(Int64($0)) } ?? .null }
        init(_ date: Date?) { self = date.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null }
        init(_ flag: Bool) { self = .integer(flag ? 1 : 0) }
    }

    private let db: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw Failure.sqlite(code)
        }
        db = handle
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 1000)
        try check(sqlite3_create_collation_v2(db, "KEEPER_TEXT", SQLITE_UTF8, nil, { _, leftCount, left, rightCount, right in
            let lhs = String(decoding: UnsafeRawBufferPointer(start: left, count: Int(leftCount)), as: UTF8.self)
            let rhs = String(decoding: UnsafeRawBufferPointer(start: right, count: Int(rightCount)), as: UTF8.self)
            return lhs == rhs ? 0 : lhs < rhs ? -1 : 1
        }, nil))
        try execute("PRAGMA journal_mode = WAL; PRAGMA cache_size = -2048; PRAGMA foreign_keys = ON")
        let version = try schemaVersion()
        if version == 0 {
            try transaction {
                // Another process may have initialized the store while this connection opened.
                if try schemaVersion() == 0 {
                    try execute("""
                        CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK (id = 1),
                            roots BLOB NOT NULL, revision INTEGER NOT NULL, scan_failures INTEGER NOT NULL);
                        CREATE TABLE files (key INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, inode INTEGER NOT NULL, size INTEGER NOT NULL,
                            modified REAL NOT NULL, changed_seconds INTEGER, changed_nanoseconds INTEGER,
                            compressed INTEGER NOT NULL, thread TEXT NOT NULL, creator TEXT, owner TEXT,
                            auxiliary INTEGER NOT NULL, unreadable INTEGER NOT NULL, omitted_baselines INTEGER NOT NULL,
                            cursor BLOB NOT NULL);
                        CREATE TABLE records (file_key INTEGER NOT NULL REFERENCES files(key) ON DELETE CASCADE
                            DEFERRABLE INITIALLY DEFERRED, id TEXT COLLATE KEEPER_TEXT NOT NULL, timestamp REAL,
                            total INTEGER NOT NULL, plan TEXT, five_hour_reset REAL, weekly_reset REAL, record BLOB NOT NULL,
                            PRIMARY KEY (file_key, id)) WITHOUT ROWID;
                        CREATE INDEX files_owner ON files(owner);
                        CREATE INDEX records_id ON records(id);
                        CREATE INDEX records_time ON records(timestamp, id);
                        CREATE INDEX records_plans ON records(timestamp, id) WHERE plan IS NOT NULL;
                        CREATE INDEX records_positive ON records(timestamp, id) WHERE total > 0;
                        CREATE INDEX records_five_hour_reset ON records(five_hour_reset) WHERE five_hour_reset IS NOT NULL;
                        CREATE INDEX records_weekly_reset ON records(weekly_reset) WHERE weekly_reset IS NOT NULL;
                        PRAGMA user_version = 1;
                        """)
                }
            }
        }
        guard try schemaVersion() == 1 else { throw Failure.incompatibleSchema }
    }

    deinit { sqlite3_close(db) }

    func transaction<T>(write: Bool = true, _ action: () throws -> T) throws -> T {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let value = try action()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func withFile<T>(_ action: () throws -> T) throws -> T {
        try execute("SAVEPOINT rollout")
        do {
            let value = try action()
            try execute("RELEASE rollout")
            return value
        } catch {
            try execute("ROLLBACK TO rollout; RELEASE rollout")
            throw error
        }
    }

    func metadata() throws -> Metadata? {
        var result: Metadata?
        try query("SELECT roots, revision, scan_failures FROM metadata") { row in
            result = Metadata(roots: Self.data(row, 0), revision: sqlite3_column_int64(row, 1),
                scanFailures: Int(sqlite3_column_int64(row, 2)))
        }
        return result
    }

    func saveMetadata(_ metadata: Metadata) throws {
        try run("INSERT OR REPLACE INTO metadata VALUES (1, ?, ?, ?)",
            [.blob(metadata.roots), .integer(metadata.revision), .integer(Int64(metadata.scanFailures))])
    }

    func files() throws -> [String: File] {
        var result: [String: File] = [:]
        try query("""
            SELECT path, inode, size, modified, changed_seconds, changed_nanoseconds, compressed,
                thread, creator, owner, auxiliary, unreadable, omitted_baselines FROM files
            """) { row in
            let stamp = Stamp(inode: UInt64(bitPattern: sqlite3_column_int64(row, 1)),
                size: UInt64(bitPattern: sqlite3_column_int64(row, 2)),
                modified: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 3)),
                changedSeconds: Self.integer(row, 4), changedNanoseconds: Self.integer(row, 5),
                compressed: sqlite3_column_int(row, 6) != 0)
            guard let path = Self.string(row, 0), let thread = Self.string(row, 7) else { throw Failure.invalidData }
            result[path] = File(stamp: stamp, thread: thread, creator: Self.string(row, 8), owner: Self.string(row, 9),
                auxiliary: sqlite3_column_int(row, 10) != 0, unreadable: sqlite3_column_int(row, 11) != 0,
                omittedBaselines: Int(sqlite3_column_int64(row, 12)))
        }
        return result
    }

    func cursor<T: Decodable>(for path: String, as type: T.Type) throws -> T {
        var result: T?
        try query("SELECT cursor FROM files WHERE path = ?", [.text(path)]) { row in
            result = try decode(type, Self.data(row, 0))
        }
        guard let result else { throw Failure.invalidData }
        return result
    }

    func saveFile<T: Encodable>(_ file: File, path: String, cursor: T) throws {
        let stamp = file.stamp
        try run("""
            INSERT INTO files(path, inode, size, modified, changed_seconds, changed_nanoseconds, compressed,
                thread, creator, owner, auxiliary, unreadable, omitted_baselines, cursor)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET inode=excluded.inode, size=excluded.size, modified=excluded.modified,
                changed_seconds=excluded.changed_seconds, changed_nanoseconds=excluded.changed_nanoseconds,
                compressed=excluded.compressed, thread=excluded.thread, creator=excluded.creator, owner=excluded.owner,
                auxiliary=excluded.auxiliary, unreadable=excluded.unreadable, omitted_baselines=excluded.omitted_baselines,
                cursor=excluded.cursor
            """, [.text(path), .integer(Int64(bitPattern: stamp.inode)), .integer(Int64(bitPattern: stamp.size)),
                Value(stamp.modified), Value(stamp.changedSeconds), Value(stamp.changedNanoseconds), Value(stamp.compressed),
                .text(file.thread), Value(file.creator), Value(file.owner), Value(file.auxiliary), Value(file.unreadable),
                .integer(Int64(file.omittedBaselines)), .blob(try encode(cursor))])
    }

    func rebindFile(_ path: String, owner: String?) throws {
        try run("UPDATE files SET owner = ? WHERE path = ?", [Value(owner), .text(path)])
    }

    func deleteFile(_ path: String) throws {
        try run("DELETE FROM files WHERE path = ?", [.text(path)])
    }

    func clearFiles() throws { try execute("DELETE FROM files") }

    func deleteRecords(for path: String) throws -> Bool {
        try run("DELETE FROM records WHERE file_key = (SELECT key FROM files WHERE path = ?)", [.text(path)])
        return sqlite3_changes(db) != 0
    }

    func append(_ records: [TokenUsageRecord], path: String) throws -> Bool {
        guard !records.isEmpty else { return false }
        var fileKey: Int64?
        try query("SELECT key FROM files WHERE path = ?", [.text(path)]) { fileKey = sqlite3_column_int64($0, 0) }
        guard let fileKey else { throw Failure.invalidData }
        let statement = try prepare("INSERT OR IGNORE INTO records VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        var changed = false
        for record in records {
            func validReset(_ quota: QuotaWindow?) -> Date? {
                guard let at = record.timestamp, let quota, quota.usedPercent >= 0, quota.usedPercent <= 100,
                      quota.resetsAt > at, quota.resetsAt.timeIntervalSince(at) <= Double(quota.windowMinutes) * 60 + 180 else { return nil }
                return quota.resetsAt
            }
            try bind([.integer(fileKey), .text(record.id), Value(record.timestamp), .integer(Int64(record.counts?.total ?? 0)),
                Value(record.planType), Value(validReset(record.fiveHour)), Value(validReset(record.weekly)),
                .blob(try encode(record))], to: statement)
            try check(sqlite3_step(statement), expecting: SQLITE_DONE)
            if sqlite3_changes(db) != 0 { changed = true }
            try check(sqlite3_reset(statement))
        }
        return changed
    }

    // The first path owns a duplicate even if its owner conflicts with the current account.
    private static let canonicalRecord = """
        NOT EXISTS (SELECT 1 FROM records AS other JOIN files AS source ON source.key = other.file_key
            WHERE other.id = r.id AND source.path COLLATE KEEPER_TEXT < f.path)
        """

    func diagnostics() throws -> (unreadable: Int, omitted: Int) {
        var result = (0, 0)
        try query("SELECT SUM(unreadable), SUM(omitted_baselines) FROM files") { row in
            result = (Int(sqlite3_column_int64(row, 0)), Int(sqlite3_column_int64(row, 1)))
        }
        return result
    }

    func unboundTokens() throws -> Int {
        var total = 0
        try query("""
            SELECT SUM(r.total) FROM records AS r JOIN files AS f ON f.key = r.file_key
            WHERE f.owner IS NULL AND r.total > 0 AND \(Self.canonicalRecord)
            """) { total = Int(sqlite3_column_int64($0, 0)) }
        return total
    }

    func windowCrossing(account: String, before: Date, includeWeekly: Bool) throws -> Date? {
        let boundary = before.addingTimeInterval(-180)
        var earliest: Date?
        for column in includeWeekly ? ["five_hour_reset", "weekly_reset"] : ["five_hour_reset"] {
            try query("""
                SELECT MIN(r.timestamp) FROM records AS r JOIN files AS f ON f.key = r.file_key
                WHERE r.\(column) >= ? AND r.timestamp < ? AND f.owner = ? AND \(Self.canonicalRecord)
                """, [Value(boundary), Value(before), .text(account)]) { row in
                guard sqlite3_column_type(row, 0) != SQLITE_NULL else { return }
                let timestamp = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 0))
                earliest = min(earliest ?? timestamp, timestamp)
            }
        }
        return earliest
    }

    func hasRecords(account: String, after: Date, through: Date) throws -> Bool {
        var found = false
        try query("""
            SELECT 1 FROM records AS r JOIN files AS f ON f.key = r.file_key
            WHERE f.owner = ? AND r.timestamp > ? AND r.timestamp <= ? LIMIT 1
            """, [.text(account), Value(after), Value(through)]) { _ in found = true }
        return found
    }

    func currentPlan(account: String?, now: Date) throws -> String? {
        guard let account else { return nil }
        var result: String?
        try query("""
            SELECT r.plan FROM records AS r INDEXED BY records_plans CROSS JOIN files AS f ON f.key = r.file_key
            WHERE f.owner = ? AND r.timestamp BETWEEN ? AND ? AND r.plan IS NOT NULL AND \(Self.canonicalRecord)
            ORDER BY r.timestamp DESC, r.id DESC LIMIT 1
            """, [.text(account), Value(now.addingTimeInterval(-86400)), Value(now)]) { row in
            result = Self.string(row, 0)
        }
        return result
    }

    func calibrationGroup(account: String?, now: Date) throws -> TokenUsageCalibrationGroup? {
        guard let account else { return nil }
        var result: TokenUsageCalibrationGroup?
        try query("""
            SELECT r.record FROM records AS r INDEXED BY records_positive CROSS JOIN files AS f ON f.key = r.file_key
            WHERE f.owner = ? AND NOT f.auxiliary AND r.timestamp <= ? AND r.total > 0 AND \(Self.canonicalRecord)
            ORDER BY r.timestamp DESC, r.id DESC LIMIT 1
            """, [.text(account), Value(now)]) { row in
            result = try decode(TokenUsageRecord.self, Self.data(row, 0)).calibrationGroup
        }
        return result
    }

    func snapshot(state: TokenUsageHistoryDatabaseState, from: Date?, through: Date) throws -> TokenUsageHistorySnapshot {
        var result = TokenUsageHistorySnapshot(accountID: state.accountID, unreadableFiles: state.unreadableFiles,
            omittedBaselines: state.omittedBaselines, currentPlan: state.currentPlan, capturedAt: state.capturedAt, isLoaded: true)
        let timeRange = from == nil ? "r.timestamp <= ?" : "r.timestamp BETWEEN ? AND ?"
        let dates = from.map { [Value($0), Value(through)] } ?? [Value(through)]
        func append(_ row: OpaquePointer) throws {
            let owner = Self.string(row, 1)
            var record = try decode(TokenUsageRecord.self, Self.data(row, 0))
            record.accountID = owner
            record.isAuxiliary = sqlite3_column_int(row, 2) != 0
            if owner != nil { result.records.append(record) }
            else {
                result.unboundRecords.append(record)
                result.unboundTokens += record.counts?.total ?? 0
            }
        }
        // Keep timed and untimed predicates separate so SQLite can seek into the time index.
        for (predicate, values) in [("r.timestamp IS NULL", []), (timeRange, dates)] {
            try query("""
                SELECT r.record, f.owner, f.auxiliary
                FROM records AS r INDEXED BY records_time CROSS JOIN files AS f ON f.key = r.file_key
                WHERE (f.owner = ? OR (f.owner IS NULL AND r.total > 0)) AND \(predicate) AND \(Self.canonicalRecord)
                ORDER BY r.timestamp, r.id
                """, [Value(state.accountID)] + values, each: append)
        }
        return result
    }

    private func schemaVersion() throws -> Int32 {
        var version: Int32 = -1
        try query("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
        return version
    }

    private func execute(_ sql: String) throws { try check(sqlite3_exec(db, sql, nil, nil, nil)) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        guard let statement else { throw Failure.invalidData }
        return statement
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        try check(sqlite3_step(statement), expecting: SQLITE_DONE)
    }

    private func query(_ sql: String, _ values: [Value] = [], each: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            try each(statement)
            code = sqlite3_step(statement)
        }
        try check(code, expecting: SQLITE_DONE)
    }

    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let column = Int32(index + 1)
            switch value {
            case .text(let text):
                try check(sqlite3_bind_text(statement, column, text, Int32(text.utf8.count), transient))
            case .integer(let integer): try check(sqlite3_bind_int64(statement, column, integer))
            case .real(let real): try check(sqlite3_bind_double(statement, column, real))
            case .blob(let data):
                try data.withUnsafeBytes { try check(sqlite3_bind_blob(statement, column, $0.baseAddress, Int32(data.count), transient)) }
            case .null: try check(sqlite3_bind_null(statement, column))
            }
        }
    }

    private func check(_ code: Int32, expecting: Int32 = SQLITE_OK) throws {
        guard code == expecting else { throw Failure.sqlite(code) }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try encoder.encode(value) } catch { throw Failure.invalidData }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) } catch { throw Failure.invalidData }
    }

    private static func data(_ row: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }

    private static func string(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(row, column) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self)
    }

    private static func integer(_ row: OpaquePointer, _ column: Int32) -> Int? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(row, column))
    }
}
