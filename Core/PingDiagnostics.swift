import Foundation
import SQLite3

struct PingTiming {
    var warning: TimeInterval = 90
    var timeout: TimeInterval = 180
    var pollInterval: TimeInterval = 5
}

enum PingFailureReason: String, Codable {
    case unknown, requestTimeout = "request_timeout", connection, proxy, server
    case configuration, processExit = "process_exit", quotaRead = "quota_read", cancelled
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

    var warning: String {
        let prefix: String
        if okReceived { prefix = taskCompleted ? L10n.text("已收到 OK，仍在确认 5 小时窗口") : L10n.text("已收到 OK，仍在等待任务完成") }
        else {
            switch reason {
            case .requestTimeout: prefix = L10n.text("保活请求超时，Codex 正在重试")
            case .proxy: prefix = L10n.text("保活代理连接异常，Codex 正在重试")
            case .server: prefix = L10n.text("保活服务返回错误，Codex 正在重试")
            case .connection: prefix = L10n.text("保活连接异常，Codex 正在重试")
            default: prefix = L10n.text("保活尚未收到回复，原因暂未确认")
            }
        }
        return prefix + L10n.format("；继续等待至 %d 秒", Int(timeoutSeconds))
    }
    var failureMessage: String {
        switch reason {
        case .configuration: return L10n.text("保活未发送：Codex 无法读取保活配置")
        case .processExit: return L10n.text("保活进程提前退出，未确认新窗口；本轮不再重试")
        case .quotaRead: return L10n.text("保活额度读取失败，无法核实新窗口；本轮不再重试")
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
