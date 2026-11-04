import Foundation

/// A small projection for the existing session state machine. Message bodies never leave this decoder.
enum SessionRolloutDecoder {
    static func decode(_ data: Data) -> [String: Any]? {
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else { return nil }
        // Error payloads can carry quota evidence in arbitrary extension fields. Keep the
        // original parser on that uncommon path instead of narrowing its evidence surface.
        if event.fullPayload { return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        return event.value
    }

    private struct Event: Decodable {
        enum Key: String, CodingKey { case type, timestamp, payload }
        let value: [String: Any]
        let fullPayload: Bool
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            let payload = try fields.decode(Payload.self, forKey: .payload)
            var value: [String: Any] = ["payload": payload.value]
            value["type"] = fields.string(.type); value["timestamp"] = fields.string(.timestamp)
            self.value = value; fullPayload = payload.fullPayload
        }
    }

    private struct Payload: Decodable {
        enum Key: String, CodingKey {
            case type, timestamp, id, cwd, source, role, content, summary, output, message, text, error
            case threadID = "thread_id", threadId, turnID = "turn_id", turnId
            case forkedFrom = "forked_from_id", historyBase = "history_base"
            case lastAgentMessage = "last_agent_message", limits = "rate_limits", info
            case metadata = "internal_chat_message_metadata_passthrough"
        }
        let value: [String: Any]
        let fullPayload: Bool
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            let type = try? fields.decode(String.self, forKey: .type)
            fullPayload = type == "error" || type == "turn_failed" ||
                (["task_complete", "turn_aborted"].contains(type ?? "") && fields.contains(.error) && (try? fields.decodeNil(forKey: .error)) != true)
            if fullPayload { value = [:]; return }
            var value: [String: Any] = [:]
            for key in [Key.type, .timestamp, .id, .cwd, .role, .threadID, .threadId, .turnID, .turnId] {
                value[key.stringValue] = fields.string(key)
            }
            for key in [Key.forkedFrom, .historyBase, .error] where fields.contains(key) { value[key.stringValue] = NSNull() }
            if fields.contains(.source) {
                value["source"] = (try? fields.decode(Source.self, forKey: .source))?.value ?? NSNull()
            }
            for key in [Key.content, .summary] where fields.contains(key) {
                value[key.stringValue] = (try? fields.decode(TextContent.self, forKey: key))?.value ?? NSNull()
            }
            for key in [Key.message, .text, .lastAgentMessage] where fields.contains(key) {
                value[key.stringValue] = (try? fields.decode(VisibleText.self, forKey: key))?.value ?? NSNull()
            }
            if ["function_call_output", "custom_tool_call_output"].contains(type ?? ""), fields.contains(.output) {
                value["output"] = (try? fields.decode(ToolOutput.self, forKey: .output))?.value ?? NSNull()
            }
            if fields.contains(.limits) { value["rate_limits"] = (try? fields.decode(Limits.self, forKey: .limits))?.value ?? NSNull() }
            if fields.contains(.info) { value["info"] = (try? fields.decode(TokenInfo.self, forKey: .info))?.value ?? NSNull() }
            if fields.contains(.metadata) {
                value[Key.metadata.rawValue] = (try? fields.decode(MessageMetadata.self, forKey: .metadata))?.value ?? NSNull()
            }
            self.value = value
        }
    }

    private struct Source: Decodable {
        enum Key: String, CodingKey { case subagent }
        let value: [String: Any]
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            value = fields.contains(.subagent) ? ["subagent": NSNull()] : [:]
        }
    }

    private struct MessageMetadata: Decodable {
        enum Key: String, CodingKey { case kinds = "content_item_kinds" }
        let value: [String: Any]
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            let kinds = try? fields.decode([String].self, forKey: .kinds)
            value = [Key.kinds.rawValue: kinds?.contains("user.text") == true ? ["user.text"] : []]
        }
    }

    private struct Limits: Decodable {
        enum Key: String, CodingKey { case limitID = "limit_id", limitId, reached = "rate_limit_reached_type", rateLimitReachedType, primary, secondary }
        let value: [String: Any]
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            var value: [String: Any] = [:]
            for key in [Key.limitID, .limitId, .reached, .rateLimitReachedType] { value[key.stringValue] = fields.string(key) }
            for key in [Key.primary, .secondary] where fields.contains(key) {
                value[key.stringValue] = (try? fields.decode(Window.self, forKey: key))?.value ?? NSNull()
            }
            self.value = value
        }
    }

    private struct Window: Decodable {
        enum Key: String, CodingKey { case usedPercent, used = "used_percent", windowDurationMins, minutes = "window_minutes", resetsAt, reset = "resets_at" }
        let value: [String: Any]
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            var value: [String: Any] = [:]
            for key in [Key.usedPercent, .used, .windowDurationMins, .minutes, .resetsAt, .reset] { value[key.stringValue] = fields.number(key) }
            self.value = value
        }
    }

    private struct TokenInfo: Decodable {
        enum Key: String, CodingKey { case total = "total_token_usage", last = "last_token_usage" }
        let value: [String: Any]
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            var value: [String: Any] = [:]
            for key in [Key.total, .last] where fields.contains(key) {
                value[key.stringValue] = (try? fields.decode(TokenTotal.self, forKey: key))?.value ?? NSNull()
            }
            self.value = value
        }
    }

    private struct TokenTotal: Decodable {
        enum Key: String, CodingKey { case total = "total_tokens" }
        let value: [String: Any]
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            var value: [String: Any] = [:]; value["total_tokens"] = fields.number(.total)
            self.value = value
        }
    }

    private struct VisibleText: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "text"
        }
    }

    private struct ToolOutput: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value = "" }
            else if text.localizedCaseInsensitiveContains("user rejected") || text.localizedCaseInsensitiveContains("approval denied") { value = "approval denied" }
            else { value = "output" }
        }
    }

    /// Preserve the joined-text prefix and emptiness separately from visible model text.
    /// Scalar prefixes keep even very long combining-character sequences bounded.
    private struct TextContent: Decodable {
        private struct Piece: Decodable {
            enum Key: String, CodingKey { case text }
            let kind: Int // 0 = other, 1 = string, 2 = object
            let hasText: Bool
            let empty: Bool
            let visible: Bool
            let prefix: String
            init(from decoder: Decoder) throws {
                let text: String?
                if let string = try? decoder.singleValueContainer().decode(String.self) { kind = 1; text = string }
                else if let object = try? decoder.container(keyedBy: Key.self) { kind = 2; text = try? object.decode(String.self, forKey: .text) }
                else { kind = 0; text = nil }
                hasText = text != nil; empty = text?.isEmpty ?? true
                visible = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                var scalars = String.UnicodeScalarView()
                if let text { scalars.append(contentsOf: text.unicodeScalars.prefix(64)) }
                prefix = String(scalars)
            }
        }
        let value: Any
        init(from decoder: Decoder) throws {
            var pieces = try decoder.unkeyedContainer()
            var kind: Int?, valid = true, visible = false, seenText = false, nonempty = false
            var prefix = String.UnicodeScalarView()
            while !pieces.isAtEnd {
                let piece = try pieces.decode(Piece.self)
                if kind == nil { kind = piece.kind }
                valid = valid && piece.kind != 0 && kind == piece.kind
                visible = visible || piece.visible
                if piece.kind == 2, piece.hasText {
                    if seenText { nonempty = true; if prefix.count < 64 { prefix.append("\n") } }
                    nonempty = nonempty || !piece.empty; seenText = true
                    prefix.append(contentsOf: piece.prefix.unicodeScalars.prefix(max(0, 64 - prefix.count)))
                }
            }
            if !valid { value = NSNull() }
            else if kind == 1 { value = visible ? ["text"] : [""] }
            else {
                var text = String(prefix)
                if nonempty && text.isEmpty { text = "\n" }
                if visible && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += "text" }
                value = [["text": text]]
            }
        }
    }
}

private extension KeyedDecodingContainer {
    func string(_ key: Key) -> Any? {
        guard contains(key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        return NSNull() // Preserve a present-but-wrong primary field before an alias fallback.
    }
    func number(_ key: Key) -> Any? {
        guard contains(key) else { return nil }
        if let value = try? decode(Bool.self, forKey: key) { return NSNumber(value: value) }
        if let value = try? decode(Int64.self, forKey: key) { return NSNumber(value: value) }
        if let value = try? decode(Double.self, forKey: key) { return NSNumber(value: value) }
        return NSNull()
    }
}
