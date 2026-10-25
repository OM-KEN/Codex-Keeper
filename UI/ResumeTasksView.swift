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
    private var rows: [ResumeTaskItem] {
        let recorded = records.map { ResumeTaskItem(task: $0.target, operation: $0) }
        guard historyIDs == nil else { return recorded }
        let keys = Set(records.map { $0.target.episodeKey })
        return recorded + state.availableTasks.filter { !keys.contains($0.episodeKey) }.map { ResumeTaskItem(task: $0, operation: nil) }
    }
    private var unreadPresentedEvents: Set<String> {
        Set(records.filter(\.needsManualContinuation).map(\.id)).subtracting(state.choices.readManualEvents ?? [])
    }
    private func markPresentedRecordsRead() {
        guard historyIDs == nil else { return }
        let ids = Set(records.map(\.id)); presentedIDs.formUnion(ids)
        DispatchQueue.main.async {
            guard NSApp.windows.contains(where: { $0.isVisible && $0.title == L10n.text("自动继续任务") }) else { return }
            state.markManualEventsRead(ids)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let historyLabel, historyAccountID == state.displayAccountID {
                    Text(historyLabel).font(.system(size: 14, weight: .semibold))
                }
                if historyIDs == nil, let failure = state.pendingStateFailure ?? state.sessions.detectionError ?? state.execution.recordingFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 13))
                }
                if rows.isEmpty {
                    Text(L10n.text("暂无可显示的任务")).font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            ResumeTaskRow(state: state, task: row.task, operation: row.operation, isHistory: historyIDs != nil,
                                ignore: { ignoring = row.task }, openError: { error = $0 })
                            if row.id != rows.last?.id { Divider().padding(.leading, 42).padding(.trailing, 16) }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
                }
            }.padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 460, idealWidth: 572, minHeight: 220, idealHeight: 300)
        .onAppear { markPresentedRecordsRead() }
        .onChange(of: unreadPresentedEvents) { _ in markPresentedRecordsRead() }
        .alert(L10n.text("忽略本轮续跑？"), isPresented: Binding(get: { ignoring != nil }, set: { if !$0 { ignoring = nil } }), presenting: ignoring) { task in
            Button(L10n.text("取消"), role: .cancel) { ignoring = nil }
            Button(L10n.text("忽略本轮"), role: .destructive) {
                if !state.ignoreEpisode(task) { error = state.pendingStateFailure ?? ResumePreflightReason.runtimeUnhealthy.userMessage }
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

struct ResumeTasksProgressView: View {
    @ObservedObject var state: AppState
    var historyIDs: Set<String>? = nil
    @State private var presentedIDs = Set<String>()

    var body: some View {
        let records = state.taskOperations(ids: historyIDs ?? Set(state.currentOperations.map(\.id)).union(presentedIDs))
        let keys = Set(records.map { $0.target.episodeKey })
        let pending = historyIDs == nil ? state.availableTasks.filter { !keys.contains($0.episodeKey) }.count : 0
        Text(L10n.format("已继续 %d/%d", records.filter { $0.respondedAt != nil }.count, records.count + pending))
            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            .frame(width: 128, height: 28, alignment: .trailing).padding(.trailing, 12)
            .onAppear { presentedIDs.formUnion(records.map(\.id)) }
            .onChange(of: Set(state.currentOperations.map(\.id))) { presentedIDs.formUnion($0) }
    }
}

private struct ResumeTaskRow: View {
    @ObservedObject var state: AppState
    let task: BlockedSession
    let operation: ResumeOperation?
    let isHistory: Bool
    let ignore: () -> Void
    let openError: (String) -> Void

    private var selected: Bool { !state.choices.deselectedEpisodes.contains(task.episodeKey) }
    private var locked: Bool { state.execution.isContentLocked(task, accountID: state.displayAccountID) }
    private var canConfigure: Bool {
        !isHistory && operation?.needsManualContinuation != true && operation?.respondedAt == nil && operation?.phase != .stopped
    }
    private var needsChoice: Bool {
        state.enabled && state.automaticResumeEnabled && selected && !state.choices.keepAliveEpisodes.contains(task.episodeKey) &&
            (state.choices.recoveryDecisions?[task.episodeKey].map { $0.phase != .responded } ?? false)
    }
    private var statusColor: Color {
        if operation?.needsManualContinuation == true { return .red }
        if operation?.respondedAt != nil { return .green }
        if operation?.notSubmittedNeedsAttention == true || (operation?.phase == .stopped && operation?.terminal != .quotaStopped) || (!isHistory && needsChoice) { return .red }
        return ResumeTaskFact.make(task: task, operation: operation).isConfirming ? .blue : .secondary
    }

    var body: some View {
        let fact = ResumeTaskFact.make(task: task, operation: operation, enabled: isHistory || state.enabled,
            autoResume: isHistory || state.automaticResumeEnabled, selected: isHistory || selected,
            cancelled: !isHistory && state.choices.keepAliveEpisodes.contains(task.episodeKey))
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble").font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 16, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 14) {
                    Text(task.displayName).font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    if !isHistory {
                        HStack(spacing: 12) {
                            if canConfigure {
                                Toggle(task.displayName, isOn: Binding(get: { selected }, set: { state.setSelected(task, $0) }))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(locked)
                                    .help(L10n.text("自动继续"))
                            }
                            Button(action: ignore) { Image(systemName: "trash").font(.system(size: 14)) }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help(L10n.text("忽略本轮"))
                                .accessibilityLabel(L10n.format("移除任务：%@", task.displayName))
                        }.frame(height: 22).fixedSize()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(needsChoice && !isHistory ? L10n.text("需要处理") : fact.text,
                        systemImage: needsChoice && !isHistory ? "exclamationmark.circle" : fact.symbol)
                        .font(.system(size: 13)).foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if canConfigure {
                        Spacer(minLength: 0)
                        Picker(L10n.text("发送内容"), selection: Binding(get: { state.choices.mode(for: task) }, set: { state.setMessageMode(task, $0) })) {
                            Text(L10n.format("默认发送“%@”", L10n.text("继续"))).tag(ResumeMessageMode.localizedDefault)
                            Text(L10n.text("自定义内容")).tag(ResumeMessageMode.fixed)
                            Text(L10n.text("使用 Codex 输入框内容")).tag(ResumeMessageMode.composerDraft)
                        }.labelsHidden().pickerStyle(.menu).controlSize(.regular).font(.system(size: 13))
                            .fixedSize().disabled(!selected || locked)
                    }
                }
                if !isHistory, operation?.needsManualContinuation == true ||
                    (operation?.phase == .checking && operation?.respondedAt == nil),
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
                    Button(L10n.text("打开 Codex")) {
                        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, failure in
                            if failure != nil { DispatchQueue.main.async { openError(L10n.text("无法打开 Codex，请手动打开应用。")) } }
                        }
                    }.font(.system(size: 13))
                }
                if canConfigure {
                    if needsChoice {
                        HStack {
                            Button(L10n.text("现在继续")) { state.resolveRecoveryDecision(.now, for: [task]) }
                                .disabled(!state.execution.canStartResume)
                            Button(L10n.text("按计划继续")) { state.resolveRecoveryDecision(.plan, for: [task]) }
                            Button(L10n.text("取消本次")) { state.resolveRecoveryDecision(.cancel, for: [task]) }
                        }.font(.system(size: 13)).disabled(!state.enabled || !state.automaticResumeEnabled || !selected)
                        if state.execution.isKeepingAlive {
                            Text(L10n.text("正在保活，完成后可选择现在继续")).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    } else if operation?.canRetrySubmission == true {
                        HStack {
                            Text(state.planExplanation(for: task) ?? "").font(.system(size: 13)).foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.text("立即重试")) { state.retry(task) }
                                .disabled(!state.execution.canStartResume || !state.automaticResumeEnabled || !selected)
                        }
                        if state.execution.isKeepingAlive {
                            Text(L10n.text("正在保活，完成后可立即重试")).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    if state.choices.mode(for: task) == .fixed {
                        TextEditor(text: Binding(get: { state.choices.messages[task.episodeKey] ?? state.defaultResumeMessage }, set: { state.setMessage(task, $0) }))
                            .keeperEditorStyle().scrollContentBackground(.hidden).font(.system(size: 14)).frame(height: 76)
                            .padding(6).background(.background, in: RoundedRectangle(cornerRadius: 5))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator)).disabled(!selected || locked)
                    } else if state.choices.mode(for: task) == .composerDraft {
                        HStack(spacing: 5) {
                            Text(L10n.text("只发送草稿文字，不含附件；空草稿发送“继续”。")).font(.system(size: 13)).foregroundStyle(.secondary)
                            InfoHintButton(label: L10n.text("草稿保留说明"), hint: L10n.text("Codex 输入框中的原草稿会保留。"), detail: L10n.text("Codex 输入框中的原草稿会保留。"))
                        }
                    }
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}

private struct ResumeTaskItem: Identifiable {
    let task: BlockedSession
    let operation: ResumeOperation?
    var id: String { operation?.id ?? task.episodeKey }
}
