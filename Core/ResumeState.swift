import Foundation

/// The quota data that preceded a submission is evidence, never a refreshed reading.
struct ResumeQuotaEvidence: Codable, Equatable {
    let accountID: String
    let capturedAt: Date
    let fiveHour: QuotaWindow?
    let weekly: QuotaWindow?

    init?(_ usage: UsageSnapshot) {
        guard let account = usage.accountID else { return nil }
        accountID = account; capturedAt = usage.capturedAt
        fiveHour = usage.fiveHour; weekly = usage.weekly
    }

    func provesRecovery(_ usage: UsageSnapshot, after stop: Date) -> Bool {
        guard usage.accountID == accountID, usage.capturedAt > stop,
              (usage.fiveHour?.usedPercent ?? 0) < 100, (usage.weekly?.usedPercent ?? 0) < 100 else { return false }
        let pairs = [(fiveHour, usage.fiveHour), (weekly, usage.weekly)]
        return pairs.contains { old, new in
            guard let old, let new else { return false }
            return old.usedPercent >= 100 || new.resetsAt != old.resetsAt ||
                (old.resetsAt > stop && usage.capturedAt >= old.resetsAt)
        }
    }
}

enum ResumePreflightReason: String, Codable {
    case workspaceUnavailable = "workspace_unavailable"
    case archived = "archived"
    case sessionUnreadable = "session_unreadable"
    case threadChanged = "thread_changed"
    case subagent = "subagent"
    case userInputAfterPause = "user_input_after_pause"
    case taskStartedAfterPause = "task_started_after_pause"
    case taskAbortedAfterPause = "task_aborted_after_pause"
    case modelResponseAfterPause = "model_response_after_pause"
    case taskRunning = "task_running"
    case pauseChanged = "pause_changed"
    case accountUnconfirmed = "account_unconfirmed"
    case accountChanged = "account_changed"
    case usageNotFresh = "usage_not_fresh"
    case usageBeforePause = "usage_before_pause"
    case quotaMissing = "quota_missing"
    case fiveHourMissing = "five_hour_missing"
    case weeklyMissing = "weekly_missing"
    case fiveHourExhausted = "five_hour_exhausted"
    case weeklyExhausted = "weekly_exhausted"
    case recoveryUnconfirmed = "recovery_unconfirmed"
    case generationChanged = "generation_changed"
    case ledgerUnhealthy = "ledger_unhealthy"
    case alreadyAttempted = "already_attempted"
    case selectionChanged = "selection_changed"
    case runtimeUnhealthy = "runtime_unhealthy"
    case sessionScanFailed = "session_scan_failed"
    case autoResumeDisabled = "auto_resume_disabled"
    case messageModeChanged = "message_mode_changed"
    case promptChanged = "prompt_changed"
    case recoveryChoiceChanged = "recovery_choice_changed"
    case timeZoneChanged = "timezone_changed"
    case policyChanged = "policy_changed"
    case anchorChanged = "anchor_changed"
    case disabled = "disabled"
    case appStateUnavailable = "app_state_unavailable"
    case workspaceChanged = "workspace_changed"
    case preparationFailed = "preparation_failed"
    case preparationInterrupted = "preparation_interrupted"

