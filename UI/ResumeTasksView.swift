import SwiftUI

struct ResumeTasksView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Text(L10n.format("已选择 %d 个任务", state.selectedTasks.count))
                    .font(.headline)
                Text(L10n.text("选择额度恢复后要继续的任务，并为每个任务设置发送给 Codex 的内容。"))
                    .font(.caption).foregroundStyle(.secondary)
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
                    Picker(L10n.text("发送内容"), selection: Binding(get: { state.choices.mode(for: task) }, set: { state.setMessageMode(task, $0) })) {
                        Text(L10n.text("使用下方内容")).tag(ResumeMessageMode.fixed)
                        Text(L10n.text("使用 Codex 输入框草稿")).tag(ResumeMessageMode.composerDraft)
                    }
                    .disabled(state.choices.deselectedEpisodes.contains(task.episodeKey))
                    if state.choices.mode(for: task) == .composerDraft {
                        Text(L10n.text("自动继续时，发送这个任务在 Codex 输入框中保存的文字；没有文字则发送“继续”。原草稿会保留，附件不会发送。"))
                            .font(.caption).foregroundStyle(.secondary)
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
