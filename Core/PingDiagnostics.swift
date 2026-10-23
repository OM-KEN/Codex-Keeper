import Foundation

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

enum PingOutcome: String, Codable {
    case submitted, newWindow = "new_window", windowActive = "window_active", windowPending = "window_pending"
    case failed, unknown, notExecuted = "not_executed", skipped
}

/// The latest event for an account/node is its one execution fact, shared by history and alerts.
struct PingNodeResult: Codable {
    let node: Date
    let accountID: String?
    let at: Date
    let outcome: PingOutcome
    var diagnostic: PingDiagnostic? = nil
    var preflight: PingPreflightDiagnostic? = nil
    var detail: String? = nil
    var acknowledgedAt: Date? = nil

    var message: String {
        switch outcome {
        case .submitted: return L10n.text("正在确认中")
        case .newWindow: return L10n.text("已确认新的 5 小时窗口")
        case .windowActive: return L10n.text("保活请求已完成，窗口有效。")
        case .windowPending: return L10n.text("保活请求已完成，窗口待确认。")
        case .skipped: return L10n.text("已有有效 5 小时窗口")
        case .notExecuted:
            let message = L10n.text("本次保活已错过，请等待下次保活或手动保活。")
            guard let detail, !detail.isEmpty, detail != L10n.text("正在确认中") else { return message }
            return message + "\n" + L10n.format("上轮原因：%@", detail)
        case .failed, .unknown: return preflight?.errorDescription ?? diagnostic?.failureMessage ?? detail ?? L10n.text("结果待确认，请刷新查看额度。")
        }
    }
    var succeeded: Bool { outcome == .newWindow || outcome == .windowActive }
    var needsAttention: Bool { acknowledgedAt == nil && [.failed, .unknown, .windowPending, .notExecuted].contains(outcome) }
    var historyLabel: String {
        switch outcome {
        case .submitted: return "正在确认中"
        case .newWindow: return "新窗口已确认"
        case .windowActive: return "请求完成，窗口有效"
        case .windowPending: return "请求完成，窗口待确认"
        case .failed: return "保活失败"
        case .unknown: return "结果待确认"
        case .notExecuted: return "本轮未执行"
        case .skipped: return "已有有效窗口"
        }
    }
}

enum PingFailureReason: String, Codable {
    case unknown, requestTimeout = "request_timeout", connection, proxy, server
    case model, request, launch, configuration, processExit = "process_exit", quotaRead = "quota_read", accountChanged = "account_changed", cancelled
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
    var errorCode: String?
    var stage: String = "confirmation"

    var warning: String { L10n.text("正在确认中") }
    var failureMessage: String {
        switch reason {
        case .launch: return L10n.text("无法启动 Codex，请更新后刷新。")
        case .model: return L10n.text("当前模型不可用，请更新 Codex 后刷新。")
        case .request: return L10n.text("保活请求失败，请等待下次保活。")
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
        case .launch: return L10n.text("保活未发送：Codex 无法启动")
        case .model, .request: return L10n.text("保活请求已报错；本轮不再重试")
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


/// Local preparation/Process.run failed before a request process existed.
struct PingSubmissionError: LocalizedError {
    let underlying: Error
    var stage = "preparation"
    var errorDescription: String? { underlying.localizedDescription }
}
