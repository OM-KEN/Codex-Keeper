import Foundation
import SQLite3

enum PingPreflightReason: String, Codable {
    case modelDiscoveryFailed = "model_discovery_failed", usageReadFailed = "usage_read_failed"
    case generationChanged = "generation_changed", disabled
    case anchorChanged = "anchor_changed", accountChanged = "account_changed", accountUnconfirmed = "account_unconfirmed"
    case runtimeUnhealthy = "runtime_unhealthy", sessionsUnscanned = "sessions_unscanned", sessionScanFailed = "session_scan_failed"
    case criticalRefresh = "critical_refresh", keeperBusy = "keeper_busy", codexTaskRunning = "codex_task_running"
    case taskSelectionChanged = "task_selection_changed", appStateUnavailable = "app_state_unavailable", newPause = "new_pause"
    case usageNotFresh = "usage_not_fresh", timeZoneChanged = "timezone_changed"
    case opportunityExpired = "opportunity_expired", nodeChanged = "node_changed"

    var message: String {
        switch self {
        case .modelDiscoveryFailed: return L10n.text("保活未发送：保活模型确认失败")
        case .usageReadFailed: return L10n.text("保活未发送：额度读取失败")
        case .generationChanged: return L10n.text("保活未发送：本次准备已取消")
        case .disabled: return L10n.text("保活未发送：自动执行已关闭")
        case .anchorChanged: return L10n.text("保活未发送：每日开始时间已改变")
        case .accountChanged: return L10n.text("保活未发送：账户已改变")
        case .accountUnconfirmed: return L10n.text("保活未发送：账户暂时无法确认")
        case .runtimeUnhealthy: return L10n.text("保活未发送：待续状态无法保存")
        case .sessionsUnscanned: return L10n.text("保活未发送：等待首次任务扫描")
        case .sessionScanFailed: return L10n.text("保活未发送：任务扫描失败")
        case .criticalRefresh: return L10n.text("保活未发送：等待关键额度刷新")
        case .keeperBusy: return L10n.text("保活未发送：Keeper 正在处理续跑任务")
        case .codexTaskRunning: return L10n.text("保活未发送：Codex 任务正在运行")
        case .taskSelectionChanged: return L10n.text("保活未发送：待续任务或选择已改变")
        case .appStateUnavailable: return L10n.text("保活未发送：应用状态暂时无法确认")
        case .newPause: return L10n.text("保活未发送：发现新的额度暂停任务")
        case .usageNotFresh: return L10n.text("保活未发送：额度读数需重新确认")
        case .timeZoneChanged: return L10n.text("保活未发送：系统时区已改变")
        case .opportunityExpired: return L10n.text("保活未发送：本次保活时间已过")
        case .nodeChanged: return L10n.text("保活未发送：当前计划节点已改变")
        }
    }
    var userMessage: String {
        switch self {
        case .accountChanged: return CodexConnectionError.userMessage(reason: "account_changed")
        case .accountUnconfirmed: return L10n.text("账户待确认，请在 Codex 检查登录后刷新。")
        case .disabled: return L10n.text("已暂停，Keeper 已停用")
        case .runtimeUnhealthy: return L10n.text("记录不可用，请检查磁盘空间后刷新。")
        case .keeperBusy, .codexTaskRunning, .newPause: return L10n.text("正在确认中")
        case .opportunityExpired: return L10n.text("本次保活已错过，请等待下次保活或手动保活。")
        case .generationChanged, .anchorChanged, .timeZoneChanged, .nodeChanged, .taskSelectionChanged: return L10n.text("设置已更新，等待下次保活。")
        case .modelDiscoveryFailed: return L10n.text("暂时无法保活，请更新 Codex，并用 ChatGPT 账户登录后刷新。")
        case .sessionsUnscanned, .criticalRefresh, .usageNotFresh: return L10n.text("正在确认中")
        case .usageReadFailed, .sessionScanFailed, .appStateUnavailable: return L10n.text("状态待更新，请刷新后查看。")
        }
    }

    var needsAttention: Bool {
        switch self {
        case .generationChanged, .disabled, .anchorChanged, .sessionsUnscanned, .criticalRefresh,
             .keeperBusy, .codexTaskRunning, .taskSelectionChanged, .newPause, .usageNotFresh,
             .timeZoneChanged, .opportunityExpired, .nodeChanged: return false
        default: return true
        }
    }

}

