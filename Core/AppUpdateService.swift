import Foundation
import Combine
import AppKit

enum AppVersion {
    static var currentString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

enum MenuVersionTextFormatter {
    static func string(version: String, hasUpdate: Bool) -> String {
        L10n.format(hasUpdate ? "版本 %@ · 有新版本" : "版本 %@", version)
    }
}

struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(tag: String) {
        let value = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({
            !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } && ($0.count == 1 || $0.first != "0")
        }), let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct AppRelease: Equatable {
    let version: SemanticVersion
    let pageURL: URL
    var importantUpdateVersion: SemanticVersion? = nil
    var releaseNotes = ""
}

extension AppRelease {
    init?(pageURL: URL) {
        let prefix = "/OM-KEN/Codex-Keeper/releases/tag/"
        guard pageURL.scheme?.lowercased() == "https", pageURL.host?.lowercased() == "github.com",
              pageURL.user == nil, pageURL.password == nil, pageURL.port == nil, pageURL.query == nil, pageURL.fragment == nil,
              pageURL.path.hasPrefix(prefix),
              let version = SemanticVersion(tag: String(pageURL.path.dropFirst(prefix.count))) else { return nil }
        self.init(version: version, pageURL: pageURL)
    }

    func displayNotes(localization: String?) -> String {
        let text = releaseNotes
            .replacingOccurrences(of: #"<!--\s*keeper-important-update:[\s\S]*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let englishHeadings = ["## What's New", "## Fixes"]
        let chineseHeadings = ["## 新功能", "## 修复"]
        let prefersEnglish = localization?.lowercased().hasPrefix("en") == true
        let preferredHeadings = prefersEnglish ? englishHeadings : chineseHeadings
        let fallbackHeadings = prefersEnglish ? chineseHeadings : englishHeadings
        var preamble = ""
        var sections: [(heading: String, content: String)] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                sections.append((line.trimmingCharacters(in: .whitespaces), ""))
            } else if sections.isEmpty {
                preamble += line + "\n"
            } else {
                sections[sections.count - 1].content += line + "\n"
            }
        }
        let populatedSections = sections.filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let preferred = populatedSections.filter { preferredHeadings.contains($0.heading) }
        let selected = preferred.isEmpty
            ? populatedSections.filter { fallbackHeadings.contains($0.heading) }
            : preferred
        if !selected.isEmpty {
            return selected.map {
                $0.heading + "\n" + $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined(separator: "\n\n")
        }
        return populatedSections.isEmpty && preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : text
    }
}

enum LatestReleaseParseResult: Equatable {
    case release(AppRelease)
    case noStableRelease
    case rateLimited
    case failure
}

enum LatestReleaseParser {
    static let endpoint = URL(string: "https://api.github.com/repos/OM-KEN/Codex-Keeper/releases/latest")!
    static let fallbackEndpoint = URL(string: "https://github.com/OM-KEN/Codex-Keeper/releases/latest")!

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let body: String?
    }

    static func parse(data: Data, response: URLResponse) -> LatestReleaseParseResult {
        guard let response = response as? HTTPURLResponse, response.url == endpoint else { return .failure }
        if response.statusCode == 429 { return .rateLimited }
        if response.statusCode == 403 {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
               response.value(forHTTPHeaderField: "Retry-After") != nil ||
               message?.lowercased().contains("rate limit") == true { return .rateLimited }
        }
        if response.statusCode == 404 { return .noStableRelease }
        guard (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(Payload.self, from: data), !payload.draft, !payload.prerelease,
              let version = SemanticVersion(tag: payload.tag_name),
              var release = AppRelease(pageURL: payload.html_url), release.version == version else { return .failure }
        release.importantUpdateVersion = importantUpdateVersion(in: payload.body, releaseVersion: version)
        release.releaseNotes = payload.body ?? ""
        return .release(release)
    }

    static func parseFallback(response: URLResponse) -> LatestReleaseParseResult {
        guard let response = response as? HTTPURLResponse, let url = response.url else { return .failure }
        if response.statusCode == 404 { return url == fallbackEndpoint ? .noStableRelease : .failure }
        guard (200..<300).contains(response.statusCode), let release = AppRelease(pageURL: url) else { return .failure }
        return .release(release)
    }

    private static func importantUpdateVersion(in body: String?, releaseVersion: SemanticVersion) -> SemanticVersion? {
        guard let body else { return nil }
        let key = "keeper-important-update"
        let lines = body.components(separatedBy: .newlines).filter { $0.contains(key) }
        guard lines.count == 1 else { return nil }
        let line = lines[0].trimmingCharacters(in: .whitespaces)
        let prefix = "<!-- keeper-important-update: "
        let suffix = " -->"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        let value = String(line.dropFirst(prefix.count).dropLast(suffix.count))
        guard let version = SemanticVersion(tag: value), value == version.description, version <= releaseVersion else { return nil }
        return version
    }
}

enum AppUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(AppRelease)
    case noStableRelease
    case failed
}

