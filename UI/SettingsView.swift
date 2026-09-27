import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @AppStorage("enabled") private var enabled = true
    @AppStorage("dailyAnchorMinutes") private var dailyAnchorMinutes = 480
    @AppStorage("autoResume") private var autoResume = true
    @AppStorage("resumeMessage") private var savedResumeMessage = L10n.text("继续")
    @AppStorage(ResumeMessagePreferences.modeKey) private var savedResumeMessageMode = ""
    @AppStorage(ResumeMessagePreferences.customizedKey) private var resumeMessageCustomized = false
    @AppStorage("resumeWorkspaceReminder") private var resumeWorkspaceReminder = true
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var showingCustomMessageEditor = false
    @State private var customMessageDraft = ""
    @State private var cliPathDraft = UserDefaults.standard.string(forKey: CodexLocator.fallbackPathKey) ?? ""
    @State private var cliPathError: String?
    @State private var cliPathSaved = false
    private var dailySchedule: String {
        let calendar = Calendar.current
        let today = Date()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        return ScheduleEngine(anchorMinutes: dailyAnchorMinutes).nodes(on: today, calendar: calendar).map {
            (calendar.isDate($0, inSameDayAs: today) ? "" : L10n.text("次日 ")) + clock.string(from: $0)
        }.joined(separator: " · ")
    }
    private var anchor: Binding<Date> {
        Binding(get: { Calendar.current.date(from: DateComponents(hour: dailyAnchorMinutes / 60, minute: dailyAnchorMinutes % 60)) ?? Date() }, set: {
            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
            dailyAnchorMinutes = (c.hour ?? 8) * 60 + (c.minute ?? 0)
        })
    }
    private var resumeMessageMode: ResumeMessagePreferences.Mode {
        ResumeMessagePreferences.mode(saved: savedResumeMessage, storedMode: savedResumeMessageMode,
            legacyCustomized: resumeMessageCustomized)
    }
    private var resumeMessageSelection: Binding<ResumeMessagePreferences.Mode> {
        Binding(get: { resumeMessageMode }, set: { mode in
            if mode == .custom { openCustomMessageEditor() }
            else { savedResumeMessageMode = mode.rawValue }
        })
    }
    private var customMessagePreview: String {
        let flattened = savedResumeMessage.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? L10n.text("尚未填写自定义内容") : flattened
    }
    private func openCustomMessageEditor() {
        let hasCustomText = resumeMessageCustomized || (savedResumeMessage != "继续" && savedResumeMessage != "Continue")
        customMessageDraft = hasCustomText ? savedResumeMessage : ""
        showingCustomMessageEditor = true
    }
    private func saveCLIPath() {
        do {
            cliPathDraft = try CodexLocator.saveFallbackPath(cliPathDraft)
            cliPathError = nil
            cliPathSaved = true
        } catch { cliPathError = error.localizedDescription; cliPathSaved = false }
    }
    private func chooseCLIPath() {
        let panel = NSOpenPanel()
        panel.message = L10n.text("选择 Codex CLI 可执行文件")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url { cliPathDraft = url.path }
        }
    }
    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("启用 Codex Keeper"), isOn: $enabled)
            }
            Section(L10n.text("保持活动")) {
                DatePicker(L10n.text("每日开始时间"), selection: anchor, displayedComponents: .hourAndMinute)
                Text(L10n.format("计划预览：%@", dailySchedule))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.text("自动继续任务")) {
                Toggle(isOn: $autoResume) {
                    HStack(spacing: 0) {
                        Text(L10n.text("额度恢复后自动继续"))
                        InfoHintButton(label: L10n.text("自动续跑说明"),
                            hint: L10n.text("确认额度正常恢复后继续；其他恢复情况先提醒你选择。"),
                            detail: L10n.text("因额度用尽而暂停的任务，将在额度恢复后自动继续。提前恢复或恢复情况不明时，会先提醒你选择。等待选择期间，Keeper 仍会按计划保活。"))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("发送给 Codex 的内容")).font(.callout.weight(.medium))
                    Picker("", selection: resumeMessageSelection) {
                        Text(L10n.format("默认发送“%@”", L10n.text("继续"))).tag(ResumeMessagePreferences.Mode.localizedDefault)
                        Text(L10n.text("自定义内容")).tag(ResumeMessagePreferences.Mode.custom)
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                    if resumeMessageMode == .custom {
                        Button(action: openCustomMessageEditor) {
                            HStack(spacing: 8) {
                                Text(customMessagePreview).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                                Image(systemName: "pencil").foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered).help(L10n.text("编辑自定义内容"))
                    }
                }
                Toggle(isOn: $resumeWorkspaceReminder) {
                    HStack(spacing: 0) {
                        Text(L10n.text("项目可能变化时附加检查提醒"))
                        InfoHintButton(label: L10n.text("项目检查说明"),
                            hint: L10n.text("文件有变化或无法核对时，在所选内容前单独附加提醒。"),
                            detail: L10n.format("项目文件有变化或无法核对时，Keeper 会在所选续跑内容前单独加上：\n\n“%@”", WorkspaceGuard.reminder))
                    }
                }
            }
            Section {
                Toggle(L10n.text("开机自启"), isOn: Binding(get: { loginEnabled }, set: { value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginEnabled = SMAppService.mainApp.status == .enabled
                        loginError = SMAppService.mainApp.status == .requiresApproval ? L10n.text("请在“系统设置 → 通用 → 登录项”中允许 Codex Keeper 登录时打开") : nil
                    } catch { loginError = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
            }
            Section(L10n.text("备用 Codex CLI 路径")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField(L10n.text("留空则自动查找"), text: $cliPathDraft)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(L10n.text("备用 Codex CLI 路径"))
                            .labelsHidden()
                            .onSubmit(saveCLIPath)
                        Button(L10n.text("选择文件…"), action: chooseCLIPath)
                    }
                    HStack(alignment: .top) {
                        Text(L10n.text("仅在自动查找失败时使用；留空则自动查找"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(L10n.text("保存"), action: saveCLIPath)
                    }
                    if let cliPathError {
                        Text(cliPathError).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if cliPathSaved {
                        Text(L10n.text("已保存")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(minWidth: 480, idealWidth: 480, minHeight: 540, idealHeight: 620)
        .onChange(of: cliPathDraft) { value in
            cliPathError = nil
            if value != (UserDefaults.standard.string(forKey: CodexLocator.fallbackPathKey) ?? "") { cliPathSaved = false }
        }
        .sheet(isPresented: $showingCustomMessageEditor) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("编辑自定义内容")).font(.headline)
                TextEditor(text: $customMessageDraft)
                    .keeperEditorStyle()
                    .font(.body).frame(height: 150)
                    .padding(5).background(.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                HStack {
                    Spacer()
                    Button(L10n.text("取消")) { showingCustomMessageEditor = false }
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.text("保存")) {
                        savedResumeMessage = customMessageDraft
                        resumeMessageCustomized = true
                        savedResumeMessageMode = ResumeMessagePreferences.Mode.custom.rawValue
                        showingCustomMessageEditor = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(customMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20).frame(width: 440)
        }
    }
}

struct InfoHintButton: View {
    let label: String
    let hint: String
    let detail: String
    @State private var showingInfo = false

    var body: some View {
        Button { showingInfo.toggle() } label: {
            Image(systemName: "info.circle")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .help(hint)
        .popover(isPresented: $showingInfo) {
            Text(detail)
                .font(.body)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}

// Plain editor styling was added in macOS 14; retain the native editor on macOS 13.
extension TextEditor {
    @ViewBuilder func keeperEditorStyle() -> some View {
        if #available(macOS 14.0, *) { self.textEditorStyle(.plain) }
        else { self }
    }
}
