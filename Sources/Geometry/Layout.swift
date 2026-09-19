import CoreGraphics
import Foundation

public enum SplitAxis: Sendable, Equatable {
    // The axis describes the divider, not the direction in which children are stacked.
    case vertical
    case horizontal
}

public indirect enum LayoutNode: Sendable, Equatable {
    case zone(id: UUID, name: String)
    case split(axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)
}

public enum LayoutError: Error, Equatable {
    case invalidRatio
    case invalidSpacing
    case duplicateZoneID
    case tooManyZones
    case tooDeep
    case invalidArea
    case invalidScale
    case tooSmall
}

public struct Layout: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let root: LayoutNode
    public let inset: CGFloat
    public let gap: CGFloat

    public init(id: UUID = UUID(), name: String, root: LayoutNode,
                inset: CGFloat = 8, gap: CGFloat = 8) {
        self.id = id
        self.name = name
        self.root = root
        self.inset = inset
        self.gap = gap
    }

    public func validate() throws {
        guard [inset, gap].allSatisfy({ $0.isFinite && (0...32).contains($0) }) else {
            throw LayoutError.invalidSpacing
        }
        var identifiers = Set<UUID>()
        func visit(_ node: LayoutNode, depth: Int) throws {
            guard depth <= 12 else { throw LayoutError.tooDeep }
            switch node {
            case let .zone(id, _):
                guard identifiers.insert(id).inserted else { throw LayoutError.duplicateZoneID }
                guard identifiers.count <= 12 else { throw LayoutError.tooManyZones }
            case let .split(_, ratio, first, second):
                guard ratio.isFinite, (0.1...0.9).contains(ratio) else { throw LayoutError.invalidRatio }
                try visit(first, depth: depth + 1)
                try visit(second, depth: depth + 1)
            }
        }
        try visit(root, depth: 1)
    }
}

public struct ResolvedZone: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let index: Int
    public let frame: CGRect
}

public enum LayoutGeometry {
    public static func zones(for layout: Layout, in area: CGRect, scale: CGFloat) throws -> [ResolvedZone] {
        try layout.validate()
        guard [area.origin.x, area.origin.y, area.width, area.height, area.maxX, area.maxY].allSatisfy(\.isFinite),
              area.size.width > 0, area.size.height > 0 else { throw LayoutError.invalidArea }
        guard scale.isFinite, scale > 0 else { throw LayoutError.invalidScale }
        let values = [area.minX + layout.inset, area.maxX - layout.inset,
                      area.minY + layout.inset, area.maxY - layout.inset, layout.gap]
        guard values.allSatisfy({ ($0 * scale).isFinite }),
              (area.width * scale).isFinite, (area.height * scale).isFinite else {
            throw LayoutError.invalidScale
        }
        // Round exterior edges inward to keep every zone inside the requested work area.
        let left = ceil(values[0] * scale) / scale
        let right = floor(values[1] * scale) / scale
        let bottom = ceil(values[2] * scale) / scale
        let top = floor(values[3] * scale) / scale
        let gap = (layout.gap * scale).rounded() / scale
        guard right > left, top > bottom else { throw LayoutError.tooSmall }
        var result: [ResolvedZone] = []
        func align(_ coordinate: CGFloat) -> CGFloat { (coordinate * scale).rounded() / scale }

        func gapBudget(_ node: LayoutNode, along axis: SplitAxis) -> CGFloat {
            switch node {
            case .zone: return 0
            case let .split(divider, _, first, second):
                let a = gapBudget(first, along: axis)
                let b = gapBudget(second, along: axis)
                // Parallel divisions add gutters; perpendicular branches share the same extent.
                return divider == axis ? gap + a + b : max(a, b)
            }
        }

        func resolve(_ node: LayoutNode, in bounds: CGRect) throws {
            guard bounds.width >= 120, bounds.height >= 120 else { throw LayoutError.tooSmall }
            switch node {
            case let .zone(id, name):
                result.append(ResolvedZone(id: id, name: name, index: result.count + 1, frame: bounds))
            case let .split(axis, ratio, first, second):
                let firstBudget = gapBudget(first, along: axis)
                let secondBudget = gapBudget(second, along: axis)
                let firstFrame: CGRect
                let secondFrame: CGRect
                switch axis {
                case .vertical:
                    let available = bounds.width - gap - firstBudget - secondBudget
                    guard available > 0 else { throw LayoutError.tooSmall }
                    let end = align(bounds.minX + available * ratio + firstBudget)
                    firstFrame = CGRect(x: bounds.minX, y: bounds.minY, width: end - bounds.minX, height: bounds.height)
                    secondFrame = CGRect(x: end + gap, y: bounds.minY, width: bounds.maxX - end - gap, height: bounds.height)
                case .horizontal:
                    let available = bounds.height - gap - firstBudget - secondBudget
                    guard available > 0 else { throw LayoutError.tooSmall }
                    // First means top in the UI even though AppKit coordinates grow upward.
                    let start = align(bounds.maxY - available * ratio - firstBudget)
                    firstFrame = CGRect(x: bounds.minX, y: start, width: bounds.width, height: bounds.maxY - start)
                    secondFrame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: start - gap - bounds.minY)
                }
                try resolve(first, in: firstFrame)
                try resolve(second, in: secondFrame)
            }
        }
        try resolve(layout.root, in: CGRect(x: left, y: bottom, width: right - left, height: top - bottom))
        return result
    }
}