@MainActor final class AppUpdateService: ObservableObject {
    static let automaticRemindersKey = "automaticUpdateRemindersEnabled"
    private static let lastCheckKey = "appUpdateLastCheck"
    private static let lastCheckFailedKey = "appUpdateLastCheckFailed"
    private static let cachedReleaseURLKey = "appUpdateCachedReleaseURL"
    private static let cachedImportantVersionKey = "appUpdateCachedImportantVersion"
    private static let cachedReleaseNotesKey = "appUpdateCachedReleaseNotes"
    private static let promptedImportantVersionsKey = "appUpdatePromptedImportantVersions"
    @Published private(set) var status: AppUpdateStatus = .idle
    @Published private(set) var availableRelease: AppRelease?
    @Published private(set) var automaticRemindersEnabled: Bool
    private let defaults: UserDefaults
    private let currentVersion: String
    private let now: () -> Date
    private let loadResponse: (URLRequest) async throws -> (Data, URLResponse)
    private var automaticChecksStarted = false
    private var automaticTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var automaticTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, currentVersion: String = AppVersion.currentString,
         now: @escaping () -> Date = Date.init,
         loadResponse: @escaping (URLRequest) async throws -> (Data, URLResponse) = AppUpdateService.fetch) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
        self.loadResponse = loadResponse
        automaticRemindersEnabled = defaults.object(forKey: Self.automaticRemindersKey) as? Bool ?? true
        restoreCachedRelease()
    }

    deinit {
        automaticTask?.cancel()
        automaticTimer?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    var showsMenuUpdateIndicator: Bool { automaticRemindersEnabled && availableRelease != nil }

    func claimImportantUpdatePrompt() -> AppRelease? {
        guard automaticRemindersEnabled, let current = SemanticVersion(tag: currentVersion),
              let release = availableRelease, let important = release.importantUpdateVersion,
              current < important, important <= release.version else { return nil }
        var prompted = defaults.stringArray(forKey: Self.promptedImportantVersionsKey) ?? []
        guard !prompted.contains(important.description) else { return nil }
        prompted.append(important.description)
        defaults.set(prompted, forKey: Self.promptedImportantVersionsKey)
        return release
    }

    func startAutomaticChecks() {
        automaticChecksStarted = true
        guard automaticRemindersEnabled else { return }
        installAutomaticTriggers()
        triggerAutomaticCheck()
    }

    func setAutomaticRemindersEnabled(_ enabled: Bool) {
        automaticRemindersEnabled = enabled
        defaults.set(enabled, forKey: Self.automaticRemindersKey)
        if enabled, automaticChecksStarted {
            installAutomaticTriggers()
            triggerAutomaticCheck()
        } else if !enabled {
            removeAutomaticTriggers()
            automaticTask?.cancel()
        }
    }

    func stop() {
        automaticChecksStarted = false
        removeAutomaticTriggers()
        automaticTask?.cancel()
    }

    private func installAutomaticTriggers() {
        guard automaticTimer == nil else { return }
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.triggerAutomaticCheck() }
        }
        automaticTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        for (center, name) in [(NotificationCenter.default, NSApplication.didBecomeActiveNotification),
                              (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.triggerAutomaticCheck() }
            }
            observers.append((center, observer))
        }
    }

    private func removeAutomaticTriggers() {
        automaticTimer?.invalidate()
        automaticTimer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func triggerAutomaticCheck() {
        guard automaticChecksStarted, automaticRemindersEnabled, automaticTask == nil else { return }
        automaticTask = Task { [weak self] in
            guard let self else { return }
            await self.checkAutomaticallyIfDue()
            self.automaticTask = nil
        }
    }

    func checkAutomaticallyIfDue() async {
        guard automaticRemindersEnabled, status != .checking else { return }
        let interval: TimeInterval = defaults.bool(forKey: Self.lastCheckFailedKey) ? 60 * 60 : 24 * 60 * 60
        if let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now().timeIntervalSince(lastCheck) < interval { return }
        await performCheck(manual: false)
    }

    func checkManually() async {
        await performCheck(manual: true)
    }

    private func performCheck(manual: Bool) async {
        guard status != .checking else { return }
        guard let current = SemanticVersion(tag: currentVersion) else {
            status = .failed; recordCheck(success: false); return
        }
        let previousStatus = status
        status = .checking
        var request = URLRequest(url: LatestReleaseParser.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let (data, response) = try await loadResponse(request)
            guard !Task.isCancelled, manual || automaticRemindersEnabled else { status = previousStatus; return }
            var result = LatestReleaseParser.parse(data: data, response: response)
            let metadataRateLimited = result == .rateLimited
            if metadataRateLimited {
                var fallback = URLRequest(url: LatestReleaseParser.fallbackEndpoint,
                    cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                fallback.httpMethod = "HEAD"
                let (_, response) = try await loadResponse(fallback)
                guard !Task.isCancelled, manual || automaticRemindersEnabled else { status = previousStatus; return }
                result = LatestReleaseParser.parseFallback(response: response)
                if case .release(var release) = result, let cached = availableRelease,
                   release.version == cached.version, release.pageURL == cached.pageURL {
                    release.importantUpdateVersion = cached.importantUpdateVersion
                    release.releaseNotes = cached.releaseNotes
                    result = .release(release)
                }
            }
            switch result {
            case .release(let release):
                recordCheck(success: !metadataRateLimited)
                availableRelease = release.version > current ? release : nil
                defaults.set(availableRelease?.pageURL.absoluteString, forKey: Self.cachedReleaseURLKey)
                defaults.set(availableRelease?.importantUpdateVersion?.description, forKey: Self.cachedImportantVersionKey)
                defaults.set(availableRelease?.releaseNotes, forKey: Self.cachedReleaseNotesKey)
                status = release.version > current ? .updateAvailable(release) : .upToDate
            case .noStableRelease:
                recordCheck(success: !metadataRateLimited)
                availableRelease = nil
                defaults.removeObject(forKey: Self.cachedReleaseURLKey)
                defaults.removeObject(forKey: Self.cachedImportantVersionKey)
                defaults.removeObject(forKey: Self.cachedReleaseNotesKey)
                status = .noStableRelease
            case .failure, .rateLimited:
                recordCheck(success: false); status = .failed
            }
        } catch {
            guard !Task.isCancelled, manual || automaticRemindersEnabled else { status = previousStatus; return }
            recordCheck(success: false); status = .failed
        }
    }

    private func recordCheck(success: Bool) {
        defaults.set(now(), forKey: Self.lastCheckKey)
        defaults.set(!success, forKey: Self.lastCheckFailedKey)
    }

    private func restoreCachedRelease() {
        guard let value = defaults.string(forKey: Self.cachedReleaseURLKey) else {
            defaults.removeObject(forKey: Self.cachedImportantVersionKey)
            defaults.removeObject(forKey: Self.cachedReleaseNotesKey)
            return
        }
        guard let url = URL(string: value), var release = AppRelease(pageURL: url),
              let current = SemanticVersion(tag: currentVersion) else {
            defaults.removeObject(forKey: Self.cachedReleaseURLKey)
            defaults.removeObject(forKey: Self.cachedImportantVersionKey)
            defaults.removeObject(forKey: Self.cachedReleaseNotesKey)
            return
        }
        if release.version > current {
            release.releaseNotes = defaults.string(forKey: Self.cachedReleaseNotesKey) ?? ""
            if let value = defaults.string(forKey: Self.cachedImportantVersionKey),
               let important = SemanticVersion(tag: value), value == important.description, important <= release.version {
                release.importantUpdateVersion = important
            } else {
                defaults.removeObject(forKey: Self.cachedImportantVersionKey)
            }
            availableRelease = release
            status = .updateAvailable(release)
        } else {
            defaults.removeObject(forKey: Self.cachedReleaseURLKey)
            defaults.removeObject(forKey: Self.cachedImportantVersionKey)
            defaults.removeObject(forKey: Self.cachedReleaseNotesKey)
            status = .upToDate
        }
    }

    nonisolated private static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}
