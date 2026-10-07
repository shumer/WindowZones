import Foundation

public struct FillSession: Sendable {
    private let count: Int
    private var skipped: Set<Int> = []
    public private(set) var remaining: [Int]
    public private(set) var selected: Int?

    public init(count: Int, occupied: Set<Int>) {
        self.count = max(0, count)
        remaining = (0..<max(0, count)).filter { !occupied.contains($0) }
        selected = remaining.first
    }

    public mutating func reconcile(occupied: Set<Int>) {
        remaining = (0..<count).filter { !occupied.contains($0) && !skipped.contains($0) }
        if selected.map({ remaining.contains($0) }) != true { selected = remaining.first }
    }

    public static func panelOrigin(size: CGSize, anchor: CGRect, available: CGRect) -> CGPoint {
        CGPoint(x: max(available.minX, min(anchor.midX - size.width / 2, available.maxX - size.width)),
                y: max(available.minY, min(anchor.midY - size.height / 2, available.maxY - size.height)))
    }

    public static func accepts(actual: CGRect, target: CGRect) -> Bool {
        [abs(actual.minX - target.minX), abs(actual.minY - target.minY),
         abs(actual.maxX - target.maxX), abs(actual.maxY - target.maxY)].allSatisfy { $0.isFinite && $0 <= 16 }
    }

    public static func occupied(zones: [CGRect], frames: [CGRect]) -> Set<Int> {
        Set(zones.indices.filter { index in
            frames.contains { frame in
                let overlap = zones[index].intersection(frame)
                return !overlap.isNull && overlap.width > 1 && overlap.height > 1
            }
        })
    }

    public mutating func select(_ index: Int) {
        if remaining.contains(index) { selected = index }
    }

    public mutating func advance() {
        guard let selected else { return }
        skipped.insert(selected)
        remaining.removeAll { $0 == selected }
        self.selected = remaining.first
    }
}
