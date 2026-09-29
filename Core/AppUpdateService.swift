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
}

enum LatestReleaseParseResult: Equatable {
    case release(AppRelease)
    case noStableRelease
    case failure
}

enum LatestReleaseParser {
    static func parse(response: URLResponse) -> LatestReleaseParseResult {
        guard let response = response as? HTTPURLResponse else { return .failure }
        guard let url = response.url else { return .failure }
        if response.statusCode == 404 {
            return url.absoluteString == "https://github.com/OM-KEN/Codex-Keeper/releases/latest" ? .noStableRelease : .failure
        }
        guard (200..<300).contains(response.statusCode), let release = AppRelease(pageURL: url) else { return .failure }
        return .release(release)
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
    @Published private(set) var status: AppUpdateStatus = .idle
    @Published private(set) var availableRelease: AppRelease?
    @Published private(set) var automaticRemindersEnabled: Bool
    private let defaults: UserDefaults
    private let currentVersion: String
    private let now: () -> Date
    private let loadResponse: (URLRequest) async throws -> URLResponse
    private var automaticChecksStarted = false
    private var automaticTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var automaticTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, currentVersion: String = AppVersion.currentString,
         now: @escaping () -> Date = Date.init,
         loadResponse: @escaping (URLRequest) async throws -> URLResponse = AppUpdateService.fetch) {
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
        var request = URLRequest(url: URL(string: "https://github.com/OM-KEN/Codex-Keeper/releases/latest")!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        do {
            let response = try await loadResponse(request)
            guard !Task.isCancelled, manual || automaticRemindersEnabled else { status = previousStatus; return }
            switch LatestReleaseParser.parse(response: response) {
            case .release(let release):
                recordCheck(success: true)
                availableRelease = release.version > current ? release : nil
                defaults.set(availableRelease?.pageURL.absoluteString, forKey: Self.cachedReleaseURLKey)
                status = release.version > current ? .updateAvailable(release) : .upToDate
            case .noStableRelease:
                recordCheck(success: true)
                availableRelease = nil
                defaults.removeObject(forKey: Self.cachedReleaseURLKey)
                status = .noStableRelease
            case .failure:
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
        guard let value = defaults.string(forKey: Self.cachedReleaseURLKey) else { return }
        guard let url = URL(string: value), let release = AppRelease(pageURL: url),
              let current = SemanticVersion(tag: currentVersion) else {
            defaults.removeObject(forKey: Self.cachedReleaseURLKey)
            return
        }
        if release.version > current {
            availableRelease = release
            status = .updateAvailable(release)
        } else {
            defaults.removeObject(forKey: Self.cachedReleaseURLKey)
            status = .upToDate
        }
    }

    nonisolated private static func fetch(_ request: URLRequest) async throws -> URLResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        return response
    }
}
