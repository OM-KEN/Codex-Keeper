import SwiftUI

struct MenuSummaryView: View {
    let summary: MenuSummary
    var openTasks: () -> Void = {}
    var showError: () -> Void = {}
    var refresh: () -> Void = {}
    @State private var tasksHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !summary.reminderTitle.isEmpty {
                Button(action: openTasks) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(summary.reminderTitle).font(.system(size: 12, weight: .semibold))
                            Text(summary.reminderBody).font(.system(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L10n.text("处理任务")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
                    }
                    .padding(10).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.orange.opacity(0.25)))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).help(L10n.text("处理任务"))
            }
            if !summary.error.isEmpty {
                Button(action: showError) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(L10n.text(summary.error)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 9))
                    }
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .padding(8).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help(L10n.text(summary.error))
            }
            HStack {
                Text("Codex Keeper").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(L10n.text(summary.badge))
                    .font(.system(size: summary.badge == "计划外" ? 13 : 11, weight: .semibold))
                    .foregroundStyle(summary.badge == "计划外" ? Color.orange : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                if !summary.eyebrow.isEmpty {
                    Text(L10n.text(summary.eyebrow)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text(summary.headline))
                        .font(.system(size: summary.isTime ? 38 : 24, weight: .semibold)).monospacedDigit()
                    if !summary.action.isEmpty {
                        Text(L10n.text(summary.action)).font(.system(size: 17, weight: .semibold))
                    }
                    Button(action: refresh) {
                        ZStack {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .opacity(summary.isRefreshing ? 0 : 1)
                            if summary.isRefreshing {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L10n.text(summary.isRefreshing ? "正在同步；点击可在完成后重新读取" : "重新同步额度"))
                    .accessibilityLabel(L10n.text(summary.isRefreshing ? "正在同步额度" : "重新同步额度"))
                    .accessibilityValue(summary.refreshMessage)
                }
                if !summary.refreshMessage.isEmpty {
                    Text(summary.refreshMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(L10n.format("同步状态：%@", summary.refreshMessage))
                }
                if let title = summary.tasks.first {
                    Button(action: openTasks) {
                        HStack(spacing: 5) {
                            Image(systemName: summary.taskCount > 1 ? "bubble.left.and.text.bubble.right" : "text.bubble")
                            Text(title).lineLimit(1).truncationMode(.tail)
                            if summary.taskCount > 1 {
                                Text(L10n.format("等%d个会话", summary.taskCount)).foregroundStyle(.primary).fixedSize()
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(tasksHovered ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .background(tasksHovered ? Color.accentColor.opacity(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.top, 4).help(L10n.text("选择会话和续跑方式"))
                        .onHover { tasksHovered = $0 }
                }
                if summary.timeline.count > 1 {
                    MenuTimelineView(points: summary.timeline).padding(.top, 10)
                }
                if !summary.note.isEmpty {
                    Text(L10n.text(summary.note)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                }
            }
            if !summary.quotas.isEmpty {
                Divider()
                VStack(spacing: 10) {
                    ForEach(summary.quotas) { quota in
                        HStack(spacing: 6) {
                            Text(L10n.text(quota.name)).foregroundStyle(.secondary).frame(width: 31, alignment: .leading)
                            if quota.remaining.rounded() <= 0 {
                                // Native ProgressView keeps a minimum fill even at zero.
                                Capsule().fill(Color.primary.opacity(0.05))
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.05)))
                                    .frame(height: 8)
                                    .accessibilityLabel(L10n.format("%@剩余额度", L10n.text(quota.name)))
                                    .accessibilityValue("0%")
                            } else {
                                ProgressView(value: max(0, min(100, quota.remaining)), total: 100)
                                    .progressViewStyle(.linear).tint(.accentColor)
                                    .accessibilityLabel(L10n.format("%@剩余额度", L10n.text(quota.name)))
                            }
                            Text("\(Int(max(0, min(100, quota.remaining)).rounded()))%")
                                .monospacedDigit().frame(width: 32, alignment: .trailing)
                            Text(L10n.text(quota.detail)).foregroundStyle(.secondary)
                                .frame(width: 106, alignment: .trailing).lineLimit(1)
                        }.font(.system(size: 11))
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 304, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private extension VerticalAlignment {
    struct TimelineSymbol: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[VerticalAlignment.center] }
    }
    static let timelineSymbol = VerticalAlignment(TimelineSymbol.self)
}

private struct MenuTimelineView: View {
    let points: [MenuTimelinePoint]
    var body: some View {
        HStack(alignment: .timelineSymbol, spacing: 6) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                VStack(spacing: 5) {
                    Text(point.timeLabel).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Image(systemName: point.symbol).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(point.isAction ? Color.accentColor : Color.secondary)
                        .frame(width: 16, height: 16)
                        .alignmentGuide(.timelineSymbol) { $0[VerticalAlignment.center] }
                    Text(L10n.text(point.label)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .layoutPriority(1)
                .help(L10n.text(point.kind == .keepAlive || point.kind == .scheduled ? "计划节点；已有有效额度窗口时跳过" : point.label))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(point.day) \(point.time) \(L10n.text(point.label))")
                if index + 1 < points.count {
                    GeometryReader { geometry in
                        Path { path in
                            path.move(to: .zero)
                            path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                        }.stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1,
                            dash: points[index + 1].solidBefore ? [] : [2, 3]))
                    }.frame(height: 1)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
