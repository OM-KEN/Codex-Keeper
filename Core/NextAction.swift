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
}

/// Choices refer to a quota-stop episode, so a later stop in the same task defaults to selected.
enum ResumeMessageMode: String, Codable { case fixed, composerDraft }

struct ResumeChoices: Codable, Equatable {
    var messageModes: [String: ResumeMessageMode]? = nil

    func mode(for task: BlockedSession) -> ResumeMessageMode { messageModes?[task.episodeKey] ?? .fixed }
    var keepAliveEpisodes = Set<String>()
    var deselectedEpisodes = Set<String>()
    var messages: [String: String] = [:]

    func available(_ tasks: [BlockedSession]) -> [BlockedSession] {
        tasks.filter { !keepAliveEpisodes.contains($0.episodeKey) }
    }
    func selected(_ tasks: [BlockedSession]) -> [BlockedSession] {
        available(tasks).filter { !deselectedEpisodes.contains($0.episodeKey) }
    }
    mutating func useKeepAlive(for tasks: [BlockedSession]) {
        keepAliveEpisodes.formUnion(tasks.map(\.episodeKey))
    }
    func message(for task: BlockedSession, default value: String) -> String {
        let custom = messages[task.episodeKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? value : custom
    }
}
