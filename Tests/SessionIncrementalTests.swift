import Foundation
import SQLite3

func checkSessionIncrementalReads(_ check: (Bool, String) -> Void, root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try checkCanonicalIncrementalReplacement(check, home: root.appendingPathComponent("canonical"))
    let id = UUID().uuidString
    let file = root.appendingPathComponent("rollout-\(id).jsonl")
    let base = Date(timeIntervalSince1970: 1_792_800_000)
    var tick: TimeInterval = 0
    func row(_ type: String, _ payload: [String: Any], at date: Date) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": ISO8601DateFormatter().string(from: date), "payload": payload])
        data.append(10); return data
    }
    func event(_ type: String, turn: String = "one", extras: [String: Any] = [:]) throws -> Data {
        tick += 1
        return try row("event_msg", extras.merging(["type": type, "turn_id": turn]) { _, new in new }, at: base.addingTimeInterval(tick))
    }
    func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    let metadata = try row("session_meta", ["id": id, "cwd": root.path], at: base)
    try metadata.write(to: file)
    let reader = SessionRolloutReader()
    func compare(_ name: String) throws {
        let date = base.addingTimeInterval(tick + 20)
        let incremental = try reader.read(url: file, mtime: date)
        let complete = SessionWatcher.parse(url: file, mtime: date)
        check(incremental == complete, "incremental and full session facts agree: " + name)
    }
    try compare("metadata only")
    try append(event("task_started")); try compare("task start")
    let reset = base.addingTimeInterval(18000).timeIntervalSince1970
    try append(event("token_count", extras: ["rate_limits": ["limit_id": "codex", "primary": ["used_percent": 100, "window_minutes": 300, "resets_at": reset]]]))
    try compare("quota exhausted")
    try append(event("error", extras: ["message": "usage_limit_reached"])); try compare("quota error")
    let stopped = try reader.read(url: file, mtime: base.addingTimeInterval(tick + 20))
    check(stopped?.quotaBlockedAt != nil && stopped?.taskRunning == false, "incremental parsing retains actual quota-stop evidence")
    let retry = try event("task_started", turn: "two")
    try append(retry.prefix(retry.count / 2)); try compare("incomplete JSON")
    try append(retry.suffix(retry.count - retry.count / 2)); try compare("completed partial JSON")
    try append(event("error", turn: "two", extras: ["message": "temporary failure", "will_retry": true])); try compare("retry remains running")
    try append(event("task_complete", turn: "two")); try compare("completion")
    var noNewline = try event("task_started", turn: "three"); noNewline.removeLast()
    try append(noNewline); try compare("valid final JSON without newline")
    try append(Data([10])); try compare("newline does not replay a final JSON")
    let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 0); try handle.close()
    var replacement = metadata; replacement.append(try event("task_started", turn: "replacement"))
    replacement.append(Data(repeating: 32, count: 800)); replacement.append(10)
    try replacement.write(to: file)
    try compare("same-inode truncate and larger rewrite")
    let renamed = file.appendingPathExtension("old"); try FileManager.default.moveItem(at: file, to: renamed)
    var restored = metadata; restored.append(try event("turn_aborted", turn: "restored")); try restored.write(to: file)
    try compare("new inode")
    var edited = metadata; edited.append(try event("task_started", turn: "changed")); try edited.write(to: file)
    try compare("same-size edit")
    let beforeInvalid = try reader.read(url: file, mtime: base.addingTimeInterval(tick + 20))
    try append(Data([0xff]))
    do { _ = try reader.read(url: file, mtime: base.addingTimeInterval(tick + 21)); check(false, "invalid UTF-8 must fail closed") }
    catch { check(true, "invalid UTF-8 must fail closed") }
    try edited.write(to: file)
    check(try reader.read(url: file, mtime: base.addingTimeInterval(tick + 22)) == SessionWatcher.parse(url: file, mtime: base.addingTimeInterval(tick + 22)),
        "a repaired file recovers its exact session state")
    check(beforeInvalid?.currentTurnID == "changed", "a read failure cannot silently consume the previously verified task")
    // Editing metadata is not an append, even if the old suffix is unchanged.
    var changedHeader = try row("session_meta", ["id": id, "cwd": String(root.path.dropLast()) + "X"], at: base)
    changedHeader.append(edited.dropFirst(metadata.count))
    changedHeader.append(try event("task_complete", turn: "changed"))
    try changedHeader.write(to: file); try compare("metadata rewrite followed by an append")
    let unicode = try event("agent_message", extras: ["message": "你好"])
    let split = unicode.firstIndex(of: 0xe4)! + 1
    try append(unicode.prefix(split))
    do { _ = try reader.read(url: file, mtime: base.addingTimeInterval(tick + 30)); check(false, "an unfinished UTF-8 character must fail closed") }
    catch { check(true, "an unfinished UTF-8 character must fail closed") }
    try append(unicode.suffix(unicode.count - split)); try compare("UTF-8 character completed after a failed read")
    try append(event("agent_reasoning", extras: ["text": String(repeating: "a", count: 8 * 1024 * 1024)]))
    try compare("a multi-megabyte record across read chunks")
    try append(event("task_started", turn: "after-large-record")); try compare("activity following a multi-megabyte record")
    // Legacy records without timestamps must retain the old mtime fallback semantics.
    var legacy = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "cwd": root.path]])
    legacy.append(10); try legacy.write(to: file); try compare("legacy missing timestamp")
    try append(event("task_started", turn: "legacy")); try compare("legacy fallback after append")
}

