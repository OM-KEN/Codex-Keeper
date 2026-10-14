import Foundation
import CryptoKit

struct ResumeReceipt: Equatable {
    let threadID: String
    let turnID: String
    let message: String
}

protocol ResumeTransport {
    func prepare(_ target: BlockedSession) throws
    func submit(_ target: BlockedSession, prompt: String, update: @escaping (ResumeTransportEvent) -> Void) throws
    func resume(_ target: BlockedSession, prompt: String) throws -> ResumeReceipt
    func cancel()
    var ownsSubmittedTask: Bool { get }
}

extension ResumeTransport {
    func cancel() {}
    var ownsSubmittedTask: Bool { false }
    func prepare(_ target: BlockedSession) throws {}
    // Small injected transports may complete synchronously; production channels split preparation and submission.
    func submit(_ target: BlockedSession, prompt: String, update: @escaping (ResumeTransportEvent) -> Void) throws {
        let receipt = try resume(target, prompt: prompt)
        update(.received(receipt, Date())); update(.responded(receipt.turnID, Date()))
        update(.ended(receipt.turnID, .completed, nil, Date()))
    }
    func resume(_ target: BlockedSession, prompt: String) throws -> ResumeReceipt {
        try prepare(target)
        let result = ResumeObservationResult()
        try submit(target, prompt: prompt) { result.consume($0, threadID: target.id) }
        return try result.wait()
    }
}

private final class ResumeObservationResult {
    private let condition = NSCondition()
    private var result: Result<ResumeReceipt, Error>?
    func consume(_ event: ResumeTransportEvent, threadID: String) {
        condition.lock(); defer { condition.unlock() }
        guard result == nil else { return }
        switch event {
        case .responded(let turn, _): result = .success(ResumeReceipt(threadID: threadID, turnID: turn, message: L10n.text("已继续")))
        case .notSubmitted(let message): result = .failure(ResumeSubmissionError(mayHaveSubmitted: false, underlying: CodexConnectionError.localizedMessage(message)))
        case .unknown(let message): result = .failure(ResumeSubmissionError(mayHaveSubmitted: true, underlying: CodexConnectionError.localizedMessage(message)))
        case .awaiting: result = .failure(CodexConnectionError.timeout)
        case .ended(_, let terminal, let message, _):
            result = .failure(terminal == .manualRequired ? CodexConnectionError.approvalRequired : CodexConnectionError.localizedMessage(message ?? L10n.text("续跑已停止，请在 Codex 检查原任务")))
        default: break
        }
        condition.broadcast()
    }
    func wait() throws -> ResumeReceipt {
        condition.lock(); defer { condition.unlock() }
        while result == nil { condition.wait() }
        return try result!.get()
    }
}

/// A desktop-owned task stays with its original writer. Ending our follower never interrupts it.
final class OwnedSessionResumeTransport: ResumeTransport {
    private let makeDesktop: () throws -> DesktopConnection
    private let fallback: ResumeTransport
    private let observationSeconds: TimeInterval
    private let lock = NSLock()
    private var desktop: DesktopConnection?
    private var owner: String?
    private var file: FileHandle?
    private var stopped = false
    private var usesFallback = false

