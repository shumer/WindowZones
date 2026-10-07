import AppKit
import ScreenCaptureKit
import Geometry

@MainActor final class FillList: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor final class FillPanel: NSPanel {
    var navigate: ((UInt16) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if navigate?(event.keyCode) != true { super.keyDown(with: event) }
    }
    var dismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

@MainActor final class FillAssistant: NSObject, NSWindowDelegate {
    let panel: FillPanel
    private let zones: [CGRect]
    private let area: CGRect
    private let map = NSView()
    private let list = FillList()
    private let status = NSTextField(wrappingLabelWithString: "Ищем доступные окна…")
    private let root = NSStackView()
    private var occupied: Set<Int>
    private var session: FillSession
    private var candidates: [FillCandidate] = []
    private var buttons: [UUID: NSButton] = [:]
    private var imageTask: Task<Void, Never>?
    private(set) var isBusy = false
    private var failureMessage: String?
    private var focusedID: UUID?
    private var controls: [NSControl] = []
    var onChoose: ((FillCandidate, Int) -> Void)?
    var onClose: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRefresh: (() -> Void)?

    init(zones: [CGRect], area: CGRect, occupied: Set<Int>) {
        self.zones = zones
        self.area = area
        self.occupied = occupied
        session = FillSession(count: zones.count, occupied: occupied)
        panel = FillPanel(contentRect: CGRect(x: 0, y: 0, width: 720, height: 700),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Заполнить раскладку"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.navigate = { [weak self] key in self?.navigate(key) ?? false }
        panel.dismiss = { [weak self] in self?.onClose?() }
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        let title = NSTextField(labelWithString: "Выбери окно для следующей зоны")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        root.addArrangedSubview(title)
        root.addArrangedSubview(status)
        map.widthAnchor.constraint(equalToConstant: 672).isActive = true
        map.heightAnchor.constraint(equalToConstant: 130).isActive = true
        root.addArrangedSubview(map)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.widthAnchor.constraint(equalToConstant: 672).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(360, max(180, area.height - 360))).isActive = true
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        root.addArrangedSubview(scroll)
        let footer = NSStackView()
        footer.spacing = 10
        for (title, action) in [("Пропустить", #selector(skip)), ("Обновить", #selector(refresh)),
                                ("Undo", #selector(undo)), ("Готово", #selector(done))] {
            let button = NSButton(title: title, target: self, action: action)
            footer.addArrangedSubview(button)
            controls.append(button)
        }
        root.addArrangedSubview(footer)
        let previews = NSButton(title: "Разрешить миниатюры…", target: self, action: #selector(allowPreviews))
        previews.isHidden = CGPreflightScreenCaptureAccess()
        root.addArrangedSubview(previews)
        panel.contentView = root
        root.widthAnchor.constraint(equalToConstant: 720).isActive = true
        panel.center()
        drawMap()
    }

    var isComplete: Bool { session.selected == nil }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
        controls.forEach { $0.isEnabled = !busy }
        buttons.values.forEach { $0.isEnabled = !busy }
        map.subviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = !busy && session.remaining.contains($0.tag) }
    }

    func reconcile(occupied: Set<Int>) {
        guard self.occupied != occupied else { return }
        self.occupied = occupied
        session.reconcile(occupied: occupied)
        drawMap()
        if isComplete { onClose?() }
    }

    func update(_ candidates: [FillCandidate], force: Bool = false) {
        let unchanged = self.candidates.count == candidates.count && zip(self.candidates, candidates).allSatisfy {
            $0.id == $1.id && $0.title == $1.title && $0.snapshot.frame == $1.snapshot.frame
        }
        guard force || !unchanged else { return }
        let focused = buttons.first { $0.value === panel.firstResponder }?.key ?? focusedID
        imageTask?.cancel()
        self.candidates = candidates
        buttons = [:]
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        for start in stride(from: 0, to: candidates.count, by: 2) {
            let row = NSStackView()
            row.spacing = 8
            for candidate in candidates[start..<min(start + 2, candidates.count)] {
                let app = NSRunningApplication(processIdentifier: candidate.snapshot.pid)
                let label = candidate.title.isEmpty ? (app?.localizedName ?? "Окно") : "\(app?.localizedName ?? "Приложение")\n\(candidate.title)"
                let button = NSButton(title: label, target: self, action: #selector(choose(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(candidate.id.uuidString)
                button.image = app?.icon
                button.imagePosition = .imageAbove
                button.imageScaling = .scaleProportionallyDown
                button.lineBreakMode = .byTruncatingTail
                button.setAccessibilityLabel(label)
                button.widthAnchor.constraint(equalToConstant: 328).isActive = true
                button.heightAnchor.constraint(equalToConstant: 172).isActive = true
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
        drawMap()
        update(candidates, force: true)
    }

    func failed() {
        setBusy(false)
        failureMessage = "Окно не помещается точно или недоступно. Undo вернёт последнее размещение. Выбери другое окно."
        updateStatus()
    }

    private func updateStatus() {
        if let failureMessage { status.stringValue = failureMessage; return }
        status.stringValue = candidates.isEmpty ? "Нет доступных окон на этом экране. Открой окно, список обновится автоматически." : "Зона \((session.selected ?? 0) + 1) · Осталось \(session.remaining.count). ✓ занято или перекрыто. Escape завершает выбор."
    }

    private func drawMap() {
        map.subviews.forEach { $0.removeFromSuperview() }
        let scale = min(672 / area.width, 130 / area.height)
        for (index, zone) in zones.enumerated() {
            let button = NSButton(title: occupied.contains(index) ? "✓" : session.remaining.contains(index) ? "\(index + 1)" : "Пропуск",
                                  target: self, action: #selector(selectZone(_:)))
            button.tag = index
            button.frame = CGRect(x: (672 - area.width * scale) / 2 + (zone.minX - area.minX) * scale,
                                  y: (zone.minY - area.minY) * scale,
                                  width: max(20, zone.width * scale - 3), height: max(20, zone.height * scale - 3))
            button.bezelStyle = .regularSquare
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.borderWidth = session.selected == index ? 3 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
            button.layer?.backgroundColor = session.selected == index ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
            button.contentTintColor = session.selected == index ? .controlAccentColor : .secondaryLabelColor
            button.isEnabled = session.remaining.contains(index)
            button.setAccessibilityLabel("Зона \(index + 1)\(session.selected == index ? ", выбрана" : "")")
            map.addSubview(button)
        }
        updateStatus()
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
        case 125: delta = 2
        case 126: delta = -2
        default: return false
        }
        let next = min(candidates.count - 1, max(0, index + delta))
        focusedID = candidates[next].id
        if let button = buttons[candidates[next].id] {
            panel.makeFirstResponder(button)
            button.scrollToVisible(button.bounds)
        }
        return true
    }

    @objc private func selectZone(_ sender: NSButton) { failureMessage = nil; session.select(sender.tag); drawMap() }
    @objc private func choose(_ sender: NSButton) {
        guard let index = session.selected, let candidate = candidates.first(where: { $0.id.uuidString == sender.identifier?.rawValue }) else { return }
        failureMessage = nil
        setBusy(true)
        onChoose?(candidate, index)
    }
    @objc private func skip() {
        session.advance()
        if isComplete { onClose?() } else { drawMap() }
    }
    @objc private func refresh() { onRefresh?() }
    @objc private func undo() { onUndo?() }
    @objc private func done() { onClose?() }
    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func allowPreviews() {
        _ = CGRequestScreenCaptureAccess()
        if CGPreflightScreenCaptureAccess() { loadPreviews() }
        else { status.stringValue = "Разреши запись экрана для WindowZones в системных настройках. Пока доступны иконки." }
    }

    private func loadPreviews() {
        guard CGPreflightScreenCaptureAccess() else { return }
        let current = candidates
        imageTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true), !Task.isCancelled else { return }
            for candidate in current {
                guard !Task.isCancelled else { return }
                let matches = content.windows.filter {
                    $0.owningApplication?.processID == candidate.snapshot.pid && GeometryEngine.close($0.frame, candidate.snapshot.frame)
                }
                guard matches.count == 1, let window = matches.first else { continue }
                let configuration = SCStreamConfiguration()
                configuration.width = 360
                configuration.height = max(1, Int(360 * window.frame.height / max(1, window.frame.width)))
                configuration.showsCursor = false
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration),
                      !Task.isCancelled else { continue }
                self?.buttons[candidate.id]?.image = NSImage(cgImage: image, size: NSSize(width: 280, height: 280 * CGFloat(image.height) / CGFloat(image.width)))
            }
        }
    }
}
