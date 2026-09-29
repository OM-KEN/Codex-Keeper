import SwiftUI
import AppKit

struct AboutView: View {
    @ObservedObject var updateService: AppUpdateService
    @State private var showFeedbackOptions = false
    @State private var openError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Codex Keeper").font(.title2.weight(.semibold))
                    Text(L10n.format("版本 %@", AppVersion.currentString)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 20)

            Form {
                Section(L10n.text("软件更新")) {
                    HStack(spacing: 8) {
                        Image(systemName: updateStatusSymbol).foregroundStyle(updateStatusColor)
                        Text(updateStatusText).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(L10n.text(updateService.status == .checking ? "正在检查…" : "检查更新")) {
                            Task { await updateService.checkManually() }
                        }
                        .disabled(updateService.status == .checking)
                        .fixedSize()
                    }
                    if let release = updateService.availableRelease {
                        Button(L10n.text("前往 GitHub 更新")) {
                            open(release.pageURL, failure: L10n.text("无法打开 GitHub，请稍后重试。"))
                        }
                    }
                    Toggle(L10n.text("更新提醒"), isOn: Binding(
                        get: { updateService.automaticRemindersEnabled },
                        set: { updateService.setAutomaticRemindersEnabled($0) }))
                }
                Section(L10n.text("支持与反馈")) {
                    Button { showFeedbackOptions = true } label: {
                        HStack {
                            Label(L10n.text("问题反馈…"), systemImage: "exclamationmark.bubble")
                            Spacer()
                            Text(L10n.text("邮件或 GitHub")).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 440, height: 380)
        .confirmationDialog(L10n.text("问题反馈"), isPresented: $showFeedbackOptions, titleVisibility: .visible) {
            Button(L10n.text("发送邮件"), action: openFeedbackEmail)
            Button(L10n.text("在 GitHub 提交 Issue")) {
                open(FeedbackSupport.githubIssueChooserURL, failure: L10n.text("无法打开 GitHub，请稍后重试。"))
            }
            Button(L10n.text("取消"), role: .cancel) {}
        }
        .alert(L10n.text("无法打开链接"), isPresented: Binding(
            get: { openError != nil }, set: { if !$0 { openError = nil } })) {
                Button(L10n.text("好"), role: .cancel) { openError = nil }
            } message: { Text(openError ?? "") }
    }

    private func open(_ url: URL, failure: String) {
        if !NSWorkspace.shared.open(url) { openError = failure }
    }

    private func openFeedbackEmail() {
        let failure = L10n.format("无法打开邮件应用，请手动发送至 %@。", FeedbackSupport.recipient)
        guard let url = FeedbackSupport.emailURL(for: .current(appVersion: AppVersion.currentString)) else {
            openError = failure
            return
        }
        open(url, failure: failure)
    }

    private var updateStatusText: String {
        switch updateService.status {
        case .idle: return L10n.text("尚未检查更新")
        case .checking: return L10n.text("正在检查更新…")
        case .upToDate: return L10n.text("已是最新版本")
        case .updateAvailable(let release): return L10n.format("发现新版本 %@", release.version.description)
        case .noStableRelease: return L10n.text("当前没有稳定版本")
        case .failed: return L10n.text("检查更新失败，请稍后重试。")
        }
    }

    private var updateStatusSymbol: String {
        switch updateService.status {
        case .idle: return "info.circle"
        case .checking: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.circle.fill"
        case .updateAvailable: return "arrow.up.circle.fill"
        case .noStableRelease: return "info.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var updateStatusColor: Color {
        switch updateService.status {
        case .updateAvailable, .upToDate: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}
