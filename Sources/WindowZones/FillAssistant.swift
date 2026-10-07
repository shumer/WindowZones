import AppKit
import ScreenCaptureKit
import Geometry

@MainActor final class FillList: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor final class FillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var navigate: ((UInt16) -> Bool)?
    var dismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if navigate?(event.keyCode) != true { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

@MainActor final class FillCard: NSButton {
    override var isFlipped: Bool { false }
    var preview: NSImage? { didSet { needsDisplay = true } }
    var appIcon: NSImage?
    var appName = ""
    var windowName = ""
    var minimized = false
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let selected = window?.firstResponder === self || hovered || isHighlighted
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 16, yRadius: 16)
        NSColor.windowBackgroundColor.withAlphaComponent(selected ? 0.98 : 0.88).setFill()
        shape.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.35)).setStroke()
        shape.lineWidth = selected ? 3 : 1
        shape.stroke()
        let content = NSRect(x: 15, y: 49, width: bounds.width - 30, height: bounds.height - 65)
        if let image = preview ?? appIcon {
            let scale = min(content.width / max(1, image.size.width), content.height / max(1, image.size.height), preview == nil ? 1 : 10)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: content.midX - size.width / 2, y: content.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5, respectFlipped: true, hints: nil)
        }
        appIcon?.draw(in: NSRect(x: 16, y: 17, width: 24, height: 24), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let label = minimized ? "\(appName) · Свёрнуто" : appName
        (label as NSString).draw(in: NSRect(x: 48, y: 28, width: bounds.width - 64, height: 17), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        (windowName as NSString).draw(in: NSRect(x: 48, y: 11, width: bounds.width - 64, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
    }
}

@MainActor final class FillBackdrop: NSVisualEffectView {
    var dismiss: (() -> Void)?
    override func mouseDown(with event: NSEvent) { dismiss?() }
}

@MainActor final class FillAssistant: NSObject, NSWindowDelegate {
    let panel: FillPanel
    private let zones: [CGRect]
    private let area: CGRect
    private let list = FillList()
    private let scroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let root = FillBackdrop()
    private let skipButton = NSButton(title: "Пропустить", target: nil, action: nil)
    private let previewsButton = NSButton(title: "Разрешить миниатюры", target: nil, action: nil)
    private var occupied: Set<Int>
    private var session: FillSession
    private var candidates: [FillCandidate] = []
    private var buttons: [UUID: FillCard] = [:]
    private var imageTask: Task<Void, Never>?
    private(set) var isBusy = false
    private var failureMessage: String?
    private var focusedID: UUID?
    private var columns = 2
    var onChoose: ((FillCandidate, Int) -> Void)?
    var onClose: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRefresh: (() -> Void)?

    init(zones: [CGRect], area: CGRect, occupied: Set<Int>) {
        self.zones = zones
        self.area = area
        self.occupied = occupied
        session = FillSession(count: zones.count, occupied: occupied)
        panel = FillPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = "Выбор окна для свободной зоны"
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.dialog)
        panel.setAccessibilityLabel("Выбор окна для свободной зоны")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.delegate = self
        panel.navigate = { [weak self] in self?.navigate($0) ?? false }
        panel.dismiss = { [weak self] in self?.onClose?() }
        root.dismiss = { [weak self] in self?.onClose?() }
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 22
        root.layer?.masksToBounds = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        list.orientation = .vertical
        list.alignment = .centerX
        list.spacing = 12
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        root.addSubview(scroll)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        root.addSubview(status)
        skipButton.bezelStyle = .inline
        skipButton.target = self
        skipButton.action = #selector(skip)
        root.addSubview(skipButton)
        previewsButton.bezelStyle = .inline
        previewsButton.target = self
        previewsButton.action = #selector(allowPreviews)
        root.addSubview(previewsButton)
        panel.contentView = root
        positionInZone()
    }

    var isComplete: Bool { session.selected == nil }

    private func positionInZone() {
        guard let index = session.selected else { return }
        let frame = zones[index].intersection(area).insetBy(dx: 6, dy: 6)
        panel.setFrame(frame, display: true)
        root.frame = CGRect(origin: .zero, size: frame.size)
        let width = max(120, min(1080, frame.width - 40))
        scroll.frame = CGRect(x: (frame.width - width) / 2, y: 60, width: width, height: max(80, frame.height - 86))
        status.frame = CGRect(x: 24, y: 16, width: max(80, frame.width - 156), height: 30)
        skipButton.frame = CGRect(x: max(0, frame.width - 116), y: 20, width: 96, height: 24)
        previewsButton.frame = CGRect(x: 24, y: max(60, frame.height - 30), width: 180, height: 22)
        previewsButton.isHidden = CGPreflightScreenCaptureAccess()
        columns = max(1, min(4, Int(width / 240)))
        updateStatus()
    }

    func show() {
        positionInZone()
        update(candidates, force: true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        imageTask?.cancel()
        imageTask = nil
        panel.orderOut(nil)
        candidates = []
        buttons = [:]
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        skipButton.isEnabled = !busy
        buttons.values.forEach { $0.isEnabled = !busy }
    }

    func reconcile(occupied: Set<Int>) {
        guard self.occupied != occupied else { return }
        self.occupied = occupied
        let previous = session.selected
        session.reconcile(occupied: occupied)
        if isComplete { onClose?(); return }
        if previous != session.selected { positionInZone(); update(candidates, force: true) }
    }

    func update(_ candidates: [FillCandidate], force: Bool = false) {
        let unchanged = self.candidates.count == candidates.count && zip(self.candidates, candidates).allSatisfy {
            $0.id == $1.id && $0.title == $1.title && $0.snapshot.frame == $1.snapshot.frame && $0.minimized == $1.minimized
        }
        guard force || !unchanged else { return }
        let focused = buttons.first { $0.value === panel.firstResponder }?.key ?? focusedID
        imageTask?.cancel()
        self.candidates = candidates
        buttons = [:]
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        let width = max(100, (scroll.frame.width - CGFloat(columns - 1) * 12 - 16) / CGFloat(columns))
        let cardHeight = min(230, max(150, width * 0.67))
        let rows = max(1, Int(ceil(Double(candidates.count) / Double(columns))))
        let availableHeight = max(80, root.bounds.height - 86)
        let contentHeight = min(availableHeight, CGFloat(rows) * (cardHeight + 12) - 12)
        scroll.setFrameSize(NSSize(width: scroll.frame.width, height: contentHeight))
        scroll.setFrameOrigin(NSPoint(x: scroll.frame.minX, y: 60 + (availableHeight - contentHeight) / 2))
        for start in stride(from: 0, to: candidates.count, by: columns) {
            let row = NSStackView()
            row.spacing = 12
            for candidate in candidates[start..<min(start + columns, candidates.count)] {
                let app = NSRunningApplication(processIdentifier: candidate.snapshot.pid)
                let button = FillCard(title: "", target: self, action: #selector(choose(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(candidate.id.uuidString)
                button.appIcon = app?.icon
                button.appName = app?.localizedName ?? "Приложение"
                button.windowName = candidate.title
                button.minimized = candidate.minimized
                button.isBordered = false
                button.setAccessibilityLabel("\(button.appName), \(candidate.title)\(candidate.minimized ? ", свёрнуто" : "")")
                button.widthAnchor.constraint(equalToConstant: width).isActive = true
                button.heightAnchor.constraint(equalToConstant: cardHeight).isActive = true
                buttons[candidate.id] = button
                row.addArrangedSubview(button)
            }
            list.addArrangedSubview(row)
        }
        if let focused, let button = buttons[focused] { panel.makeFirstResponder(button) }
        updateStatus()
        loadPreviews()
    }

    func placed(_ id: UUID, blocked: Set<Int>) {
        candidates.removeAll { $0.id == id }
        occupied.formUnion(blocked)
        session.reconcile(occupied: occupied)
        if isComplete { onClose?(); return }
        positionInZone()
        update(candidates, force: true)
    }

    func failed() {
        setBusy(false)
        failureMessage = "Окно недоступно или не помещается. Выбери другое. Отмена размещения доступна в меню."
        updateStatus()
    }

    private func updateStatus() {
        status.stringValue = failureMessage ?? (candidates.isEmpty ? "Нет доступных окон. Список обновляется автоматически." : "Выбери окно · Зона \((session.selected ?? 0) + 1) · Esc для выхода")
    }

    private func navigate(_ key: UInt16) -> Bool {
        guard !isBusy, !candidates.isEmpty else { return false }
        let current = buttons.first { $0.value === panel.firstResponder }?.key ?? focusedID
        let index = candidates.firstIndex { $0.id == current } ?? 0
        if key == 36 || key == 49 {
            if let button = buttons[candidates[index].id] { choose(button) }
            return true
        }
        let delta: Int
        switch key {
        case 123: delta = -1
        case 124: delta = 1
        case 125: delta = columns
        case 126: delta = -columns
        default: return false
        }
        let next = min(candidates.count - 1, max(0, index + delta))
        focusedID = candidates[next].id
        if let button = buttons[candidates[next].id] {
            panel.makeFirstResponder(button)
            button.scrollToVisible(button.bounds)
            buttons.values.forEach { $0.needsDisplay = true }
        }
        return true
    }

    @objc private func choose(_ sender: NSButton) {
        guard let index = session.selected, let candidate = candidates.first(where: { $0.id.uuidString == sender.identifier?.rawValue }) else { return }
        failureMessage = nil
        setBusy(true)
        onChoose?(candidate, index)
    }
    @objc private func skip() {
        session.advance()
        if isComplete { onClose?() } else { positionInZone(); update(candidates, force: true) }
    }
    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func allowPreviews() {
        _ = CGRequestScreenCaptureAccess()
        if CGPreflightScreenCaptureAccess() { previewsButton.isHidden = true; loadPreviews() }
        else { status.stringValue = "Разреши запись экрана для миниатюр. Пока доступны иконки." }
    }

    private func loadPreviews() {
        guard CGPreflightScreenCaptureAccess() else { return }
        let current = candidates
        imageTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true), !Task.isCancelled else { return }
            for candidate in current where !candidate.minimized {
                guard !Task.isCancelled else { return }
                let matches = content.windows.filter {
                    $0.owningApplication?.processID == candidate.snapshot.pid && GeometryEngine.close($0.frame, candidate.snapshot.frame)
                }
                guard matches.count == 1, let window = matches.first else { continue }
                let configuration = SCStreamConfiguration()
                configuration.width = 480
                configuration.height = max(1, Int(480 * window.frame.height / max(1, window.frame.width)))
                configuration.showsCursor = false
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration), !Task.isCancelled else { continue }
                self?.buttons[candidate.id]?.preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }
}