    var message: String {
        switch self {
        case .workspaceUnavailable: return L10n.text("工作目录不可用")
        case .archived: return L10n.text("原任务已归档")
        case .sessionUnreadable: return L10n.text("无法读取原任务记录")
        case .threadChanged: return L10n.text("原任务身份已改变")
        case .subagent: return L10n.text("子任务不支持自动续跑")
        case .userInputAfterPause: return L10n.text("原任务已有新的用户输入")
        case .taskStartedAfterPause: return L10n.text("原任务已再次开始")
        case .taskAbortedAfterPause: return L10n.text("原任务已被停止")
        case .modelResponseAfterPause: return L10n.text("原任务已有新的模型响应")
        case .taskRunning: return L10n.text("原任务正在运行")
        case .pauseChanged: return L10n.text("原任务的额度停止记录已变化")
        case .accountUnconfirmed: return L10n.text("账户暂时无法确认")
        case .accountChanged: return L10n.text("账户已改变")
        case .usageNotFresh: return L10n.text("额度读数需重新确认")
        case .usageBeforePause: return L10n.text("额度采样未晚于本次暂停")
        case .quotaMissing: return L10n.text("额度窗口暂时无法确认")
        case .fiveHourMissing: return L10n.text("5 小时额度暂时无法确认")
        case .weeklyMissing: return L10n.text("每周额度暂时无法确认")
        case .fiveHourExhausted: return L10n.text("5 小时额度尚未恢复")
        case .weeklyExhausted: return L10n.text("每周额度尚未恢复")
        case .recoveryUnconfirmed: return L10n.text("本次额度恢复尚未确认")
        case .generationChanged: return L10n.text("本次续跑准备已取消")
        case .ledgerUnhealthy: return L10n.text("执行记录无法保存")
        case .alreadyAttempted: return L10n.text("本次暂停已尝试续跑")
        case .selectionChanged: return L10n.text("任务选择已改变")
        case .runtimeUnhealthy: return L10n.text("待续状态无法保存")
        case .sessionScanFailed: return L10n.text("任务扫描失败")
        case .autoResumeDisabled: return L10n.text("自动续跑已关闭")
        case .messageModeChanged: return L10n.text("发送内容选项已改变")
        case .promptChanged: return L10n.text("发送内容已改变")
        case .recoveryChoiceChanged: return L10n.text("续跑恢复选择已改变")
        case .timeZoneChanged: return L10n.text("系统时区已改变")
        case .policyChanged: return L10n.text("提前恢复策略已改变")
        case .anchorChanged: return L10n.text("每日开始时间已改变")
        case .disabled: return L10n.text("Keeper 已停用")
        case .appStateUnavailable: return L10n.text("应用状态暂时无法确认")
        case .workspaceChanged: return L10n.text("原任务工作目录已改变")
        case .preparationFailed: return L10n.text("续跑准备失败")
        case .preparationInterrupted: return L10n.text("续跑准备已中断")
        }
    }
    var userMessage: String {
        switch self {
        case .accountChanged: return CodexConnectionError.userMessage(reason: "account_changed")
        case .accountUnconfirmed: return L10n.text("账户待确认，请在 Codex 检查登录后刷新。")
        case .usageNotFresh, .usageBeforePause, .quotaMissing, .fiveHourMissing, .weeklyMissing: return L10n.text("额度待更新，请刷新后重试。")
        case .fiveHourExhausted, .weeklyExhausted, .recoveryUnconfirmed: return L10n.text("额度待恢复，请等待额度恢复后再试。")
        case .runtimeUnhealthy, .ledgerUnhealthy: return L10n.text("记录不可用，请检查磁盘空间后刷新。")
        case .disabled: return L10n.text("Keeper 已暂停，请在设置中启用 Keeper。")
        case .autoResumeDisabled: return L10n.text("自动继续已暂停，请在设置中开启自动继续。")
        case .generationChanged, .timeZoneChanged, .policyChanged, .anchorChanged, .selectionChanged, .messageModeChanged, .promptChanged:
            return L10n.text("设置已更新，请查看当前计划。")
        case .recoveryChoiceChanged: return L10n.text("续跑选择已更新，请查看当前计划。")
        case .sessionScanFailed, .appStateUnavailable: return L10n.text("状态待更新，请刷新后查看。")
        case .workspaceUnavailable: return L10n.text("找不到项目文件夹，请检查位置或废纸篓。")
        case .archived: return L10n.text("原任务已归档，请到 Codex 查看原任务。")
        case .sessionUnreadable: return L10n.text("任务记录无法读取，请到 Codex 查看原任务。")
        case .taskAbortedAfterPause: return L10n.text("任务已中断，请到 Codex 查看原任务。")
        case .userInputAfterPause, .taskStartedAfterPause, .modelResponseAfterPause, .taskRunning: return L10n.text("原任务已手动继续。")
        case .pauseChanged, .alreadyAttempted: return L10n.text("任务状态已更新。")
        case .threadChanged, .subagent, .workspaceChanged, .preparationFailed:
            return L10n.text("任务待处理，请先到 Codex 查看原任务。")
        case .preparationInterrupted: return L10n.text("继续操作已中断，请手动重试。")
        }
    }

    var isOrdinaryUpdate: Bool {
        switch self {
        case .generationChanged, .timeZoneChanged, .policyChanged, .anchorChanged, .selectionChanged,
             .messageModeChanged, .promptChanged, .recoveryChoiceChanged, .disabled, .autoResumeDisabled,
             .userInputAfterPause, .taskStartedAfterPause, .modelResponseAfterPause, .taskRunning,
             .pauseChanged, .alreadyAttempted: return true
        default: return false
        }
    }
    var isQuotaWait: Bool {
        switch self {
        case .usageNotFresh, .usageBeforePause, .quotaMissing, .fiveHourMissing, .weeklyMissing,
             .fiveHourExhausted, .weeklyExhausted, .recoveryUnconfirmed: return true
        default: return false
        }
    }
}

