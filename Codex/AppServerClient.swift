import Foundation
import Darwin
import CryptoKit
import AppKit

/// Official JSONL stdio protocol. Callers serialize requests on each client.
protocol CodexTransport: AnyObject {
    func request(_ method: String, params: [String: Any]) throws -> [String: Any]
    func nextMessage(timeout: TimeInterval) throws -> [String: Any]
    func close()
}

enum CodexConnectionError: LocalizedError {
    case unavailable, timeout, ended, invalidResponse, server(String), localizedMessage(String), approvalRequired
    var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.text("找不到官方 Codex CLI")
        case .timeout: return L10n.text("Codex 连接超时，未自动重试")
        case .ended: return L10n.text("Codex 连接已结束")
        case .invalidResponse: return L10n.text("Codex 返回了无法识别的数据")
        case .server(let message):
            switch Self.serverFailureReason(message) {
            case "workspace_routing_timeout", "request_timeout": return L10n.text("Codex 服务连接超时，请检查网络或代理后重新同步。")
            case "connection_failed": return L10n.text("无法连接 Codex 服务，请检查网络或代理后重新同步。")
            case "service_unavailable": return L10n.text("Codex 服务暂时不可用，请稍后重新同步。")
            default:
                return message.range(of: #"[\p{Han}]"#, options: .regularExpression) != nil ? L10n.text(message) : L10n.text("Codex 请求失败，请检查网络和登录状态后重试。")
            }
        case .localizedMessage(let message): return message
        case .approvalRequired: return L10n.text("需要用户授权；请在 Codex 中检查原任务后继续")
        }
    }

    static func serverFailureReason(_ message: String) -> String {
        let text = message.lowercased()
        let timedOut = ["timed out", "timedout", "timeout"].contains(where: text.contains)
        if text.contains("workspace routing discovery"), timedOut { return "workspace_routing_timeout" }
        if timedOut { return "request_timeout" }
        if ["connection refused", "connection reset", "dns error", "error sending request", "failed to connect"].contains(where: text.contains) { return "connection_failed" }
        if text.range(of: #"(?:status(?: code)?[: ]+|http(?:/\d(?:\.\d)?)? )5\d\d\b"#, options: .regularExpression) != nil { return "service_unavailable" }
        return "server_error"
    }
}

final class AppServerClient: CodexTransport {
    private static let registryLock = NSLock()
    private static var processes: [Int32: Process] = [:]
    static func closeAll() {
        registryLock.lock(); let own = Array(processes.values); registryLock.unlock()
        for process in own where process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    private let stateLock = NSLock()
    private var closed = false
    private let process: Process
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var identifier = 0
    private var pending: [[String: Any]] = []

    init(binary: URL? = nil, usageOnly: Bool = false, process: Process = Process()) throws {
        self.process = process
        let executable = try binary ?? CodexLocator.binary()
        process.executableURL = executable
        process.arguments = ["app-server"]
        if usageOnly {
            // Quota reads need no plugin catalogs; overrides apply only to this child.
            process.arguments! += ["-c", "features.plugins=false", "-c", "features.remote_plugin=false"]
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Keeper 的独立 app-server 通过 stdio 通信；仅对子进程禁用远程控制。
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED"] = "1"
        environment["CODEX_HOME"] = CodexEnvironment.home.path
        process.environment = environment
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw CodexConnectionError.ended
        }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        Self.registryLock.lock(); Self.processes[process.processIdentifier] = process; Self.registryLock.unlock()
        do {
            _ = try request("initialize", params: ["clientInfo": ["name": "codex_keeper", "version": "0.1.0"], "capabilities": ["experimentalApi": true]])
            try write(["method": "initialized"])
        } catch { close(); throw error }
    }

    deinit { close() }

    private func write(_ object: [String: Any]) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !closed, process.isRunning else { throw CodexConnectionError.ended }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        identifier += 1
        let id = identifier
        try write(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let message = try readMessage(timeout: deadline.timeIntervalSinceNow)
            if (message["id"] as? Int) == id, message["method"] == nil {
                if let error = message["error"] as? [String: Any] { throw CodexConnectionError.server(error["message"] as? String ?? "Codex 请求失败") }
                guard let result = message["result"] as? [String: Any] else { throw CodexConnectionError.invalidResponse }
                return result
            }
            // Never approve any server request. The caller can interrupt the resumed turn.
            if message["method"] != nil, message["id"] != nil { throw CodexConnectionError.approvalRequired }
            if pending.count >= 256 { pending.removeFirst() }
            pending.append(message)
        }
        throw CodexConnectionError.timeout
    }

