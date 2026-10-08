import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor final class MenuBarController: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var summaryHost: NSHostingView<MenuSummaryView>?
    private let summaryItem = NSMenuItem()
    private var quotaHost: NSHostingView<MenuQuotaView>?
    private let quotaItem = NSMenuItem()
    private let quotaSeparator = NSMenuItem.separator()
    private var cancelResumeItem: NSMenuItem?
    private var versionItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var cliPathWindow: NSWindow?
    private var tasksWindow: NSWindow?
    private let appState = AppState()
    private let updateService = AppUpdateService()
    private var updateScheduled = false
    private var notifiedCurrentPing = false
    private var executionFailureSeen = false
    private var presentation = MenuPresentation()
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
            guard let self else { return }
            if running { self.notifiedCurrentPing = false }
            // Capture before persisted attempts remove the executing tasks from the available list.
            _ = self.makeSummary(running: running)
        }.store(in: &cancellables)
        appState.execution.$lastFailure.sink { [weak self] _ in
            self?.executionFailureSeen = false
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
        appState.$recoveryReminderTasks.receive(on: DispatchQueue.main).sink { [weak self] tasks in
            self?.sendRecoveryReminders(for: tasks)
        }.store(in: &cancellables)
        Publishers.Merge(appState.objectWillChange, updateService.objectWillChange).sink { [weak self] _ in
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
        updateService.startAutomaticChecks()
        if CommandLine.arguments.contains("--show-settings") { openKeeperSettings() }
    }

    // Refresh on every opening; the observation above updates the visible menu when it returns.
    func menuNeedsUpdate(_ menu: NSMenu) {
        executionFailureSeen = true
        appState.refresh(manual: true, source: "menu_open"); rebuildMenu()
    }
    func shutdown() { updateService.stop(); appState.execution.cancelCurrent() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    private func sendRecoveryReminders(for tasks: [BlockedSession]) {
        for task in tasks {
            let key = task.episodeKey
            guard let reminder = appState.claimRecoveryReminder(for: key) else { continue }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                guard self.appState.recoveryReminderIsCurrent(for: key, phase: reminder.phase),
                      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    self.appState.finishRecoveryReminder(for: key, phase: reminder.phase, delivered: false)
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = L10n.text("有暂停的任务等你处理")
                content.body = task.displayName + "\n" + reminder.message + "\n" + L10n.text("点击查看任务或调整续跑方式。")
                content.sound = .default
                content.userInfo = ["keeper_action": "recovery-decision"]
                do {
                    try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "keeper-recovery-" + key, content: content, trigger: nil))
                    self.appState.finishRecoveryReminder(for: key, phase: reminder.phase, delivered: true)
                } catch {
                    self.appState.finishRecoveryReminder(for: key, phase: reminder.phase, delivered: false)
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["keeper_action"] as? String == "recovery-decision" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState.openRecoveryDecisions { self.openTasks() }
            }
        }
        completionHandler()
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
            menu.addItem(quotaSeparator)
            cancelResumeItem = row(L10n.text("取消下一次自动继续"), action: #selector(useKeepAlive))
            let quotaHost = NSHostingView(rootView: MenuQuotaView(quotas: summary.quotas))
            self.quotaHost = quotaHost
            quotaItem.view = quotaHost
            menu.addItem(quotaItem)
            menu.addItem(.separator())
            row(L10n.text("设置…"), action: #selector(openKeeperSettings)).keyEquivalent = ","
            versionItem = row(L10n.format("版本 %@", AppVersion.currentString), action: #selector(openAbout))
            row(L10n.text("退出 Codex Keeper"), action: #selector(quitApp)).keyEquivalent = "q"
        }
        host.layoutSubtreeIfNeeded()
        host.frame.size = NSSize(width: 304, height: host.fittingSize.height)
        cancelResumeItem?.title = L10n.text(appState.nextAction?.needsRecoveryDecision == true ? "选择续跑方式…" : "取消下一次自动继续")
        cancelResumeItem?.isHidden = !enabled || appState.selectedTasks.isEmpty
        cancelResumeItem?.isEnabled = !appState.execution.running
        quotaHost?.rootView = MenuQuotaView(quotas: summary.quotas)
        quotaHost?.layoutSubtreeIfNeeded()
        if let quotaHost {
            quotaHost.frame.size = NSSize(width: 304, height: quotaHost.fittingSize.height)
        }
        quotaItem.isHidden = summary.quotas.isEmpty
        quotaSeparator.isHidden = summary.quotas.isEmpty && cancelResumeItem?.isHidden != false
        let hasUpdate = updateService.showsMenuUpdateIndicator
        let versionTitle = MenuVersionTextFormatter.string(version: AppVersion.currentString, hasUpdate: hasUpdate)
        versionItem?.title = versionTitle
        versionItem?.attributedTitle = nil
        if hasUpdate, let image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: L10n.text("有新版本"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen])) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            let title = NSMutableAttributedString(string: versionTitle + " ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(attachment: attachment))
            versionItem?.attributedTitle = title
        }
    }

    private func makeSummary(running: Bool? = nil) -> MenuSummary {
        let defaults = UserDefaults.standard
        return presentation.build(plan: appState.nextAction, usage: appState.usage.snapshot,
            schedule: appState.schedule, tasks: appState.selectedTasks, availableTasks: appState.availableTasks,
            choices: appState.choices, enabled: defaults.bool(forKey: "enabled"), autoResume: defaults.bool(forKey: "autoResume"),
            earlyRecoveryPolicy: defaults.string(forKey: "earlyRecoveryPolicy") ?? "ask",
            confirmations: appState.execution.confirmations,
            usageError: appState.usage.lastError, usageErrorIsTransient: appState.usage.lastErrorIsTransient,
            sessionError: appState.sessions.detectionError,
            running: running ?? appState.execution.running, executionMode: appState.execution.activeMode,
            executionFailure: appState.execution.lastFailure,
            executionFailureIsCurrent: !executionFailureSeen || appState.execution.activeMode == nil,
            executionWarning: appState.execution.warning,
            refreshing: appState.usage.refreshing, refreshMessage: appState.usage.refreshMessage)
    }

    @objc private func showExecutionIssue() {
        if (try? CodexLocator.binary()) == nil {
            openCLIPath()
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("Codex Keeper 遇到问题")
        alert.informativeText = L10n.text(makeSummary().error)
        alert.addButton(withTitle: L10n.text("好"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    private func openCLIPath() {
        if cliPathWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.text("设置 Codex 路径")
            window.center(); window.isReleasedWhenClosed = false
            cliPathWindow = window
        }
        let previousPath = UserDefaults.standard.string(forKey: CodexLocator.fallbackPathKey)
        let host = NSHostingView(rootView: CodexCLIPathView(
            cancel: { [weak self] in self?.cliPathWindow?.close() },
            saved: { [weak self] in
                self?.cliPathWindow?.close()
                // Changed paths already trigger AppState's immediate refresh notification.
                if previousPath == UserDefaults.standard.string(forKey: CodexLocator.fallbackPathKey) {
                    self?.refreshUsage()
                }
            }))
        cliPathWindow?.contentView = host
        cliPathWindow?.setContentSize(host.fittingSize)
        NSApp.activate(ignoringOtherApps: true)
        cliPathWindow?.makeKeyAndOrderFront(nil)
    }
    private func refreshUsage() {
        presentation.requestRefreshFeedback()
        appState.refresh(manual: true, source: "button")
        rebuildMenu()
    }
    @objc private func useKeepAlive() {
        if appState.nextAction?.needsRecoveryDecision == true { openTasks(); return }
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
    @objc func openKeeperSettings() {
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
    @objc private func openAbout() {
        if aboutWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.text("关于 Codex Keeper")
            window.contentView = NSHostingView(rootView: AboutView(updateService: updateService))
            window.center(); window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.moveToActiveSpace)
            aboutWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
