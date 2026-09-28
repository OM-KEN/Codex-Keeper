import Foundation

enum NextActionMode {
    case keepAlive, resume
    var title: String { self == .resume ? "自动继续" : "保持活动" }
}

struct NextAction {
    var mode: NextActionMode
    var date: Date?
    var decision: KeeperDecision
    var note: String
    var needsRecoveryDecision = false
}

/// Choices refer to a quota-stop episode, so a later stop in the same task defaults to selected.
enum ResumeMessageMode: String, Codable { case fixed, composerDraft }

enum ResumeMessagePreferences {
    enum Mode: String { case localizedDefault = "default", custom }

    static let modeKey = "resumeMessageMode"
    static let customizedKey = "resumeMessageCustomized"

    static func mode(saved: String?, storedMode: String?, legacyCustomized: Bool) -> Mode {
        if let storedMode, let mode = Mode(rawValue: storedMode) { return mode }
        if let saved, !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           legacyCustomized || (saved != "继续" && saved != "Continue") { return .custom }
        return .localizedDefault
    }

    static func content(saved: String?, mode: Mode, localizedDefault: String) -> String {
        guard mode == .custom, let saved, !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return localizedDefault }
        return saved
    }

    static func current(defaults: UserDefaults = .standard) -> String {
        let saved = defaults.string(forKey: "resumeMessage")
        return content(saved: saved, mode: mode(saved: saved, storedMode: defaults.string(forKey: modeKey),
            legacyCustomized: defaults.bool(forKey: customizedKey)), localizedDefault: L10n.text("继续"))
    }
}

struct RecoveryDecision: Codable, Equatable {
    enum NotificationState: String, Codable { case pending, requested, delivered, unavailable }
    enum Phase: String, Codable { case waitingForActivity, waitingForChoice, responded }
    let recoveredAt: Date
    var phase: Phase = .waitingForActivity
    var deadline: Date?
    var notification: NotificationState = .pending

    var message: String {
        switch phase {
        case .waitingForActivity, .waitingForChoice:
            return L10n.text("未选择时，提醒会一直保留，任务不会自动继续。")
        case .responded:
            return L10n.text("你已选择「现在继续」。若执行失败，请查看提示后重试。")
        }
    }
}

enum RecoveryChoice { case now, plan, cancel }

struct ResumeChoices: Codable, Equatable {
    var recoveryDecisions: [String: RecoveryDecision]? = nil

    mutating func requestRecoveryDecision(for task: BlockedSession, now: Date) {
        guard !keepAliveEpisodes.contains(task.episodeKey), recoveryDecisions?[task.episodeKey] == nil else { return }
        if recoveryDecisions == nil { recoveryDecisions = [:] }
        recoveryDecisions?[task.episodeKey] = RecoveryDecision(recoveredAt: now)
    }

    mutating func resolveRecoveryDecision(_ choice: RecoveryChoice, for task: BlockedSession) -> Bool {
        let key = task.episodeKey
        guard recoveryDecisions?[key] != nil, !keepAliveEpisodes.contains(key), !deselectedEpisodes.contains(key) else { return false }
        switch choice {
        case .now:
            recoveryDecisions?[key]?.phase = .responded
            recoveryDecisions?[key]?.deadline = nil
        case .plan: recoveryDecisions?.removeValue(forKey: key)
        case .cancel: useKeepAlive(for: [task])
        }
        return true
    }

    var messageModes: [String: ResumeMessageMode]? = nil

    func mode(for task: BlockedSession) -> ResumeMessageMode { messageModes?[task.episodeKey] ?? .fixed }
    var keepAliveEpisodes = Set<String>()
    var deselectedEpisodes = Set<String>()
    var messages: [String: String] = [:]

    var keepAliveIgnoredEpisodes: Set<String> {
        keepAliveEpisodes.union(recoveryDecisions?.keys.map { $0 } ?? [])
    }

    func permitsKeepAlive(for tasks: [BlockedSession], ignoring episodes: Set<String>) -> Bool {
        episodes.isSubset(of: keepAliveIgnoredEpisodes) && tasks.allSatisfy { episodes.contains($0.episodeKey) }
    }

    func available(_ tasks: [BlockedSession]) -> [BlockedSession] {
        tasks.filter { !keepAliveEpisodes.contains($0.episodeKey) }
    }
    func selected(_ tasks: [BlockedSession]) -> [BlockedSession] {
        available(tasks).filter { !deselectedEpisodes.contains($0.episodeKey) }
    }
    mutating func useKeepAlive(for tasks: [BlockedSession]) {
        keepAliveEpisodes.formUnion(tasks.map(\.episodeKey))
        for task in tasks { recoveryDecisions?.removeValue(forKey: task.episodeKey) }
    }
    func message(for task: BlockedSession, default value: String) -> String {
        let custom = messages[task.episodeKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? value : custom
    }
}
