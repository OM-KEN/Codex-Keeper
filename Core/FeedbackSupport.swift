import Foundation
import Darwin

struct FeedbackEnvironment {
    let appVersion: String
    let macOSVersion: String
    let chip: String

    static func current(appVersion: String) -> FeedbackEnvironment {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var bytes = [CChar](repeating: 0, count: 128)
        var size = bytes.count
        let result = sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return FeedbackEnvironment(appVersion: appVersion,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            chip: result == 0 ? String(cString: bytes) : "Apple Silicon")
    }
}

enum FeedbackSupport {
    static let recipient = "omken.feedback@gmail.com"
    static let githubIssueChooserURL = URL(string: "https://github.com/OM-KEN/Codex-Keeper/issues/new/choose")!

    static func emailURL(for environment: FeedbackEnvironment) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: L10n.text("Codex Keeper 问题反馈")),
            URLQueryItem(name: "body", value: L10n.format("应用版本：%@\nmacOS：%@\n芯片：%@\n\n问题描述：\n\n复现步骤：\n1. ",
                environment.appVersion, environment.macOSVersion, environment.chip))
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
