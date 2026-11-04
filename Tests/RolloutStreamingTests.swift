import Foundation
import CryptoKit
import AppKit

func checkRolloutStreaming(_ check: (Bool, String) -> Void, root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try checkRolloutProjection(check, root: root.appendingPathComponent("projection"))
    try checkCompressedRolloutStreaming(check, root: root.appendingPathComponent("compressed"))
}

private func checkRolloutProjection(_ check: (Bool, String) -> Void, root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let large = String(repeating: "body ", count: 200_000)
    let payloads: [[String: Any]] = [
        ["type": "function_call_output", "output": large],
        ["type": "function_call_output", "output": large + "APPROVAL DENIED" + large],
        ["type": "custom_tool_call_output", "output": "UsEr ReJeCtEd"],
        ["type": "function_call_output", "output": " \n\t"],
        ["type": "function_call_output", "output": ["result": "done"]],
        ["type": "message", "role": "assistant", "content": [["text": large]], "unused": ["nested": [large]]],
        ["type": "message", "role": "assistant", "content": [["text": ""], ["text": "\n"]]],
        ["type": "message", "role": "assistant", "content": [["text": ""], ["text": "done"]]],
        ["type": "message", "role": "assistant", "content": [["text": "done"], "wrong type"]],
        ["type": "message", "role": "assistant", "content": ["", "done"]],
        ["type": "reasoning", "summary": [["text": large]], "content": NSNull()],
        ["type": "reasoning", "summary": [" \n", "done"]],
        ["type": "reasoning", "summary": [["text": 1]], "content": [["text": "done"]]],
        ["type": "agent_message", "message": large],
        ["type": "agent_reasoning", "text": large],
        ["type": "agent_reasoning_raw_content", "message": false, "text": "done"],
        ["type": "task_complete", "last_agent_message": large, "error": NSNull()],
        ["type": "task_complete", "last_agent_message": large, "error": ["nested": "quota_exhausted"]]
    ]
    for (index, payload) in payloads.enumerated() {
        try autoreleasepool {
            let kind = ["agent_message", "agent_reasoning", "agent_reasoning_raw_content", "task_complete"].contains(payload["type"] as? String ?? "") ? "event_msg" : "response_item"
            let data = try JSONSerialization.data(withJSONObject: ["type": kind, "payload": payload])
            let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let projected = SessionRolloutDecoder.decode(data)
            check(projected != nil && ResumeModelActivity.rollout(projected!) == ResumeModelActivity.rollout(original),
                "selective rollout decoding preserves real model-activity and approval-denial evidence: \(index)")
            if payload["error"] == nil || payload["error"] is NSNull {
                let retained = try projected.map { try JSONSerialization.data(withJSONObject: $0).count } ?? Int.max
                check(retained < 1024, "selective rollout projection does not retain message/tool bodies: \(index)")
            }
        }
    }
    for json in [
        #"{"type":"response_item","payload":{"type":"message","type":"function_call_output","role":"assistant","content":[{"text":"done"}],"output":"approval denied"}}"#,
        #"{"ty\u0070e":"response_item","payload":{"type":"function_call_output","output":"\u0061pproval denied"}}"#
    ] {
        let data = Data(json.utf8)
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        check(SessionRolloutDecoder.decode(data).map(ResumeModelActivity.rollout) == ResumeModelActivity.rollout(original),
            "duplicate/escaped JSON keys retain the original model-evidence decision")
    }
    let id = UUID().uuidString
    let file = root.appendingPathComponent("rollout-\(id).jsonl")
    let base = Date(timeIntervalSince1970: 1_792_800_000)
    func row(_ kind: String, _ payload: [String: Any], _ seconds: Double, timestamp: Bool = true) throws -> Data {
        var object: [String: Any] = ["type": kind, "payload": payload]
        if timestamp { object["timestamp"] = ISO8601DateFormatter().string(from: base.addingTimeInterval(seconds)) }
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10); return data
    }
    func metadata(_ extra: [String: Any] = [:]) throws -> Data {
        try row("session_meta", extra.merging(["id": id, "cwd": root.path]) { _, new in new }, 0)
    }
    let reset = base.addingTimeInterval(18000).timeIntervalSince1970
    let limits: [String: Any] = ["limit_id": "codex", "primary": ["used_percent": 40, "window_minutes": 300, "resets_at": reset]]
    func tokens(_ total: Int) -> [String: Any] {
        ["type": "token_count", "info": ["total_token_usage": ["total_tokens": total], "last_token_usage": ["total_tokens": 10]], "rate_limits": limits]
    }
    let texts: [(Any, Bool, Bool)] = [
        ([["text": "<environment_context>fixture"]], false, false),
        ([["text": "# AGENTS.md fixture"]], false, false),
        ([["text": ""], ["text": "<environment_context>fixture"]], true, true),
        ([["text": "<environment_"], ["text": "context>fixture"]], true, true),
        ([["text": String(repeating: " ", count: 100)], ["text": "real input"]], true, true),
        ([["text": ""]], true, false),
        ([["text": NSNull()]], true, false),
        (["<environment_context>fixture"], true, false),
        ([["text": "real input"], 7], true, false)
    ]
    for (index, item) in texts.enumerated() {
        var trace = try metadata()
        trace += try row("event_msg", tokens(10), 1)
        trace += try row("response_item", ["type": "message", "role": "user", "content": item.0,
            "internal_chat_message_metadata_passthrough": ["content_item_kinds": ["user.text"]]], 2)
        trace += try row("event_msg", tokens(20), 3)
        try trace.write(to: file)
        let parsed = try SessionRolloutReader().read(url: file, mtime: base)
        check((parsed?.lastUserMessageAt != nil) == item.1 && (parsed?.userUsage != nil) == item.2,
            "selective content preserves joined-text prefix/empty/type semantics: \(index)")
    }
    for key in ["forked_from_id", "history_base"] {
        var trace = try metadata([key: NSNull()])
        trace += try row("event_msg", ["type": "task_started", "turn_id": "inherited"], 0)
        try trace.write(to: file)
        check(try SessionRolloutReader().read(url: file, mtime: base)?.taskRunning == false,
            "a null-valued inherited-history key still isolates copied events: " + key)
    }
    var trace = try metadata(["source": ["subagent": NSNull()]])
    trace += try row("event_msg", ["type": "task_started", "turn_id": "one"], 1)
    trace += try row("event_msg", ["type": "error", "turn_id": "one", "unknown": ["nested": ["code": "INSUFFICIENT_QUOTA"]]], 2)
    try trace.write(to: file)
    let error = try SessionRolloutReader().read(url: file, mtime: base)
    check(error?.isSubagent == true && error?.quotaBlockedAt == base.addingTimeInterval(2) && error?.turns["one"]?.terminal == .quotaStopped,
        "null subagent presence and quota markers in unknown nested error fields remain authoritative")
    trace = try metadata()
    trace += try row("event_msg", ["type": "task_started", "turn_id": "one"], 1)
    trace += try row("event_msg", ["type": "agent_message", "message": "done", "content": false, "rate_limits": []], 2, timestamp: false)
    try trace.write(to: file)
    let legacy = try SessionRolloutReader().read(url: file, mtime: base.addingTimeInterval(40))
    check(legacy?.lastAssistantMessageAt == base.addingTimeInterval(40) && legacy?.turns["one"]?.responseAt == nil,
        "wrong optional field types do not discard valid activity or invent a timestamped response")
}