/// Sanitized evidence from either admission checkpoint; never includes task content or account identity.
struct PingPreflightDiagnostic: Codable, LocalizedError {
    enum Stage: String, Codable { case modelDiscovery = "model_discovery", usageRead = "usage_read", sessionScan = "session_scan", afterUsage = "after_usage", beforeSend = "before_send" }
    let stage: Stage
    let reasons: [PingPreflightReason]
    let startedAt: Date
    let checkedAt: Date
    let elapsedSeconds: Double
    let usageCapturedAt: Date?
    let usageAgeSeconds: Double?
    let opportunityStartsAt: Date?
    let opportunityDeadline: Date?
    let newPauseCount: Int?
    var failure: UsageReadDiagnostic? = nil

    private func requiresAttention(_ reason: PingPreflightReason) -> Bool {
        reason.needsAttention && !(reason == .usageReadFailed && failure?.isTransient == true)
    }
    var needsAttention: Bool { reasons.isEmpty || reasons.contains(where: requiresAttention) }
    var errorDescription: String? {
        if let reason = reasons.first(where: requiresAttention) {
            if let failure, [.modelDiscoveryFailed, .usageReadFailed, .sessionScanFailed].contains(reason) {
                return CodexConnectionError.userMessage(reason: failure.reason)
            }
            return reason.userMessage
        }
        if reasons.contains(.disabled) { return PingPreflightReason.disabled.userMessage }
        if reasons.contains(.opportunityExpired) { return PingPreflightReason.opportunityExpired.userMessage }
        if reasons.contains(.usageReadFailed) { return L10n.text("正在确认中") }
        return reasons.first?.userMessage
    }
}

struct PingTiming {
    var warning: TimeInterval = 90
    var timeout: TimeInterval = 180
    var pollInterval: TimeInterval = 5
}

enum PingFailureReason: String, Codable {
    case unknown, requestTimeout = "request_timeout", connection, proxy, server
    case configuration, processExit = "process_exit", quotaRead = "quota_read", accountChanged = "account_changed", cancelled
}

