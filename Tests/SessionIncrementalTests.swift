import Foundation

func checkSessionIncrementalReads(_ check: (Bool, String) -> Void, root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
