import AppKit
import QuartzCore

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class SwitcherPanel: NSPanel {
    private let canvas = FlippedView()
    private let document = FlippedView()
    private let scroll = NSScrollView()
    private var pool: [TileView] = []
    private var tiles: [WindowID: TileView] = [:]
    private var badges: [String: String] = [:]
    private var selected: WindowID?
    private var layoutSignature = ""
    private(set) var columns = 1
    var onSelect: ((WindowID) -> Void)?
    var onAction: ((WindowAction, WindowID) -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        title = "AltTab2 Switcher"
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 20
        canvas.layer?.masksToBounds = true
        canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView = canvas
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = document
        canvas.addSubview(scroll)
    }

    func prepare(_ records: [WindowRecord], screen: NSScreen, thumbnail: (WindowID) -> CGImage?) {
        let ids = records.map(\.id)
        let bounds = screen.visibleFrame
        let tileWidth: CGFloat = min(270, max(180, (bounds.width - 88) / 2))
        let tileHeight: CGFloat = 204
        let gap: CGFloat = 12
        let maxWidth = min(1160, bounds.width - 64)
        columns = max(1, min(records.count, Int((maxWidth - 36 + gap) / (tileWidth + gap))))
        let rows = max(1, Int(ceil(Double(records.count) / Double(columns))))
        let width = CGFloat(columns) * (tileWidth + gap) - gap + 36
        let documentHeight = CGFloat(rows) * (tileHeight + gap) - gap + 8
        let height = min(documentHeight + 32, bounds.height * 0.78)
        let signature = "\(ids)-\(bounds)-\(columns)"
        if signature != layoutSignature {
            layoutSignature = signature
            setContentSize(NSSize(width: width, height: height))
            setFrameOrigin(NSPoint(x: bounds.midX - width / 2, y: bounds.midY - height / 2))
            canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
            scroll.frame = NSRect(x: 16, y: 16, width: width - 32, height: height - 32)
            document.frame = NSRect(x: 0, y: 0, width: width - 32, height: documentHeight)
        }
        while pool.count < records.count {
            let tile = TileView()
            tile.onSelect = { [weak self] id in self?.onSelect?(id) }
            tile.onAction = { [weak self] action, id in self?.onAction?(action, id) }
            document.addSubview(tile)
            pool.append(tile)
        }
        tiles.removeAll(keepingCapacity: true)
        for (index, tile) in pool.enumerated() {
            guard index < records.count else {
                tile.isHidden = true
                tile.clear()
                continue
            }
            let record = records[index]
            tile.isHidden = false
            tile.frame = NSRect(
                x: CGFloat(index % columns) * (tileWidth + gap) + 2,
                y: CGFloat(index / columns) * (tileHeight + gap) + 2, width: tileWidth, height: tileHeight)
            tile.bind(record, image: thumbnail(record.id))
            tile.setSelected(record.id == selected)
            tile.setBadge(record.appURL.flatMap { badges[$0.standardizedFileURL.path] })
            tiles[record.id] = tile
        }
        canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        canvas.layoutSubtreeIfNeeded()
    }

    func highlight(_ id: WindowID?) {
        guard selected != id else { return }
        if let selected { tiles[selected]?.setSelected(false) }
        selected = id
        if let id, let tile = tiles[id] {
            tile.setSelected(true)
            document.scrollToVisible(tile.frame.insetBy(dx: -2, dy: -2))
        }
    }

    func updateImage(_ id: WindowID, _ image: CGImage) { tiles[id]?.setImage(image) }
    func evictImage(_ id: WindowID) { tiles[id]?.removeImage() }

    func updateBadges(_ labels: [String: String]) {
        badges = labels
        for tile in tiles.values { tile.updateBadge(labels) }
    }

    func present(selected id: WindowID?) {
        // Refresh the highlight even if a tile was rebound since the previous gesture.
        selected = nil
        pool.forEach { $0.setSelected(false) }
        highlight(id)
        orderFrontRegardless()
    }

    func dismiss() { orderOut(nil) }

}