/// Classification and timing only; model text, prompts, account identifiers and paths are never included.
struct ResumePreflightDiagnostic: Codable, Equatable, LocalizedError {
    enum Stage: String, Codable {
        case channelPrepare = "channel_prepare", sessionCheck = "session_check", usageRead = "usage_read", sessionScan = "session_scan"
        case pauseCheck = "pause_check", quotaCheck = "quota_check", promptRead = "prompt_read", planCheck = "plan_check", beforeSend = "before_send"
    }
    let stage: Stage
    let reasons: [ResumePreflightReason]
    let checkedAt: Date
    let pauseAt: Date
    let usageCapturedAt: Date?
    let usageAgeSeconds: Double?
    var startedAt: Date?
    var elapsedSeconds: Double?
    var failure: UsageReadDiagnostic?

    init(stage: Stage, reasons: [ResumePreflightReason], target: BlockedSession, checkedAt: Date, usage: UsageSnapshot? = nil, failure: UsageReadDiagnostic? = nil) {
        self.stage = stage; self.reasons = reasons; self.checkedAt = checkedAt; pauseAt = target.blockedAt
        usageCapturedAt = usage?.capturedAt; usageAgeSeconds = usage.map { checkedAt.timeIntervalSince($0.capturedAt) }; self.failure = failure
    }
    private func requiresAttention(_ reason: ResumePreflightReason, manual: Bool?) -> Bool {
        if reason.isOrdinaryUpdate { return false }
        if stage == .planCheck, reason == .preparationFailed { return false }
        if manual == false, reason.isQuotaWait || reason == .preparationInterrupted { return false }
        if manual == false, reason == .preparationFailed, failure?.isTransient == true,
           [.channelPrepare, .usageRead].contains(stage) { return false }
        return true
    }
    func needsAttention(manual: Bool?) -> Bool {
        stage == .promptRead || reasons.isEmpty || reasons.contains { requiresAttention($0, manual: manual) }
    }
    func userMessage(manual: Bool?) -> String? {
        if stage == .promptRead { return L10n.text("发送内容不可用，请改用“默认发送”后重试。") }
        if let reason = reasons.first(where: { requiresAttention($0, manual: manual) }) {
            if reason == .preparationFailed, let failure { return CodexConnectionError.userMessage(reason: failure.reason) }
            return reason.userMessage
        }
        if reasons.contains(.disabled) { return L10n.text("已暂停，Keeper 已停用") }
        if reasons.contains(.autoResumeDisabled) { return L10n.text("已暂停，自动续跑已关闭") }
        if reasons.contains(where: { [.userInputAfterPause, .taskStartedAfterPause, .modelResponseAfterPause, .taskRunning].contains($0) }) {
            return L10n.text("原任务已手动继续。")
        }
        if reasons.contains(.pauseChanged) || reasons.contains(.alreadyAttempted) { return L10n.text("任务状态已更新。") }
        if reasons.contains(.recoveryChoiceChanged) { return ResumePreflightReason.recoveryChoiceChanged.userMessage }
        if stage == .planCheck { return L10n.text(manual == false ? "等待下次自动继续。" : "本次未发送，请查看当前计划。") }
        if reasons.contains(where: \.isOrdinaryUpdate) {
            return L10n.text(manual == false ? "设置已更新，等待下次自动继续。" : "设置已更新，请查看当前计划。")
        }
        if reasons.contains(.fiveHourExhausted) || reasons.contains(.weeklyExhausted) || reasons.contains(.recoveryUnconfirmed) {
            return L10n.text("等待额度恢复。")
        }
        if reasons.contains(.preparationInterrupted) { return L10n.text("继续操作已中断，等待自动重试。") }
        return reasons.isEmpty ? nil : L10n.text("正在确认中")
    }
    var errorDescription: String? { userMessage(manual: nil) }
    var diagnosticDescription: String? {
        if let failure, reasons.contains(.preparationFailed) {
            switch failure.reason {
            case "cli_unavailable": return CodexConnectionError.unavailable.diagnosticDescription
            case "invalid_response": return CodexConnectionError.invalidResponse.diagnosticDescription
            case "approval_required": return CodexConnectionError.approvalRequired.diagnosticDescription
            case "request_timeout", "workspace_routing_timeout": return L10n.text("Codex 服务连接超时，请检查网络或代理后重新同步。")
            case "connection_failed", "connection_ended": return L10n.text("无法连接 Codex 服务，请检查网络或代理后重新同步。")
            case "service_unavailable": return L10n.text("Codex 服务暂时不可用，请稍后重新同步。")
            case "authentication_failed", "capability_or_authentication", "account_changed": return L10n.text("无法确认 Codex 账户身份，请重新登录或更新 Codex；自动操作已暂停")
            case "response_too_large": return L10n.text("Codex 返回的数据超过读取上限，已停止本次操作")
            default: return L10n.text("Codex 请求失败，请检查网络和登录状态后重试。")
            }
        }
        return reasons.first?.message
    }
}

