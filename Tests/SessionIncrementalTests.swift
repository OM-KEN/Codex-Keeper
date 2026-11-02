import Foundation
import SQLite3

func checkSessionIncrementalReads(_ check: (Bool, String) -> Void, root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try checkCompressedSessions(check, home: root.appendingPathComponent("compressed"))
    try checkCompressedPingReceipts(check, home: root.appendingPathComponent("ping-receipts"))
    try checkCLICompatibilityBuild(check, root: root.appendingPathComponent("cli-probe"))
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
    let ignored = BlockedSessionDetector.detect(in: stopped.0).first!.stabilized(from: nil)
    try Data([0xff]).write(to: current)
    for _ in 0..<3 {
        let scan = worker.read(watchedIDs: [], watchedPaths: [], ignoredPauses: [id: ignored], protectedIDs: [])
        check(scan.1 == nil && scan.0.isEmpty && scan.2.contains(where: { $0.stage == "ignored_rollout_parse.decode_utf8" }),
            "a verified stopped replacement retires the old segment's running cache before ignore")
    }
}

// A standards-compliant Zstandard frame with raw blocks: no test-time compressor dependency.
func compressedRolloutFixture(_ data: Data) -> Data {
    var frame = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
    let size = UInt32(data.count)
    for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8(truncatingIfNeeded: size >> shift)) }
    var offset = 0
    repeat {
        let count = min(128 * 1024, data.count - offset)
        let header = UInt32(count << 3) | (offset + count == data.count ? 1 : 0)
        for shift in stride(from: 0, to: 24, by: 8) { frame.append(UInt8(truncatingIfNeeded: header >> shift)) }
        frame.append(data[offset..<(offset + count)]); offset += count
    } while offset < data.count
    return frame
}

