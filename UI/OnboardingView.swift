import SwiftUI
import AppKit

struct OnboardingView: View {
    var onSizeChange: ((CGSize) -> Void)? = nil
    var onNavigate: ((@escaping () -> Void) -> Void)? = nil
    let onStart: (Int) -> Void
    @State private var step = 0
    @State private var startTime = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()

    private var anchorMinutes: Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        return (components.hour ?? 8) * 60 + (components.minute ?? 0)
    }

    private var followingTimes: [String] {
        let today = Date()
        let calendar = Calendar.current
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        return ScheduleEngine(anchorMinutes: anchorMinutes).nodes(on: today, calendar: calendar).dropFirst().map {
            (calendar.isDate($0, inSameDayAs: today) ? "" : L10n.text("次日 ")) + clock.string(from: $0)
        }
    }

    private func navigate(to destination: Int) {
        let change = { step = destination }
        if let onNavigate { onNavigate(change) }
        else { change() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            page.frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if step > 0 {
                    Button { navigate(to: step - 1) } label: {
                        Text(L10n.text("开始使用")).hidden().overlay(Text(L10n.text("返回")))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Spacer()
                }
                Button {
                    if step < 2 { navigate(to: step + 1) }
                    else { onStart(anchorMinutes) }
                } label: {
                    Text(L10n.text("开始使用")).hidden()
                        .overlay(Text(L10n.text(step == 0 ? "开始设置" : step == 1 ? "下一步" : "开始使用")))
                        .frame(maxWidth: step == 0 ? .infinity : nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: OnboardingSizeKey.self, value: geometry.size)
        })
        .onPreferenceChange(OnboardingSizeKey.self) { onSizeChange?($0) }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                Text("Codex Keeper").font(.title.weight(.semibold))
            }
        case 1:
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("1. 按计划保持活动")).font(.title2.weight(.semibold))
                Text(L10n.text("每 5 小时让 Codex 自动保持活动，帮你更充分地利用每天的额度。"))
                    .font(.system(size: NSFont.systemFontSize + 1))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("设置你的每日计划")).fontWeight(.medium)
                    OnboardingTimesLayout {
                        DatePicker(L10n.text("设置你的每日计划"), selection: $startTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .fixedSize()
                        ForEach(Array(followingTimes.enumerated()), id: \.offset) { _, time in
                            HStack(spacing: 5) {
                                Text("→").foregroundStyle(.secondary)
                                Text(time).monospacedDigit()
                            }
                            .fixedSize()
                        }
                    }
                }
                .font(.system(size: NSFont.systemFontSize + 1))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        default:
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("2. 自动继续任务")).font(.title2.weight(.semibold))
                Text(L10n.text("因额度用尽而暂停的任务，将在额度正常恢复后自动继续；提前恢复时提醒你选择，未选择时不会继续。"))
                    .font(.system(size: NSFont.systemFontSize + 1))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OnboardingTimesLayout: Layout {
    private func arrangement(width: CGFloat?, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let available = width ?? sizes.reduce(0) { $0 + $1.width + 5 }
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            if x > 0 && x + size.width > available {
                x = 0
                y += rowHeight + 8
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + 5
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: available, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            let rowHeight = frames.filter { $0.minY == frame.minY }.map(\.height).max() ?? frame.height
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY + (rowHeight - frame.height) / 2),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

private struct OnboardingSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

@MainActor final class OnboardingWindow: NSWindow {
    private var transitioning = false
    init(onStart: @escaping (Int) -> Void) {
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Codex Keeper"
        isReleasedWhenClosed = false
        let content = NSHostingView(rootView: OnboardingView(onSizeChange: { [weak self] size in
            // Apply the intrinsic page size after SwiftUI finishes its layout pass.
            DispatchQueue.main.async { self?.fitPage(size) }
        }, onNavigate: { [weak self] change in
            self?.changePage(change)
        }, onStart: onStart))
        contentView = content
        setContentSize(content.fittingSize)
    }

    private func pageFrame(_ size: CGSize) -> NSRect {
        var target = frameRect(forContentRect: NSRect(origin: .zero, size: size))
        target.origin = NSPoint(x: frame.midX - target.width / 2, y: frame.maxY - target.height)
        return target
    }

    private func fitPage(_ size: CGSize) {
        guard !transitioning, size.width > 0, size.height > 0 else { return }
        let target = pageFrame(size)
        guard abs(target.height - frame.height) > 0.5 || abs(target.width - frame.width) > 0.5 else { return }
        setFrame(target, display: true, animate: isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func changePage(_ change: @escaping () -> Void) {
        guard !transitioning, let content = contentView else { return }
        transitioning = true
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : 0.12
            content.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            change()
            DispatchQueue.main.async {
                content.layoutSubtreeIfNeeded()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduced ? 0 : 0.18
                    self.animator().setFrame(self.pageFrame(content.fittingSize), display: true)
                } completionHandler: {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = reduced ? 0.12 : 0.2
                        content.animator().alphaValue = 1
                    } completionHandler: {
                        DispatchQueue.main.async {
                            self.transitioning = false
                            self.fitPage(content.fittingSize)
                        }
                    }
                }
            }
        }
    }
}
