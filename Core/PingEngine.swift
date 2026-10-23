import Foundation
import Darwin

protocol PingTransport {
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider) throws -> UsageSnapshot
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void) throws -> UsageSnapshot
    func cancel()
    var preparedModel: PingModel { get }
    func prepareForSend() throws
    func maintainPreparation(provider: UsageProvider, forceCheck: Bool)
    func invalidatePreparation()
    func relocatePreparation()
    func perform(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void) throws -> PingResult
}

extension PingTransport {
    var preparedModel: PingModel { PingModel(model: "gpt-6-luna", reasoningEffort: nil) }
    func prepareForSend() throws {}
    func maintainPreparation(provider: UsageProvider, forceCheck: Bool) {}
    func invalidatePreparation() {}
    func relocatePreparation() { invalidatePreparation() }
    func perform(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void) throws -> PingResult {
        let after = try ping(before: before, model: model, provider: provider, progress: progress)
        return PingResult(after: after, diagnostic: PingDiagnostic(elapsedSeconds: 0, warningSeconds: 90, timeoutSeconds: 180,
            taskCompleted: true, windowConfirmed: PingConfirmation.accepts(before: before, after: after, now: after.capturedAt)))
    }
    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void) throws -> UsageSnapshot {
        try ping(before: before, model: model, provider: provider)
    }
}

/// The goal is a confirmed subscription window, not a successful process exit or an OK reply.
enum PingConfirmation {
    static func accepts(before: UsageSnapshot, after: UsageSnapshot, now: Date) -> Bool {
        guard after.isFresh(at: now), let account = before.accountID, after.accountID == account,
              let new = after.fiveHour else { return false }
        return after.activeFiveHourWindow == true && new.resetsAt > now &&
            new.usedPercent < 100 && (after.weekly?.usedPercent ?? 0) < 100
    }

    static func newWindow(before: UsageSnapshot, after: UsageSnapshot, now: Date, submittedAt: Date? = nil) -> Bool {
        accepts(before: before, after: after, now: now) && before.isFresh(at: submittedAt ?? now) &&
            before.fiveHour != nil && before.activeFiveHourWindow == false &&
            abs(after.fiveHour!.resetsAt.timeIntervalSince(now) - 5 * 3600) < 300
    }
}

struct PingResult {
    let after: UsageSnapshot?
    var diagnostic: PingDiagnostic
}

