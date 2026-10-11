import AppKit
import QuartzCore
import Geometry

@MainActor private final class DragBarDrawing: NSView {
    var cells: [DragBarCell] = []
    var selected: DragBarCell?
    var origin = CGPoint.zero
    var expanded = false
    var contentProgress: CGFloat = 0
    var layoutSize = CGSize.zero

    private func localFrame(_ frame: CGRect) -> CGRect {
        let xScale = bounds.width / max(1, layoutSize.width)
        let yScale = bounds.height / max(1, layoutSize.height)
        return CGRect(x: (frame.minX - origin.x) * xScale, y: (frame.minY - origin.y) * yScale,
                      width: frame.width * xScale, height: frame.height * yScale)
    }

    override func draw(_ dirtyRect: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = expanded ? 12 : 8
        let outline = NSBezierPath()
        outline.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        outline.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        outline.line(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        outline.curve(to: CGPoint(x: rect.maxX - radius, y: rect.minY),
                      controlPoint1: CGPoint(x: rect.maxX, y: rect.minY),
                      controlPoint2: CGPoint(x: rect.maxX, y: rect.minY))
        outline.line(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        outline.curve(to: CGPoint(x: rect.minX, y: rect.minY + radius),
                      controlPoint1: CGPoint(x: rect.minX, y: rect.minY),
                      controlPoint2: CGPoint(x: rect.minX, y: rect.minY))
        outline.close()
        let alpha: CGFloat = opaque ? 1 : 0.88
        let top = NSColor(calibratedRed: 0.275, green: 0.314, blue: 0.353, alpha: alpha)
        let bottom = NSColor(calibratedRed: 0.161, green: 0.200, blue: 0.239, alpha: alpha)
        NSGradient(starting: bottom, ending: top)?.draw(in: outline, angle: 90)
        NSColor(calibratedWhite: 1, alpha: contrast ? 0.85 : 0.25).setStroke()
        outline.lineWidth = contrast ? 2 : 1
        outline.stroke()
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setAlpha(1 - contentProgress)
        if contentProgress < 1 {
            NSColor(calibratedWhite: 0.85, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: CGRect(x: bounds.midX - 26, y: 6, width: 52, height: 3),
                         xRadius: 2, yRadius: 2).fill()
        }
        context?.restoreGState()
        guard contentProgress > 0 else { return }
        context?.saveGState()
        context?.setAlpha(contentProgress)
        defer { context?.restoreGState() }
        for cell in cells {
            let active = selected == cell
            let rect = localFrame(cell.frame)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            (active ? NSColor.controlAccentColor : NSColor(calibratedRed: 0.627, green: 0.671, blue: 0.710, alpha: 0.78)).setFill()
            path.fill()
            NSColor(calibratedWhite: 1, alpha: contrast ? 0.95 : (active ? 0.8 : 0.5)).setStroke()
            path.lineWidth = active || contrast ? 2 : 1
            path.stroke()
            if active {
                // Choose the higher-contrast mark for the user's system accent.
                let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
                func linear(_ value: CGFloat) -> CGFloat {
                    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * linear(accent.redComponent) + 0.7152 * linear(accent.greenComponent)
                    + 0.0722 * linear(accent.blueComponent)
                let mark: NSColor = luminance > 0.179 ? .black : .white
                let text = "✓" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: mark]
                let size = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }
    }
}

@MainActor final class DragBar {
    private var panel: OverlayPanel?
    private let drawing = DragBarDrawing()
    private var timer: Timer?
    private var targetFrame = CGRect.zero
    private var targetAlpha: CGFloat = 0
    private var targetContent: CGFloat = 0
    private var startFrame = CGRect.zero
    private var startAlpha: CGFloat = 0
    private var startContent: CGFloat = 0
    private var started: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.18
    private var hiding = false
    private var anchor: CGPoint?

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
            material.material = .hudWindow
            material.appearance = NSAppearance(named: .vibrantDark)
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 12
            material.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            material.layer?.masksToBounds = true
            material.addSubview(drawing)
            drawing.autoresizingMask = [.width, .height]
            window.contentView = material
            panel = window
        }
        guard let panel else { return }
        let newAnchor = CGPoint(x: rect.midX, y: rect.maxY)
        let changedScreen = anchor != nil && anchor != newAnchor
        anchor = newAnchor
        drawing.origin = geometry.frame.origin
        drawing.layoutSize = geometry.frame.size
        drawing.cells = geometry.cells
        drawing.expanded = interaction.expanded
        drawing.selected = interaction.selected
        drawing.needsDisplay = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !panel.isVisible || changedScreen {
            timer?.invalidate()
            timer = nil
            panel.setFrame(reduceMotion ? rect : tucked(rect), display: false)
            panel.alphaValue = 0
            drawing.contentProgress = interaction.expanded ? 1 : 0
            panel.orderFrontRegardless()
        }
        let content: CGFloat = interaction.expanded ? 1 : 0
        if hiding || targetFrame != rect || targetAlpha != 1 || targetContent != content || changedScreen {
            hiding = false
            animate(to: rect, alpha: 1, content: content, duration: reduceMotion ? 0.10 : 0.20)
        }
    }

    func hide() {
        guard let panel, panel.isVisible, !hiding else { return }
        hiding = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animate(to: reduceMotion ? panel.frame : tucked(panel.frame), alpha: 0,
                content: drawing.contentProgress, duration: reduceMotion ? 0.10 : 0.16)
    }

    private func tucked(_ frame: CGRect) -> CGRect {
        // Keep the upper edge anchored below the menu while sliding the lower edge up.
        CGRect(x: frame.midX - frame.width * 0.46, y: frame.maxY - 2,
               width: frame.width * 0.92, height: 2)
    }

    private func animate(to frame: CGRect, alpha: CGFloat, content: CGFloat, duration: CFTimeInterval) {
        guard let panel else { return }
        timer?.invalidate()
        startFrame = panel.frame
        startAlpha = panel.alphaValue
        startContent = drawing.contentProgress
        targetFrame = frame
        targetAlpha = alpha
        targetContent = content
        self.duration = duration
        started = CACurrentMediaTime()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startFrame = frame
            panel.setFrame(frame, display: false)
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceAnimation() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceAnimation() {
        guard let panel else { return }
        let elapsed = min(1, max(0, (CACurrentMediaTime() - started) / duration))
        let progress = CGFloat(1 - pow(1 - elapsed, 3))
        func mix(_ start: CGFloat, _ end: CGFloat) -> CGFloat { start + (end - start) * progress }
        let frame = CGRect(x: mix(startFrame.minX, targetFrame.minX), y: mix(startFrame.minY, targetFrame.minY),
                           width: mix(startFrame.width, targetFrame.width), height: mix(startFrame.height, targetFrame.height))
        panel.setFrame(frame, display: false)
        drawing.frame = CGRect(origin: .zero, size: frame.size)
        drawing.contentProgress = mix(startContent, targetContent)
        drawing.needsDisplay = true
        panel.alphaValue = mix(startAlpha, targetAlpha)
        if elapsed == 1 {
            timer?.invalidate()
            timer = nil
            if hiding { panel.orderOut(nil) }
        }
    }
}
