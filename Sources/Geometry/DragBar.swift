import Foundation

public struct DragBarCell: Sendable, Equatable {
    public let layoutID: UUID
    public let zoneIndex: Int
    public let frame: CGRect
    public let target: CGRect
    public var isSelectable = true
}

public struct DragBarGeometry: Sendable {
    public let frame: CGRect
    public let offer: CGRect
    public let activation: CGRect
    public let retention: CGRect
    public let cells: [DragBarCell]

    public init(layouts: [Layout], area: CGRect, scale: CGFloat, top: CGFloat? = nil, reservedPairZone: Int? = nil) {
        let available = layouts.compactMap { layout -> (Layout, [CGRect])? in
            guard let zones = try? LayoutGeometry.zones(for: layout, in: area, scale: scale), !zones.isEmpty else { return nil }
            return (layout, zones.map(\.frame))
        }
        let count = max(1, available.count)
        let width = min(area.width - 32, CGFloat(count) * 132 + 32)
        let menuBottom = min(area.maxY, top ?? area.maxY)
        let anchor = menuBottom - 8
        frame = CGRect(x: area.midX - width / 2, y: anchor - 104, width: width, height: 104)
        let offerWidth = min(width, area.width * 0.38)
        offer = CGRect(x: area.midX - offerWidth / 2, y: anchor - 20, width: offerWidth, height: 20)
        activation = CGRect(x: frame.minX, y: anchor - 40, width: frame.width, height: 48)
        retention = CGRect(x: frame.minX - 24, y: frame.minY - 32, width: frame.width + 48, height: frame.height + 32)
        let cardWidth = (width - 32) / CGFloat(count)
        var result: [DragBarCell] = []
        for (index, entry) in available.enumerated() {
            let card = CGRect(x: frame.minX + 16 + CGFloat(index) * cardWidth,
                              y: frame.minY + 18, width: cardWidth - 12, height: 68)
            for (zoneIndex, target) in entry.1.enumerated() {
                let miniature = CGRect(x: card.minX + (target.minX - area.minX) / area.width * card.width,
                                       y: card.minY + (target.minY - area.minY) / area.height * card.height,
                                       width: target.width / area.width * card.width,
                                       height: target.height / area.height * card.height).insetBy(dx: 1, dy: 1)
                var cell = DragBarCell(layoutID: entry.0.id, zoneIndex: zoneIndex, frame: miniature, target: target)
                cell.isSelectable = entry.0.id != PairSuggestion.layoutID || zoneIndex != reservedPairZone
                result.append(cell)
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
        selected = expanded ? geometry.cells.first { $0.isSelectable && $0.frame.contains(pointer) } : nil
    }

    public func drop(at pointer: CGPoint, screen: UInt32, geometry: DragBarGeometry) -> DragBarCell? {
        guard !cancelled, expanded, self.screen == screen else { return nil }
        return geometry.cells.first { $0.isSelectable && $0.frame.contains(pointer) }
    }

    public mutating func cancel() {
        cancelled = true
        expanded = false
        selected = nil
    }
}
