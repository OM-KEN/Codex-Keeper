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

    var locksContent: Bool { phase != .notSubmitted && phase != .preparing }
    var observesStartup: Bool { [.preparing, .sending, .confirming].contains(phase) }
    var needsManualContinuation: Bool { terminal == .manualRequired && endedAt != nil }
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
        guard ["item/started", "item/completed"].contains(method), let item = params["item"] as? [String: Any],
              let type = item["type"] as? String else { return false }
        if ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch", "imageGeneration", "computerUse"].contains(type) {
            guard method == "item/completed", item["error"] == nil else { return false }
            if ["commandExecution", "fileChange"].contains(type) { return item["status"] as? String == "completed" }
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

    static func make(task: BlockedSession, operation: ResumeOperation?, enabled: Bool = true, autoResume: Bool = true) -> ResumeTaskFact {
        let clock = DateFormatter(); clock.dateFormat = "MM-dd HH:mm"
        func fact(_ text: String, _ symbol: String = "clock", confirming: Bool = false) -> ResumeTaskFact {
            ResumeTaskFact(text: text, symbol: symbol, isConfirming: confirming)
        }
        if task.identityUncertain == true { return fact(L10n.text("确认中"), "clock", confirming: true) }
        if let operation {
            if operation.needsManualContinuation {
                return fact(operation.respondedAt.map { L10n.format("%@ · 已继续，请到 Codex 手动继续", clock.string(from: $0)) } ??
                    L10n.text("发送失败，请到 Codex 手动继续"), "exclamationmark.circle")
            }
            if let at = operation.respondedAt { return fact(L10n.format("%@ · 已继续", clock.string(from: at)), "checkmark.circle.fill") }
            switch operation.phase {
            case .preparing, .sending: return fact(L10n.text("正在发送"), "paperplane")
            case .confirming, .checking:
                return fact(L10n.text(operation.phase == .checking && !operation.protectsThread ? "本次启动未确认，原任务已有新进展" : "确认中"), "clock", confirming: operation.protectsThread)
            case .notSubmitted: return fact(L10n.format("未发送，%@", operation.failure ?? L10n.text("等待重试")), "exclamationmark.circle")
            case .stopped:
                return fact(L10n.text(operation.terminal == .quotaStopped ? "已暂停，等待自动继续" : "续跑已停止，请在 Codex 检查原任务"))
            case .continued, .manualRequired: break
            }
        }
        if !enabled { return fact(L10n.text("已暂停，Keeper 已停用"), "pause.circle") }
        if !autoResume { return fact(L10n.text("已暂停，自动续跑已关闭"), "pause.circle") }
        return fact(L10n.text("已暂停，等待自动继续"))
    }
}
