import SwiftUI

struct ResumeTasksView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Text(L10n.format("已选择 %d 个任务", state.selectedTasks.count))
                    .font(.headline)
            }
            ForEach(state.availableTasks, id: \.episodeKey) { task in
                Section {
                    Toggle(isOn: Binding(get: {
                        !state.choices.deselectedEpisodes.contains(task.episodeKey)
                    }, set: { state.setSelected(task, $0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.displayName).fontWeight(.medium)
                            Text(L10n.format("%@ · %@ · %@ 暂停", task.project, String(task.id.prefix(8)), AppState.dayClockFormatter.string(from: task.blockedAt)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let decision = state.choices.recoveryDecisions?[task.episodeKey] {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("任务还在暂停")).font(.headline)
                            Text(decision.message).font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button(L10n.text("现在继续")) { state.resolveRecoveryDecision(.now, for: [task]) }
                                Button(L10n.text("按计划继续")) { state.resolveRecoveryDecision(.plan, for: [task]) }
                                Button(L10n.text("取消本次")) { state.resolveRecoveryDecision(.cancel, for: [task]) }
                            }
                            .disabled(state.choices.deselectedEpisodes.contains(task.episodeKey))
                        }
                    }
                    Picker(L10n.text("发送内容"), selection: Binding(get: { state.choices.mode(for: task) }, set: { state.setMessageMode(task, $0) })) {
                        Text(L10n.text("使用下方内容")).tag(ResumeMessageMode.fixed)
                        Text(L10n.text("使用 Codex 输入框草稿")).tag(ResumeMessageMode.composerDraft)
                    }
                    .disabled(state.choices.deselectedEpisodes.contains(task.episodeKey))
                    if state.choices.mode(for: task) == .composerDraft {
                        HStack {
                            Text(L10n.text("只发送草稿文字，不含附件；空草稿发送“继续”。"))
                                .font(.callout).foregroundStyle(.secondary)
                            InfoHintButton(label: L10n.text("草稿保留说明"),
                                hint: L10n.text("Codex 输入框中的原草稿会保留。"),
                                detail: L10n.text("Codex 输入框中的原草稿会保留。"))
                        }
                    } else {
                        TextEditor(text: Binding(get: {
                            state.choices.messages[task.episodeKey] ?? ResumeMessagePreferences.current()
                        }, set: { state.setMessage(task, $0) }))
                        .keeperEditorStyle()
                        .scrollContentBackground(.hidden)
                        .font(.body).frame(height: 120)
                        .padding(5).background(.background, in: RoundedRectangle(cornerRadius: 5))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                        .disabled(state.choices.deselectedEpisodes.contains(task.episodeKey))
                    }
                }
            }
            if state.availableTasks.isEmpty { Text(L10n.text("当前没有等待自动继续的任务。")).foregroundStyle(.secondary) }
        }
        .disabled(state.execution.running)
        .formStyle(.grouped)
        .padding(12)
        .frame(minWidth: 500, idealWidth: 500, minHeight: 500, idealHeight: 600)
    }
}