private func checkCompressedRolloutStreaming(_ check: (Bool, String) -> Void, root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let compressed = root.appendingPathComponent("stream.jsonl.zst")
    let text = Data(("first\n" + String(repeating: "你好🌟", count: 12_000) + "\nlast without newline").utf8)
    let split = text.firstIndex(of: 0xe4)! + 1
    let frames = compressedRolloutFixture(Data(text.prefix(split))) + compressedRolloutFixture(Data(text.suffix(text.count - split)))
    try frames.write(to: compressed)
    var hash = SHA256(), count = 0, sizes: [Int] = []
    try RolloutFile.forEachChunk(compressed, chunkSize: 37) { chunk in
        hash.update(data: chunk); count += chunk.count; sizes.append(chunk.count)
    }
    check(count == text.count && sizes.dropLast().allSatisfy { $0 == 37 } && sizes.last == (text.count - 1) % 37 + 1 &&
        Data(hash.finalize()) == Data(SHA256.hash(data: text)),
        "concatenated zstd frames stream through a fixed-size output buffer, including a split UTF-8 character")
    var lines: [Data] = []
    try RolloutFile.forEachLine(compressed, chunkSize: 7) { lines.append($0) }
    check(lines == text.split(separator: 10).map { Data($0) },
        "compressed line streaming joins UTF-8 across blocks and delivers the final line without a newline")
    check(try RolloutFile.read(compressed) == text, "full-data callers retain exact concatenated-frame compatibility")
    try compressedRolloutFixture(Data()).write(to: compressed)
    check(try RolloutFile.read(compressed).isEmpty, "a complete empty zstd frame is distinct from a missing/truncated frame")
    for (name, data) in [("empty", Data()), ("truncated", frames.dropLast()), ("corrupt-tail", frames + Data([0xff]))] {
        try data.write(to: compressed)
        do { try RolloutFile.forEachChunk(compressed) { _ in }; check(false, "compressed stream must reject " + name) }
        catch { check(true, "compressed stream must reject " + name) }
    }
    let id = UUID().uuidString
    let plain = root.appendingPathComponent("rollout-\(id).jsonl")
    let zipped = plain.appendingPathExtension("zst")
    let base = Date(timeIntervalSince1970: 1_792_800_000)
    func row(_ kind: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": kind,
            "timestamp": ISO8601DateFormatter().string(from: base), "payload": payload]); data.append(10); return data
    }
    var baseline = try row("session_meta", ["id": id, "cwd": root.path])
    baseline += try row("response_item", ["type": "message", "role": "user", "content": [["text": String(repeating: "body", count: 30_000)]]])
    try compressedRolloutFixture(baseline).write(to: zipped)
    let tail = try RolloutTailReader(url: zipped)
    check(try tail.read(upToCount: 65536)?.isEmpty == true, "streamed cold-tail verification waits for a materialized rollout")
    let response = try row("event_msg", ["type": "agent_message", "message": "done"])
    var changed = baseline
    changed[changed.count / 2] = changed[changed.count / 2] == 0x61 ? 0x62 : 0x61
    try (changed + response).write(to: plain)
    do { _ = try tail.read(upToCount: 65536); check(false, "a changed middle byte must invalidate the whole compressed baseline") }
    catch { check(true, "a changed middle byte must invalidate the whole compressed baseline") }
    try tail.close(); try FileManager.default.removeItem(at: plain)
    let restored = try RolloutTailReader(url: zipped)
    try (baseline + response).write(to: plain)
    check(try restored.read(upToCount: 65536) == response, "bounded baseline verification positions the tail after exactly the original decompressed bytes")
    try restored.close(); try FileManager.default.removeItem(at: plain)
    var invalid = baseline; invalid.append(0xff)
    try compressedRolloutFixture(invalid).write(to: zipped)
    do { _ = try SessionRolloutReader().read(url: zipped, mtime: base); check(false, "compressed invalid UTF-8 must fail closed") }
    catch { check(true, "compressed invalid UTF-8 must fail closed") }
    try (compressedRolloutFixture(baseline) + Data([0xff])).write(to: zipped)
    do { _ = try SessionRolloutReader().read(url: zipped, mtime: base); check(false, "a corrupt later frame must not publish earlier parsed session facts") }
    catch { check(true, "a corrupt later frame must not publish earlier parsed session facts") }
    let usageHome = root.appendingPathComponent("usage-home")
    let usageDirectory = usageHome.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: usageDirectory, withIntermediateDirectories: true)
    let usageFile = usageDirectory.appendingPathComponent(zipped.lastPathComponent)
    try (compressedRolloutFixture(baseline) + Data([0xff])).write(to: usageFile)
    let usageReader = TokenUsageHistoryReader(home: usageHome)
    check(usageReader.read(now: base).unreadableFiles > 0 && usageReader.bytesRead == 0,
        "failed compressed statistics reads do not commit a partial cursor or decoded-byte count")
    try compressedRolloutFixture(baseline).write(to: usageFile)
    check(usageReader.read(now: base).unreadableFiles == 0 && usageReader.bytesRead == UInt64(baseline.count),
        "a repaired compressed statistics file starts from its complete original cursor")
}

@MainActor func checkImportantUpdateWindowRelease(_ check: (Bool, String) -> Void) {
    _ = NSApplication.shared
    let controller = ImportantUpdateWindowController(openReleasePage: { _ in })
    let release = AppRelease(pageURL: URL(string: "https://github.com/OM-KEN/Codex-Keeper/releases/tag/v1.1.0")!)!
    weak var previousWindow: NSWindow?
    weak var previousContent: NSView?
    autoreleasepool {
        check(controller.show(release), "important-update release fixture presents an actual hosting window")
        previousWindow = controller.window; previousContent = controller.window?.contentView
        controller.close()
        check(controller.window == nil, "closing the important-update prompt clears its owning controller")
    }
    let deadline = Date().addingTimeInterval(1)
    while (previousWindow != nil || previousContent != nil) && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    check(previousWindow == nil && previousContent == nil, "closed important-update window and hosting content are released")
    check(controller.show(release), "a released important-update prompt rebuilds and opens again")
    controller.window?.performClose(nil)
    check(controller.window == nil, "the titlebar close action releases the rebuilt important-update prompt too")
}