    func nextMessage(timeout: TimeInterval) throws -> [String: Any] {
        if !pending.isEmpty { return pending.removeFirst() }
        return try readMessage(timeout: timeout)
    }

    private func readMessage(timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CodexConnectionError.invalidResponse }
                return message
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexConnectionError.timeout }
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !closed else { throw CodexConnectionError.ended }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
            if ready < 0 { if errno == EINTR { continue }; throw CodexConnectionError.ended }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw CodexConnectionError.ended }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 8 * 1024 * 1024 else { throw CodexConnectionError.invalidResponse }
        }
    }

    func close() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !closed else { return }
        closed = true
        Self.registryLock.lock(); Self.processes.removeValue(forKey: process.processIdentifier); Self.registryLock.unlock()
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            // Foundation can miss the exit notification; never wait for it without a deadline.
        }
    }
}

protocol UsageProvider {
    func read() throws -> UsageSnapshot
    func readForUserRefresh() throws -> UsageSnapshot
    func pingModel() throws -> PingModel
    func setRetryOpportunity(_ opportunity: UsageRetryOpportunity?, now: Date)
}

struct PingModel: Equatable {
    let model: String
    let reasoningEffort: String?
}

extension UsageProvider {
    func readForUserRefresh() throws -> UsageSnapshot { try read() }
    func pingModel() throws -> PingModel {
        throw CodexConnectionError.server("无法确认保活模型；请更新 Codex 后重试")
    }
    func setRetryOpportunity(_ opportunity: UsageRetryOpportunity?, now: Date) {}
}

private struct CodexCapabilityError: LocalizedError {
    let message: String
    var errorDescription: String? { L10n.text(message) }
}

/// Describes Keeper's RPC calls, not the CLI's upstream network requests. No raw error is encoded.
struct UsageReadDiagnostic: Codable, Equatable {
    let requestStage: String
    let rpcAttempted: Bool?
    let cooldown: Bool
    let elapsedMilliseconds: Int
    let reason: String

    var isTransient: Bool {
        ["workspace_routing_timeout", "request_timeout", "connection_failed", "connection_ended", "service_unavailable"].contains(reason)
    }

    func sameFailure(as other: UsageReadDiagnostic?) -> Bool {
        guard let other else { return false }
        return requestStage == other.requestStage && rpcAttempted == other.rpcAttempted &&
            cooldown == other.cooldown && reason == other.reason
    }
}

struct UsageReadFailure: LocalizedError {
    let underlying: Error
    let diagnostic: UsageReadDiagnostic
    var errorDescription: String? { underlying.localizedDescription }

    static func describe(_ error: Error, elapsed: TimeInterval) -> UsageReadDiagnostic {
        if let failure = error as? UsageReadFailure { return failure.diagnostic }
        return UsageReadDiagnostic(requestStage: "provider", rpcAttempted: nil, cooldown: false,
            elapsedMilliseconds: Int(max(0, elapsed) * 1000), reason: reason(for: error))
    }

    static func canRetry(_ error: Error) -> Bool {
        let error = (error as? UsageReadFailure)?.underlying ?? error
        switch error {
        case CodexConnectionError.timeout, CodexConnectionError.ended: return true
        case CodexConnectionError.server:
            return describe(error, elapsed: 0).isTransient
        default: return false
        }
    }

    static func reason(for error: Error) -> String {
        switch error {
        case CodexConnectionError.timeout: return "request_timeout"
        case CodexConnectionError.ended: return "connection_ended"
        case CodexConnectionError.unavailable: return "cli_unavailable"
        case CodexConnectionError.invalidResponse: return "invalid_response"
        case CodexConnectionError.approvalRequired: return "approval_required"
        case CodexConnectionError.server(let message):
            if message.contains("账户在刷新期间改变") || message.contains("账户身份不一致") { return "account_changed" }
            let text = message.lowercased()
            if ["unauthorized", "authentication", "not logged in", "login required"].contains(where: text.contains) ||
                text.range(of: #"(?:status(?: code)?[: ]+|http(?:/\d(?:\.\d)?)? )(?:401|403)\b"#, options: .regularExpression) != nil {
                return "authentication_failed"
            }
            return CodexConnectionError.serverFailureReason(message)
        case is CodexCapabilityError: return "capability_or_authentication"
        default: return "read_failed"
        }
    }
}

