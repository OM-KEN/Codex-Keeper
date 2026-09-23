import SwiftUI
import AppKit

@main
struct CodexKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var menuBar: MenuBarController?
    private var onboardingWindow: NSWindow?

    func applicationWillTerminate(_ notification: Notification) { menuBar?.shutdown(); AppServerClient.closeAll() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let needsSetup = OnboardingPreferences.needsSetup(defaults: .standard)
        NSApp.setActivationPolicy(needsSetup ? .regular : .accessory)
        UserDefaults.standard.removeObject(forKey: "executionEnabled")
        // @AppStorage 与 NSMenu 共享 UserDefaults，先注册默认值保证两侧一致
        UserDefaults.standard.register(defaults: [
            "enabled": true,
            "autoResume": true,
            "resumeMessage": L10n.text("继续"),
            "resumeWorkspaceReminder": true,
        ])
        if needsSetup { showOnboarding() }
        else {
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            startKeeper()
        }
    }

    private func startKeeper() {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController()
        menuBar?.setup()
    }

    private func showOnboarding() {
        let window = OnboardingWindow { [weak self] minutes in
            guard let self else { return }
            OnboardingPreferences.complete(anchorMinutes: minutes, defaults: .standard)
            self.startKeeper()
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
        }
        window.delegate = self
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if menuBar == nil, notification.object as? NSWindow === onboardingWindow { NSApp.terminate(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onboardingWindow?.makeKeyAndOrderFront(nil)
        return true
    }
}
