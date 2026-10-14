import SwiftUI
import AppKit

struct ResumeTasksView: View {
    @ObservedObject var state: AppState
    var historyIDs: Set<String>? = nil
    var historyAccountID: String? = nil
    var historyLabel: String? = nil
    @State private var presentedIDs = Set<String>()
    @State private var ignoring: BlockedSession?
    @State private var error: String?

    private var records: [ResumeOperation] {
        historyIDs.map { state.taskOperations(ids: $0) } ?? state.taskOperations(ids: Set(state.currentOperations.map(\.id)).union(presentedIDs))
    }
    private var rows: [ResumeTaskRow] {
        let recorded = records.map { ResumeTaskRow(task: $0.target, operation: $0) }
        guard historyIDs == nil else { return recorded }
        let keys = Set(records.map { $0.target.episodeKey })
        return recorded + state.availableTasks.filter { !keys.contains($0.episodeKey) }.map { ResumeTaskRow(task: $0, operation: nil) }
    }

    private var unreadPresentedEvents: Set<String> {
        Set(records.filter(\.needsManualContinuation).map(\.id)).subtracting(state.choices.readManualEvents ?? [])
    }
    private func markPresentedRecordsRead() {
        let ids = Set(records.map(\.id)); presentedIDs.formUnion(ids)
        DispatchQueue.main.async {
            guard NSApp.windows.contains(where: { $0.isVisible && $0.title == L10n.text("自动继续任务") }) else { return }
            state.markManualEventsRead(ids)
        }
    }

    var body: some View {
        Form {
            if let historyLabel, historyAccountID == state.displayAccountID { Text(historyLabel).font(.headline) }
            if let failure = state.execution.recordingFailure { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
            ForEach(rows) { row in
                let task = row.task; let operation = row.operation
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "text.bubble").foregroundStyle(.secondary)
                        Text(task.displayName).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                        Button { ignoring = task } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.text("忽略本轮"))
                    }
                    let fact = ResumeTaskFact.make(task: task, operation: operation, enabled: state.enabled, autoResume: state.automaticResumeEnabled)
                    Label(fact.text, systemImage: fact.symbol).font(.callout)
                        .foregroundStyle(fact.isConfirming ? Color.blue : operation?.needsManualContinuation == true ? Color.orange : operation?.respondedAt != nil ? Color.green : operation?.phase == .notSubmitted || operation?.terminal == .failed ? Color.red : Color.secondary)
                    if operation?.needsManualContinuation == true {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
                            Button(L10n.text("打开 Codex")) {
                                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, failure in
                                    if failure != nil { DispatchQueue.main.async { error = L10n.text("无法打开 Codex，请手动打开应用。") } }
                                }
                            }
                        }
                    }
                    if historyIDs == nil, operation?.needsManualContinuation != true, operation?.respondedAt == nil, operation?.phase != .stopped {
                        Toggle(L10n.text("自动继续此任务"), isOn: Binding(get: {
                            !state.choices.deselectedEpisodes.contains(task.episodeKey)
                        }, set: { state.setSelected(task, $0) })).disabled(state.execution.isContentLocked(task, accountID: state.displayAccountID))
                        if let decision = state.choices.recoveryDecisions?[task.episodeKey], decision.phase != .responded {
                            HStack {
                                Button(L10n.text("现在继续")) { state.resolveRecoveryDecision(.now, for: [task]) }
                                    .disabled(!state.execution.canStartResume)
                                Button(L10n.text("按计划继续")) { state.resolveRecoveryDecision(.plan, for: [task]) }
                                Button(L10n.text("取消本次")) { state.resolveRecoveryDecision(.cancel, for: [task]) }
                            }.disabled(!state.enabled || !state.automaticResumeEnabled || state.choices.deselectedEpisodes.contains(task.episodeKey))
                            if state.execution.isKeepingAlive {
                                Text(L10n.text("正在保活，完成后可选择现在继续")).font(.callout).foregroundStyle(.secondary)
                            }
                        } else if operation?.phase == .notSubmitted {
                            HStack {
                                Text(state.planExplanation(for: task) ?? "").font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Button(L10n.text("立即重试")) { state.retry(task) }
                                    .disabled(!state.execution.canStartResume || !state.automaticResumeEnabled || state.choices.deselectedEpisodes.contains(task.episodeKey))
                            }
                            if state.execution.isKeepingAlive {
                                Text(L10n.text("正在保活，完成后可立即重试")).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Picker(L10n.text("发送内容"), selection: Binding(get: { state.choices.mode(for: task) }, set: { state.setMessageMode(task, $0) })) {
                            Text(L10n.text("使用下方内容")).tag(ResumeMessageMode.fixed)
                            Text(L10n.text("使用 Codex 输入框草稿")).tag(ResumeMessageMode.composerDraft)
                        }.disabled(state.choices.deselectedEpisodes.contains(task.episodeKey) || state.execution.isContentLocked(task, accountID: state.displayAccountID))
                        if state.choices.mode(for: task) == .composerDraft {
                            HStack {
                                Text(L10n.text("只发送草稿文字，不含附件；空草稿发送“继续”。")).font(.callout).foregroundStyle(.secondary)
                                InfoHintButton(label: L10n.text("草稿保留说明"), hint: L10n.text("Codex 输入框中的原草稿会保留。"), detail: L10n.text("Codex 输入框中的原草稿会保留。"))
                            }
                        } else {
                            TextEditor(text: Binding(get: { state.choices.messages[task.episodeKey] ?? state.defaultResumeMessage }, set: { state.setMessage(task, $0) }))
                                .keeperEditorStyle().scrollContentBackground(.hidden).font(.body).frame(height: 120)
                                .padding(5).background(.background, in: RoundedRectangle(cornerRadius: 5))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                                .disabled(state.choices.deselectedEpisodes.contains(task.episodeKey) || state.execution.isContentLocked(task, accountID: state.displayAccountID))
                        }
                    }
                }
            }
            if rows.isEmpty { Text(L10n.text("暂无可显示的任务")).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped).padding(12)
        .frame(minWidth: 500, idealWidth: 500, minHeight: 300, idealHeight: 600)
        .onAppear { markPresentedRecordsRead() }
        .onChange(of: unreadPresentedEvents) { _ in markPresentedRecordsRead() }
        .alert(L10n.text("忽略本轮续跑？"), isPresented: Binding(get: { ignoring != nil }, set: { if !$0 { ignoring = nil } }), presenting: ignoring) { task in
            Button(L10n.text("取消"), role: .cancel) { ignoring = nil }
            Button(L10n.text("忽略本轮"), role: .destructive) {
                if !state.ignoreEpisode(task) { error = L10n.text("待续状态无法保存，暂停自动操作") }
                ignoring = nil
            }
        } message: { task in
            Text(L10n.format("仅跳过“%@”这次续跑；之后再次暂停仍正常处理。Codex 任务和已有记录会保留。", task.displayName))
        }
        .background {
            Color.clear.alert(L10n.text("Codex Keeper 遇到问题"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L10n.text("好")) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

private struct ResumeTaskRow: Identifiable {
    let task: BlockedSession
    let operation: ResumeOperation?
    var id: String { operation?.id ?? task.episodeKey }
}
