import CoreGraphics

public struct DisplayGeometry: Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let visible: CGRect
    public let scale: CGFloat
    public let primaryTop: CGFloat

    public init(id: UInt32, frame: CGRect, visible: CGRect, scale: CGFloat, primaryTop: CGFloat) {
        self.id = id
        self.frame = frame
        self.visible = visible
        self.scale = scale
        self.primaryTop = primaryTop
    }
}

public enum DisplayConfiguration {
    // Compare against the original session snapshot so small changes cannot accumulate.
    public static func compatible(_ original: [DisplayGeometry], _ current: [DisplayGeometry],
                                  visibleTolerance: CGFloat = 1) -> Bool {
        guard !original.isEmpty, original.count == current.count,
              visibleTolerance.isFinite, visibleTolerance >= 0,
              Set(original.map(\.id)).count == original.count,
              Set(current.map(\.id)).count == current.count else { return false }
        return original.allSatisfy { before in
            guard let after = current.first(where: { $0.id == before.id }),
                  before.frame == after.frame, before.scale == after.scale,
                  before.primaryTop == after.primaryTop else { return false }
            let edgeChanges = [before.visible.minX - after.visible.minX,
                               before.visible.maxX - after.visible.maxX,
                               before.visible.minY - after.visible.minY,
                               before.visible.maxY - after.visible.maxY]
            return edgeChanges.allSatisfy { $0.isFinite && abs($0) <= visibleTolerance }
        }
    }
}
