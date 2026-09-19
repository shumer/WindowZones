import AppKit
import Geometry

struct Display: Sendable, Equatable {
    let id: UInt32
    let frame: CGRect
    let visible: CGRect
    let scale: CGFloat
    let primaryTop: CGFloat

    @MainActor static func connected() -> [Display] {
        guard let first = NSScreen.screens.first else { return [] }
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(id: id.uint32Value, frame: screen.frame, visible: screen.visibleFrame,
                           scale: screen.backingScaleFactor, primaryTop: first.frame.maxY)
        }
    }
    var zones: [CGRect] { (try? GeometryEngine.zones(in: visible, scale: scale)) ?? [] }
    func ax(_ rect: CGRect) -> CGRect { GeometryEngine.flip(rect, primaryTop: primaryTop) }
    var axVisible: CGRect { ax(visible) }

    private var geometry: DisplayGeometry {
        DisplayGeometry(id: id, frame: frame, visible: visible, scale: scale, primaryTop: primaryTop)
    }

    static func compatible(_ original: [Display], _ current: [Display]) -> Bool {
        DisplayConfiguration.compatible(original.map(\.geometry), current.map(\.geometry))
    }
}

@MainActor final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class ZoneDrawing: NSView {
    var zones: [CGRect] = []
    var selected: Int?
    var showsLabels = true
    override func draw(_ dirtyRect: NSRect) {
        for (index, zone) in zones.enumerated() {
            let active = selected == index
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let accent = NSColor.controlAccentColor
            (active ? accent.withAlphaComponent(0.16) : NSColor.windowBackgroundColor.withAlphaComponent(0.04)).setFill()
            let path = NSBezierPath(roundedRect: zone.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { path.fill() }
            (active ? accent : NSColor.labelColor.withAlphaComponent((contrast || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) ? 1 : 0.35)).setStroke()
            path.lineWidth = active ? 3 : (contrast ? 2 : 1)
            path.stroke()
            guard showsLabels else { continue }
            let label = "\(index + 1)\(active ? " ✓" : "")" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            let size = label.size(withAttributes: attributes)
            let badge = CGRect(x: zone.midX - (size.width + 24) / 2, y: zone.maxY - 56,
                               width: size.width + 24, height: 36)
            NSColor.windowBackgroundColor.setFill()
            let badgePath = NSBezierPath(roundedRect: badge, xRadius: 10, yRadius: 10)
            badgePath.fill()
            (active ? accent : NSColor.separatorColor).setStroke()
            badgePath.lineWidth = active ? 2 : 1
            badgePath.stroke()
            label.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

@MainActor final class Overlay {
    private var panel: OverlayPanel?
    private var lastDisplay: Display?
    private var lastSelected: Int?
    private var lastZones: [CGRect] = []
    private var lastShowsLabels = true
    func show(display: Display, selected: Int?, zones: [CGRect]? = nil, showsLabels: Bool = true) {
        let resolved = zones ?? display.zones
        if panel?.isVisible == true, lastDisplay == display, lastSelected == selected, lastZones == resolved, lastShowsLabels == showsLabels { return }
        lastDisplay = display
        lastSelected = selected
        lastZones = resolved
        lastShowsLabels = showsLabels
        let current: OverlayPanel
        if let panel { current = panel } else {
            current = OverlayPanel(contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            current.isOpaque = false
            current.backgroundColor = .clear
            current.ignoresMouseEvents = true
            current.hasShadow = false
            current.level = .floating
            current.collectionBehavior = [.canJoinAllSpaces, .stationary]
            current.contentView = ZoneDrawing(frame: CGRect(origin: .zero, size: display.frame.size))
            panel = current
        }
        if current.frame != display.frame { current.setFrame(display.frame, display: false) }
        if let drawing = current.contentView as? ZoneDrawing {
            drawing.zones = resolved.map { $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
            drawing.selected = selected
            drawing.showsLabels = showsLabels
            drawing.needsDisplay = true
        }
        if !current.isVisible { current.orderFrontRegardless() }
    }
    func hide() { panel?.orderOut(nil) }
}

@MainActor final class PickerWindow: NSWindow {
    var choose: ((Int) -> Void)?
    var cancel: (() -> Void)?
    var moveSelection: ((Int) -> Void)?
    var selected = 1
    var zoneCount = 3
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let content = contentView as? ZonePickerContent {
            if event.keyCode == 48 {
                content.advanceFocus(backwards: event.modifierFlags.contains(.shift))
                return
            }
            if [36, 76, 49].contains(event.keyCode),
               let button = firstResponder as? PickerCancelButton, button.isEnabled {
                button.performClick(nil)
                return
            }
        }
        super.sendEvent(event)
    }
    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53: cancel?()
        case 36, 76:
            if let button = firstResponder as? ZoneChoiceButton, button.isEnabled { button.performClick(nil) }
            else if firstResponder is NSControl { super.keyDown(with: event) }
            else { choose?(selected) }
        case 123, 126: moveSelection?(-1)
        case 124, 125: moveSelection?(1)
        default:
            if let number = Int(event.charactersIgnoringModifiers ?? ""), number >= 1, number <= min(zoneCount, 9) { choose?(number - 1) }
            else { super.keyDown(with: event) }
        }
    }
    override func cancelOperation(_ sender: Any?) { cancel?() }
}

@MainActor func verticalStack() -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    return stack
}

@MainActor final class ZoneChoiceButton: NSButton {
    var preview: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override var state: NSControl.StateValue {
        didSet { updateSelectionBorder() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionBorder()
    }
    private func updateSelectionBorder() {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = state == .on ? 2 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76, 49: if isEnabled { performClick(nil) }
        case 123, 124, 125, 126: window?.keyDown(with: event)
        default: super.keyDown(with: event)
        }
    }
    override func mouseEntered(with event: NSEvent) { if isEnabled { preview?() } }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result && isEnabled { preview?() }
        return result
    }
}

@MainActor private final class LayoutCard: NSView {
    let layoutID: UUID
    let label: NSTextField
    var buttons: [ZoneChoiceButton] = []
    private let definition: Layout
    private var normalizedFrames: [CGRect] = []
    private(set) var geometryAvailable = false
    private var lastArea: CGRect?
    private var lastScale: CGFloat?

    init(layout: Layout, owner: ZonePickerContent) {
        layoutID = layout.id
        label = NSTextField(labelWithString: layout.name)
        definition = layout
        func names(_ node: LayoutNode) -> [String] {
            switch node {
            case let .zone(_, name): return [name]
            case let .split(_, _, first, second): return names(first) + names(second)
            }
        }
        let zoneNames = names(layout.root)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        for (index, zoneName) in zoneNames.enumerated() {
            let button = ZoneChoiceButton(title: "\(index + 1)", target: owner, action: #selector(ZonePickerContent.chosen(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(layout.id.uuidString)
            button.tag = index
            button.bezelStyle = .regularSquare
            button.setButtonType(.toggle)
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.setAccessibilityLabel("\(layout.name), зона \(index + 1), \(zoneName)")
            button.toolTip = "\(layout.name): \(zoneName)"
            button.preview = { [weak owner] in owner?.preview?(layout.id, index) }
            buttons.append(button)
            addSubview(button)
        }
        updateDisplay(area: CGRect(x: 0, y: 0, width: 1600, height: 1000), scale: 2)
    }
    required init?(coder: NSCoder) { nil }
    func updateDisplay(area: CGRect, scale: CGFloat) {
        guard lastArea != area || lastScale != scale else { return }
        lastArea = area
        lastScale = scale
        if let zones = try? LayoutGeometry.zones(for: definition, in: area, scale: scale) {
            normalizedFrames = zones.map {
                CGRect(x: ($0.frame.minX - area.minX) / area.width,
                       y: ($0.frame.minY - area.minY) / area.height,
                       width: $0.frame.width / area.width, height: $0.frame.height / area.height)
            }
            geometryAvailable = true
        } else {
            // Disabled cards keep a schematic shape instead of losing their leaf controls.
            normalizedFrames = []
            func schematic(_ node: LayoutNode, in frame: CGRect) {
                switch node {
                case .zone: normalizedFrames.append(frame)
                case let .split(axis, ratio, first, second):
                    let fraction = ratio.isFinite ? min(0.9, max(0.1, ratio)) : 0.5
                    if axis == .vertical {
                        let cut = frame.width * fraction
                        schematic(first, in: CGRect(x: frame.minX, y: frame.minY, width: cut, height: frame.height))
                        schematic(second, in: CGRect(x: frame.minX + cut, y: frame.minY, width: frame.width - cut, height: frame.height))
                    } else {
                        let cut = frame.height * fraction
                        schematic(first, in: CGRect(x: frame.minX, y: frame.maxY - cut, width: frame.width, height: cut))
                        schematic(second, in: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - cut))
                    }
                }
            }
            schematic(definition.root, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            geometryAvailable = false
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        label.frame = CGRect(x: 2, y: bounds.height - 18, width: bounds.width - 4, height: 16)
        let height = max(0, bounds.height - 24)
        for (button, frame) in zip(buttons, normalizedFrames) {
            let scaled = CGRect(x: frame.minX * bounds.width, y: frame.minY * height,
                                width: frame.width * bounds.width, height: frame.height * height)
            button.frame = scaled.insetBy(dx: min(1.5, scaled.width * 0.15), dy: min(1.5, scaled.height * 0.15))
        }
    }
}

@MainActor private final class PickerCancelButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
}

@MainActor final class PickerDisplayPopup: NSPopUpButton {
    override var acceptsFirstResponder: Bool { isEnabled }
}

@MainActor final class ZonePickerContent: NSView {
    let displayPopup = PickerDisplayPopup()
    private let cancelButton = PickerCancelButton()
    let hint = NSTextField(labelWithString: "")
    private var cards: [LayoutCard] = []
    var choose: ((UUID, Int) -> Void)?
    var preview: ((UUID, Int) -> Void)?
    var cancel: (() -> Void)?

    init(applicationName: String, layouts: [Layout] = BuiltInLayouts.all) {
        super.init(frame: CGRect(x: 0, y: 0, width: 520, height: 420))
        let stack = verticalStack()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 10
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let title = NSTextField(labelWithString: "Разместить окно")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(title)
        let app = NSTextField(labelWithString: applicationName)
        app.textColor = .secondaryLabelColor
        app.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(app)
        displayPopup.setAccessibilityLabel("Целевой монитор")
        stack.addArrangedSubview(displayPopup)
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 12
        grid.distribution = .fillEqually
        for rowStart in stride(from: 0, to: layouts.count, by: 2) {
            let row = NSStackView()
            row.spacing = 16
            row.distribution = .fillEqually
            for layout in layouts[rowStart..<min(rowStart + 2, layouts.count)] {
                let card = LayoutCard(layout: layout, owner: self)
                cards.append(card)
                row.addArrangedSubview(card)
            }
            if row.arrangedSubviews.count == 1 { row.addArrangedSubview(NSView()) }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(grid)
        NSLayoutConstraint.activate([
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            grid.heightAnchor.constraint(greaterThanOrEqualToConstant: 210)
        ])
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        let footer = NSStackView()
        let help = NSTextField(labelWithString: "Tab · 1-9 · Стрелки и Enter")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        footer.addArrangedSubview(help)
        footer.addArrangedSubview(NSView())
        cancelButton.title = "Отмена"
        cancelButton.target = self
        cancelButton.action = #selector(cancelled)
        cancelButton.keyEquivalent = "\u{1b}"
        footer.addArrangedSubview(cancelButton)
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        let controls: [NSView] = [displayPopup] + cards.flatMap(\.buttons) + [cancelButton]
        for index in controls.indices { controls[index].nextKeyView = controls[(index + 1) % controls.count] }
    }
    required init?(coder: NSCoder) { nil }
    func updateDisplay(area: CGRect, scale: CGFloat) {
        for card in cards { card.updateDisplay(area: area, scale: scale) }
    }
    func advanceFocus(backwards: Bool) {
        guard let window else { return }
        let controls: [NSControl] = [displayPopup] + cards.flatMap(\.buttons) + [cancelButton]
        let available = controls.filter { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }
        guard !available.isEmpty else { return }
        let current = available.firstIndex { $0 === window.firstResponder }
        let index = current.map { ($0 + (backwards ? -1 : 1) + available.count) % available.count }
            ?? (backwards ? available.count - 1 : 0)
        window.makeFirstResponder(available[index])
    }
    func focusSelection(layoutID: UUID, index: Int) {
        guard let card = cards.first(where: { $0.layoutID == layoutID }),
              let button = card.buttons.first(where: { $0.tag == index }), button.isEnabled else { return }
        window?.makeFirstResponder(button)
    }
    func select(layoutID: UUID, index: Int, availableLayoutIDs: Set<UUID>) {
        for card in cards {
            let available = availableLayoutIDs.contains(card.layoutID) && card.geometryAvailable
            card.label.textColor = available ? .labelColor : .disabledControlTextColor
            card.toolTip = available ? nil : "Эта раскладка не помещается на выбранном мониторе"
            for button in card.buttons {
                let selected = card.layoutID == layoutID && button.tag == index
                button.state = selected ? .on : .off
                button.isEnabled = available
                button.title = selected ? "\(button.tag + 1) ✓" : "\(button.tag + 1)"
                button.contentTintColor = selected ? .controlAccentColor : .labelColor
                button.needsDisplay = true
            }
        }
    }
    @objc fileprivate func chosen(_ sender: NSButton) {
        guard let rawID = sender.identifier?.rawValue, let id = UUID(uuidString: rawID) else { return }
        choose?(id, sender.tag)
    }
    @objc private func cancelled() { cancel?() }
}
