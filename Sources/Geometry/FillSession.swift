import Foundation

public struct FillSession: Sendable {
    public private(set) var remaining: [Int]
    public private(set) var selected: Int?

    public init(count: Int, occupied: Set<Int>) {
        remaining = (0..<max(0, count)).filter { !occupied.contains($0) }
        selected = remaining.first
    }

    public mutating func select(_ index: Int) {
        if remaining.contains(index) { selected = index }
    }

    public mutating func advance() {
        guard let selected else { return }
        remaining.removeAll { $0 == selected }
        self.selected = remaining.first
    }
}
