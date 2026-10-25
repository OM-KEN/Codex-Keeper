import AppKit

@MainActor func checkNativeMenuQuotaUpdates(_ check: (Bool, String) -> Void, root: URL) throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func labels(_ view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
    }
    func capture(_ view: NSView, _ name: String) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: root.appendingPathComponent(name + ".png")); return png
    }
    let old = MenuQuota(name: "5小时", remaining: 89, detail: "今天 18:00")
    let new = MenuQuota(name: "5小时", remaining: 88, detail: "今天 18:00")
    let menu = MenuQuotaHostView(quotas: [old], accountID: "ui-fixture")
    check(labels(menu).contains("89%"), "the native menu initially displays its actual quota")
    let nameLabel = menu.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }
        .first { $0.stringValue == L10n.text("5小时") }
    check(nameLabel.map { ($0.cell?.cellSize.width ?? 0) <= $0.bounds.width } == true,
        "the localized quota name fits its native text cell without truncation")
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 304, height: menu.frame.height),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = menu
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    let before = try capture(menu, "menu-89")
    menu.menuWillOpen()
    let meter = menu.subviews.first?.subviews.first { !($0 is NSTextField) }
    let previousWidth = meter?.subviews.first?.frame.width
    let timer = Timer(timeInterval: 0.08, repeats: false) { _ in
        MainActor.assumeIsolated { menu.update(quotas: [new], accountID: "ui-fixture") }
    }
    RunLoop.main.add(timer, forMode: .common)
    let deadline = Date().addingTimeInterval(0.7)
    while Date() < deadline { _ = RunLoop.main.run(mode: .eventTracking, before: deadline) }
    check(labels(menu).contains("88%") && !labels(menu).contains("89%"),
        "89% becomes 88% in event-tracking mode without closing or reopening the menu")
    let after = try capture(menu, "menu-88")
    check(before != after, "the native menu renders changed pixels before menu close")
    check(meter.flatMap { view in view.subviews.first.map { abs($0.frame.width - view.bounds.width * 0.88) < 0.1 && $0.frame.width != previousWidth } } == true,
        "the native quota fill also reaches 88% while the menu remains visible")
    menu.menuDidClose()
    menu.update(quotas: [MenuQuota(name: "5小时", remaining: 0, detail: "—")], accountID: "ui-fixture")
    check(labels(menu).contains("0%"), "a quota of zero is shown immediately rather than a retained positive label")
    menu.update(quotas: [], accountID: nil)
    check(labels(menu).isEmpty, "account and quota removal clears the native rows")
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
    let bar = MenuBarQuotaView(); bar.attach(to: button)
    button.layoutSubtreeIfNeeded()
    bar.update(old, title: "18:00", image: nil)
    let outsideBefore = try capture(button, "outside-89")
    bar.update(new, title: "18:00", image: nil)
    let outsideAfter = try capture(button, "outside-88")
    check(outsideBefore != outsideAfter, "the outside quota rail repaints from 89% to 88% without opening a menu")
}
