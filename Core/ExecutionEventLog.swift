import Foundation
import Darwin

private enum ExecutionLogWrite { static let lock = NSLock() }

private struct ExecutionLogStamp: Equatable {
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
    var changedSeconds: Int
    var changedNanoseconds: Int

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        inode = UInt64(info.st_ino); size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

private final class LegacyEvidenceCache {
    let lock = NSLock()
    var stamp: ExecutionLogStamp?
    var records: [String: LegacyResumeAttempt] = [:]
    var readCount = 0
}

struct ExecutionEventLog {
    let url: URL
    private let legacyCache = LegacyEvidenceCache()
    private let readLegacyData: (URL) throws -> Data

    init(url: URL, readLegacyData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.url = url; self.readLegacyData = readLegacyData
    }
    var legacyReadCount: Int {
        legacyCache.lock.lock(); defer { legacyCache.lock.unlock() }
        return legacyCache.readCount
    }
    /// A missing log is empty; unreadable or malformed evidence must not start an inactivity deadline.
    func resumeStarts() -> [String: Date]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        var starts: [String: Date] = [:]
        for line in text.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let at = UsageDecoder.timestamp(row["at"] as? String) else { return nil }
            if row["kind"] as? String == "resume", row["event"] as? String == "started" {
                guard let id = row["thread_id"] as? String else { return nil }
                starts[id] = max(starts[id] ?? .distantPast, at)
            }
        }
        return starts
    }

    func confirmations() -> [ExecutionConfirmation] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        var starts: [String: Date] = [:]
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = row["kind"] as? String, ["ping", "resume"].contains(kind),
                  let at = UsageDecoder.timestamp(row["at"] as? String) else { return nil }
            let key = kind + ":" + (row["operation_id"] as? String ?? row["thread_id"] as? String ?? row["node"] as? String ?? "")
            if row["event"] as? String == "started" { starts[key] = at; return nil }
            guard ["confirmed", "startup_confirmed"].contains(row["event"] as? String ?? "") else { return nil }
            let reset = UsageDecoder.timestamp(row["after_reset"] as? String)
            return ExecutionConfirmation(kind: kind == "ping" ? .keepAlive : .resume,
                actionAt: starts[key] ?? at, confirmedAt: at,
                windowStart: row["ping_result"].flatMap { $0 as? [String: Any] }?["outcome"] as? String == "window_active" ? nil : reset?.addingTimeInterval(-ScheduleEngine.windowDuration),
                accountID: (row["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                operationID: row["operation_id"] as? String, episodeKey: row["episode_key"] as? String,
                threadID: row["thread_id"] as? String, turnID: row["turn_id"] as? String)
        }
    }

    func legacyResumeAttempts() -> [String: LegacyResumeAttempt] {
        legacyCache.lock.lock(); defer { legacyCache.lock.unlock() }
        guard let stamp = ExecutionLogStamp(url) else {
            legacyCache.stamp = nil; legacyCache.records = [:]; return [:]
        }
        if legacyCache.stamp == stamp { return legacyCache.records }
        legacyCache.stamp = nil; legacyCache.records = [:]
        legacyCache.readCount += 1
        guard let data = try? readLegacyData(url), let text = String(data: data, encoding: .utf8),
              ExecutionLogStamp(url) == stamp else { return [:] }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        var result: [String: LegacyResumeAttempt] = [:]
        for line in text.split(separator: "\n") {
            // Partial or malformed evidence cannot release a persisted submission guard.
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let raw = row["at"] as? String,
                  let at = fractional.date(from: raw) ?? ordinary.date(from: raw) else { return [:] }
            guard row["kind"] as? String == "resume", row["operation_id"] == nil,
                  let thread = row["thread_id"] as? String else { continue }
            if row["event"] as? String == "started" { result[thread] = LegacyResumeAttempt(startedAt: at) }
            if row["event"] as? String == "confirmed", var record = result[thread], at >= record.startedAt {
                record.confirmedAt = at; record.turnID = row["turn_id"] as? String; record.accountID = row["account_id"] as? String
                result[thread] = record
            }
        }
        guard ExecutionLogStamp(url) == stamp else { return [:] }
        legacyCache.stamp = stamp; legacyCache.records = result
        return result
    }

    func pingResults() -> [PingNodeResult] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = UsageDecoder.timestamp(value) else { throw CodexConnectionError.invalidResponse }
            return date
        }
        var results: [String: PingNodeResult] = [:]
        for line in text.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let value = row["ping_result"], let data = try? JSONSerialization.data(withJSONObject: value),
                  let result = try? decoder.decode(PingNodeResult.self, from: data) else { continue }
            results[(result.accountID ?? "") + ":" + String(result.node.timeIntervalSince1970)] = result
        }
        return results.values.sorted { $0.at < $1.at }
    }

    func record(_ event: String, kind: String, node: Date?, before: UsageSnapshot? = nil, after: UsageSnapshot? = nil, error: String? = nil, threadID: String? = nil, turnID: String? = nil, diagnostic: PingDiagnostic? = nil, preflight: PingPreflightDiagnostic? = nil, resumePreflight: ResumePreflightDiagnostic? = nil, accountID: String? = nil, operationID: String? = nil, episodeKey: String? = nil, at: Date? = nil, pingResult: PingNodeResult? = nil) throws {
        ExecutionLogWrite.lock.lock(); defer { ExecutionLogWrite.lock.unlock() }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var row: [String: Any] = ["event": event, "kind": kind, "at": iso.string(from: at ?? Date())]
        if let node { row["node"] = iso.string(from: node) }
        if let reset = before?.fiveHour?.resetsAt { row["before_reset"] = iso.string(from: reset) }
        if let reset = after?.fiveHour?.resetsAt { row["after_reset"] = iso.string(from: reset) }
        if let accountID, !accountID.isEmpty { row["account_id"] = accountID }
        if let error { row["error"] = error }
        if let operationID { row["operation_id"] = operationID }
        if let episodeKey { row["episode_key"] = episodeKey }
        if let threadID { row["thread_id"] = threadID }
        if let turnID { row["turn_id"] = turnID }
        if let diagnostic {
            row["diagnostic"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic))
            if let id = diagnostic.threadID { row["thread_id"] = id }
            if let id = diagnostic.turnID { row["turn_id"] = id }
        }
        if let preflight {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var value = encoder.singleValueContainer(); try value.encode(iso.string(from: date))
            }
            row["preflight"] = try JSONSerialization.jsonObject(with: encoder.encode(preflight))
        }
        if let resumePreflight {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var value = encoder.singleValueContainer(); try value.encode(iso.string(from: date))
            }
            row["preflight"] = try JSONSerialization.jsonObject(with: encoder.encode(resumePreflight))
        }
        if let pingResult {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var value = encoder.singleValueContainer(); try value.encode(iso.string(from: date))
            }
            row["ping_result"] = try JSONSerialization.jsonObject(with: encoder.encode(pingResult))
        }
        var data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys); data.append(10)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
}

struct ExecutionConfirmation {
    let kind: NextActionMode
    let actionAt: Date
    let confirmedAt: Date
    let windowStart: Date?
    var accountID: String? = nil
    var operationID: String? = nil
    var episodeKey: String? = nil
    var threadID: String? = nil
    var turnID: String? = nil
}

struct LegacyResumeAttempt {
    let startedAt: Date
    var confirmedAt: Date?
    var turnID: String?
    var accountID: String?
}