enum ResumePhase: String, Codable {
    case preparing, sending, confirming, checking, continued, notSubmitted, stopped, manualRequired
}

enum ResumeTerminal: String, Codable { case completed, quotaStopped, manualRequired, aborted, failed, disconnected }

struct ResumeOperation: Codable, Equatable, Identifiable {
    let id: String
    let batchID: String
    let accountID: String?
    let target: BlockedSession
    var actionAt: Date
    var phase: ResumePhase
    var turnID: String?
    var receivedAt: Date?
    var respondedAt: Date?
    var endedAt: Date?
    var terminal: ResumeTerminal?
    var failure: String?
    var quotaBefore: ResumeQuotaEvidence?
    var protectsThread: Bool
    var manual: Bool? = nil
    var manualRequested: Bool? = nil
    var preflight: ResumePreflightDiagnostic? = nil

    var locksContent: Bool { phase != .notSubmitted && phase != .preparing }
    var observesStartup: Bool { [.preparing, .sending, .confirming].contains(phase) }
    var needsManualContinuation: Bool { terminal == .manualRequired && endedAt != nil }
    var notSubmittedNeedsAttention: Bool { phase == .notSubmitted && (preflight?.needsAttention(manual: manual) ?? true) }
    var waitsForAutomaticRetry: Bool {
        phase == .notSubmitted && manual == false && !notSubmittedNeedsAttention &&
            preflight?.reasons.allSatisfy { $0.isQuotaWait || $0 == .preparationFailed || $0 == .preparationInterrupted } == true
    }
    var canRetrySubmission: Bool {
        guard phase == .notSubmitted, notSubmittedNeedsAttention || manual == true else { return false }
        return preflight?.reasons.contains { [.userInputAfterPause, .taskStartedAfterPause, .modelResponseAfterPause,
            .taskRunning, .taskAbortedAfterPause, .pauseChanged, .alreadyAttempted].contains($0) } != true
    }
    var notSubmittedMessage: String {
        preflight?.userMessage(manual: manual) ?? L10n.text("发送未完成，请先在 Codex 检查原任务。")
    }
}

struct SessionTurnEvidence: Equatable {
    var startedAt: Date?
    var responseAt: Date?
    var endedAt: Date?
    var terminal: ResumeTerminal?
}

/// Only the content-submission RPC uses this distinction. Preparation cannot send content.
struct ResumeSubmissionError: LocalizedError {
    let mayHaveSubmitted: Bool
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

enum ResumeTransportEvent {
    case received(ResumeReceipt, Date)
    case responded(String, Date)
    case awaiting
    case unknown(String)
    case notSubmitted(String)
    case manualRequested
    case ended(String?, ResumeTerminal, String?, Date)
    case observationEnded
}

/// Model activity only; empty placeholders and user input do not prove startup.
enum ResumeModelActivity {
    static func rollout(_ row: [String: Any]) -> Bool {
        guard let payload = row["payload"] as? [String: Any] else { return false }
        let type = payload["type"] as? String ?? ""
        if row["type"] as? String == "event_msg" {
            if type == "task_complete" {
                return (payload["error"] == nil || payload["error"] is NSNull) && nonempty(payload["last_agent_message"])
            }
            guard ["agent_message", "agent_reasoning", "agent_reasoning_raw_content"].contains(type) else { return false }
            return nonempty(payload["message"]) || nonempty(payload["text"])
        }
        guard row["type"] as? String == "response_item" else { return false }
        if type == "function_call_output" || type == "custom_tool_call_output" {
            let output = payload["output"] as? String ?? ""
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !output.localizedCaseInsensitiveContains("user rejected") && !output.localizedCaseInsensitiveContains("approval denied")
        }
        if type == "message", payload["role"] as? String == "assistant" {
            return hasText(payload["content"])
        }
        if type == "reasoning" { return hasText(payload["summary"]) || hasText(payload["content"]) }
        return false
    }

