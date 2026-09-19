import CoreGraphics
import Foundation

public enum GeometryError: Error { case invalidInput, tooSmall }

public enum GeometryEngine {
    public static func zones(in area: CGRect, scale: CGFloat, inset: CGFloat = 8,
                             gap: CGFloat = 8) throws -> [CGRect] {
        guard [area.minX, area.minY, area.width, area.height, scale, inset, gap].allSatisfy(\.isFinite),
              area.size.width > 0, area.size.height > 0, scale > 0, inset >= 0, gap >= 0 else {
            throw GeometryError.invalidInput
        }
        let bounds = area.insetBy(dx: inset, dy: inset)
        func align(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let left = align(bounds.minX)
        let right = align(bounds.maxX)
        let bottom = align(bounds.minY)
        let top = align(bounds.maxY)
        let actualGap = align(gap)
        let available = right - left - 2 * actualGap
        guard [left, right, bottom, top, actualGap, available].allSatisfy(\.isFinite), available > 0, top > bottom else { throw GeometryError.tooSmall }
        let firstEnd = align(left + available * 0.25)
        let secondStart = firstEnd + actualGap
        let secondEnd = align(secondStart + available * 0.5)
        let thirdStart = secondEnd + actualGap
        let result = [
            CGRect(x: left, y: bottom, width: firstEnd - left, height: top - bottom),
            CGRect(x: secondStart, y: bottom, width: secondEnd - secondStart, height: top - bottom),
            CGRect(x: thirdStart, y: bottom, width: right - thirdStart, height: top - bottom)
        ]
        guard result.allSatisfy({ $0.width >= 120 && $0.height >= 120 }) else {
            throw GeometryError.tooSmall
        }
        return result
    }

    // Both conversions use the primary display's top edge in AppKit coordinates.
    public static func flip(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    public static func undoTarget(_ original: CGRect, sourceScreen: CGRect,
                                  currentScreen: CGRect?, available: CGRect) -> CGRect {
        guard let currentScreen else { return fit(original, into: available) }
        guard currentScreen != sourceScreen else { return original }
        return fit(original.offsetBy(dx: currentScreen.minX - sourceScreen.minX,
                                     dy: currentScreen.minY - sourceScreen.minY), into: available)
    }

    public static func keepVisible(_ rect: CGRect, in area: CGRect) -> CGRect {
        CGRect(x: max(area.minX, min(rect.minX, area.maxX - rect.width)),
               y: max(area.minY, min(rect.minY, area.maxY - rect.height)),
               width: rect.width, height: rect.height)
    }

    public static func fit(_ rect: CGRect, into area: CGRect) -> CGRect {
        let width = min(rect.width, area.width)
        let height = min(rect.height, area.height)
        return CGRect(x: min(max(rect.minX, area.minX), area.maxX - width),
                      y: min(max(rect.minY, area.minY), area.maxY - height),
                      width: width, height: height)
    }
}

public struct DragEvidence: Sendable {
    public static func isTranslation(from initial: CGRect, to current: CGRect,
                                     pointerDelta: CGPoint) -> Bool {
        hypot(current.minX - initial.minX, current.minY - initial.minY) >= 4 &&
            matchesTranslation(from: initial, to: current, pointerDelta: pointerDelta)
    }

    public static func matchesTranslation(from initial: CGRect, to current: CGRect,
                                          pointerDelta: CGPoint) -> Bool {
        let dx = current.minX - initial.minX
        let dy = current.minY - initial.minY
        return abs(initial.width - current.width) <= 2 && abs(initial.height - current.height) <= 2 &&
            abs(dx - pointerDelta.x) <= 12 && abs(dy - pointerDelta.y) <= 12
    }
}

public struct DragRecognition: Sendable {
    public private(set) var isConfirmed = false
    private var isCancelled = false

    public init() {}

    public mutating func cancel() {
        isCancelled = true
        isConfirmed = false
    }

    public mutating func observe(initial: CGRect, current: CGRect, pointerDelta: CGPoint) -> Bool {
        guard !isCancelled else { return false }
        guard abs(initial.width - current.width) <= 2, abs(initial.height - current.height) <= 2 else {
            cancel()
            return false
        }
        // Once confirmed, transient AX/pointer skew must not toggle the preview off and on.
        if DragEvidence.isTranslation(from: initial, to: current, pointerDelta: pointerDelta) {
            isConfirmed = true
        }
        return isConfirmed
    }

    public func canFinish(initial: CGRect, current: CGRect, pointerDelta: CGPoint) -> Bool {
        isConfirmed && !isCancelled &&
            DragEvidence.matchesTranslation(from: initial, to: current, pointerDelta: pointerDelta)
    }
}