final class AppServerUsageProvider: UsageProvider {
    private let lock = NSLock()
    private let retryOpportunityLock = NSLock()
    private let makeTransport: () throws -> CodexTransport
    private let contextIdentity: () throws -> Data?
    private let accountIdentity: () throws -> String?
    private let fallbackPath: () -> String?
    private let uptime: () -> TimeInterval
    private var lastFallbackPath: String?
    private var transport: CodexTransport?
    private var identity: Data?
    private var retryAfter: TimeInterval = 0
    private var manualRetryAfter: TimeInterval = 0
    private var lastFailure: Error?
    private var failureCount = 0
    private var upstreamFailure = false
    private var lastAutomaticAttempt: TimeInterval = -.infinity
    private var shortRetryNode: Date?
    private var shortRetryUntil: TimeInterval = 0
    private var modelFailure: Error?
    private var modelRetryAfter: TimeInterval = 0
    private var cachedModel: PingModel?
    private var cachedModelUntil: TimeInterval = 0

    init(makeTransport: @escaping () throws -> CodexTransport = { try AppServerClient(usageOnly: true) },
         contextIdentity: (() throws -> Data?)? = nil,
         accountIdentity: (() throws -> String?)? = nil,
         fallbackPath: @escaping () -> String? = { UserDefaults.standard.string(forKey: CodexLocator.fallbackPathKey) },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.makeTransport = makeTransport
        self.contextIdentity = contextIdentity ?? { try Self.authenticationIdentity() }
        self.accountIdentity = accountIdentity ?? (contextIdentity == nil ? { try Self.authenticationAccountID() } : { nil })
        self.fallbackPath = fallbackPath
        self.lastFallbackPath = fallbackPath()
        self.uptime = uptime
    }

    deinit { transport?.close() }

