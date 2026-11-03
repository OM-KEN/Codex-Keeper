import AppKit
import SwiftUI

private enum TokenUsageHints {
    static func today(_ analysis: TokenUsageHistoryAnalysis) -> String {
        L10n.text("今日 Token") + "\n" + (analysis.todayTokens.map(TokenUsageFormat.compact) ?? "—") + " Token"
    }
    static func estimate(_ estimate: TokenUsageEstimate, weekly: Bool) -> String {
        L10n.text(weekly ? "每周真实额度估算" : "5小时真实额度估算") + "\n" +
            (estimate.tokens.map(TokenUsageFormat.compact) ?? "—") + " Token"
    }
    static var tps: String { L10n.text("tps 表示平均每秒生成的 Token 数，用来衡量输出速度。") }
    static func info(_ analysis: TokenUsageHistoryAnalysis) -> String {
        var lines = [
            L10n.text("本机记录 · 输入含缓存，输出含推理"),
            L10n.text("近7日较前7日同期；今日尚未结束。空白表示没有记录，不代表零消耗。"),
            L10n.text("跨午夜的5小时窗口全部计入开始日；未知窗口按记录时间显示。"),
            L10n.format("价格覆盖 %@ / %@ Token；时间未知 %@，账户未知 %@。",
                TokenUsageFormat.compact(analysis.pricedTokens), TokenUsageFormat.compact(analysis.totalTimedTokens),
                TokenUsageFormat.compact(analysis.unknownTimeTokens), TokenUsageFormat.compact(analysis.snapshot.unboundTokens)),
            L10n.text("API 等值按当前价格折算，非官方余额或账单；不含工具及未记录的速度费用。"),
            L10n.text("仅采用同模型同档位、可完整配对的 Plus 用量；每个窗口累计匹配消耗超过25%后按消耗比例加权。"),
            L10n.text("未记录速度档位的历史按标准 API 价显示，不参与额度校准。")
        ]
        if let group = analysis.calibrationGroup {
            let tier = group.serviceTier == "standard" ? L10n.text("标准") : group.serviceTier.capitalized
            lines.insert(L10n.format("额度估算基准：%@ · %@", group.model, tier), at: 0)
        } else if analysis.snapshot.isLoaded { lines.append(L10n.text("当前模型或速度档位未知")) }
        if !analysis.snapshot.isLoaded { lines.append(L10n.text("正在读取本机历史…")) }
        if analysis.snapshot.accountID == nil { lines.append(L10n.text("尚未确认当前账户")) }
        if analysis.snapshot.unreadableFiles > 0 { lines.append(L10n.text("部分本机记录无法读取")) }
        if analysis.snapshot.omittedBaselines > 0 { lines.append(L10n.text("首次旧累计仅建立基线，未将继承历史重复计入。")) }
        lines.append(L10n.format("价格表 %@", TokenUsagePrices.version) + "\n" + TokenUsagePrices.source.absoluteString)
        return lines.joined(separator: "\n")
    }
}

/// System tooltips are suppressed while NSMenu tracks the mouse. A nonactivating
/// panel keeps the same native appearance without taking focus from the menu.
@MainActor private final class TokenUsageHoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class TokenUsageHover: NSObject {
    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private var text: String?
    var visibleText: String? { panel?.isVisible == true ? text : nil }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(hide), name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hide), name: NSWindow.willCloseNotification, object: nil)
    }

    func show(_ text: String, formatted: NSAttributedString? = nil, at point: NSPoint, in view: NSView) {
        guard let parent = view.window, parent.isVisible else { hide(); return }
        if panel == nil {
            let panel = TokenUsageHoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            let background = NSVisualEffectView()
            background.material = .popover; background.blendingMode = .behindWindow; background.state = .active
            background.wantsLayer = true; background.layer?.cornerRadius = 7; background.layer?.masksToBounds = true
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.maximumNumberOfLines = 0
            label.cell?.usesSingleLineMode = false
            background.addSubview(label); panel.contentView = background
            self.panel = panel
        }
        guard let panel else { return }
        self.text = text
        panel.appearance = view.effectiveAppearance
        let content = NSMutableAttributedString(attributedString: formatted ?? NSAttributedString(string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: content.length)) { color, range, _ in
                if let color = color as? NSColor {
                    content.addAttribute(.foregroundColor, value: color.usingColorSpace(.deviceRGB) ?? color, range: range)
                }
            }
        }
        label.attributedStringValue = content
        let measured = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 300, height: 1000))
        let size = NSSize(width: ceil(measured.width) + 24, height: ceil(measured.height) + 24)
        let screenPoint = parent.convertPoint(toScreen: view.convert(point, to: nil))
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        let origin = NSPoint(x: max(screen.minX + 8, min(screenPoint.x + 14, screen.maxX - size.width - 8)),
            y: max(screen.minY + 8, min(screenPoint.y - size.height - 14, screen.maxY - size.height - 8)))
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        label.frame = NSRect(x: 12, y: 10, width: size.width - 24, height: size.height - 20)
        panel.orderFront(nil)
    }

    @objc func hide() { panel?.orderOut(nil); text = nil }
}

