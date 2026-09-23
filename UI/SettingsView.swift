import SwiftUI
import ServiceManagement

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
    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("启用 Codex Keeper"), isOn: $enabled)
                Text(L10n.text("按计划保持 Codex 活动，并支持在额度恢复后自动继续任务。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("保持活动")) {
                DatePicker(L10n.text("每日开始时间"), selection: anchor, displayedComponents: .hourAndMinute)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("从每天的开始时间起，每隔 5 小时安排一次保活，共 4 次。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.format("计划保活点：%@", dailySchedule))
                        .font(.caption).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L10n.text("自动继续任务")) {
                Toggle(L10n.text("额度恢复后自动继续"), isOn: $autoResume)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("发送给 Codex 的内容")).font(.caption).foregroundStyle(.secondary)
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
                Text(L10n.text("任务因额度用尽而暂停后，会在额度恢复后自动继续。默认继续所有待续任务，你可以在菜单中选择要继续的任务，并为每个任务修改发送内容。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("继续前提醒 Codex 检查项目"), isOn: $resumeWorkspaceReminder)
                Text(L10n.text("项目文件有变化，或无法确认是否变化时，会在发送内容中提醒 Codex 先检查项目和任务进度。关闭后只发送你选定的内容。"))
                    .font(.caption).foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(minWidth: 480, idealWidth: 480, minHeight: 540, idealHeight: 620)
        .sheet(isPresented: $showingCustomMessageEditor) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("编辑自定义内容")).font(.headline)
                Text(L10n.text("输入发送给 Codex 的内容。"))
                    .font(.caption).foregroundStyle(.secondary)
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

// Plain editor styling was added in macOS 14; retain the native editor on macOS 13.
extension TextEditor {
    @ViewBuilder func keeperEditorStyle() -> some View {
        if #available(macOS 14.0, *) { self.textEditorStyle(.plain) }
        else { self }
    }
}