private func checkCanonicalIncrementalReplacement(_ check: (Bool, String) -> Void, home: URL) throws {
    let directory = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID().uuidString
    let old = directory.appendingPathComponent("rollout-\(id).jsonl")
    let current = directory.appendingPathComponent("rollout-\(id)_\(UUID().uuidString).jsonl")
    let base = Date(timeIntervalSince1970: 1_792_800_000)
    func row(_ type: String, _ payload: [String: Any], after seconds: TimeInterval) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type,
            "timestamp": ISO8601DateFormatter().string(from: base.addingTimeInterval(seconds)), "payload": payload])
        data.append(10); return data
    }
    let metadata = try row("session_meta", ["id": id, "cwd": home.path], after: 0)
    var trace = metadata
    trace.append(try row("event_msg", ["type": "task_started", "turn_id": "old"], after: 1))
    try trace.write(to: old)
    var state: OpaquePointer?
    guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &state) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    defer { sqlite3_close(state) }
    func register(_ file: URL) throws {
        let path = file.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(state, "DELETE FROM threads; INSERT INTO threads VALUES('\(id)', '\(path)')", nil, nil, nil) == SQLITE_OK else {
            throw CodexConnectionError.invalidResponse
        }
    }
    guard sqlite3_exec(state, "CREATE TABLE threads(id TEXT, rollout_path TEXT)", nil, nil, nil) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    try register(old)
    var logs: OpaquePointer?
    guard sqlite3_open(home.appendingPathComponent("logs_1.sqlite").path, &logs) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    defer { sqlite3_close(logs) }
    guard sqlite3_exec(logs, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil) == SQLITE_OK else { throw CodexConnectionError.invalidResponse }
    let worker = SessionScanWorker(codexHome: home)
    let first = worker.read(watchedIDs: [id])
    check(first.1 == nil && first.0.first?.taskRunning == true && first.0.first?.currentTurnID == "old",
        "the incremental worker initially follows the registered running segment")
    trace = metadata
    trace.append(try row("event_msg", ["type": "task_started", "turn_id": "current"], after: 2))
    try trace.write(to: current)
    try register(current)
    try Data([0xff]).write(to: old)
    let replaced = worker.read(watchedIDs: [id], watchedPaths: [old])
    check(replaced.1 == nil && replaced.0.count == 1 && replaced.0.first?.fileURL.resolvingSymlinksInPath() == current.resolvingSymlinksInPath() &&
        replaced.0.first?.currentTurnID == "current" && replaced.0.first?.currentRolloutVerified == true,
        "canonical replacement excludes a corrupt cached running segment before incremental parsing")
    let quota = try row("event_msg", ["type": "error", "message": "usage_limit_reached", "turn_id": "current"], after: 3)
    func append(_ bytes: Data) throws {
        let handle = try FileHandle(forWritingTo: current); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
    }
    try append(quota.prefix(quota.count / 2))
    let partial = worker.read(watchedIDs: [id], watchedPaths: [old])
    check(partial.1 == nil && partial.0.first?.taskRunning == true && partial.0.first?.quotaBlockedAt == nil,
        "the new canonical segment retains its incremental state across an incomplete append")
    try append(quota.suffix(quota.count - quota.count / 2))
    try FileManager.default.removeItem(at: old)
    let stopped = worker.read(watchedIDs: [id], watchedPaths: [old])
    check(stopped.1 == nil && stopped.0.count == 1 && stopped.0.first?.quotaTurnID == "current" &&
        stopped.0.first?.quotaBlockedAt == base.addingTimeInterval(3) && stopped.0.first?.taskRunning == false,
        "the completed append produces exactly the current pause after obsolete history disappears")
    check(worker.read(watchedIDs: [id]).0 == stopped.0,
        "unchanged canonical segments do not replay or revive the replaced running history")
}