private func checkCompressedSessions(_ check: (Bool, String) -> Void, home: URL) throws {
    let directory = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID().uuidString
    let plain = directory.appendingPathComponent("rollout-\(id)_\(UUID().uuidString).jsonl")
    let zipped = plain.appendingPathExtension("zst")
    let compressedBlock = home.appendingPathComponent("compressed-block.jsonl.zst")
    try Data(base64Encoded: "KLUv/QRYrQQAUskdHGBrdYZH4xd01/anxqTP6R+CvBBAI44bkCEwWjkJEhVEcsu8U8KIsGUyfXS3PVszS7j1YSllOARJHYmgSr8uYWte+ProCoasl10s4Hm+k+nGSwS+7hjI0QtJVQdJVTXp1927s+5aVJomj956IVviY17++sqm7wQJAOzPeujlY4JLlgHByGtdvGQoDAiQSVIyUAbyln1l")!.write(to: compressedBlock)
    check(SessionWatcher.parse(url: compressedBlock, mtime: Date())?.currentTurnID == "compressed-block", "vendored decoder reads real compressed blocks and checksum")
    try FileManager.default.removeItem(at: compressedBlock)
    let date = Date(timeIntervalSince1970: 1_792_800_000)
    func record(_ kind: String, _ payload: [String: Any], _ seconds: Double) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": kind, "timestamp": ISO8601DateFormatter().string(from: date.addingTimeInterval(seconds)), "payload": payload])
        data.append(10); return data
    }
    var trace = try record("session_meta", ["id": id, "cwd": home.path], 0)
    trace.append(try record("event_msg", ["type": "task_started", "turn_id": "one"], 1))
    try trace.write(to: plain)
    var db: OpaquePointer?
    sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db)
    defer { sqlite3_close(db) }
    check(sqlite3_exec(db, "CREATE TABLE threads(id TEXT, rollout_path TEXT); INSERT INTO threads VALUES('\(id)', '\(plain.path)');", nil, nil, nil) == SQLITE_OK, "compressed fixture canonical state")
    var logs: OpaquePointer?
    sqlite3_open(home.appendingPathComponent("logs_2.sqlite").path, &logs)
    defer { sqlite3_close(logs) }
    check(sqlite3_exec(logs, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil) == SQLITE_OK, "compressed fixture logs")
    let worker = SessionScanWorker(codexHome: home)
    let first = worker.read(watchedIDs: [id])
    check(first.1 == nil && first.0.first?.taskRunning == true, "plain task running before compression and stop")
    trace.append(try record("event_msg", ["type": "error", "turn_id": "one", "message": "usage_limit_reached"], 2))
    try compressedRolloutFixture(trace).write(to: zipped)
    try FileManager.default.removeItem(at: plain)
    let zippedRead = worker.read(watchedIDs: [id])
    check(zippedRead.1 == nil && zippedRead.0.count == 1 && zippedRead.0.first?.quotaTurnID == "one" && zippedRead.0.first?.currentRolloutVerified == true, "canonical plain path transparently follows compressed segment")
    check(worker.read(watchedIDs: [id]).0 == zippedRead.0, "compressed cache preserves facts")
    check(SessionWatcher.parse(url: plain, mtime: date)?.quotaTurnID == "one", "preflight resolves missing plain to compressed")
    check(SessionWatcher.rolloutThreadID(zipped) == id, "compressed segmented filename retains thread owner")
    let ignored = BlockedSessionDetector.detect(in: zippedRead.0).first!.stabilized(from: nil)
    try Data([0xff]).write(to: zipped)
    for _ in 0..<3 {
        let scan = worker.read(watchedIDs: [], watchedPaths: [], ignoredPauses: [id: ignored], protectedIDs: [])
        check(scan.1 == nil && scan.0.isEmpty && scan.2.contains(where: { $0.stage == "ignored_rollout_parse" }),
            "a verified compressed stop retires the plain running cache before ignore")
    }
    check(SessionScanWorker(codexHome: home).read(watchedIDs: [], ignoredPauses: [id: ignored]).1 == nil,
        "warm ignored compression has the same isolation as a fresh worker")
    try compressedRolloutFixture(trace).write(to: zipped)
    try trace.write(to: plain)
    try Data([0xff]).write(to: zipped)
    check(worker.read(watchedIDs: [id]).1 == nil, "plain wins when compressed sibling is damaged")
    try FileManager.default.removeItem(at: plain)
    check(worker.read(watchedIDs: [id]).1 != nil, "damaged compressed frame fails closed")
    try compressedRolloutFixture(trace).dropLast().write(to: zipped)
    check(worker.read(watchedIDs: [id]).1 != nil, "truncated compressed frame cannot reuse successful cached pause")
    try compressedRolloutFixture(trace).write(to: zipped)
    check(worker.read(watchedIDs: [id]).1 == nil, "repaired compressed frame recovers")
    let tail = try RolloutTailReader(url: zipped)
    check(try tail.read(upToCount: 65536)?.isEmpty == true, "cold desktop observation waits for materialization")
    let response = try record("event_msg", ["type": "agent_message", "turn_id": "two", "message": "done"], 5)
    var materialized = trace; materialized.append(response)
    try materialized.write(to: plain)
    check(try tail.read(upToCount: 65536) == response, "desktop receipt follows materialized plain log from validated baseline")
    try tail.close()
    try FileManager.default.removeItem(at: plain)
    let mismatchTail = try RolloutTailReader(url: zipped)
    try Data("different rollout".utf8).write(to: plain)
    do { _ = try mismatchTail.read(upToCount: 65536); check(false, "materialized replacement must match compressed baseline") }
    catch { check(true, "materialized replacement must match compressed baseline") }
    try mismatchTail.close()

    try FileManager.default.removeItem(at: plain)
    try Data([0xff]).write(to: zipped)
    for _ in 0..<3 {
        let scan = worker.read(watchedIDs: [], ignoredPauses: [id: ignored])
        check(scan.1 == nil && scan.0.isEmpty && scan.2.contains(where: { $0.stage == "ignored_rollout_parse" }), "ignored corrupt old episode is isolated with diagnostics across refreshes")
    }
    check(try SessionWatcher.freshBlockedSessions(codexHome: home, watchedIDs: [], worker: worker).isEmpty, "preflight scan retains ignored context")
    check(worker.read(watchedIDs: [id]).1 != nil, "explicit preflight target overrides ignored isolation")
    check(worker.read(watchedIDs: [], watchedPaths: [plain]).1 != nil, "protected in-flight path overrides ignored isolation")
    check(worker.read(watchedIDs: []).1 != nil, "preflight retains watcher protected paths")
    _ = worker.read(watchedIDs: [], watchedPaths: [], protectedIDs: [id])
    check(worker.read(watchedIDs: []).1 != nil, "preflight retains watcher busy thread IDs")
    try FileManager.default.removeItem(at: zipped)
    check(worker.read(watchedIDs: []).1 != nil, "missing busy thread remains monitored outside recent files")
    try Data([0xff]).write(to: zipped)
    _ = worker.read(watchedIDs: [], protectedIDs: [])
    let restarted = SessionScanWorker(codexHome: home)
    check(restarted.read(watchedIDs: [], ignoredPauses: [id: ignored]).1 == nil, "restored ignored pause context isolates corrupt file after restart")
    let oldStop = Int(ignored.blockedAt.timeIntervalSince1970)
    func logStop(_ row: Int, _ turn: String, _ at: Int) {
        let sql = "INSERT INTO logs VALUES(\(row), \(at), 0, 'codex_core::session::turn', '\(id)', 'turn_id=\(turn) session_task.run:run_turn: Turn error: You''ve hit your usage limit.')"
        check(sqlite3_exec(logs, sql, nil, nil, nil) == SQLITE_OK, "ignored episode quota log fixture")
    }
    logStop(1, "one", oldStop)
    check(worker.read(watchedIDs: []).1 == nil, "old quota log cannot reintroduce ignored corrupt episode")
    logStop(2, "two", oldStop)
    check(worker.read(watchedIDs: []).1 != nil, "same-time different-turn stop overrides ignored isolation")
    logStop(3, "one", oldStop + 10)
    check(worker.read(watchedIDs: []).1 != nil, "newer quota log overrides ignored isolation")
    var next = try record("session_meta", ["id": id, "cwd": home.path], 0)
    next.append(try record("event_msg", ["type": "task_started", "turn_id": "two"], 20))
    next.append(try record("event_msg", ["type": "error", "turn_id": "two", "message": "usage_limit_reached"], 21))
    try compressedRolloutFixture(next).write(to: zipped)
    let newScan = worker.read(watchedIDs: [])
    let newPause = BlockedSessionDetector.detect(in: newScan.0).first?.stabilized(from: ignored)
    check(newScan.1 == nil && newPause?.episodeKey != ignored.episodeKey && newPause?.stoppedTurnID == "two", "ignored thread discovers a valid new pause episode")
    next = try record("session_meta", ["id": id, "cwd": home.path], 0)
    next.append(try record("event_msg", ["type": "task_started", "turn_id": "running"], 30))
    try compressedRolloutFixture(next).write(to: zipped)
    check(worker.read(watchedIDs: []).0.first?.taskRunning == true, "ignored thread still discovers running task")
    try Data([0xff]).write(to: zipped)
    check(worker.read(watchedIDs: []).1 != nil, "cached running task remains fail closed despite ignored old pause")

}

