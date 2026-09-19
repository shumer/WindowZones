import AppKit
import Geometry

@main struct Render {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let canvas = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 600))
            canvas.wantsLayer = true
            canvas.layer?.backgroundColor = NSColor(calibratedWhite: name == "light" ? 0.88 : 0.12, alpha: 1).cgColor
            canvas.appearance = NSAppearance(named: appearance)
            let drawing = ZoneDrawing(frame: canvas.bounds)
            drawing.zones = [CGRect(x: 20, y: 20, width: 226, height: 560), CGRect(x: 254, y: 20, width: 452, height: 560), CGRect(x: 714, y: 20, width: 226, height: 560)]
            drawing.selected = 1
            canvas.addSubview(drawing)
            let panel = ZonePickerContent(applicationName: "Finder")
            panel.frame.origin = CGPoint(x: 220, y: 35)
            panel.wantsLayer = true
            panel.layer?.cornerRadius = 12
            canvas.appearance?.performAsCurrentDrawingAppearance {
                panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            panel.displayPopup.addItem(withTitle: "Встроенный дисплей")
            panel.hint.stringValue = "Выбрана зона 2"
            panel.updateDisplay(area: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
            panel.select(layoutID: BuiltInLayouts.focused.id, index: 1, availableLayoutIDs: Set(BuiltInLayouts.all.map(\.id)))
            canvas.addSubview(panel)
            let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = canvas
            canvas.layoutSubtreeIfNeeded()
            guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { fatalError() }
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/design/picker-\(name).png"))
        }
    }
}