    init(makeDesktop: @escaping () throws -> DesktopConnection = { try DesktopIPCClient() },
         fallback: ResumeTransport = AppServerResumeTransport(), observationSeconds: TimeInterval = 60) {
        self.makeDesktop = makeDesktop; self.fallback = fallback; self.observationSeconds = observationSeconds
    }
    var ownsSubmittedTask: Bool { lock.lock(); let uses = usesFallback; lock.unlock(); return uses && fallback.ownsSubmittedTask }
    func cancel() {
        lock.lock(); stopped = true; let connection = desktop; let file = file; lock.unlock()
        connection?.cancel(); try? file?.close(); fallback.cancel()
    }
    func prepare(_ target: BlockedSession) throws {
        let connection = try? makeDesktop()
        lock.lock(); desktop = connection; let cancelled = stopped; lock.unlock()
        guard !cancelled else { throw CodexConnectionError.ended }
        do {
            if let connection, let owner = try connection.owner(of: target.id) {
                let file = try FileHandle(forReadingFrom: target.fileURL)
                try file.seekToEnd()
                lock.lock(); self.owner = owner; self.file = file; lock.unlock()
            } else {
                connection?.cancel()
                lock.lock(); usesFallback = true; lock.unlock()
                try fallback.prepare(target)
            }
        } catch { cancel(); throw error }
    }
    func submit(_ target: BlockedSession, prompt: String, update: @escaping (ResumeTransportEvent) -> Void) throws {
        lock.lock(); let cancelled = stopped; let uses = usesFallback
        let connection = desktop; let owner = owner; let file = file; lock.unlock()
        guard !cancelled else { throw ResumeSubmissionError(mayHaveSubmitted: false, underlying: CodexConnectionError.ended) }
        if uses { try fallback.submit(target, prompt: prompt, update: update); return }
        guard let connection, let owner, let file else { throw ResumeSubmissionError(mayHaveSubmitted: false, underlying: CodexConnectionError.invalidResponse) }
        let turnID: String
        do { turnID = try connection.start(threadID: target.id, prompt: prompt, owner: owner) }
        catch {
            if let error = error as? ResumeSubmissionError, !error.mayHaveSubmitted { cancel(); throw error }
            update(.unknown(error.localizedDescription)); connection.cancel(); try? file.close()
            update(.observationEnded); return
        }
        update(.received(ResumeReceipt(threadID: target.id, turnID: turnID, message: L10n.text("已接收")), Date()))
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { connection.cancel(); try? file.close(); update(.observationEnded) }
            var monitor = ResumeTurnMonitor(turnID: turnID)
            let deadline = ProcessInfo.processInfo.systemUptime + observationSeconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                lock.lock(); let cancelled = stopped; lock.unlock()
                if cancelled { return }
                do {
                    let data = try file.read(upToCount: 65536) ?? Data()
                    if try monitor.consume(data) { update(.responded(turnID, monitor.responseAt ?? Date())); return }
                    if data.isEmpty { Thread.sleep(forTimeInterval: min(0.25, observationSeconds)) }
                } catch {
                    if let terminal = monitor.terminal { update(.ended(turnID, terminal, error.localizedDescription, Date())) }
                    else { update(.unknown(error.localizedDescription)) }
                    return
                }
            }
            update(.awaiting)
        }
    }
}

struct ResumeTurnMonitor {
    let turnID: String
    private var buffer = Data()
    private var currentTurn: String?
    private(set) var responseAt: Date?
    private(set) var terminal: ResumeTerminal?
    init(turnID: String) { self.turnID = turnID }
    mutating func consume(_ data: Data) throws -> Bool {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = row["payload"] as? [String: Any] else { continue }
            let type = payload["type"] as? String ?? ""
            let eventTurn = (payload["turn_id"] ?? payload["turnId"]) as? String
            if type == "task_started" || row["type"] as? String == "turn_context" { currentTurn = eventTurn }
            guard (eventTurn ?? currentTurn) == turnID else { continue }
            if type == "turn_aborted" { terminal = .aborted; throw CodexConnectionError.server("续跑已停止，请在 Codex 查看原任务") }
            if (type == "error" || type == "turn_failed"), payload["will_retry"] as? Bool != true {
                let message = payload["message"] as? String ?? "续跑出错，请在 Codex 查看原任务"
                terminal = ResumeModelActivity.quotaError(String(describing: payload)) ? .quotaStopped : .failed
                throw CodexConnectionError.server(message)
            }
            if type == "task_complete", let error = payload["error"] {
                terminal = ResumeModelActivity.quotaError(String(describing: error)) ? .quotaStopped : .failed
                throw CodexConnectionError.server((error as? [String: Any])?["message"] as? String ?? "续跑未完成")
            }
            if ResumeModelActivity.rollout(row) || (type == "task_complete" && eventTurn == turnID) {
                responseAt = UsageDecoder.timestamp(row["timestamp"] as? String) ?? Date()
                if type == "task_complete" { terminal = .completed }
                return true
            }
        }
        guard buffer.count <= 8 * 1024 * 1024 else { throw CodexConnectionError.invalidResponse }
        return false
    }
}

