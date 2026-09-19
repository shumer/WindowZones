import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        let inset = p * 0.07
        let background = NSBezierPath(roundedRect: CGRect(x: inset, y: inset, width: p - inset * 2, height: p - inset * 2), xRadius: p * 0.2, yRadius: p * 0.2)
        NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.48, blue: 0.98, alpha: 1), ending: NSColor(srgbRed: 0.28, green: 0.24, blue: 0.78, alpha: 1))!.draw(in: background, angle: -60)
        let gap = p * 0.04
        let x = p * 0.21
        let y = p * 0.23
        let w = p * 0.58
        let h = p * 0.54
        let left = CGRect(x: x, y: y, width: (w - gap) * 0.56, height: h)
        let rightX = left.maxX + gap
        let rightW = x + w - rightX
        for (index, rect) in [left, CGRect(x: rightX, y: y + (h + gap) / 2, width: rightW, height: (h - gap) / 2), CGRect(x: rightX, y: y, width: rightW, height: (h - gap) / 2)].enumerated() {
            NSColor.white.withAlphaComponent(index == 0 ? 1 : 0.65).setFill()
            NSBezierPath(roundedRect: rect, xRadius: p * 0.025, yRadius: p * 0.025).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