    // Hash only for local equality checks; credentials never enter logs or snapshots.
    static func authenticationIdentity(home: URL = CodexEnvironment.home) throws -> Data? {
        do { return Data(SHA256.hash(data: try Data(contentsOf: home.appendingPathComponent("auth.json")))) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    static func authenticationAccountID(home: URL = CodexEnvironment.home) throws -> String? {
        let data: Data
        do { data = try Data(contentsOf: home.appendingPathComponent("auth.json")) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let id = (object?["tokens"] as? [String: Any])?["account_id"] as? String
        return id?.isEmpty == false ? id : nil
    }

    func read() throws -> UsageSnapshot {
        try read(manual: false)
    }

    func readForUserRefresh() throws -> UsageSnapshot { try read(manual: true) }

    func setRetryOpportunity(_ opportunity: UsageRetryOpportunity?, now: Date) {
        retryOpportunityLock.lock(); defer { retryOpportunityLock.unlock() }
        guard let opportunity else { shortRetryUntil = 0; return }
        guard opportunity.node != shortRetryNode else { return }
        shortRetryNode = opportunity.node
        // A fixed monotonic limit cannot be renewed by every 20-second recomputation.
        shortRetryUntil = uptime() + min(600, max(0, opportunity.end.timeIntervalSince(now)))
    }

    private func read(manual: Bool) throws -> UsageSnapshot {
        let started = uptime()
        var requestStage = "connection"
        var rpcAttempted: Bool? = false
        do {
            return try withConnection(manual: manual, stage: {
                requestStage = $0
                // The transport factory may initialize a child with RPCs; its internals are unknown here.
                if $0 == "connection" { rpcAttempted = nil }
            }) { client in
                requestStage = "account_read"; rpcAttempted = true
                try Self.requireChatGPT(try client.request("account/read", params: ["refreshToken": false]))
                var snapshot = try read(from: client, stage: { requestStage = $0 })
                requestStage = "account_verification"
                let fileAccount = try accountIdentity()
                if let reported = snapshot.accountID, let fileAccount, reported != fileAccount {
                    throw CodexConnectionError.server("账户身份不一致，请重新登录 Codex 后重试")
                }
                snapshot.accountID = snapshot.accountID ?? fileAccount
                guard snapshot.accountID != nil else {
                    throw CodexCapabilityError(message: "无法确认 Codex 账户身份，请重新登录或更新 Codex；自动操作已暂停")
                }
                return snapshot
            }
        } catch {
            let reason = ["authentication", "account_verification"].contains(requestStage) && !(error is CodexConnectionError) && !(error is CodexCapabilityError) ?
                "authentication_failed" : UsageReadFailure.reason(for: error)
            throw UsageReadFailure(underlying: error, diagnostic: UsageReadDiagnostic(requestStage: requestStage,
                rpcAttempted: rpcAttempted, cooldown: requestStage == "cooldown",
                elapsedMilliseconds: Int(max(0, uptime() - started) * 1000), reason: reason))
        }
    }

    static func requireChatGPT(_ response: [String: Any]) throws {
        guard let account = response["account"] as? [String: Any] else {
            throw CodexCapabilityError(message: "请先在 Codex 中登录支持额度查询的 ChatGPT 账户")
        }
        guard account["type"] as? String == "chatgpt" else {
            throw CodexCapabilityError(message: "当前 Codex 使用 API key 或其他登录方式；Keeper 需要 ChatGPT 账户额度")
        }
    }

    func pingModel() throws -> PingModel {
        // A locally cached discovery needs no automatic RPC admission. Authentication is
        // still checked, and the final quota/account read remains mandatory before sending.
        lock.lock()
        do {
            if lastFailure != nil, let cachedModel, uptime() < cachedModelUntil, transport != nil, try contextIdentity() == identity,
               fallbackPath() == lastFallbackPath {
                lock.unlock(); return cachedModel
            }
        } catch { /* The shared connection path reports and budgets authentication failures. */ }
        lock.unlock()
        return try withConnection(resetFailuresOnSuccess: false) { client in
            if uptime() < modelRetryAfter, let modelFailure { throw modelFailure }
            cachedModel = nil
            do {
                try Self.requireChatGPT(try client.request("account/read", params: ["refreshToken": false]))
                var cursor: String?
                var cursors = Set<String>()
                // Bound both network work and malformed/repeating pagination.
                for _ in 0..<10 {
                    var params: [String: Any] = ["limit": 20, "includeHidden": false]
                    if let cursor { params["cursor"] = cursor }
                    let page = try client.request("model/list", params: params)
                    guard let models = page["data"] as? [[String: Any]] else { throw CodexConnectionError.invalidResponse }
                    if let entry = models.first(where: {
                        ($0["model"] as? String ?? $0["id"] as? String) == "gpt-6-luna" && ($0["hidden"] as? Bool) != true
                    }) {
                        let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]])?.compactMap { $0["reasoningEffort"] as? String }.filter { ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains($0) } ?? []
                        let declared = entry["defaultReasoningEffort"] as? String
                        let effort = efforts.contains("low") ? "low" : (declared.flatMap { efforts.contains($0) ? $0 : nil })
                        modelFailure = nil
                        let model = PingModel(model: "gpt-6-luna", reasoningEffort: effort)
                        cachedModel = model
                        cachedModelUntil = uptime() + 300
                        return model
                    }
                    guard let next = page["nextCursor"] as? String, !next.isEmpty else { break }
                    guard cursors.insert(next).inserted else { throw CodexConnectionError.invalidResponse }
                    cursor = next
                }
                throw CodexCapabilityError(message: "当前账户未提供 gpt-6-luna；请确认 Codex 登录和模型权限后重试，Keeper 不会自动改用其他模型")
            } catch {
                let failure = CodexCapabilityError(message: L10n.format("保活模型确认失败：%@；5 分钟后可重试", error.localizedDescription))
                // Capability errors leave the healthy quota connection reusable.
                if error is CodexCapabilityError {
                    modelFailure = failure
                    modelRetryAfter = uptime() + 300
                    throw failure
                }
                throw error
            }
        }
    }

