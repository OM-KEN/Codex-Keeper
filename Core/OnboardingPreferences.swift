import Foundation

enum OnboardingPreferences {
    // Only saved preferences count as prior setup; registered defaults do not.
    static func needsSetup(defaults: UserDefaults, domainName: String = Bundle.main.bundleIdentifier ?? "") -> Bool {
        let saved = defaults.persistentDomain(forName: domainName) ?? [:]
        if let completed = saved["onboardingCompleted"] as? Bool { return !completed }
        return !["dailyAnchorMinutes", "enabled", "autoResume", "resumeMessage", "resumeWorkspaceReminder"].contains {
            saved[$0] != nil
        }
    }

    static func complete(anchorMinutes: Int, defaults: UserDefaults) {
        defaults.set(anchorMinutes, forKey: "dailyAnchorMinutes")
        defaults.set(true, forKey: "onboardingCompleted")
    }
}
