import Foundation
import Darwin

protocol PingTransport {
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider) throws -> UsageSnapshot
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void) throws -> UsageSnapshot
    func cancel()
}

extension PingTransport {
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void) throws -> UsageSnapshot {
        try ping(before: before, model: model, provider: provider)
    }
}

/// The goal is a confirmed subscription window, not a successful process exit or an OK reply.
enum PingConfirmation {
    static func accepts(before: UsageSnapshot, after: UsageSnapshot, now: Date) -> Bool {
        guard after.isFresh(at: now), let account = before.accountID, after.accountID == account,
              before.fiveHour != nil, let new = after.fiveHour else { return false }
        return before.activeFiveHourWindow == false && after.activeFiveHourWindow == true &&
            new.resetsAt > now && abs(new.resetsAt.timeIntervalSince(now) - 5 * 3600) < 300 &&
            new.usedPercent < 100 && (after.weekly?.usedPercent ?? 0) < 100
    }
}

struct PingReceipt {
    var threadID: String?
    var turnID: String?
    var replied = false
    var completed = false

    static func read(home: URL, excluding previous: Set<URL>) -> PingReceipt {
        let files = SessionWatcher.recentRollouts(codexHome: home, limit: 20).filter { !previous.contains($0.url) }
        guard files.count == 1, let file = files.first,
              let content = try? String(contentsOf: file.url, encoding: .utf8) else { return PingReceipt() }
        var receipt = PingReceipt()
        for line in content.split(separator: "\n") {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any] else { continue }
            if entry["type"] as? String == "session_meta", let id = payload["id"] as? String, UUID(uuidString: id) != nil { receipt.threadID = id }
            if payload["type"] as? String == "task_started" {
                receipt.turnID = (payload["turn_id"] as? String).flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
                receipt.replied = false; receipt.completed = false
            }
            if payload["role"] as? String == "assistant", receipt.turnID != nil {
                let text = (payload["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
                receipt.replied = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "OK"
            }
            if payload["type"] as? String == "task_complete", receipt.turnID != nil,
               payload["turn_id"] as? String == receipt.turnID {
                receipt.completed = receipt.replied && (payload["error"] == nil || payload["error"] is NSNull)
            }
            if payload["type"] as? String == "turn_aborted" { receipt.completed = false }
        }
        return receipt
    }
    static func completed(home: URL, excluding previous: Set<URL>) -> Bool {
        let receipt = read(home: home, excluding: previous)
        return receipt.threadID != nil && receipt.completed
    }
}

final class PTYPingTransport: PingTransport {
    private let mainHome: URL
    private let supportRoot: URL?
    private let executable: URL?
    private let timing: PingTiming
    init(codexHome: URL = CodexEnvironment.home, supportRoot: URL? = nil, binary: URL? = nil, timing: PingTiming = PingTiming()) {
        mainHome = codexHome; self.supportRoot = supportRoot; executable = binary; self.timing = timing
    }
    private let lock = NSLock()
    private var active: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; let process = active; lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            let end = Date().addingTimeInterval(1)
            while process.isRunning && Date() < end { usleep(10000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider) throws -> UsageSnapshot {
        try ping(before: before, model: model, provider: provider, progress: { _ in })
    }

    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void) throws -> UsageSnapshot {
        lock.lock(); cancelled = false; lock.unlock()
        let fm = FileManager.default
        guard model.model == "gpt-5.6-luna" else { throw CodexConnectionError.server("保活模型未经确认") }
        let reasoning = model.reasoningEffort.map { "model_reasoning_effort = \"\($0)\"" } ?? ""
        let root = supportRoot ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexKeeper/ping")
        let home = root.appendingPathComponent("home")
        let work = root.appendingPathComponent("work")
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let auth = try Data(contentsOf: mainHome.appendingPathComponent("auth.json"))
        let authURL = home.appendingPathComponent("auth.json")
        try auth.write(to: authURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        // This is Keeper's own empty directory, not an approval of a user project or a tool request.
        // TOML strings accept JSON escapes except the optional escaped forward slash.
        let quotedWork = String(data: try JSONSerialization.data(withJSONObject: work.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        let config = """
        model = "gpt-5.6-luna"
        \(reasoning)
        sandbox_mode = "read-only"
        approval_policy = "never"
        forced_login_method = "chatgpt"
        developer_instructions = "Reply only OK. Do not call tools or read files."
        [projects.\(quotedWork)]
        trust_level = "trusted"
        """
        try config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let binary = try executable ?? CodexLocator.binary()
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw CodexConnectionError.server("无法建立保活终端") }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        process.executableURL = binary
        // A positional prompt enters the real interactive TUI, bypassing no approval or onboarding UI.
        process.arguments = ["--no-alt-screen", "-C", work.path, "ok"]
        process.currentDirectoryURL = work
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        environment["TERM"] = "xterm-256color"
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        process.environment = environment
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        defer {
            if process.isRunning { process.terminate() }
            let end = Date().addingTimeInterval(1)
            while process.isRunning && Date() < end { usleep(10000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? terminal.close()
            Darwin.close(master)
            lock.lock(); active = nil; lock.unlock()
        }
        let previousSessions = Set(SessionWatcher.recentRollouts(codexHome: home, limit: Int.max).map(\.url))
        try process.run()
        lock.lock(); active = process; lock.unlock()
        let startedAt = Date()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        var nextRead = timing.pollInterval
        var terminalOutput = Data()
        var lastWarning: String?
        var diagnostic = PingDiagnostic(elapsedSeconds: 0, warningSeconds: timing.warning, timeoutSeconds: timing.timeout)
        func refreshDiagnostic() {
            diagnostic.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
            let receipt = PingReceipt.read(home: home, excluding: previousSessions)
            diagnostic.threadID = receipt.threadID; diagnostic.turnID = receipt.turnID
            diagnostic.okReceived = receipt.replied; diagnostic.taskCompleted = receipt.completed
            diagnostic.reason = .unknown; diagnostic.retryCount = nil; diagnostic.logStatus = "unavailable"
            if let threadID = receipt.threadID {
                let logs = PingDiagnosticLogReader(home: home).read(threadID: threadID, turnID: receipt.turnID, since: startedAt, until: Date())
                diagnostic.logStatus = logs.status
                diagnostic.reason = logs.evidence?.reason ?? .unknown
                diagnostic.retryCount = logs.evidence?.retryCount
            }
        }
        func fail(_ reason: PingFailureReason? = nil) throws -> Never {
            diagnostic.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
            if let reason { diagnostic.reason = reason }
            diagnostic.outcome = reason == .cancelled ? "cancelled" : "failed"
            progress(diagnostic)
            throw PingFailure(diagnostic: diagnostic)
        }
        while ProcessInfo.processInfo.systemUptime - startedUptime < timing.timeout {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { refreshDiagnostic(); try fail(.cancelled) }
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0 {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(master, &bytes, bytes.count)
                if count > 0 {
                    terminalOutput.append(contentsOf: bytes.prefix(count))
                    // Never persist terminal content; retain only a bounded tail for config failure detection.
                    if terminalOutput.count > 8192 { terminalOutput.removeFirst(terminalOutput.count - 8192) }
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedUptime
            let exited = !process.isRunning
            if elapsed >= nextRead || exited || (lastWarning == nil && elapsed >= timing.warning) {
                refreshDiagnostic()
                // Publish the warning before a potentially slow quota query.
                if diagnostic.elapsedSeconds >= timing.warning, lastWarning != diagnostic.warning {
                    lastWarning = diagnostic.warning; progress(diagnostic)
                }
                if diagnostic.threadID != nil, diagnostic.taskCompleted {
                    let after: UsageSnapshot
                    do { after = try provider.read() }
                    catch { try fail(.quotaRead) }
                    lock.lock(); let stoppedAfterRead = cancelled; lock.unlock()
                    if stoppedAfterRead { refreshDiagnostic(); try fail(.cancelled) }
                    if PingConfirmation.accepts(before: before, after: after, now: Date()) {
                        diagnostic.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
                        diagnostic.windowConfirmed = true; diagnostic.outcome = "confirmed"
                        progress(diagnostic)
                        return after
                    }
                }
                nextRead = ProcessInfo.processInfo.systemUptime - startedUptime + timing.pollInterval
            }
            if exited {
                if String(decoding: terminalOutput, as: UTF8.self).contains("Error loading config.toml") { try fail(.configuration) }
                try fail(.processExit)
            }
        }
        refreshDiagnostic()
        try fail()
    }
}
