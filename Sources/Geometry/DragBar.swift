import Foundation

public struct DragBarCell: Sendable, Equatable {
    public let layoutID: UUID
    public let zoneIndex: Int
    public let frame: CGRect
    public let target: CGRect
}

public struct DragBarGeometry: Sendable {
    public let frame: CGRect
    public let offer: CGRect
    public let activation: CGRect
    public let retention: CGRect
    public let cells: [DragBarCell]

    public init(layouts: [Layout], area: CGRect, scale: CGFloat) {
        let available = layouts.compactMap { layout -> (Layout, [CGRect])? in
            guard let zones = try? LayoutGeometry.zones(for: layout, in: area, scale: scale), !zones.isEmpty else { return nil }
            return (layout, zones.map(\.frame))
        }
        let count = max(1, available.count)
        let width = min(area.width - 32, CGFloat(count) * 132 + 16)
        frame = CGRect(x: area.midX - width / 2, y: area.maxY - 120, width: width, height: 96)
        offer = CGRect(x: area.midX - 70, y: area.maxY - 44, width: 140, height: 24)
        activation = CGRect(x: frame.minX, y: frame.minY - 20, width: frame.width, height: 120)
        retention = frame.insetBy(dx: -24, dy: -40)
        let cardWidth = (width - 16) / CGFloat(count)
        var result: [DragBarCell] = []
        for (index, entry) in available.enumerated() {
            let card = CGRect(x: frame.minX + 12 + CGFloat(index) * cardWidth,
                              y: frame.minY + 16, width: cardWidth - 8, height: 64)
            for (zoneIndex, target) in entry.1.enumerated() {
                let miniature = CGRect(x: card.minX + (target.minX - area.minX) / area.width * card.width,
                                       y: card.minY + (target.minY - area.minY) / area.height * card.height,
                                       width: target.width / area.width * card.width,
                                       height: target.height / area.height * card.height).insetBy(dx: 1, dy: 1)
                result.append(DragBarCell(layoutID: entry.0.id, zoneIndex: zoneIndex, frame: miniature, target: target))
            }
        }
        cells = result
    }
}

public struct DragBarInteraction: Sendable {
    public private(set) var expanded = false
    public private(set) var selected: DragBarCell?
    private var screen: UInt32?
    private var cancelled = false

    public init() {}

    public mutating func update(pointer: CGPoint, screen: UInt32, geometry: DragBarGeometry) {
        guard !cancelled else { return }
        if self.screen != screen { expanded = false }
        self.screen = screen
        if geometry.activation.contains(pointer) { expanded = true }
        else if !geometry.retention.contains(pointer) { expanded = false }
        selected = expanded ? geometry.cells.first { $0.frame.contains(pointer) } : nil
    }

    public func drop(at pointer: CGPoint, screen: UInt32, geometry: DragBarGeometry) -> DragBarCell? {
        guard !cancelled, expanded, self.screen == screen else { return nil }
        return geometry.cells.first { $0.frame.contains(pointer) }
    }

    public mutating func cancel() {
        cancelled = true
        expanded = false
        selected = nil
    }
}