private final class TileView: NSView {
    override var isFlipped: Bool { true }
    private let preview = CALayer()
    private let fallback = NSImageView()
    private let icon = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private var buttons: [TrafficLightButton] = []
    private var tracking: NSTrackingArea?
    private var record: WindowRecord?
    private var isSelected = false
    private var hovered = false
    private var hasThumbnail = false
    var onSelect: ((WindowID) -> Void)?
    var onAction: ((WindowAction, WindowID) -> Void)?

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        preview.contentsGravity = .resizeAspect
        preview.masksToBounds = true
        preview.cornerRadius = 7
        preview.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(preview)
        for view in [fallback, icon, badge, title, subtitle] { addSubview(view) }
        fallback.imageScaling = .scaleProportionallyUpOrDown
        icon.imageScaling = .scaleProportionallyUpOrDown
        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.maximumNumberOfLines = 1
        badge.lineBreakMode = .byTruncatingTail
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 8
        badge.layer?.masksToBounds = true
        badge.isHidden = true
        badge.setAccessibilityElement(false)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let definitions: [(WindowAction, String, String, NSColor)] = [
            (.quit, "power", "Quit app", .systemGray),
            (.close, "xmark", "Close window", .systemRed),
            (.minimize, "minus", "Minimize or restore", .systemYellow),
            (.fullscreen, "arrow.up.left.and.arrow.down.right", "Enter or exit fullscreen", .systemGreen),
        ]
        for (action, symbol, label, color) in definitions {
            let button = TrafficLightButton(action: action, symbol: symbol, label: label, color: color)
            button.target = self
            button.action = #selector(self.action(_:))
            addSubview(button)
            buttons.append(button)
        }
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func bind(_ next: WindowRecord, image: CGImage?) {
        record = next
        let newTitle = next.title.isEmpty ? next.appName : next.title
        if title.stringValue != newTitle { title.stringValue = newTitle }
        var status = next.appName
        if next.minimized { status += " · Minimized" }
        if next.fullscreen { status += " · Fullscreen" }
        if next.windowless { status += " · No open windows" }
        if subtitle.stringValue != status { subtitle.stringValue = status }
        icon.image = next.icon
        fallback.image = next.icon
        preview.contents = image
        hasThumbnail = image != nil
        fallback.isHidden = hasThumbnail
        for button in buttons {
            button.isEnabled = button.windowAction == .quit ? next.bundleID != "com.apple.finder" : next.element != nil
        }
        layoutTile()
    }

    func updateBadge(_ labels: [String: String]) {
        setBadge(record?.appURL.flatMap { labels[$0.standardizedFileURL.path] })
    }

    func setBadge(_ label: String?) {
        badge.stringValue = label ?? ""
        badge.isHidden = label == nil
        badge.toolTip = label.map { "Dock badge: \($0)" }
        if let record {
            let status = label.map { ", Dock badge: \($0)" } ?? ""
            setAccessibilityLabel("\(record.appName), \(record.title)\(status)")
        }
        layoutTile()
    }

    func clear() {
        preview.contents = nil
        fallback.image = nil
        icon.image = nil
        setBadge(nil)
        record = nil
        hovered = false
        hasThumbnail = false
    }

    func setImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.contents = image
        CATransaction.commit()
        hasThumbnail = true
        fallback.isHidden = true
    }

    func removeImage() {
        preview.contents = nil
        hasThumbnail = false
        fallback.isHidden = false
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        buttons.forEach { $0.isHidden = !selected && !hovered }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        layer?.backgroundColor =
            (selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.13) : NSColor.labelColor.withAlphaComponent(0.045))
            .cgColor
        CATransaction.commit()
    }

    private func layoutTile() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = NSRect(x: 8, y: 8, width: bounds.width - 16, height: 148)
        CATransaction.commit()
        fallback.frame = NSRect(x: bounds.midX - 28, y: 52, width: 56, height: 56)
        icon.frame = NSRect(x: 12, y: 168, width: 22, height: 22)
        var textX: CGFloat = 42
        if !badge.isHidden {
            let badgeWidth = min(52, max(18, ceil(badge.intrinsicContentSize.width) + 8))
            badge.frame = NSRect(x: 38, y: 171, width: badgeWidth, height: 16)
            textX = badge.frame.maxX + 6
        }
        title.frame = NSRect(x: textX, y: 163, width: bounds.width - textX - 12, height: 17)
        subtitle.frame = NSRect(x: textX, y: 181, width: bounds.width - textX - 12, height: 14)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 12 + CGFloat(index) * 20, y: 12, width: 20, height: 20)
        }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        buttons.forEach { $0.isHidden = false }
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        buttons.forEach { $0.isHidden = !isSelected }
    }
    override func mouseDown(with event: NSEvent) { if let record { onSelect?(record.id) } }
    override func accessibilityPerformPress() -> Bool {
        if let record {
            onSelect?(record.id)
            return true
        }
        return false
    }

    @objc private func action(_ sender: TrafficLightButton) {
        guard let record else { return }
        onAction?(sender.windowAction, record.id)
    }
}

private final class TrafficLightButton: NSButton {
    let windowAction: WindowAction
    private let color: NSColor
    private var tracking: NSTrackingArea?

    init(action: WindowAction, symbol: String, label: String, color: NSColor) {
        windowAction = action
        self.color = color
        super.init(frame: .zero)
        clipsToBounds = true
        isBordered = false
        title = ""
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(.init(paletteColors: [.black.withAlphaComponent(0.76)]))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        toolTip = label
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) {
        needsDisplay = true
        if isEnabled { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        needsDisplay = true
        if isEnabled { NSCursor.arrow.set() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let hovered = window.map { visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        let pressed = cell?.isHighlighted == true
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        var fill = color
        if !isEnabled {
            fill = .disabledControlTextColor
        } else if pressed {
            fill = color.blended(withFraction: 0.25, of: .black) ?? color
        } else if hovered {
            fill = color.blended(withFraction: 0.25, of: .white) ?? color
        }
        fill.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        circle.lineWidth = 0.75
        circle.stroke()
        if isEnabled, hovered || pressed, let image {
            let rect = NSRect(
                x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                width: image.size.width, height: image.size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