    private func withConnection<T>(manual: Bool = false, resetFailuresOnSuccess: Bool = true,
                                   stage: ((String) -> Void)? = nil, _ operation: (CodexTransport) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let currentFallbackPath = fallbackPath()
        retryOpportunityLock.lock(); let shortUntil = shortRetryUntil; retryOpportunityLock.unlock()
        let automaticRetryAfter = upstreamFailure && uptime() < shortUntil ? lastAutomaticAttempt + 30 : retryAfter
        if uptime() < automaticRetryAfter, let lastFailure {
            // A deliberate retry can bypass background backoff, but repeated clicks cannot spawn a storm.
            guard manual, currentFallbackPath != lastFallbackPath || uptime() >= manualRetryAfter else {
                stage?("cooldown"); throw lastFailure
            }
        }
        lastFallbackPath = currentFallbackPath
        if manual { manualRetryAfter = uptime() + 5 }
        var operationStarted = false
        do {
            stage?("authentication")
            let currentIdentity = try contextIdentity()
            if transport != nil, identity != currentIdentity {
                transport?.close()
                transport = nil
                modelFailure = nil
                modelRetryAfter = 0
                cachedModel = nil
            }
            if transport == nil {
                stage?("connection")
                transport = try makeTransport()
                identity = currentIdentity
            }
            operationStarted = true
            lastAutomaticAttempt = uptime()
            let result = try operation(transport!)
            stage?("authentication")
            guard try contextIdentity() == currentIdentity else {
                throw CodexConnectionError.server("账户在刷新期间改变")
            }
            if resetFailuresOnSuccess {
                lastFailure = nil
                failureCount = 0
                upstreamFailure = false
                cachedModel = nil
            } else if lastFailure != nil {
                // Model discovery does not repay a failed quota read or permit an immediate
                // second automatic batch. Its cached result is available at the next admission.
                retryAfter = uptime() + min(300, 20 * pow(2, Double(min(failureCount - 1, 4))))
            }
            return result
        } catch {
            if error is CodexCapabilityError { throw error }
            var failure = error
            var retainConnection = false
            if operationStarted, case CodexConnectionError.server = error, UsageReadFailure.canRetry(error) {
                // A complete RPC error leaves stdio usable only within the same authentication context.
                do { try requireSameAuthentication(); retainConnection = true }
                catch let authenticationError {
                    stage?("authentication")
                    failure = authenticationError
                }
            }
            if !retainConnection {
                transport?.close()
                transport = nil
                cachedModel = nil
            }
            lastFailure = failure
            failureCount += 1
            upstreamFailure = retainConnection && ["connection_failed", "service_unavailable"].contains(UsageReadFailure.reason(for: failure))
            // Back off persistent protocol/network failures without a process every poll.
            retryAfter = uptime() + min(300, 20 * pow(2, Double(min(failureCount - 1, 4))))
            throw failure
        }
    }

    private func requireSameAuthentication() throws {
        guard try contextIdentity() == identity else { throw CodexConnectionError.server("账户在刷新期间改变") }
    }

    private func readRateLimits(from client: CodexTransport, stage: (String) -> Void) throws -> UsageSnapshot {
        let response: [String: Any]
        do {
            response = try client.request("account/rateLimits/read", params: [:])
        } catch CodexConnectionError.server(let message) where CodexConnectionError.serverFailureReason(message) == "connection_failed" && UsageReadFailure.canRetry(CodexConnectionError.server(message)) {
            // A transient network error can leave the retained app-server healthy.
            do { try requireSameAuthentication() }
            catch { stage("authentication"); throw error }
            response = try client.request("account/rateLimits/read", params: [:])
        }
        return try UsageDecoder.account(response, at: Date())
    }

    private func read(from client: CodexTransport, stage: (String) -> Void) throws -> UsageSnapshot {
        stage("rate_limits")
        let first = try readRateLimits(from: client, stage: stage)
        guard let five = first.fiveHour, five.usedPercent == 0, five.resetsAt > first.capturedAt else { return first }
        // With no active window the service returns a rolling now+5h reset. A fixed
        // reset at 0% instead represents a real window whose usage rounds to zero.
        Thread.sleep(forTimeInterval: 2.2)
        stage("window_verification")
        var second = try readRateLimits(from: client, stage: stage)
        guard first.accountID == second.accountID else { throw CodexConnectionError.server("账户在刷新期间改变") }
        if let current = second.fiveHour, current.usedPercent == 0 {
            second.zeroUseWindowActive = abs(current.resetsAt.timeIntervalSince(five.resetsAt)) <= 1
        }
        return second
    }
}

