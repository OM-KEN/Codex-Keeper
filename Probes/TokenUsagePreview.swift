import Foundation
import AppKit
import SwiftUI

@MainActor private final class TokenPreviewCanvas: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: bounds).fill()
    }
}

// Fixture-only preview. Never initializes AppState, reads user history, or starts the scheduler.
@main struct TokenUsagePreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let calendar = Calendar.current, now = Date()
        let today = calendar.startOfDay(for: now)
        var records: [TokenUsageRecord] = []
        for day in -13...0 {
            for hour in [7, 14, 22] {
                let start = calendar.date(byAdding: .day, value: day, to: today)!.addingTimeInterval(Double(hour * 3600))
                for index in 0..<3 {
                    let at = start.addingTimeInterval(Double(index * 3600 + 30))
                    guard at <= now else { continue }
                    let input = 1_200_000 + (day + 13) * 160_000 + index * 90_000
                    let counts = TokenUsageCounts(input: input, cachedInput: input * 9 / 10, cacheWriteInput: 0,
                        output: 28_000, reasoningOutput: 20_000, total: input + 28_000)
                    let five = QuotaWindow(usedPercent: Double(5 + index * 30), windowMinutes: 300,
                        resetsAt: start.addingTimeInterval(18000))
                    let weekly = QuotaWindow(usedPercent: Double((day + 14) * 5 + index), windowMinutes: 10080,
                        resetsAt: today.addingTimeInterval(86400))
                    records.append(TokenUsageRecord(id: "\(day)-\(hour)-\(index)", threadID: "preview", accountID: "preview",
                        timestamp: at, model: "gpt-6.1-sol", counts: counts,
                        requestInput: input, serviceTier: "standard", samplingSeconds: Double(650 + index * 100),
                        fiveHour: five, weekly: weekly, planType: "plus"))
                }
            }
        }
        let snapshot = TokenUsageHistorySnapshot(accountID: "preview", records: records, currentPlan: "plus", capturedAt: now, isLoaded: true)
        let analysis = TokenUsageHistoryAnalysis(snapshot: snapshot, now: now)
        precondition(analysis.fiveHourEstimate.value != nil && analysis.weeklyEstimate.value != nil,
            "Preview fixtures must exercise the UI with both allowance estimates available")
        let outputIndex = CommandLine.arguments.firstIndex(of: "--output")
        let folder = URL(fileURLWithPath: outputIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? ".build/token-preview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func capture(_ view: NSView, _ size: NSSize, _ name: String, dark: Bool,
                     hover: Bool = false, expandModels: Bool = false, hoverTPS: Bool = false) throws {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance
            let canvas = TokenPreviewCanvas(frame: NSRect(origin: .zero, size: size))
            canvas.wantsLayer = true
            appearance.performAsCurrentDrawingAppearance { canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            canvas.addSubview(view); window.contentView = canvas
            view.frame = NSRect(origin: .zero, size: size); view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if expandModels {
                func outline(in view: NSView) -> NSOutlineView? {
                    if let outline = view as? NSOutlineView { return outline }
                    return view.subviews.lazy.compactMap { outline(in: $0) }.first
                }
                if let list = outline(in: view), list.numberOfRows > 1 {
                    list.expandItem(list.item(atRow: 1))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1)); view.layoutSubtreeIfNeeded()
                }
            }
            if hover, let menu = view as? TokenUsageMenuView {
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFrontRegardless()
                menu.display()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let point = NSPoint(x: menu.chart.plotRect.minX + menu.chart.plotRect.width * 6.5 / 7,
                    y: menu.chart.plotRect.minY + 4)
                if hoverTPS { menu.hoverMetric(at: NSPoint(x: menu.metricTPSFrame.midX, y: menu.metricTPSFrame.midY)) }
                else { menu.chart.hover(at: point); menu.chart.displayIfNeeded() }
            }
            let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            let target = folder.appendingPathComponent(dark ? "dark" : "light")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(name + ".png"))
            if hover, let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }), let content = panel.contentView {
                let tooltip = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: tooltip)
                try tooltip.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(
                    hoverTPS ? "tps-tooltip.png" : "tooltip.png"))
                (view as? TokenUsageMenuView)?.menuDidClose()
            }
            window.orderOut(nil)
        }
        let menuView = TokenUsageMenuView(analysis: analysis)
        let history = TokenUsageHistoryObserver(home: folder.appendingPathComponent("unused-home"), support: folder, initial: analysis)
        let host = NSHostingView(rootView: TokenUsageHistoryView(history: history))
        for dark in [false, true] {
            try capture(menuView, menuView.frame.size, "menu", dark: dark)
            try capture(menuView, menuView.frame.size, "menu-hover", dark: dark, hover: true)
            try capture(menuView, menuView.frame.size, "menu-tps-hover", dark: dark, hover: true, hoverTPS: true)
            try capture(host, NSSize(width: 900, height: 800), "history", dark: dark)
            try capture(host, NSSize(width: 900, height: 800), "history-details", dark: dark, expandModels: true)
            try capture(host, NSSize(width: 860, height: 698), "history-compact", dark: dark)
        }
        if CommandLine.arguments.contains("--live") {
            NSApp.setActivationPolicy(.accessory)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Codex Keeper · " + L10n.text("Token 用量历史")
            window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
            let menu = NSMenu(); let item = NSMenuItem(); item.view = menuView; menu.addItem(item)
            menuView.openHistory = { menu.cancelTracking(); window.makeKeyAndOrderFront(nil) }
            NSApp.activate(ignoringOtherApps: true)
            if CommandLine.arguments.contains("--menu") { menu.popUp(positioning: nil, at: NSPoint(x: 100, y: 600), in: nil) }
            NSApp.run()
        }
        print("Fixture previews: \(folder.path)")
    }
}
