import Foundation

/// Reads only the selected task's persisted composer text. Never changes Codex's state.
struct ComposerDraftReader {
    var url = CodexEnvironment.home.appendingPathComponent(".codex-global-state.json")

    func read(threadID: String) throws -> String? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw CodexConnectionError.server("无法读取 Codex 草稿；请检查 Codex 或改用固定内容") }
        return try Self.decode(data, threadID: threadID)
    }

    static func decode(_ data: Data, threadID: String) throws -> String? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atoms = root["electron-persisted-atom-state"] as? [String: Any] else {
            throw CodexConnectionError.server("Codex 草稿格式已变化，请改用固定内容")
        }
        // A present, empty v2 store means the old v1 drafts were cleared/migrated.
        let rawStore = atoms["composer-prompt-drafts-v2"] ?? atoms["composer-prompt-drafts-v1"]
        guard let rawStore else { return nil }
        guard let store = rawStore as? [String: Any] else { throw unsupported }
        let key = "local:" + threadID
        guard let entry = store[key], !(entry is NSNull) else { return nil }
        let rawPrompt = (entry as? [String: Any])?["prompt"] ?? entry
        let text: String
        if let string = rawPrompt as? String { text = string }
        else if let prompt = rawPrompt as? [String: Any], let document = prompt["document"] as? [String: Any] {
            let retained = (atoms["composer-retained-documents-v1"] as? [String: Any])?[key] as? [String: Any]
            if let saved = retained?["document"] as? [String: Any], NSDictionary(dictionary: document).isEqual(to: saved),
               (retained?["plainTextMode"] as? Bool ?? false) == (prompt["plainTextMode"] as? Bool ?? false),
               let serialized = retained?["prompt"] as? String {
                text = serialized
            } else { text = try plainDocument(document) }
        } else { throw unsupported }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static var unsupported: CodexConnectionError {
        .server("草稿含有无法读取的格式；请改用固定内容，或在 Codex 中发送")
    }
    private static func plainDocument(_ node: [String: Any]) throws -> String {
        switch node["type"] as? String {
        case "text":
            guard let text = node["text"] as? String else { throw unsupported }
            // Rich text is read as text; unsupported references are never silently dropped.
            if let marks = node["marks"] as? [[String: Any]], marks.contains(where: { $0["type"] as? String == "link" }) { throw unsupported }
            return text
        case "hard_break": return "\n"
        case "doc", "paragraph":
            let children = node["content"] as? [[String: Any]] ?? []
            return try children.map(plainDocument).joined(separator: node["type"] as? String == "doc" ? "\n" : "")
        default: throw unsupported
        }
    }
}