enum UsageDecoder {
    static func windows(_ limits: [String: Any]) -> (QuotaWindow?, QuotaWindow?) {
        var five: QuotaWindow?
        var weekly: QuotaWindow?
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any],
                  let used = (w["usedPercent"] ?? w["used_percent"]) as? NSNumber,
                  let minutes = (w["windowDurationMins"] ?? w["window_minutes"]) as? NSNumber,
                  let reset = (w["resetsAt"] ?? w["resets_at"]) as? NSNumber,
                  used.doubleValue.isFinite, used.doubleValue >= 0 else { continue }
            let quota = QuotaWindow(usedPercent: used.doubleValue, windowMinutes: minutes.intValue, resetsAt: Date(timeIntervalSince1970: reset.doubleValue))
            if (240...360).contains(minutes.intValue) { five = quota }
            if (8000...12000).contains(minutes.intValue) { weekly = quota }
        }
        return (five, weekly)
    }

    static func account(_ response: [String: Any], at now: Date) throws -> UsageSnapshot {
        // The legacy bucket can be a model-specific quota; prefer the account's codex bucket.
        let byID = response["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = (byID?["codex"] as? [String: Any]) ?? (response["rateLimits"] as? [String: Any]) else { throw CodexConnectionError.invalidResponse }
        let (five, weekly) = windows(limits)
        guard five != nil || weekly != nil else { throw CodexConnectionError.invalidResponse }
        return UsageSnapshot(fiveHour: five, weekly: weekly, capturedAt: now, accountID: response["accountId"] as? String, sourceFile: "app-server")
    }

    static func timestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}


enum CodexEnvironment {
    static var home: URL { home(environment: ProcessInfo.processInfo.environment) }
    static func home(environment: [String: String], userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }
        return userHome.appendingPathComponent(".codex")
    }
}

enum CodexCLIPathError: LocalizedError, Equatable {
    case relative, missing, notFile, notExecutable
    var errorDescription: String? {
        switch self {
        case .relative: return L10n.text("请输入 Codex CLI 的绝对路径（可使用 ~/）。")
        case .missing: return L10n.text("找不到该文件，请检查路径。")
        case .notFile: return L10n.text("请选择 Codex CLI 可执行文件，不能选择文件夹。")
        case .notExecutable: return L10n.text("该文件不可执行，请选择 Codex CLI 可执行文件。")
        }
    }
}

enum CodexLocator {
    static let fallbackPathKey = "codexCLIFallbackPath"
    static let fallbackPathChanged = Notification.Name("CodexKeeperCLIFallbackPathChanged")

    static func validateFallbackPath(_ raw: String, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = trimmed.hasPrefix("~/") ? userHome.appendingPathComponent(String(trimmed.dropFirst(2))).path : trimmed
        guard path.hasPrefix("/") else { throw CodexCLIPathError.relative }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw CodexCLIPathError.missing }
        guard !isDirectory.boolValue,
              (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CodexCLIPathError.notFile
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CodexCLIPathError.notExecutable }
        return url
    }

    @discardableResult static func saveFallbackPath(_ raw: String, defaults: UserDefaults = .standard,
                                                    userHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        let path = try validateFallbackPath(raw, userHome: userHome)?.path
        if path != defaults.string(forKey: fallbackPathKey) {
            if let path { defaults.set(path, forKey: fallbackPathKey) }
            else { defaults.removeObject(forKey: fallbackPathKey) }
            NotificationCenter.default.post(name: fallbackPathChanged, object: defaults)
        }
        return path ?? ""
    }

    static func binary() throws -> URL {
        let bundles = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" }.compactMap { $0.bundleURL }
        return try binary(environment: ProcessInfo.processInfo.environment, userHome: FileManager.default.homeDirectoryForCurrentUser,
            runningBundles: bundles, fallbackPath: UserDefaults.standard.string(forKey: fallbackPathKey))
    }

    static func binary(environment: [String: String], userHome: URL, runningBundles: [URL], fallbackPath: String? = nil,
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) throws -> URL {
        let relativePaths = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
        var bundles = runningBundles
        for directory in ["/Applications", userHome.appendingPathComponent("Applications").path] {
            for app in ["Codex.app", "ChatGPT.app"] { bundles.append(URL(fileURLWithPath: directory).appendingPathComponent(app)) }
        }
        var paths = bundles.flatMap { bundle in relativePaths.map { bundle.appendingPathComponent($0).path } }
        paths += (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        if let path = paths.first(where: isExecutable) { return URL(fileURLWithPath: path) }
        if let fallback = try validateFallbackPath(fallbackPath ?? "", userHome: userHome) { return fallback }
        throw CodexConnectionError.unavailable
    }
}