    static func appServer(method: String, params: [String: Any]) -> Bool {
        if ["item/agentMessage/delta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta"].contains(method) {
            return nonempty(params["delta"])
        }
        if ["item/commandExecution/outputDelta", "item/fileChange/outputDelta"].contains(method) { return nonempty(params["delta"]) }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any], let items = turn["items"] as? [[String: Any]] {
            return items.contains { appServer(method: "item/completed", params: ["item": $0]) }
        }
        guard ["item/started", "item/completed"].contains(method), let item = params["item"] as? [String: Any],
              let type = item["type"] as? String else { return false }
        if ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch", "imageGeneration", "computerUse"].contains(type) {
            guard method == "item/completed", item["error"] == nil || item["error"] is NSNull else { return false }
            if ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall"].contains(type) { return item["status"] as? String == "completed" }
            return item["status"] as? String != "failed" && item["status"] as? String != "declined"
        }
        if type == "agentMessage" { return nonempty(item["text"]) }
        if type == "reasoning" { return hasText(item["summary"]) || hasText(item["content"]) }
        return false
    }

    static func manualRequest(_ method: String) -> Bool {
        ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput",
         "item/permissions/requestApproval", "mcpServer/elicitation/request", "execCommandApproval", "applyPatchApproval"].contains(method)
    }

    static func quotaError(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["usage_limit_reached", "usage_limit_exceeded", "quota_exhausted", "insufficient_quota",
                "you’ve hit your usage limit", "you've hit your usage limit"].contains { text.contains($0) }
    }

    private static func nonempty(_ value: Any?) -> Bool {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    private static func hasText(_ value: Any?) -> Bool {
        if let strings = value as? [String] { return strings.contains { nonempty($0) } }
        return (value as? [[String: Any]])?.contains { nonempty($0["text"]) } == true
    }
}

struct ResumeTaskFact {
    let text: String
    let symbol: String
    let isConfirming: Bool

    static func make(task: BlockedSession, operation: ResumeOperation?, enabled: Bool = true, autoResume: Bool = true,
                     selected: Bool = true, cancelled: Bool = false) -> ResumeTaskFact {
        let clock = DateFormatter(); clock.dateFormat = "MM-dd HH:mm"
        func fact(_ text: String, _ symbol: String = "clock", confirming: Bool = false) -> ResumeTaskFact {
            ResumeTaskFact(text: text, symbol: symbol, isConfirming: confirming)
        }
        if task.identityUncertain == true { return fact(L10n.text("正在确认中"), "clock", confirming: true) }
        if let operation {
            if operation.needsManualContinuation {
                return fact(operation.respondedAt.map { L10n.format("%@ · 已继续，请到 Codex 手动继续", clock.string(from: $0)) } ??
                    L10n.text("需要手动继续，请到 Codex 查看原任务。"), "exclamationmark.circle")
            }
            if let at = operation.respondedAt { return fact(L10n.format("%@ · 已继续", clock.string(from: at)), "checkmark.circle.fill") }
            switch operation.phase {
            case .preparing, .sending, .confirming, .checking: return fact(L10n.text("正在确认中"), "clock", confirming: true)
            case .notSubmitted:
                if operation.notSubmittedNeedsAttention { return fact(operation.notSubmittedMessage, "exclamationmark.circle") }
                if !enabled { return fact(L10n.text("已暂停，Keeper 已停用"), "pause.circle") }
                if cancelled { return fact(L10n.text("已取消本次自动继续"), "pause.circle") }
                if !autoResume { return fact(L10n.text("已暂停，自动续跑已关闭"), "pause.circle") }
                if !selected { return fact(L10n.text("已暂停，未选择自动继续"), "pause.circle") }
                return fact(operation.notSubmittedMessage)
            case .stopped:
                switch operation.terminal {
                case .quotaStopped: break
                case .aborted: return fact(L10n.text("任务已中断，请到 Codex 查看原任务。"))
                case .failed: return fact(L10n.text("继续失败，请到 Codex 查看原任务。"))
                default: return fact(L10n.text("结果未确认，请到 Codex 查看原任务。"))
                }
            case .continued, .manualRequired: break
            }
        }
        if !enabled { return fact(L10n.text("已暂停，Keeper 已停用"), "pause.circle") }
        if cancelled { return fact(L10n.text("已取消本次自动继续"), "pause.circle") }
        if !autoResume || !selected { return fact(L10n.text("已暂停，自动续跑已关闭"), "pause.circle") }
        return fact(L10n.text("等待自动继续"))
    }
}
