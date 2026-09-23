import Foundation
import CryptoKit

struct ResumeReceipt: Equatable {
    let threadID: String
    let turnID: String
    let message: String
}

protocol ResumeTransport {
    func resume(_ target: BlockedSession, prompt: String) throws -> ResumeReceipt
    func cancel()
}

extension ResumeTransport { func cancel() {} }

/// A desktop-owned task must be continued by its existing writer. Only unowned
/// tasks use a separate app-server. Never fall back after a submission may exist.
final class OwnedSessionResumeTransport: ResumeTransport {
    private let makeDesktop: () throws -> DesktopConnection
    private let fallback: ResumeTransport
    private let lock = NSLock()
    private var desktop: DesktopConnection?
    private var stopped = false

    init(makeDesktop: @escaping () throws -> DesktopConnection = { try DesktopIPCClient() },
         fallback: ResumeTransport = AppServerResumeTransport()) {
        self.makeDesktop = makeDesktop; self.fallback = fallback
    }

    func cancel() {
        lock.lock(); stopped = true; let connection = desktop; lock.unlock()
        connection?.cancel(); fallback.cancel()
    }

    func resume(_ target: BlockedSession, prompt: String) throws -> ResumeReceipt {
        let connection = try? makeDesktop()
        lock.lock(); desktop = connection; let cancelled = stopped; lock.unlock()
        guard !cancelled else { throw CodexConnectionError.ended }
        defer { lock.lock(); desktop = nil; lock.unlock() }
        guard let connection, let owner = try connection.owner(of: target.id) else {
            do { return try fallback.resume(target, prompt: prompt) }
            catch CodexConnectionError.server(let message) where message.contains("already has an active writer") {
                throw CodexConnectionError.server("原任务仍由 Codex 占用，但桌面控制通道不可用；未发送继续")
            }
        }
        let file = try FileHandle(forReadingFrom: target.fileURL)
        defer { try? file.close() }
        try file.seekToEnd()
        let turnID = try connection.start(threadID: target.id, prompt: prompt, owner: owner)
        var monitor = ResumeTurnMonitor(turnID: turnID)
        while true {
            lock.lock(); let cancelled = stopped; lock.unlock()
            guard !cancelled else { throw CodexConnectionError.ended }
            let data = try file.read(upToCount: 65536) ?? Data()
            if try monitor.consume(data) {
                return ResumeReceipt(threadID: target.id, turnID: turnID, message: "桌面原任务续跑轮次已完成")
            }
            if data.isEmpty { Thread.sleep(forTimeInterval: 1) }
        }
    }
}

/// Verify the specific turn acknowledged by the owner, not another task's output.
struct ResumeTurnMonitor {
    let turnID: String
    private var buffer = Data()
    private var currentTurn: String?

    init(turnID: String) { self.turnID = turnID }

    mutating func consume(_ data: Data) throws -> Bool {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  row["type"] as? String == "event_msg", let payload = row["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            let eventTurn = payload["turn_id"] as? String
            if type == "task_started" { currentTurn = eventTurn }
            guard (eventTurn ?? currentTurn) == turnID else { continue }
            if type == "turn_aborted" { throw CodexConnectionError.server("续跑已停止，请在 Codex 查看原任务") }
            if type == "error", payload["will_retry"] as? Bool != true {
                throw CodexConnectionError.server(payload["message"] as? String ?? "续跑出错，请在 Codex 查看原任务")
            }
            if type == "task_complete", eventTurn == turnID {
                if let error = payload["error"] as? [String: Any] {
                    throw CodexConnectionError.server(error["message"] as? String ?? "续跑未完成")
                }
                return true
            }
        }
        guard buffer.count <= 8 * 1024 * 1024 else { throw CodexConnectionError.invalidResponse }
        return false
    }
}

