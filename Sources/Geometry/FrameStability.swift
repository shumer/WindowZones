import CoreGraphics
import Foundation

// Require a quiet interval relative to one anchor, without accumulating small movements.
public struct FrameStability: Sendable {
    private var anchor: CGRect?
    private var anchorTime: TimeInterval = 0
    private var lastTime: TimeInterval = 0

    public init() {}

    public mutating func observe(_ frame: CGRect, at time: TimeInterval) -> Bool {
        guard time.isFinite,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else {
            anchor = nil
            return false
        }
        guard let anchor, time >= lastTime,
              GeometryEngine.close(anchor, frame, tolerance: 0.5) else {
            self.anchor = frame
            anchorTime = time
            lastTime = time
            return false
        }
        lastTime = time
        return time - anchorTime >= 0.1
    }
}
