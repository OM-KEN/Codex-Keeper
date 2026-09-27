import Foundation

struct ExecutionEventLog {
    let url: URL
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
        let iso = ISO8601DateFormatter()
        var starts: [String: Date] = [:]
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = row["kind"] as? String, ["ping", "resume"].contains(kind),
                  let at = (row["at"] as? String).flatMap(iso.date(from:)) else { return nil }
            let key = kind + ":" + (row["thread_id"] as? String ?? row["node"] as? String ?? "")
            if row["event"] as? String == "started" { starts[key] = at; return nil }
            guard row["event"] as? String == "confirmed" else { return nil }
            let reset = (row["after_reset"] as? String).flatMap(iso.date(from:))
            return ExecutionConfirmation(kind: kind == "ping" ? .keepAlive : .resume,
                actionAt: starts[key] ?? at, confirmedAt: at,
                windowStart: reset?.addingTimeInterval(-ScheduleEngine.windowDuration))
        }
    }

    func record(_ event: String, kind: String, node: Date?, before: UsageSnapshot? = nil, after: UsageSnapshot? = nil, error: String? = nil, threadID: String? = nil, turnID: String? = nil, diagnostic: PingDiagnostic? = nil) throws {
        let iso = ISO8601DateFormatter()
        var row: [String: Any] = ["event": event, "kind": kind, "at": iso.string(from: Date())]
        if let node { row["node"] = iso.string(from: node) }
        if let reset = before?.fiveHour?.resetsAt { row["before_reset"] = iso.string(from: reset) }
        if let reset = after?.fiveHour?.resetsAt { row["after_reset"] = iso.string(from: reset) }
        if let error { row["error"] = error }
        if let threadID { row["thread_id"] = threadID }
        if let turnID { row["turn_id"] = turnID }
        if let diagnostic {
            row["diagnostic"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic))
            if let id = diagnostic.threadID { row["thread_id"] = id }
            if let id = diagnostic.turnID { row["turn_id"] = id }
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
}
