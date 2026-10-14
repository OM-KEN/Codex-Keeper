import AppKit

@MainActor private final class MenuBarContentButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        guard let superview else { return }
        frame = NSRect(x: 10, y: -3, width: max(0, superview.bounds.width - 20), height: superview.bounds.height)
    }
}

@MainActor final class MenuBarQuotaView: NSView {
    private var quota: MenuQuota?
    private let contentButton = MenuBarContentButton()
    private var menuHighlighted = false

    func attach(to button: NSButton) {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        button.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: button.leadingAnchor),
            trailingAnchor.constraint(equalTo: button.trailingAnchor),
            bottomAnchor.constraint(equalTo: button.bottomAnchor),
            heightAnchor.constraint(equalToConstant: 3)
        ])
        contentButton.isBordered = false
        contentButton.imagePosition = .imageLeft
        contentButton.imageScaling = .scaleNone
        contentButton.setAccessibilityElement(false)
        contentButton.autoresizingMask = [.width, .height]
        button.addSubview(contentButton)
        contentButton.resize(withOldSuperviewSize: .zero)
    }

    func update(_ quota: MenuQuota?, title: String, image: NSImage?) {
        self.quota = quota
        isHidden = quota == nil
        contentButton.isHidden = quota == nil
        needsDisplay = true
        guard let button = superview as? NSButton else { return }
        button.title = title
        button.image = image
        button.image?.isTemplate = true
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: button.font ?? NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: quota == nil ? NSColor.labelColor : NSColor.clear
        ])
        if quota != nil, let cell = button.cell as? NSButtonCell {
            button.image = NSImage(size: cell.imageRect(forBounds: button.bounds).size)
            button.image?.isTemplate = true
        }
        contentButton.font = button.font
        contentButton.appearance = button.effectiveAppearance
        contentButton.title = title
        contentButton.image = image
        contentButton.image?.isTemplate = true
        setHighlighted(menuHighlighted)
    }

    func setHighlighted(_ highlighted: Bool) {
        menuHighlighted = highlighted
        let appearance = superview?.effectiveAppearance ?? effectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = highlighted || dark ? NSColor.white : NSColor.black
        contentButton.cell?.backgroundStyle = highlighted || dark ? .emphasized : .normal
        contentButton.contentTintColor = color
        contentButton.attributedTitle = NSAttributedString(string: contentButton.title, attributes: [
            .font: contentButton.font ?? NSFont.menuBarFont(ofSize: 0), .baselineOffset: 1, .foregroundColor: color
        ])
        if quota == nil, let button = superview as? NSButton {
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: button.font ?? NSFont.menuBarFont(ofSize: 0), .foregroundColor: color
            ])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setHighlighted(menuHighlighted)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let quota, let button = superview as? NSButton, let cell = button.cell as? NSButtonCell else { return }
        let content = cell.imageRect(forBounds: button.bounds).union(cell.titleRect(forBounds: button.bounds))
        let track = NSRect(x: content.minX, y: bounds.minY, width: content.width, height: bounds.height)
        guard track.width > 0 else { return }
        let radius = bounds.height / 2
        let color: NSColor
        switch quota.statusLevel {
        case .normal: color = .controlAccentColor
        case .critical: color = .systemRed
        }
        let trackColor = quota.barRemaining > 0 ? NSColor.labelColor.withAlphaComponent(0.18) : color.withAlphaComponent(0.35)
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        guard quota.barRemaining > 0 else { return }
        color.setFill()
        let width = min(track.width, max(track.height, track.width * quota.barRemaining / 100))
        let fill = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
