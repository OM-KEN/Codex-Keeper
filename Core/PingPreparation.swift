import Foundation

struct PingAuthentication {
    let data: Data
    let accountID: String

    static func read(home: URL) throws -> PingAuthentication {
        let url = home.appendingPathComponent("auth.json")
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["auth_mode"] == nil || object["auth_mode"] as? String == "chatgpt",
              object["OPENAI_API_KEY"] == nil || object["OPENAI_API_KEY"] is NSNull,
              let tokens = object["tokens"] as? [String: Any],
              let account = tokens["account_id"] as? String, !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["access_token", "id_token", "refresh_token"].contains(where: { (tokens[$0] as? String)?.isEmpty == false }),
              try Data(contentsOf: url) == data else {
            throw CodexConnectionError.server("无法确认 Codex 账户身份，请重新登录或更新 Codex；自动操作已暂停")
        }
        return PingAuthentication(data: data, accountID: account)
    }
}

/// Only this small, known set of files is checked between actual preparation events.
final class PingPreparation {
    let home: URL
    let work: URL
    private let mainHome: URL
    private let locate: () throws -> URL
    private let uptime: () -> TimeInterval
    private let lock = NSLock()
    private var executable: URL?
    private var model = PingModel(model: "gpt-6-luna", reasoningEffort: nil)
    private var metadata: [String] = []
    private var lastCheck: TimeInterval?
    private var accountID: String?
    private var invalidated = true
    private var relocationRequested = false
    private var configuredModel: PingModel?
    private var configMetadata: String?

    init(mainHome: URL, root: URL, locate: @escaping () throws -> URL = { try CodexLocator.binary() },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.mainHome = mainHome; self.locate = locate; self.uptime = uptime
        home = root.appendingPathComponent("home"); work = root.appendingPathComponent("work")
    }

    var preparedModel: PingModel { lock.lock(); defer { lock.unlock() }; return model }
    func invalidate(relocate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        invalidated = true; relocationRequested = relocationRequested || relocate
        model = PingModel(model: "gpt-6-luna", reasoningEffort: nil)
    }

    func maintain(provider: UsageProvider, forceCheck: Bool = false) {
        lock.lock()
        let now = uptime()
        guard invalidated || forceCheck || lastCheck.map({ now - $0 >= 300 }) != false else { lock.unlock(); return }
        lastCheck = now
        let first = executable == nil && metadata.isEmpty
        let old = metadata
        var discover = invalidated || first
        if first || relocationRequested { executable = try? locate(); discover = true; relocationRequested = false }
        let current = knownMetadata()
        let cliChanged = !old.isEmpty && Array(old.dropLast()) != Array(current.dropLast())
        if cliChanged { executable = try? locate(); model = PingModel(model: "gpt-6-luna", reasoningEffort: nil); discover = true }
        if first || old.last != current.last {
            let currentAccount = (try? PingAuthentication.read(home: mainHome))?.accountID
            if currentAccount != accountID {
                accountID = currentAccount; model = PingModel(model: "gpt-6-luna", reasoningEffort: nil); discover = true
            }
        }
        metadata = knownMetadata(); invalidated = false
        let discoveryAccount = accountID
        lock.unlock()
        if discover {
            provider.invalidatePingModel()
            let discovered = try? provider.pingModel()
            lock.lock()
            if let discovered, discovered.model == "gpt-6-luna",
               (try? PingAuthentication.read(home: mainHome))?.accountID == discoveryAccount { model = discovered }
            lock.unlock()
        }
        _ = try? prepareForSend()
    }

    /// No RPC, version probe, or session scan is allowed on the submission path.
    @discardableResult func prepareForSend(model requestedModel: PingModel? = nil) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let requestedModel { model = requestedModel }
        let currentAccount = (try? PingAuthentication.read(home: mainHome))?.accountID
        if currentAccount != accountID {
            accountID = currentAccount
            model = PingModel(model: "gpt-6-luna", reasoningEffort: nil); invalidated = true
        }
        if executable.map({ !FileManager.default.isExecutableFile(atPath: $0.path) }) != false {
            executable = try locate() // One local relocation when the cached path is missing.
            model = PingModel(model: "gpt-6-luna", reasoningEffort: nil); invalidated = true
        }
        let fm = FileManager.default
        for directory in [home, work] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let config = home.appendingPathComponent("config.toml")
        let signature = Self.fileMetadata(config)
        if configuredModel != model || configMetadata != signature || !fm.fileExists(atPath: config.path) {
            let text = try PTYPingTransport.configuration(work: work, model: model)
            if (try? String(contentsOf: config, encoding: .utf8)) != text { try text.write(to: config, atomically: true, encoding: .utf8) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            configuredModel = model; configMetadata = Self.fileMetadata(config)
        }
        return executable!
    }

    private func knownMetadata() -> [String] {
        var files: [URL] = []
        if let executable {
            files.append(executable)
            var parent = executable.deletingLastPathComponent()
            while parent.path != "/" {
                if parent.pathExtension == "app" { files.append(parent.appendingPathComponent("Contents/Info.plist")) }
                parent.deleteLastPathComponent()
            }
        }
        return files.map(Self.fileMetadata) + [Self.fileMetadata(mainHome.appendingPathComponent("auth.json"))]
    }

    private static func fileMetadata(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return [url.path, String(describing: attributes?[.systemFileNumber]), String(describing: (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate), String(describing: attributes?[.size])].joined(separator: ":")
    }
}
