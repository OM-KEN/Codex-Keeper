import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor final class MenuBarController: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var summaryHost: NSHostingView<MenuSummaryView>?
    private let summaryItem = NSMenuItem()
    private var cancelResumeItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var tasksWindow: NSWindow?
    private let appState = AppState()
    private var updateScheduled = false
    private var notifiedCurrentPing = false
    private var cancellables = Set<AnyCancellable>()

    func setup() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
        appState.execution.$running.removeDuplicates().sink { [weak self] running in
            if running { self?.notifiedCurrentPing = false }
        }.store(in: &cancellables)
        appState.execution.$warning.receive(on: DispatchQueue.main).sink { [weak self] warning in
            guard let self, let warning, self.appState.execution.running,
                  self.appState.execution.activeMode == .keepAlive, !self.notifiedCurrentPing else { return }
            self.notifiedCurrentPing = true
            let content = UNMutableNotificationContent()
            content.title = L10n.text("Codex Keeper 保活仍在等待")
            content.body = warning
            content.sound = .default
            notifications.add(UNNotificationRequest(identifier: "keeper-ping-wait-" + UUID().uuidString,
                content: content, trigger: nil))
        }.store(in: &cancellables)
        appState.objectWillChange.sink { [weak self] _ in
            guard let self, !self.updateScheduled else { return }
            self.updateScheduled = true
            RunLoop.main.perform(inModes: [.common]) {
                // Main run loop also delivers updates while NSMenu tracks the pointer.
                MainActor.assumeIsolated {
                    self.updateScheduled = false
                    self.rebuildMenu()
                }
            }
        }.store(in: &cancellables)
        rebuildMenu()
        if CommandLine.arguments.contains("--show-settings") { openSettings() }
    }

    // Refresh on every opening; the observation above updates the visible menu when it returns.
    func menuNeedsUpdate(_ menu: NSMenu) { appState.refresh(manual: true, source: "menu_open"); rebuildMenu() }
    func shutdown() { appState.execution.cancelCurrent() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    @discardableResult private func row(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        menu.addItem(item)
        return item
    }

    private func rebuildMenu() {
        let enabled = UserDefaults.standard.bool(forKey: "enabled")
        let summary = makeSummary()
        let statusText = appState.execution.running ? L10n.text(summary.headline) : summary.statusText
        let action = summary.action.isEmpty ? summary.headline : summary.action
        statusItem.button?.title = enabled ? " " + statusText : ""
        statusItem.button?.image = NSImage(systemSymbolName: summary.statusSymbol, accessibilityDescription: L10n.text(action))
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Codex Keeper · " + L10n.text(action) + (summary.isTime ? " · " + summary.statusText : "") + (summary.warning.isEmpty ? "" : " · " + summary.warning)
        let view = MenuSummaryView(summary: summary,
            openTasks: { [weak self] in self?.menu.cancelTracking(); self?.openTasks() },
            showError: { [weak self] in self?.menu.cancelTracking(); self?.showExecutionIssue() },
            refresh: { [weak self] in self?.refreshUsage() })
        let host: NSHostingView<MenuSummaryView>
        if let existing = summaryHost {
            host = existing
            host.rootView = view
        } else {
            host = NSHostingView(rootView: view)
            summaryHost = host
            summaryItem.view = host
            menu.addItem(summaryItem)
            cancelResumeItem = row(L10n.text("取消下一次自动继续"), action: #selector(useKeepAlive))
            menu.addItem(.separator())
            row(L10n.text("设置…"), action: #selector(openSettings)).keyEquivalent = ","
            row(L10n.text("退出 Codex Keeper"), action: #selector(quitApp)).keyEquivalent = "q"
        }
        host.layoutSubtreeIfNeeded()
        host.frame.size = NSSize(width: 304, height: host.fittingSize.height)
        cancelResumeItem?.isHidden = !enabled || appState.selectedTasks.isEmpty
        cancelResumeItem?.isEnabled = !appState.execution.running
    }

    private func makeSummary() -> MenuSummary {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "enabled") else {
            var summary = MenuSummary(headline: "已停用")
            summary.isRefreshing = appState.usage.refreshing
            summary.refreshMessage = appState.usage.refreshMessage
            return summary
        }
        var summary = MenuSummary.build(plan: appState.nextAction, usage: appState.usage.snapshot,
            schedule: appState.schedule, tasks: appState.selectedTasks, confirmations: appState.execution.confirmations)
        if summary.tasks.isEmpty, !appState.availableTasks.isEmpty {
            summary.tasks = Array(appState.availableTasks.sorted { $0.blockedAt > $1.blockedAt }.prefix(1).map(\.displayName))
            summary.taskCount = appState.availableTasks.count
        }
        summary.applyIssues(usageError: appState.usage.lastError, sessionError: appState.sessions.detectionError,
            executionFailure: appState.execution.lastFailure,
            executionAction: appState.execution.activeMode == .resume ? "自动继续" : "保活")
        if !appState.execution.running {
            summary.applyUsageRefreshState(refreshing: appState.usage.refreshing, error: appState.usage.lastError)
            if appState.usage.snapshot?.isFresh(at: Date()) != true, let error = appState.usage.lastError {
                summary.error = error
            }
        }
        if appState.execution.running {
            summary.headline = appState.execution.activeMode == .resume ? "正在继续" : "正在保活"
            summary.action = ""; summary.isTime = false
            summary.timeline = []; summary.eyebrow = ""; summary.isSyncing = false
            if let warning = appState.execution.warning {
                summary.warning = warning
                summary.note = warning
                summary.headline = "保活等待中"
            }
        }
        summary.isRefreshing = appState.usage.refreshing
        summary.refreshMessage = appState.usage.refreshMessage
        return summary
    }

    @objc private func showExecutionIssue() {
        let alert = NSAlert()
        alert.messageText = L10n.text("Codex Keeper 遇到问题")
        alert.informativeText = L10n.text(makeSummary().error)
        alert.addButton(withTitle: L10n.text("好"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    private func refreshUsage() {
        appState.refresh(manual: true, source: "button")
        rebuildMenu()
    }
    @objc private func useKeepAlive() {
        let tasks = appState.availableTasks
        guard let plan = appState.cancellationPlan else {
            appState.refresh()
            let alert = NSAlert()
            alert.messageText = L10n.text("正在同步")
            alert.informativeText = L10n.text("同步完成后即可确认取消时间。")
            alert.addButton(withTitle: L10n.text("好")); alert.runModal()
            return
        }
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        let full = DateFormatter(); full.dateFormat = L10n.text("M月d日 HH:mm")
        func time(_ date: Date) -> String {
            Calendar.current.isDateInToday(date) ? clock.string(from: date) : full.string(from: date)
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("取消下一次自动继续？")
        alert.informativeText = L10n.format("取消后，所有因达到使用上限而停止的会话不会在%@自动继续，Keeper 将会按照计划在%@继续保持活动。", time(plan.resume), time(plan.keepAlive))
        alert.addButton(withTitle: L10n.text("取消自动继续"))
        alert.addButton(withTitle: L10n.text("保留自动继续"))
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { appState.useKeepAlive(for: tasks) }
    }
    @objc private func openTasks() {
        if tasksWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("自动继续任务")
            window.contentView = NSHostingView(rootView: ResumeTasksView(state: appState))
            window.center(); window.isReleasedWhenClosed = false
            tasksWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        tasksWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("Codex Keeper 设置")
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center(); window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.moveToActiveSpace)
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