final class AppServerResumeTransport: ResumeTransport {
    var makeTransport: () throws -> CodexTransport
    private let lock = NSLock()
    private var activeClient: CodexTransport?
    init(makeTransport: @escaping () throws -> CodexTransport = { try AppServerClient() }) { self.makeTransport = makeTransport }
    func cancel() {
        lock.lock(); let client = activeClient; lock.unlock()
        client?.close()
    }
    func resume(_ target: BlockedSession, prompt: String) throws -> ResumeReceipt {
        let client = try makeTransport()
        lock.lock(); activeClient = client; lock.unlock()
        defer { client.close(); lock.lock(); activeClient = nil; lock.unlock() }
        // No cwd/model/approval/sandbox overrides: retain the original session configuration.
        let resumed = try client.request("thread/resume", params: ["threadId": target.id])
        guard let thread = resumed["thread"] as? [String: Any], thread["id"] as? String == target.id,
              resumed["cwd"] as? String == target.cwd else { throw CodexConnectionError.server("恢复的会话或工作目录与原任务不一致") }
        if let status = thread["status"] as? [String: Any], status["type"] as? String == "active" {
            throw CodexConnectionError.server("原任务已经运行，取消重复续跑")
        }
        let started = try client.request("turn/start", params: ["threadId": target.id, "input": [["type": "text", "text": prompt, "text_elements": []]]])
        guard let turn = started["turn"] as? [String: Any], let turnID = turn["id"] as? String else { throw CodexConnectionError.invalidResponse }
        // A valid long task may run for hours; only shutdown, failure or approval stops it.
        do {
            while true {
                let message: [String: Any]
                do { message = try client.nextMessage(timeout: 30) }
                catch CodexConnectionError.timeout { continue }
                if message["method"] != nil && message["id"] != nil { throw CodexConnectionError.approvalRequired }
                guard let params = message["params"] as? [String: Any], params["threadId"] as? String == target.id else { continue }
                if message["method"] as? String == "turn/completed", let result = params["turn"] as? [String: Any], result["id"] as? String == turnID {
                    guard result["status"] as? String == "completed" else { throw CodexConnectionError.server("续跑已停止，请在 Codex 检查原任务") }
                    return ResumeReceipt(threadID: target.id, turnID: turnID, message: "续跑轮次已完成")
                }
            }
        } catch {
            // Stop our own turn on timeout or approval. Never answer an approval request.
            _ = try? client.request("turn/interrupt", params: ["threadId": target.id, "turnId": turnID])
            throw error
        }
    }
}

enum WorkspaceGuard {
    static let reminder = "Keeper 自动续跑提醒：请先检查项目当前文件和任务进度，再继续。"

    static func resumePrompt(_ body: String, before: String?, after: String?, reminderEnabled: Bool) -> String {
        guard reminderEnabled else { return body }
        if let before, before == after { return body }
        return reminder + "\n" + body
    }

    static func fingerprint(cwd: String) -> String? {
        let root = URL(fileURLWithPath: cwd)
        guard cwd.hasPrefix("/"), let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: []) else { return nil }
        var records: [String] = []
        for case let url as URL in enumerator {
            if [".git", "node_modules", ".build", "build", "DerivedData"].contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            guard records.count < 20000, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
            if values.isRegularFile == true {
                records.append("\(url.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        var gitDirectory = root.appendingPathComponent(".git")
        if let pointer = try? String(contentsOf: gitDirectory, encoding: .utf8), pointer.hasPrefix("gitdir:") {
            let path = pointer.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
        }
        for path in ["HEAD", "index", "packed-refs"] {
            if let data = try? Data(contentsOf: gitDirectory.appendingPathComponent(path)) { records.append("git/\(path):\(SHA256.hash(data: data))") }
        }
        if let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8), head.hasPrefix("ref: ") {
            let ref = head.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            var commonDirectory = gitDirectory
            if let common = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) {
                commonDirectory = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDirectory).standardizedFileURL
            }
            if let packed = try? Data(contentsOf: commonDirectory.appendingPathComponent("packed-refs")) { records.append("common-refs:\(SHA256.hash(data: packed))") }
            if let data = try? Data(contentsOf: commonDirectory.appendingPathComponent(ref)) { records.append("ref:\(SHA256.hash(data: data))") }
        }
        return SHA256.hash(data: Data(records.sorted().joined(separator: "\n").utf8)).description
    }
}

struct ResumePreflight {
    let usage: UsageSnapshot
    let session: SessionActivity

    static func read(target: BlockedSession, provider: UsageProvider, codexHome: URL = CodexEnvironment.home) throws -> ResumePreflight {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.cwd, isDirectory: &directory), directory.boolValue,
              !target.fileURL.pathComponents.contains("archived_sessions"),
              let session = SessionWatcher.parse(url: target.fileURL, mtime: Date()), session.id == target.id,
              !session.isSubagent,
              (session.lastUserMessageAt ?? .distantPast) <= target.blockedAt,
              (session.lastTaskStartedAt ?? .distantPast) <= target.blockedAt,
              (session.lastAbortedAt ?? .distantPast) <= target.blockedAt,
              (session.lastAssistantMessageAt ?? .distantPast) <= target.blockedAt,
              !session.taskRunning else { throw CodexConnectionError.server("原任务已继续、被归档或工作目录已改变，取消续跑") }
        let usage = try provider.read()
        let blocked = try SessionWatcher.freshBlockedSessions(codexHome: codexHome, watchedIDs: [target.id])
        guard blocked.contains(where: { $0.episodeKey == target.episodeKey }) else {
            throw CodexConnectionError.server("原任务的额度停止记录已变化，取消续跑")
        }
        return ResumePreflight(usage: usage, session: session)
    }
}
