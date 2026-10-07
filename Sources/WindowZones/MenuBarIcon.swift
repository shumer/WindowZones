import AppKit

@MainActor enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let frame = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 3.75, width: 14.5, height: 10.5),
                                     xRadius: 1.75, yRadius: 1.75)
            frame.lineWidth = 1.5
            frame.stroke()

            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: 8.5, y: 4.5))
            divider.line(to: NSPoint(x: 8.5, y: 13.5))
            divider.lineWidth = 1.25
            divider.stroke()

            NSBezierPath(roundedRect: NSRect(x: 10, y: 5.5, width: 4.5, height: 7),
                         xRadius: 0.6, yRadius: 0.6).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "WindowZones"
        return image
    }
}