private func checkCompressedPingReceipts(_ check: (Bool, String) -> Void, home: URL) throws {
    let directory = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func row(_ kind: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": kind, "payload": payload])
        data.append(10); return data
    }
    func receipt(_ id: String, _ turn: String, completedTurn: String? = nil) throws -> Data {
        var data = try row("session_meta", ["id": id])
        data.append(try row("event_msg", ["type": "task_started", "turn_id": turn]))
        data.append(try row("response_item", ["role": "assistant", "content": [["text": "OK"]]]))
        data.append(try row("event_msg", ["type": "task_complete", "turn_id": completedTurn ?? turn]))
        return data
    }
    let old = directory.appendingPathComponent("rollout-old.jsonl")
    let history = try receipt(UUID().uuidString, UUID().uuidString)
    try history.write(to: old)
    let previous = Set(SessionWatcher.recentRollouts(codexHome: home, limit: Int.max).map(\.url))
    try compressedRolloutFixture(history).write(to: old.appendingPathExtension("zst"))
    try FileManager.default.removeItem(at: old)
    check(!PingReceipt.completed(home: home, excluding: previous), "compressed history cannot confirm a new ping")
    let id = UUID().uuidString, turn = UUID().uuidString
    let current = directory.appendingPathComponent("rollout-new.jsonl")
    let zipped = current.appendingPathExtension("zst")
    let completed = try receipt(id, turn)
    try completed.write(to: current)
    let plainReceipt = PingReceipt.read(home: home, excluding: previous)
    check(plainReceipt.threadID == id && plainReceipt.turnID == turn && plainReceipt.replied && plainReceipt.completed,
        "old history compression does not obscure the exact new ping completion")
    try compressedRolloutFixture(completed).write(to: zipped)
    try FileManager.default.removeItem(at: current)
    let compressedReceipt = PingReceipt.read(home: home, excluding: previous)
    check(compressedReceipt.threadID == id && compressedReceipt.turnID == turn && compressedReceipt.completed,
        "a compressed new ping retains exact thread and turn completion evidence")
    let alias = home.appendingPathComponent("sessions-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    let compressedPrevious: Set<URL> = [alias.appendingPathComponent(old.lastPathComponent).appendingPathExtension("zst")]
    try history.write(to: old)
    check(PingReceipt.completed(home: home, excluding: compressedPrevious), "materialized old history is excluded across compressed and symlink aliases")
    try FileManager.default.removeItem(at: old)
    try Data([0xff]).write(to: zipped)
    check(!PingReceipt.completed(home: home, excluding: previous), "a damaged compressed ping cannot be confirmed")
    try compressedRolloutFixture(completed).dropLast().write(to: zipped)
    check(!PingReceipt.completed(home: home, excluding: previous), "a truncated compressed ping cannot be confirmed")
    try compressedRolloutFixture(receipt(id, turn, completedTurn: UUID().uuidString)).write(to: zipped)
    check(!PingReceipt.completed(home: home, excluding: previous), "a different turn cannot complete a compressed ping")
    let replyOnly = try row("session_meta", ["id": id]) + row("event_msg", ["type": "task_started", "turn_id": turn]) + row("response_item", ["role": "assistant", "content": [["text": "OK"]]])
    try compressedRolloutFixture(replyOnly).write(to: zipped)
    check(!PingReceipt.completed(home: home, excluding: previous), "a compressed OK reply without task completion cannot confirm a ping")
    try compressedRolloutFixture(completed).write(to: zipped)
    let second = directory.appendingPathComponent("rollout-second.jsonl")
    try receipt(UUID().uuidString, UUID().uuidString).write(to: second)
    check(!PingReceipt.completed(home: home, excluding: previous), "multiple new logical sessions cannot confirm a ping")
}

private func checkCLICompatibilityBuild(_ check: (Bool, String) -> Void, root: URL) throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let script = root.appendingPathComponent("Probes/check-cli-compatibility.sh")
    let dependencies = ["Core/Fixture.swift", "Codex/Fixture.swift", "Probes/CLICompatibility.swift",
        "Codex/ZstdBridge/KeeperZstd.c", "Codex/ZstdBridge/KeeperZstd.h", "Codex/ZstdBridge/module.modulemap",
        "Vendor/zstd/zstddeclib.c", "Vendor/zstd/LICENSE"]
    for path in dependencies {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: file)
    }
    try FileManager.default.copyItem(at: repository.appendingPathComponent("Probes/check-cli-compatibility.sh"), to: script)
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let compiler = """
    #!/bin/bash
    set -euo pipefail
    if [[ "${1:-}" == "--version" ]]; then echo fixture-compiler; exit 0; fi
    compiler=$(basename "$0")
    output=""
    includes_bridge=false
    links_bridge=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -o) output="$2"; shift ;;
            -I) [[ "$2" != Codex/ZstdBridge ]] || includes_bridge=true; shift ;;
            *.o) [[ ! -f "$1" ]] || links_bridge=true ;;
        esac
        shift
    done
    if [[ "$compiler" == swiftc ]]; then
        [[ "$includes_bridge" == true && "$links_bridge" == true ]] || exit 9
        printf '#!/bin/bash\\nexit 0\\n' > "$output"
        chmod +x "$output"
    else
        touch "$output"
    fi
    echo "$compiler" >> build-events
    """
    for name in ["clang", "swiftc"] {
        let file = bin.appendingPathComponent(name)
        try compiler.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    func run() throws -> (Int32, Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--identity"]
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": bin.path + ":/usr/bin:/bin"]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        let events = (try? String(contentsOf: root.appendingPathComponent("build-events"), encoding: .utf8)) ?? ""
        return (process.terminationStatus, events.split(separator: "\n").count)
    }
    let initial = try run()
    check(initial.0 == 0 && initial.1 == 2, "CLI compatibility probe compiles and links its C decoder bridge")
    let unchanged = try run()
    check(unchanged.0 == 0 && unchanged.1 == initial.1, "unchanged CLI compatibility dependencies reuse the probe")
    for (index, path) in dependencies.dropFirst(3).enumerated() {
        try Data("changed dependency\n".utf8).write(to: root.appendingPathComponent(path))
        let rebuilt = try run()
        check(rebuilt.0 == 0 && rebuilt.1 == initial.1 + 2 * (index + 1),
            "CLI compatibility rebuilds when only its decoder dependency changes: " + path)
    }
}

