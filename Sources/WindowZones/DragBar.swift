import AppKit
import Geometry

@MainActor private final class DragBarDrawing: NSView {
    var cells: [DragBarCell] = []
    var selected: DragBarCell?
    var origin = CGPoint.zero
    var expanded = false

    override func draw(_ dirtyRect: NSRect) {
        if !expanded {
            let text = "Раскладки" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
            return
        }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        for cell in cells {
            let active = selected == cell
            let rect = cell.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            (active ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
            path.fill()
            (active ? NSColor.controlAccentColor : (contrast ? NSColor.labelColor : NSColor.separatorColor)).setStroke()
            path.lineWidth = active || contrast ? 2 : 1
            path.stroke()
            if active {
                let text = "✓" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white]
                let size = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }
    }
}

@MainActor final class DragBar {
    private var panel: OverlayPanel?
    private let drawing = DragBarDrawing()

    func show(geometry: DragBarGeometry, interaction: DragBarInteraction) {
        let rect = interaction.expanded ? geometry.frame : geometry.offer
        if panel == nil {
            let window = OverlayPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.hasShadow = true
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 14
            material.layer?.masksToBounds = true
            material.addSubview(drawing)
            drawing.autoresizingMask = [.width, .height]
            window.contentView = material
            panel = window
        }
        guard let panel else { return }
        panel.setFrame(rect, display: false)
        drawing.frame = CGRect(origin: .zero, size: rect.size)
        drawing.origin = rect.origin
        drawing.cells = geometry.cells
        drawing.expanded = interaction.expanded
        drawing.selected = interaction.selected
        drawing.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }
}