/// Native tracking works while NSMenu owns the event loop, including macOS 13.
@MainActor final class TokenUsageChartView: NSView {
    var days: [TokenUsageDay] = [] { didSet { needsDisplay = true } }
    var openHistory: (() -> Void)?
    var hoverChanged: ((String?) -> Void)?
    private var tracking: NSTrackingArea?
    private struct Hit { var rect: NSRect; var text: String; var formatted: NSAttributedString; var segmentID: String? }
    private var hits: [Hit] = []
    private let hoverPanel = TokenUsageHover()
    private var hoverPoint: NSPoint?
    private(set) var highlightedSegment: String?
    var visibleHoverText: String? { hoverPanel.visibleText }
    var plotRect: NSRect { NSRect(x: 46, y: 22, width: max(1, bounds.width - 52), height: max(1, bounds.height - 43)) }
    static func color(_ index: Int) -> NSColor {
        guard index >= 0 else { return .secondaryLabelColor.withAlphaComponent(0.35) }
        let accent = NSColor.controlAccentColor.blended(withFraction: 0.25, of: .secondaryLabelColor) ?? .controlAccentColor
        return accent.withAlphaComponent([0.38, 0.62, 0.86][index % 3])
    }
    override var acceptsFirstResponder: Bool { false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { dismissHover() }
    override func mouseDown(with event: NSEvent) { dismissHover(); openHistory?() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { dismissHover() }; super.viewWillMove(toWindow: newWindow) }
    func dismissHover() {
        hoverPoint = nil; hoverPanel.hide(); hoverChanged?(nil)
        if highlightedSegment != nil { highlightedSegment = nil; needsDisplay = true }
    }
    func hover(at point: NSPoint) {
        hoverPoint = point
        let hit = hits.last(where: { $0.rect.contains(point) })
        if highlightedSegment != hit?.segmentID { highlightedSegment = hit?.segmentID; needsDisplay = true }
        let text = hit?.text
        if let hit { hoverPanel.show(hit.text, formatted: hit.formatted, at: point, in: self) } else { hoverPanel.hide() }
        hoverChanged?(text)
    }

    private static func formattedHover(_ text: String, primary: String, dayTotal: String? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 7
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        let source = text as NSString
        let primaryRange = source.range(of: primary)
        if primaryRange.location != NSNotFound {
            result.addAttributes([.font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: NSColor.labelColor], range: primaryRange)
        }
        if let dayTotal {
            let totalRange = source.range(of: dayTotal, options: .backwards)
            if totalRange.location != NSNotFound {
                result.addAttributes([.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.labelColor], range: totalRange)
            }
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        hits = []
        let plot = plotRect
        let maximum = max(1, days.map(\.total).max() ?? 1)
        func text(_ value: String, _ rect: NSRect, size: CGFloat = 10, color: NSColor = .secondaryLabelColor,
                  alignment: NSTextAlignment = .left) {
            let style = NSMutableParagraphStyle(); style.alignment = alignment
            (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size),
                .foregroundColor: color, .paragraphStyle: style])
        }
        for fraction in [0.0, 0.5, 1.0] {
            let y = plot.minY + plot.height * fraction
            NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
            let line = NSBezierPath(); line.lineWidth = 0.5
            line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y)); line.stroke()
            text(TokenUsageFormat.compact(Int(Double(maximum) * fraction), fractionDigits: 0),
                NSRect(x: 0, y: y - 5, width: 41, height: 12))
        }
        let date = DateFormatter(); date.dateFormat = "M/d"
        let slot = plot.width / CGFloat(max(1, days.count))
        for (index, day) in days.enumerated() {
            let x = plot.minX + CGFloat(index) * slot
            text(date.string(from: day.date), NSRect(x: x, y: 3, width: slot, height: 14), alignment: .center)
            let columnText = date.string(from: day.date) + "\n" +
                L10n.format("当日总量：%@ Token", day.hasRecords ? TokenUsageFormat.compact(day.total) : "—")
            let column = NSRect(x: x, y: plot.minY, width: slot, height: plot.height)
            hits.append(Hit(rect: column, text: columnText,
                formatted: Self.formattedHover(columnText, primary: day.hasRecords ? TokenUsageFormat.compact(day.total) : "—"),
                segmentID: nil))
            guard day.hasRecords else {
                text("—", NSRect(x: x, y: plot.minY + 2, width: slot, height: 14), alignment: .center); continue
            }
            var y = plot.minY
            NSGraphicsContext.saveGraphicsState()
            let bar = NSRect(x: x + slot * 0.2, y: y, width: slot * 0.6,
                height: plot.height * CGFloat(day.total) / CGFloat(maximum))
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).addClip()
            for segment in day.segments {
                let height = plot.height * CGFloat(segment.total) / CGFloat(maximum)
                let rect = NSRect(x: bar.minX, y: y, width: bar.width, height: height)
                let fill = rect.insetBy(dx: 0, dy: min(0.5, height / 4))
                let key = day.date.description + ":" + segment.id
                let selected = highlightedSegment == key
                let color = Self.color(segment.colorIndex)
                (selected ? color.blended(withFraction: 0.2, of: .controlAccentColor) ?? color : color).setFill()
                NSBezierPath(rect: fill).fill()
                if selected {
                    NSColor.keyboardFocusIndicatorColor.setStroke()
                    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: min(0.75, height / 4)), xRadius: 2, yRadius: 2)
                    outline.lineWidth = 1.5; outline.stroke()
                }
                let detail = TokenUsageFormat.range(segment.start, segment.reset) + "\n" +
                    L10n.format(segment.windowID == nil ? "该分段：%@ Token" : "5小时用量：%@ Token", TokenUsageFormat.compact(segment.total)) + "\n" +
                    L10n.format("当日总量：%@ Token", TokenUsageFormat.compact(day.total))
                hits.append(Hit(rect: rect, text: detail, formatted: Self.formattedHover(detail,
                    primary: TokenUsageFormat.compact(segment.total), dayTotal: TokenUsageFormat.compact(day.total)), segmentID: key))
                y += height
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.text("近七日 Token 用量，点击查看历史"))
        if hoverPanel.visibleText != nil, let hoverPoint { hover(at: hoverPoint) }
    }
}