@MainActor func checkIgnoredPauseAppState(_ check: (Bool, String) -> Void, home: URL) async throws {
    let directory = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID().uuidString
    let file = directory.appendingPathComponent("rollout-\(id).jsonl.zst")
    try Data([0xff]).write(to: file)
    var logs: OpaquePointer?
    sqlite3_open(home.appendingPathComponent("logs.sqlite").path, &logs)
    defer { sqlite3_close(logs) }
    check(sqlite3_exec(logs, "CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, target TEXT, thread_id TEXT, feedback_log_body TEXT)", nil, nil, nil) == SQLITE_OK, "AppState ignored fixture logs")
    let target = BlockedSession(id: id, project: "ignored", cwd: home.path, blockedAt: Date().addingTimeInterval(-3600),
        fiveHourResetAt: nil, weeklyResetAt: nil, fileURL: file, pauseID: "\(id):turn:old", stoppedTurnID: "old")
    var choices = ResumeChoices(); choices.ignoredEpisodes = [target.episodeKey]
    struct RuntimeFixture: Encodable {
        let confirmed: [String: BlockedSession]
        let pauseRegistry: [String: BlockedSession]
        let accounts: [String: String] = [:]
        let workspaces: [String: String] = [:]
        let held: [String] = []
        let choices: ResumeChoices
    }
    let runtime = home.appendingPathComponent("pending-runtime.json")
    try JSONEncoder().encode(RuntimeFixture(confirmed: [id: target], pauseRegistry: [id: target], choices: choices)).write(to: runtime)
    let suite = "keeper.ignored-compressed." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "enabled")
    for restart in 0..<2 {
        let state = AppState(provider: FakePingUsage(account: "fixture"), defaults: defaults, runtimeURL: runtime, codexHome: home, startMonitoring: false)
        for refresh in 0..<3 {
            let old = state.sessions.scannedAt
            state.sessions.refresh()
            let deadline = Date().addingTimeInterval(3)
            while state.sessions.scannedAt == old && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            check(state.sessions.scannedAt != old && state.sessions.detectionError == nil && state.sessions.ignoredPauses[id]?.episodeKey == target.episodeKey,
                "AppState keeps durable ignored pause after filtered confirmed clears: restart \(restart), refresh \(refresh)")
        }
        state.sessions.stop(); state.usage.stop()
    }
}
