import Foundation
import SQLite3

struct CodexDatabaseError: LocalizedError {
    let kind: String
    let stage: String
    let code: Int32
    let extendedCode: Int32
    let incompatible: Bool

    var errorDescription: String? {
        let message = incompatible ? L10n.text("Codex 本地日志格式不兼容；请更新 Keeper，自动继续已暂停") : L10n.text("无法读取 Codex 本地暂停记录")
        return message
    }
}

/// READWRITE permits SQLite's normal WAL/SHM lifecycle; query_only forbids database changes.
/// Never creates a missing database, changes journal mode, or bypasses the active WAL.
final class ReadOnlyDatabase {
    private var db: OpaquePointer?
    private let kind: String

    init(url: URL, kind: String) throws {
        self.kind = kind
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK else {
            let error = failure("open")
            if let db { sqlite3_close(db) }; db = nil
            throw error
        }
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 1000)
        do {
            guard sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else { throw failure("restrict") }
            let statement = try prepare("PRAGMA query_only")
            defer { sqlite3_finalize(statement) }
            guard try step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1 else { throw failure("restrict") }
        } catch {
            sqlite3_close(db); db = nil
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw failure("prepare")
        }
        guard sqlite3_stmt_readonly(statement) != 0 else {
            sqlite3_finalize(statement)
            throw CodexDatabaseError(kind: kind, stage: "prepare", code: SQLITE_READONLY, extendedCode: SQLITE_READONLY, incompatible: false)
        }
        return statement
    }

    func step(_ statement: OpaquePointer?) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure("read") }
        return result
    }

    private func failure(_ stage: String) -> CodexDatabaseError {
        let code = sqlite3_errcode(db)
        let detail = String(cString: sqlite3_errmsg(db))
        let incompatible = code == SQLITE_ERROR && (detail.hasPrefix("no such table:") || detail.hasPrefix("no such column:"))
        return CodexDatabaseError(kind: kind, stage: stage, code: code & 0xff, extendedCode: sqlite3_extended_errcode(db), incompatible: incompatible)
    }
}