private struct TokenUsageTPSAnchor: NSViewRepresentable {
    var changed: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); changed(view); return view
    }
    func updateNSView(_ view: NSView, context: Context) { changed(view) }
}

private struct TokenUsageMetrics: View {
    let analysis: TokenUsageHistoryAnalysis
    var tpsViewChanged: (NSView) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("今日 Token")).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(analysis.todayTokens.map(TokenUsageFormat.compact) ?? "—")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(TokenUsageFormat.tps(analysis.todaySpeed.value) + " tps")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .fixedSize()
                        .background(TokenUsageTPSAnchor(changed: tpsViewChanged).allowsHitTesting(false))
                        .help(TokenUsageHints.tps)
                    Spacer(minLength: 0)
                }
            }.help(TokenUsageHints.today(analysis))
            if analysis.fiveHourEstimate.value != nil || analysis.weeklyEstimate.value != nil {
                HStack(spacing: 12) {
                    if analysis.fiveHourEstimate.value != nil { metric(analysis.fiveHourEstimate, weekly: false) }
                    if analysis.weeklyEstimate.value != nil { metric(analysis.weeklyEstimate, weekly: true) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func metric(_ estimate: TokenUsageEstimate, weekly: Bool) -> some View {
        HStack(spacing: 4) {
            Text(L10n.text(weekly ? "1周" : "5小时")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            Text(estimate.value.map(TokenUsageFormat.dollars) ?? "—").font(.system(size: 13, weight: .medium)).fixedSize()
            if let change = estimate.change {
                Text(TokenUsageFormat.change(change)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .help(TokenUsageHints.estimate(estimate, weekly: weekly))
    }
}

@MainActor private final class TokenUsageMetricsHost: NSHostingView<TokenUsageMetrics> {
    private var tracking: NSTrackingArea?
    private let hoverPanel = TokenUsageHover()
    private weak var tpsView: NSView?
    var tpsHoverRect: NSRect {
        guard let tpsView, tpsView.isDescendant(of: self) else { return .zero }
        return convert(tpsView.bounds, from: tpsView)
    }
    var visibleHoverText: String? { hoverPanel.visibleText }
    func update(_ analysis: TokenUsageHistoryAnalysis) {
        dismissHover()
        rootView = TokenUsageMetrics(analysis: analysis, tpsViewChanged: { [weak self] in self?.tpsView = $0 })
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { dismissHover() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { dismissHover() }; super.viewWillMove(toWindow: newWindow) }
    func dismissHover() { hoverPanel.hide() }
    func hover(at point: NSPoint) {
        guard bounds.contains(point) else { dismissHover(); return }
        let analysis = rootView.analysis
        let hasFiveHour = analysis.fiveHourEstimate.value != nil, hasWeekly = analysis.weeklyEstimate.value != nil
        let estimateRow = (hasFiveHour || hasWeekly) && (isFlipped ? point.y >= bounds.height - 24 : point.y <= 24)
        let text: String
        if !estimateRow {
            let tpsRect = tpsHoverRect
            text = !tpsRect.isEmpty && tpsRect.insetBy(dx: -3, dy: -5).contains(point) ? TokenUsageHints.tps : TokenUsageHints.today(analysis)
        } else {
            let weekly = !hasFiveHour || (hasWeekly && point.x > bounds.midX)
            text = TokenUsageHints.estimate(weekly ? analysis.weeklyEstimate : analysis.fiveHourEstimate, weekly: weekly)
        }
        hoverPanel.show(text, at: point, in: self)
    }
}

@MainActor final class TokenUsageMenuView: NSView {
    override var isFlipped: Bool { true }
    private let metrics: TokenUsageMetricsHost
    let chart = TokenUsageChartView()
    var openHistory: (() -> Void)?
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var hoverTimer: Timer?
    private var lastPointer: NSPoint?

    init(analysis: TokenUsageHistoryAnalysis) {
        metrics = TokenUsageMetricsHost(rootView: TokenUsageMetrics(analysis: analysis))
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: 234))
        metrics.frame = NSRect(x: 16, y: 14, width: 272, height: 78)
        addSubview(metrics)
        chart.frame = NSRect(x: 16, y: 96, width: 272, height: 124)
        chart.openHistory = { [weak self] in self?.openHistory?() }
        addSubview(chart)
        update(analysis)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { openHistory?() }
    func menuWillOpen() {
        guard hoverTimer == nil else { return }
        lastPointer = nil
        // NSMenu's tracking loop consumes mouseMoved before NSView receives it.
        // Poll only while this menu is open, and redraw the tooltip only on change.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }
    func menuDidClose() {
        hoverTimer?.invalidate(); hoverTimer = nil; lastPointer = nil
        chart.dismissHover(); metrics.dismissHover()
    }
    deinit { hoverTimer?.invalidate() }
    private func trackPointer() {
        guard let window, window.isVisible else { return }
        let point = convert(window.convertPoint(fromScreen: pointerLocation()), from: nil)
        let changed = lastPointer != point
        lastPointer = point
        let plotPoint = chart.convert(point, from: self)
        if chart.bounds.contains(plotPoint) {
            metrics.dismissHover()
            if changed || chart.visibleHoverText == nil { chart.hover(at: plotPoint) }
        } else if metrics.frame.contains(point) {
            chart.dismissHover()
            if changed || metrics.visibleHoverText == nil { metrics.hover(at: metrics.convert(point, from: self)) }
        } else if changed {
            chart.dismissHover(); metrics.dismissHover()
        }
    }
    var visibleMetricHoverText: String? { metrics.visibleHoverText }
    var metricTPSFrame: NSRect { metrics.tpsHoverRect }
    func hoverMetric(at point: NSPoint) { metrics.hover(at: point) }
    func update(_ analysis: TokenUsageHistoryAnalysis) {
        metrics.update(analysis)
        chart.days = analysis.days
        let metricsHeight: CGFloat = analysis.fiveHourEstimate.value != nil || analysis.weeklyEstimate.value != nil ? 78 : 52
        if metrics.frame.height != metricsHeight {
            metrics.setFrameSize(NSSize(width: 272, height: metricsHeight))
            chart.setFrameOrigin(NSPoint(x: 16, y: metrics.frame.maxY + 4))
            setFrameSize(NSSize(width: 304, height: chart.frame.maxY + 14))
            lastPointer = nil
            chart.dismissHover()
            layoutSubtreeIfNeeded()
        }
    }
}

private struct TokenHistoryChart: NSViewRepresentable {
    var days: [TokenUsageDay]
    func makeNSView(context: Context) -> TokenUsageChartView { TokenUsageChartView() }
    func updateNSView(_ view: TokenUsageChartView, context: Context) { view.days = days }
}

struct TokenUsageHistoryView: View {
    @ObservedObject var history: TokenUsageHistoryObserver
    @State private var pageEnd = Calendar.current.startOfDay(for: Date())
    @State private var expanded: Set<Date> = [Calendar.current.startOfDay(for: Date())]
    @State private var expandedWindows: Set<String> = []
    private var analysis: TokenUsageHistoryAnalysis { history.analysis }
    private var pageDays: [TokenUsageDay] {
        let calendar = analysis.calendar
        let end = calendar.startOfDay(for: pageEnd)
        let byDate = Dictionary(uniqueKeysWithValues: analysis.historicalDays.map { ($0.date, $0) })
        return (-6...0).map { value in
            let date = calendar.date(byAdding: .day, value: value, to: end)!
            return byDate[date] ?? TokenUsageDay(date: date, segments: [])
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            overview
            trend
            details
        }.padding(24).frame(minWidth: 820, minHeight: 680)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private var overview: some View {
        HStack(alignment: .top, spacing: 14) {
            metric("今日 Token", analysis.todayTokens.map(TokenUsageFormat.compact) ?? "—",
                hint: TokenUsageHints.today(analysis))
            metric("今日 tps", TokenUsageFormat.tps(analysis.todaySpeed.value), hint: TokenUsageHints.tps)
            if let value = analysis.fiveHourEstimate.value {
                metric("5小时真实额度估算", TokenUsageFormat.dollars(value),
                    change: analysis.fiveHourEstimate.change, hint: TokenUsageHints.estimate(analysis.fiveHourEstimate, weekly: false))
            }
            if let value = analysis.weeklyEstimate.value {
                metric("每周真实额度估算", TokenUsageFormat.dollars(value),
                    change: analysis.weeklyEstimate.change, hint: TokenUsageHints.estimate(analysis.weeklyEstimate, weekly: true))
            }
        }
    }
    private var trend: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Text(L10n.text("用量趋势")).font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        Button { move(-7) } label: { Image(systemName: "chevron.left") }.help(L10n.text("更早七日"))
                        if let first = pageDays.first?.date, let last = pageDays.last?.date {
                            Text(first, style: .date).font(.subheadline)
                            Text("–")
                            Text(last, style: .date).font(.subheadline)
                        }
                        Button { move(7) } label: { Image(systemName: "chevron.right") }
                            .disabled(pageEnd >= analysis.calendar.startOfDay(for: analysis.now))
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    DatePicker(L10n.text("截至日期"), selection: Binding(get: { pageEnd }, set: {
                        pageEnd = analysis.calendar.startOfDay(for: $0)
                    }), in: ...analysis.now, displayedComponents: .date).labelsHidden().fixedSize()
                    Button { pageEnd = analysis.calendar.startOfDay(for: analysis.now) } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }.help(L10n.text("今天"))
                    Link(destination: TokenUsagePrices.source) { Image(systemName: "info.circle") }
                        .help(TokenUsageHints.info(analysis))
                }.controlSize(.small)
                TokenHistoryChart(days: pageDays).frame(height: 168)
            }.padding(12)
        }
    }
    private var details: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("每日用量")).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.top, 12)
                historyList
            }
        }
    }
    private var historyList: some View {
            List {
                    ForEach(pageDays.reversed()) { day in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(day.date) }, set: { value in
                            if value { expanded.insert(day.date) } else { expanded.remove(day.date) }
                        })) {
                                ForEach(day.segments) { segment in
                                    let key = day.date.description + ":" + segment.id
                                    DisclosureGroup(isExpanded: Binding(get: { expandedWindows.contains(key) }, set: { value in
                                        if value { expandedWindows.insert(key) } else { expandedWindows.remove(key) }
                                    })) {
                                        modelRows(segment.records).padding(.vertical, 12).padding(.leading, 12)
                                    } label: {
                                        HStack {
                                            Circle().fill(Color(nsColor: TokenUsageChartView.color(segment.colorIndex))).frame(width: 8, height: 8)
                                            Text(TokenUsageFormat.range(segment.start, segment.reset,
                                                relativeTo: day.date, calendar: analysis.calendar)).font(.subheadline)
                                            Spacer()
                                            Text(TokenUsageFormat.compact(segment.total) + " Token").font(.system(size: 13)).monospacedDigit()
                                            Text(TokenUsageFormat.tps(TokenUsageSpeed(segment.records).value) + " tps")
                                                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
                                                .help(TokenUsageHints.tps)
                                        }
                                    }.padding(.vertical, 8)
                                }
                                if !day.hasRecords { Text("—").foregroundStyle(.secondary).help(L10n.text("没有本机记录")) }
                        } label: {
                            HStack {
                                if analysis.calendar.isDate(day.date, inSameDayAs: analysis.now) {
                                    Text(L10n.text("今天")).fontWeight(.medium)
                                } else { Text(day.date, format: .dateTime.month(.abbreviated).day()).fontWeight(.medium) }
                                Spacer()
                                Text(day.hasRecords ? TokenUsageFormat.compact(day.total) + " Token" : "—")
                                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                Text(TokenUsageFormat.tps(TokenUsageSpeed(day.records).value) + " tps")
                                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
                                    .help(TokenUsageHints.tps)
                            }
                        }.padding(.vertical, 10)
                    }
                    if analysis.unknownTimeTokens > 0 {
                        DisclosureGroup {
                            modelRows(analysis.snapshot.records.filter { $0.timestamp == nil }).padding(10)
                        } label: {
                            HStack {
                                Text(L10n.text("时间未知"))
                                Spacer()
                                Text(TokenUsageFormat.compact(analysis.unknownTimeTokens) + " Token").monospacedDigit()
                            }.help(L10n.format("时间未知：%@ Token", TokenUsageFormat.compact(analysis.unknownTimeTokens)))
                        }.padding(.vertical, 10)
                    }
            }.listStyle(.inset).scrollContentBackground(.hidden)
    }
    private func metric(_ title: String, _ value: String, change: Double? = nil, hint: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text(title)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.85)
                    if let change { Text(TokenUsageFormat.change(change)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, minHeight: 68, alignment: .leading).padding(12)
        }.frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110).help(hint)
    }
    private func move(_ value: Int) {
        pageEnd = min(analysis.calendar.startOfDay(for: analysis.now), analysis.calendar.date(byAdding: .day, value: value, to: pageEnd)!)
    }
    private func modelRows(_ records: [TokenUsageRecord]) -> some View {
        let models = Dictionary(grouping: records.filter { $0.counts != nil }) { $0.model ?? L10n.text("模型未知") }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("模型")).frame(maxWidth: .infinity, alignment: .leading)
                Text("Token").frame(width: 100, alignment: .trailing)
                Text("tps").frame(width: 88, alignment: .trailing).help(TokenUsageHints.tps)
                Text(L10n.text("API 等值")).frame(width: 86, alignment: .trailing)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(models.keys.sorted(), id: \.self) { model in
                let entries = models[model]!
                let counts = entries.compactMap(\.counts).reduce(.zero, +)
                let covered = entries.allSatisfy { $0.cost != nil }
                let cost = covered ? entries.compactMap(\.cost).reduce(0, +) : nil
                HStack {
                    Text(model).frame(maxWidth: .infinity, alignment: .leading)
                    Text(TokenUsageFormat.compact(counts.total)).frame(width: 100, alignment: .trailing)
                        .help(L10n.format("输入 %@ · 缓存 %@\n输出 %@ · 推理 %@",
                            counts.hasCompleteBreakdown ? TokenUsageFormat.compact(counts.input) : "—",
                            counts.hasCompleteBreakdown ? TokenUsageFormat.compact(counts.cachedInput) : "—",
                            counts.hasCompleteBreakdown ? TokenUsageFormat.compact(counts.output) : "—",
                            counts.hasCompleteBreakdown ? TokenUsageFormat.compact(counts.reasoningOutput) : "—"))
                    Text(TokenUsageFormat.tps(TokenUsageSpeed(entries).value)).frame(width: 88, alignment: .trailing)
                        .help(TokenUsageHints.tps)
                    Text(cost.map { TokenUsageFormat.dollars($0) } ?? "—")
                        .help(cost == nil ? L10n.text("未完整定价") : "")
                        .frame(width: 86, alignment: .trailing)
                }.monospacedDigit()
            }
        }.font(.system(size: 12)).textSelection(.enabled)
    }
}
