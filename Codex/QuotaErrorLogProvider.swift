import Foundation
import SQLite3

struct QuotaStop: Equatable {
    let threadID: String
    let at: Date
    var turnID: String? = nil
    var sourceEventID: String? = nil
}

/// Read only the official runtime's turn-error records, never prompt text or prewarm warnings.
final class QuotaErrorLogProvider {
    private let databaseURL: URL?
    private let codexHome: URL?
    private var databaseIdentity: String?
    private var cursor: Int64 = 0
    private var stops: [String: QuotaStop] = [:]

    init(databaseURL: URL) { self.databaseURL = databaseURL; codexHome = nil }
    init(codexHome: URL) { self.codexHome = codexHome; databaseURL = nil }

    private func locateDatabase() throws -> URL {
        if let databaseURL { return databaseURL }
        let home = codexHome!
        let files = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = files.filter { $0.lastPathComponent.range(of: #"^logs(?:_[0-9]+)?\.sqlite$"#, options: .regularExpression) != nil }
        func modified(_ url: URL) -> Date {
            let main = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let wal = (try? URL(fileURLWithPath: url.path + "-wal").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return max(main, wal)
        }
        guard let selected = candidates.sorted(by: {
            let left = modified($0), right = modified($1)
            return left == right ? $0.lastPathComponent > $1.lastPathComponent : left > right
        }).first else {
            throw CodexConnectionError.server("尚无 Codex 本地运行日志；请先在 Codex 中运行任务，自动继续暂不可用")
        }
        return selected
    }

    func read(now: Date = Date()) throws -> [String: QuotaStop] {
        let databaseURL = try locateDatabase()
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let identity = databaseURL.path + ":" + String(describing: attributes[.systemFileNumber]) + ":" + String(describing: attributes[.creationDate])
        if databaseIdentity != identity {
            cursor = 0
            stops = [:]
            databaseIdentity = identity
        }
        let reader = try ReadOnlyDatabase(url: databaseURL, kind: "logs")
        // Validate the fields we actually consume; do not infer evidence from a filename/version.
        let schema = try reader.prepare("SELECT id, ts, ts_nanos, thread_id, feedback_log_body, target FROM logs LIMIT 0")
        sqlite3_finalize(schema)
        let maximum = try reader.prepare("SELECT MAX(id) FROM logs")
        defer { sqlite3_finalize(maximum) }
        if try reader.step(maximum) == SQLITE_ROW, sqlite3_column_int64(maximum, 0) < cursor {
            cursor = 0
            stops = [:]
        }
        stops = stops.filter { now.timeIntervalSince($0.value.at) <= 30 * 86400 }
        let query = "SELECT id, ts, ts_nanos, thread_id, feedback_log_body FROM logs WHERE id > ? AND ts >= ? AND target = 'codex_core::session::turn' ORDER BY id"
        let statement = try reader.prepare(query)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cursor)
        sqlite3_bind_int64(statement, 2, Int64(now.addingTimeInterval(-30 * 86400).timeIntervalSince1970))
        var step = try reader.step(statement)
        while step == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            cursor = max(cursor, id)
            if let threadRaw = sqlite3_column_text(statement, 3), let bodyRaw = sqlite3_column_text(statement, 4) {
                let thread = String(cString: threadRaw)
                let body = String(cString: bodyRaw)
                if Self.isQuotaTurnError(body), UUID(uuidString: thread) != nil {
                    let turns = Self.turnIDs(in: body)
                    if turns.count <= 1 {
                        let time = Double(sqlite3_column_int64(statement, 1)) + Double(sqlite3_column_int64(statement, 2)) / 1_000_000_000
                        stops[thread] = QuotaStop(threadID: thread, at: Date(timeIntervalSince1970: time), turnID: turns.first, sourceEventID: identity + ":" + String(id))
                    } else { stops.removeValue(forKey: thread) }
                }
            }
            step = try reader.step(statement)
        }
        return stops
    }

    static func turnID(in body: String) -> String? {
        let ids = turnIDs(in: body)
        return ids.count == 1 ? ids.first : nil
    }

    private static func turnIDs(in body: String) -> Set<String> {
        let span = body.range(of: ": Turn error: ", options: .backwards).map { String(body[..<$0.lowerBound]) } ?? body
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])turn[_.]id[=:]\s*["']?([A-Za-z0-9-]+)"#) else { return [] }
        return Set(regex.matches(in: span, range: NSRange(span.startIndex..., in: span)).compactMap {
            Range($0.range(at: 1), in: span).map { String(span[$0]) }
        })
    }

    static func isQuotaTurnError(_ body: String) -> Bool {
        // Runtime logs contain a span prefix. Match the actual event boundary, not an arbitrary quote.
        guard !body.contains("will_retry=true"), !body.contains("will_retry: true") else { return false }
        guard let marker = body.range(of: ": Turn error: ", options: .backwards) else { return false }
        let prefix = body[..<marker.lowerBound]
        guard prefix.hasSuffix("session_task.run:run_turn") else { return false }
        let error = body[marker.upperBound...]
        return error.hasPrefix("You've hit your usage limit.") || error.hasPrefix("You’ve hit your usage limit.")
    }
}