/// Only allowlisted classifications leave the in-memory runtime log reader.
struct PingLogEvidence: Equatable {
    let reason: PingFailureReason
    let retryCount: Int?
    static func classify(_ body: String) -> PingLogEvidence? {
        let event = body.components(separatedBy: "}: ").last ?? body
        guard event.hasPrefix("stream disconnected - retrying sampling request "),
              let marker = event.range(of: "sampling_error=") else { return nil }
        let error = String(event[marker.upperBound...]).lowercased()
        let reason: PingFailureReason
        if error.contains("proxy authentication required") || error.contains("proxy connect") || error.contains("proxy tunnel") { reason = .proxy }
        else if error.range(of: #"(?:unexpected status(?: code)?[: ]+|http(?:/\d(?:\.\d)?)? )5\d\d\b"#, options: .regularExpression) != nil { reason = .server }
        else if error.contains("request timed out") { reason = .requestTimeout }
        else if ["connection refused", "connection reset", "dns error", "failed to lookup", "tls handshake", "certificate verify failed"].contains(where: error.contains) { reason = .connection }
        else { reason = .unknown }
        let expression = try! NSRegularExpression(pattern: #"\((\d+)/\d+"#)
        let match = expression.firstMatch(in: event, range: NSRange(event.startIndex..., in: event))
        let retry = match.flatMap { Range($0.range(at: 1), in: event) }.flatMap { Int(event[$0]) }
        return PingLogEvidence(reason: reason, retryCount: retry)
    }
}

struct PingDiagnostic: Codable {
    var elapsedSeconds: Double
    var warningSeconds: Double
    var timeoutSeconds: Double
    var threadID: String?
    var turnID: String?
    var reason: PingFailureReason = .unknown
    var retryCount: Int?
    var logStatus = "unavailable"
    var okReceived = false
    var taskCompleted = false
    var windowConfirmed = false
    var outcome = "waiting"
    var quotaReadFailure: UsageReadDiagnostic?

    var warning: String { L10n.text("正在确认中") }
    var failureMessage: String {
        switch reason {
        case .configuration: return L10n.text("设置未就绪，请更新 Codex。")
        case .accountChanged: return L10n.text("账户已切换，请切回原账户。")
        case .connection, .proxy, .requestTimeout: return L10n.text("连接失败，请检查网络。")
        case .server: return L10n.text("服务暂不可用，请等待下次保活。")
        case .cancelled: return L10n.text("本次保活已停止。")
        case .processExit, .quotaRead, .unknown: return L10n.text("结果待确认，请刷新查看额度。")
        }
    }
    var diagnosticMessage: String {
        switch reason {
        case .configuration: return L10n.text("保活未发送：Codex 无法读取保活配置")
        case .processExit: return L10n.text("保活进程提前退出，未确认新窗口；本轮不再重试")
        case .quotaRead: return L10n.text("保活已发送，但额度读取失败，未确认新窗口；本轮不再重试")
        case .accountChanged: return L10n.text("保活账户已改变，停止确认新窗口；本轮不再重试")
        case .cancelled: return L10n.text("保活已停止，未确认新窗口；本轮不再重试")
        default:
            let detail = okReceived ? (taskCompleted ? L10n.text("已收到 OK，但未确认新窗口") : L10n.text("已收到 OK，但任务尚未确认完成")) :
                reason == .requestTimeout ? L10n.text("请求超时，未收到模型回复") :
                reason == .proxy ? L10n.text("日志显示代理连接异常") :
                reason == .server ? L10n.text("日志显示服务端错误") :
                reason == .connection ? L10n.text("日志显示连接异常") : L10n.text("未收到模型回复，原因尚未确认")
            return L10n.format("保活未确认（%d 秒）：%@；本轮不再重试", Int(elapsedSeconds), detail)
        }
    }
}

struct PingFailure: LocalizedError {
    let diagnostic: PingDiagnostic
    var errorDescription: String? { diagnostic.failureMessage }
}

/// Scope evidence to the newly created ping session and the current attempt, including nanoseconds.
struct PingDiagnosticLogReader {
    let home: URL
    func read(threadID: String, turnID: String? = nil, since: Date, until: Date) -> (evidence: PingLogEvidence?, status: String) {
        guard UUID(uuidString: threadID) != nil else { return (nil, "unavailable") }
        let files = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        let databases = files.filter { $0.lastPathComponent.range(of: #"^logs(?:_[0-9]+)?\.sqlite$"#, options: .regularExpression) != nil }
        var latest: (Double, PingLogEvidence)?
        var readable = false
        for file in databases {
            var db: OpaquePointer?
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }; continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 100)
            var statement: OpaquePointer?
            let query = "SELECT ts, ts_nanos, feedback_log_body FROM logs WHERE thread_id = ? AND ts >= ? AND ts <= ? AND target = 'codex_core::responses_retry' ORDER BY ts DESC, ts_nanos DESC LIMIT 100"
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { sqlite3_finalize(statement); continue }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, threadID, -1, transient)
            sqlite3_bind_int64(statement, 2, Int64(since.timeIntervalSince1970))
            sqlite3_bind_int64(statement, 3, Int64(until.timeIntervalSince1970))
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                let at = Double(sqlite3_column_int64(statement, 0)) + Double(sqlite3_column_int64(statement, 1)) / 1_000_000_000
                if at >= since.timeIntervalSince1970, at <= until.timeIntervalSince1970,
                   let raw = sqlite3_column_text(statement, 2) {
                    let body = String(cString: raw)
                    let event = body.components(separatedBy: "}: ").last ?? body
                    let pattern = #"(?:^|\s)turn_id=([0-9a-fA-F-]{36})(?:\s|$)"#
                    let regex = try! NSRegularExpression(pattern: pattern)
                    let match = regex.firstMatch(in: event, range: NSRange(event.startIndex..., in: event))
                    let eventTurn = match.flatMap { Range($0.range(at: 1), in: event) }.map { String(event[$0]) }
                    if (turnID == nil || eventTurn == turnID), let evidence = PingLogEvidence.classify(body),
                       latest == nil || at > latest!.0 { latest = (at, evidence) }
                }
                step = sqlite3_step(statement)
            }
            if step == SQLITE_DONE { readable = true }
        }
        return (latest?.1, readable ? "readable" : "unavailable")
    }
}