struct PingReceipt {
    var threadID: String?
    var turnID: String?
    var replied = false
    var completed = false
    var failure: PingFailureReason?
    var errorCode: String?

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
                receipt.replied = false; receipt.completed = false; receipt.failure = nil; receipt.errorCode = nil
            }
            if payload["role"] as? String == "assistant", receipt.turnID != nil {
                let text = (payload["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
                receipt.replied = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "OK"
            }
            if payload["type"] as? String == "task_complete", receipt.turnID != nil,
               payload["turn_id"] as? String == receipt.turnID {
                receipt.completed = receipt.replied && (payload["error"] == nil || payload["error"] is NSNull)
            }
            if payload["type"] as? String == "turn_aborted" { receipt.completed = false; receipt.failure = .cancelled }
            let type = payload["type"] as? String
            if ((type == "error" || type == "turn_failed") && payload["will_retry"] as? Bool != true) ||
                (type == "task_complete" && payload["error"] != nil && !(payload["error"] is NSNull)) {
                let detail = String(describing: payload["error"] ?? payload["message"] ?? payload).lowercased()
                receipt.failure = ["model_not_found", "unsupported_model", "invalid_model", "model_not_available"].contains(where: detail.contains) ? .model : .request
                let code = (payload["error"] as? [String: Any])?["code"] as? String ?? payload["code"] as? String
                if let code, ["model_not_found", "unsupported_model", "invalid_model", "model_not_available", "usage_limit_reached", "usage_limit_exceeded", "request_timeout", "server_error"].contains(code) { receipt.errorCode = code }
                receipt.completed = false
            }
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
    private let preparation: PingPreparation
    private let timing: PingTiming
    init(codexHome: URL = CodexEnvironment.home, supportRoot: URL? = nil, binary: URL? = nil, timing: PingTiming = PingTiming()) {
        mainHome = codexHome; self.timing = timing
        let root = supportRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexKeeper/ping")
        preparation = PingPreparation(mainHome: codexHome, root: root, locate: { try binary ?? CodexLocator.binary() })
    }
    var preparedModel: PingModel { preparation.preparedModel }
    func prepareForSend() throws {
        lock.lock(); cancelled = false; lock.unlock()
        do { try preparation.prepareForSend() }
        catch { throw PingSubmissionError(underlying: error, stage: "configuration") }
    }
    func maintainPreparation(provider: UsageProvider, forceCheck: Bool) { preparation.maintain(provider: provider, forceCheck: forceCheck) }
    func invalidatePreparation() { preparation.invalidate() }
    func relocatePreparation() { preparation.invalidate(relocate: true) }
    private let lock = NSLock()
    private var active: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; let process = active; lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            let end = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(10000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider) throws -> UsageSnapshot {
        try ping(before: before, model: model, provider: provider, progress: { _ in })
    }

    static func configuration(work: URL, model: PingModel) throws -> String {
        let reasoning = model.reasoningEffort.map { "model_reasoning_effort = \"\($0)\"" } ?? ""
        // This is Keeper's own empty directory, not an approval of a user project or a tool request.
        // TOML strings accept JSON escapes except the optional escaped forward slash.
        let quotedWork = String(data: try JSONSerialization.data(withJSONObject: work.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        return """
        model = "gpt-6-luna"
        model_provider = "keeper_http"
        \(reasoning)
        sandbox_mode = "read-only"
        approval_policy = "never"
        forced_login_method = "chatgpt"
        developer_instructions = "Reply only OK. Do not call tools or read files."
        features.daemon_auto_start = false
        model_providers.keeper_http.name = "OpenAI"
        model_providers.keeper_http.requires_openai_auth = true
        model_providers.keeper_http.supports_websockets = false
        model_providers.keeper_http.wire_api = "responses"
        [projects.\(quotedWork)]
        trust_level = "trusted"
        """
    }

    func ping(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void) throws -> UsageSnapshot {
        try prepareForSend()
        let result = try perform(before: before, model: model, provider: provider, progress: progress)
        guard let after = result.after else { throw PingFailure(diagnostic: result.diagnostic) }
        return after
    }

    func perform(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void) throws -> PingResult {
        var started = false
        do { return try execute(before: before, model: model, provider: provider, progress: progress, didStart: { started = true }) }
        catch { if !started, !(error is PingSubmissionError) { throw PingSubmissionError(underlying: error) }; throw error }
    }

    private func execute(before: UsageSnapshot, model: PingModel, provider: UsageProvider, progress: @escaping (PingDiagnostic) -> Void, didStart: () -> Void) throws -> PingResult {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw PingFailure(diagnostic: PingDiagnostic(elapsedSeconds: 0, warningSeconds: timing.warning, timeoutSeconds: timing.timeout, reason: .cancelled, outcome: "cancelled")) }
        let fm = FileManager.default
        guard model.model == "gpt-6-luna" else { throw CodexConnectionError.server("保活模型未经确认") }
        let binary = try preparation.prepareForSend(model: model)
        let home = preparation.home; let work = preparation.work
        let authentication: PingAuthentication
        do { authentication = try PingAuthentication.read(home: mainHome) }
        catch { throw PingSubmissionError(underlying: error, stage: "authentication") }
        guard authentication.accountID == before.accountID else { throw CodexConnectionError.server("账户在刷新期间改变") }
        let authURL = home.appendingPathComponent("auth.json")
        try authentication.data.write(to: authURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
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
            let end = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(10000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? terminal.close()
            Darwin.close(master)
            lock.lock(); active = nil; lock.unlock()
        }
        let previousSessions = Set(SessionWatcher.recentRollouts(codexHome: home, limit: Int.max).map(\.url))
        lock.lock()
        if cancelled {
            lock.unlock()
            throw PingFailure(diagnostic: PingDiagnostic(elapsedSeconds: 0, warningSeconds: timing.warning, timeoutSeconds: timing.timeout, reason: .cancelled, outcome: "cancelled"))
        }
        do { try process.run(); active = process; didStart(); lock.unlock() }
        catch { lock.unlock(); preparation.invalidate(relocate: true); throw PingSubmissionError(underlying: error, stage: "process_launch") }
        let startedUptime = ProcessInfo.processInfo.systemUptime
        var nextRead = timing.pollInterval
        var terminalOutput = Data()
        var lastWarning: String?
        var lastReadFailure: UsageReadDiagnostic?
        var diagnostic = PingDiagnostic(elapsedSeconds: 0, warningSeconds: timing.warning, timeoutSeconds: timing.timeout)
        func refreshDiagnostic() {
            diagnostic.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
            if !diagnostic.taskCompleted {
                let receipt = PingReceipt.read(home: home, excluding: previousSessions)
                diagnostic.threadID = receipt.threadID; diagnostic.turnID = receipt.turnID
                diagnostic.okReceived = receipt.replied; diagnostic.taskCompleted = receipt.completed
                diagnostic.reason = receipt.failure ?? .unknown; diagnostic.errorCode = receipt.errorCode
                diagnostic.logStatus = "isolated_jsonl"
            }
        }
        func fail(_ reason: PingFailureReason? = nil) throws -> Never {
            diagnostic.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
            if let reason { diagnostic.reason = reason }
            diagnostic.outcome = reason == .cancelled ? "cancelled" : "failed"
            if reason == .model || reason == .configuration { preparation.invalidate() }
            progress(diagnostic)
            throw PingFailure(diagnostic: diagnostic)
        }
        while ProcessInfo.processInfo.systemUptime - startedUptime < timing.timeout {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { refreshDiagnostic(); try fail(.cancelled) }
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if !process.isRunning {
                Thread.sleep(forTimeInterval: min(0.1, max(0, timing.timeout - (ProcessInfo.processInfo.systemUptime - startedUptime))))
            } else if poll(&descriptor, 1, 100) > 0 {
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
            if elapsed >= nextRead || (exited && (diagnostic.threadID == nil || !diagnostic.taskCompleted)) || (lastWarning == nil && elapsed >= timing.warning) {
                refreshDiagnostic()
                if diagnostic.reason == .model || diagnostic.reason == .request { try fail(diagnostic.reason) }
                // Publish the warning before a potentially slow quota query.
                if diagnostic.elapsedSeconds >= timing.warning, lastWarning != diagnostic.warning {
                    lastWarning = diagnostic.warning; progress(diagnostic)
                }
                if diagnostic.threadID != nil, diagnostic.taskCompleted,
                   ProcessInfo.processInfo.systemUptime - startedUptime < timing.timeout {
                    let readStarted = ProcessInfo.processInfo.systemUptime
                    let after: UsageSnapshot?
                    do { after = try provider.read(); diagnostic.quotaReadFailure = nil; lastReadFailure = nil }
                    catch {
                        lock.lock(); let stoppedAfterError = cancelled; lock.unlock()
                        if stoppedAfterError { refreshDiagnostic(); try fail(.cancelled) }
                        let failure = UsageReadFailure.describe(error, elapsed: ProcessInfo.processInfo.systemUptime - readStarted)
                        diagnostic.quotaReadFailure = failure
                        if failure.reason == "account_changed" { try fail(.accountChanged) }
                        if !UsageReadFailure.canRetry(error) {
                            diagnostic.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
                            diagnostic.reason = .quotaRead; diagnostic.outcome = "completed_pending"
                            progress(diagnostic)
                            return PingResult(after: nil, diagnostic: diagnostic)
                        }
                        if !failure.sameFailure(as: lastReadFailure) {
                            diagnostic.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
                            progress(diagnostic); lastReadFailure = failure
                        }
                        after = nil
                    }
                    lock.lock(); let stoppedAfterRead = cancelled; lock.unlock()
                    if stoppedAfterRead { refreshDiagnostic(); try fail(.cancelled) }
                    if let after, after.accountID != before.accountID { try fail(.accountChanged) }
                    if let after, PingConfirmation.accepts(before: before, after: after, now: Date()) {
                        diagnostic.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
                        diagnostic.windowConfirmed = true; diagnostic.outcome = "confirmed"
                        progress(diagnostic)
                        return PingResult(after: after, diagnostic: diagnostic)
                    }
                }
                nextRead = ProcessInfo.processInfo.systemUptime - startedUptime + timing.pollInterval
            }
            if exited && (diagnostic.threadID == nil || !diagnostic.taskCompleted) {
                if String(decoding: terminalOutput, as: UTF8.self).contains("Error loading config.toml") { try fail(.configuration) }
                try fail(.processExit)
            }
        }
        refreshDiagnostic()
        if diagnostic.taskCompleted {
            diagnostic.outcome = "completed_pending"
            diagnostic.reason = diagnostic.quotaReadFailure == nil ? .unknown : .quotaRead
            progress(diagnostic)
            return PingResult(after: nil, diagnostic: diagnostic)
        }
        try fail(diagnostic.quotaReadFailure == nil ? nil : .quotaRead)
    }
}