/// From the content request onward this object owns the writer and its sole event consumer.
final class AppServerResumeTransport: ResumeTransport {
    var makeTransport: () throws -> CodexTransport
    private let observationSeconds: TimeInterval
    private let lock = NSLock()
    private var activeClient: CodexTransport?
    private var submitted = false
    private var stopped = false
    init(makeTransport: @escaping () throws -> CodexTransport = { try AppServerClient() }, observationSeconds: TimeInterval = 60) {
        self.makeTransport = makeTransport; self.observationSeconds = observationSeconds
    }
    var ownsSubmittedTask: Bool { lock.lock(); defer { lock.unlock() }; return submitted && activeClient != nil }
    func cancel() {
        lock.lock(); stopped = true; let client = activeClient; activeClient = nil; submitted = false; lock.unlock()
        client?.close()
    }
    func prepare(_ target: BlockedSession) throws {
        let client = try makeTransport()
        lock.lock(); activeClient = client; let stopped = stopped; lock.unlock()
        if stopped { client.close(); throw CodexConnectionError.ended }
        do {
            let resumed = try client.request("thread/resume", params: ["threadId": target.id, "excludeTurns": true])
            guard let thread = resumed["thread"] as? [String: Any], thread["id"] as? String == target.id,
                  resumed["cwd"] as? String == target.cwd else { throw CodexConnectionError.server("恢复的会话或工作目录与原任务不一致") }
            if let status = thread["status"] as? [String: Any], status["type"] as? String == "active" {
                throw CodexConnectionError.server("原任务已经运行，取消重复续跑")
            }
        } catch { cancel(); throw error }
    }
    func submit(_ target: BlockedSession, prompt: String, update: @escaping (ResumeTransportEvent) -> Void) throws {
        lock.lock(); let client = activeClient; let stopped = stopped
        if !stopped, client != nil { submitted = true }; lock.unlock()
        guard let client, !stopped else { throw ResumeSubmissionError(mayHaveSubmitted: false, underlying: CodexConnectionError.ended) }
        var turnID: String?
        var receivedUptime: TimeInterval?
        do {
            let started = try client.request("turn/start", params: ["threadId": target.id,
                "input": [["type": "text", "text": prompt, "text_elements": []]]])
            guard let turn = started["turn"] as? [String: Any], let id = turn["id"] as? String else { throw CodexConnectionError.invalidResponse }
            turnID = id; receivedUptime = ProcessInfo.processInfo.systemUptime
            update(.received(ResumeReceipt(threadID: target.id, turnID: id, message: L10n.text("已接收")), Date()))
        } catch {
            if let error = error as? ResumeSubmissionError, !error.mayHaveSubmitted { cancel(); throw error }
            update(.unknown(error.localizedDescription))
        }
        let initialTurn = turnID; let initialUptime = receivedUptime
        let submissionRequestID = client.lastSubmissionRequestID
        DispatchQueue.global(qos: .utility).async { [self] in
            var turnID = initialTurn; var receivedUptime = initialUptime
            var responded = false; var awaiting = false; var manual = false
            var interruptedRequests = Set<String>()
            var deferredResponses: [String: Date] = [:]
            var deferredTerminals: [String: [String: Any]] = [:]
            var deferredRequests: [String: [[String: Any]]] = [:]
            var replay: [[String: Any]] = []
            while true {
                lock.lock(); let stopped = stopped; lock.unlock()
                if stopped { return }
                if !responded, !awaiting, let began = receivedUptime,
                   ProcessInfo.processInfo.systemUptime - began >= observationSeconds { awaiting = true; update(.awaiting) }
                let message: [String: Any]
                do { message = replay.isEmpty ? try client.nextMessage(timeout: min(1, max(0.01, observationSeconds))) : replay.removeFirst() }
                catch CodexConnectionError.timeout { continue }
                catch CodexConnectionError.ended {
                    cancel(); update(.ended(turnID, .disconnected, L10n.text("确认中"), Date())); return
                } catch { if !awaiting { awaiting = true; update(.unknown(error.localizedDescription)) }; Thread.sleep(forTimeInterval: 0.25); continue }
                // A late RPC reply still belongs to the only content request on this connection.
                if turnID == nil, message["method"] == nil, let submissionRequestID, message["id"] as? Int == submissionRequestID,
                   let result = message["result"] as? [String: Any], let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String {
                    turnID = id; receivedUptime = ProcessInfo.processInfo.systemUptime
                    update(.received(ResumeReceipt(threadID: target.id, turnID: id, message: L10n.text("已接收")), Date()))
                    if let at = deferredResponses[id] { responded = true; update(.responded(id, at)) }
                    replay = deferredRequests[id] ?? []
                    if let terminal = deferredTerminals[id] { replay.append(terminal) }
                    deferredResponses.removeAll(); deferredTerminals.removeAll(); deferredRequests.removeAll()
                    continue
                }
                if turnID == nil, message["method"] == nil, let submissionRequestID, message["id"] as? Int == submissionRequestID,
                   let error = message["error"] as? [String: Any] {
                    cancel(); update(.notSubmitted(CodexConnectionError.server(error["message"] as? String ?? "Codex 请求失败").localizedDescription)); return
                }
                guard let method = message["method"] as? String, let params = message["params"] as? [String: Any],
                      (params["threadId"] ?? params["thread_id"]) as? String == target.id else { continue }
                let turn = params["turn"] as? [String: Any]
                let eventTurn = (params["turnId"] ?? params["turn_id"] ?? turn?["id"]) as? String
                if turnID == nil, let candidate = eventTurn {
                    if ResumeModelActivity.appServer(method: method, params: params), deferredResponses[candidate] == nil { deferredResponses[candidate] = Date() }
                    if method == "turn/completed" { deferredTerminals[candidate] = message }
                    if message["id"] != nil, ResumeModelActivity.manualRequest(method) {
                        // Only routing/type evidence is retained; request body and model text are not saved.
                        deferredRequests[candidate, default: []].append(["id": message["id"]!, "method": method,
                            "params": ["threadId": target.id, "turnId": candidate]])
                    }
                    continue
                }
                guard let id = turnID, eventTurn == id else { continue }
                if message["id"] != nil {
                    if ResumeModelActivity.manualRequest(method), interruptedRequests.insert(String(describing: message["id"]!)).inserted {
                        manual = true; update(.manualRequested)
                        // The same consumer performs the interrupt and continues until actual terminal evidence.
                        _ = try? client.request("turn/interrupt", params: ["threadId": target.id, "turnId": id])
                    } else if !awaiting { awaiting = true; update(.awaiting) }
                    continue
                }
                if !responded, ResumeModelActivity.appServer(method: method, params: params) {
                    responded = true; update(.responded(id, Date()))
                }
                if method == "error", (params["willRetry"] ?? params["will_retry"]) as? Bool == true { continue }
                if method == "turn/completed", let turn, let status = turn["status"] as? String {
                    let error = turn["error"].map { String(describing: $0) }
                    let terminal: ResumeTerminal = manual ? .manualRequired : ResumeModelActivity.quotaError(error ?? "") ? .quotaStopped :
                        status == "completed" ? .completed : status == "interrupted" ? .aborted : .failed
                    cancel()
                    if !responded && terminal == .completed { update(.responded(id, Date())) }
                    update(.ended(id, terminal, error, Date())); return
                }
            }
        }
    }
}

enum WorkspaceGuard {
    static var reminder: String { L10n.text("Codex 额度已恢复，期间项目文件可能发生了变化。请先核对当前任务涉及的项目文件和进度，再继续该任务。") }

    static func resumePrompt(_ body: String, before: String?, after: String?, reminderEnabled: Bool) -> String {
        guard reminderEnabled else { return body }
        if let before, before == after { return body }
        return reminder + "\n\n" + body
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
        guard blocked.contains(where: { target.matchesPause($0) }) else {
            throw CodexConnectionError.server("原任务的额度停止记录已变化，取消续跑")
        }
        return ResumePreflight(usage: usage, session: session)
    }
}
