import CoreGraphics
import Testing
@testable import Geometry

struct GeometryTests {
    @Test func defaultRatiosAndGaps() throws {
        let zones = try GeometryEngine.zones(in: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
        #expect(zones.map(\.width) == [352, 704, 352])
        #expect(zones[0].minX == 8)
        #expect(zones[2].maxX == 1432)
        #expect(zones[1].minX - zones[0].maxX == 8)
        #expect(zones[2].minX - zones[1].maxX == 8)
    }

    @Test func roundingAndNegativeDisplays() throws {
        for scale: CGFloat in [1, 2] {
            for width in 1000...1050 {
                let area = CGRect(x: -1511, y: 982, width: width, height: 850)
                let zones = try GeometryEngine.zones(in: area, scale: scale)
                #expect(zones.last!.maxX == area.maxX - 8)
                #expect(zones.map(\.width).reduce(0, +) + 32 == area.width)
                for zone in zones {
                    #expect(zone.minX * scale == (zone.minX * scale).rounded())
                    #expect(area.contains(zone))
                }
            }
        }
    }

    @Test func coordinateConversionAcrossPrimaryTop() {
        let above = CGRect(x: -400, y: 1100, width: 800, height: 600)
        let ax = GeometryEngine.flip(above, primaryTop: 1080)
        #expect(ax == CGRect(x: -400, y: -620, width: 800, height: 600))
        #expect(GeometryEngine.flip(ax, primaryTop: 1080) == above)
    }

    @Test func invalidGeometry() {
        for scale: CGFloat in [0, -1, .nan, .infinity, .greatestFiniteMagnitude] {
            #expect(throws: GeometryError.self) {
                try GeometryEngine.zones(in: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: scale)
            }
        }
        #expect(throws: GeometryError.self) {
            try GeometryEngine.zones(in: CGRect(x: 0, y: 0, width: 300, height: 800), scale: 2)
        }
        #expect(throws: GeometryError.self) {
            try GeometryEngine.zones(in: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2, gap: -1)
        }
        #expect(throws: GeometryError.self) {
            try GeometryEngine.zones(in: CGRect(x: 0, y: 0, width: -1000, height: 800), scale: 2)
        }
    }

    @Test func undoFallbackFitsVisibleArea() {
        let fit = GeometryEngine.fit(CGRect(x: -1900, y: -200, width: 1800, height: 1200),
                                     into: CGRect(x: 0, y: 24, width: 1440, height: 850))
        #expect(fit == CGRect(x: 0, y: 24, width: 1440, height: 850))
    }

    @Test func undoPreservesOffscreenPositionWhenScreenUnchanged() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let original = CGRect(x: 1134, y: 48, width: 1315, height: 865)
        let visible = CGRect(x: 0, y: 33, width: 1512, height: 897)
        #expect(GeometryEngine.undoTarget(original, sourceScreen: screen,
                                         currentScreen: screen, available: visible) == original)
        #expect(visible.contains(GeometryEngine.undoTarget(original, sourceScreen: screen,
                                                          currentScreen: nil, available: visible)))
    }

    @Test func refusedResizeKeepsWindowVisibleWithoutChangingSize() {
        let actual = CGRect(x: 1134, y: 48, width: 1315, height: 865)
        let visible = CGRect(x: 0, y: 33, width: 1512, height: 897)
        let corrected = GeometryEngine.keepVisible(actual, in: visible)
        #expect(corrected.size == actual.size)
        #expect(visible.contains(corrected))
        #expect(corrected.minX == 197)
    }

    @Test func confirmedDragSurvivesTemporaryPointerSkewButCannotSnapWithIt() {
        let initial = CGRect(x: 100, y: 100, width: 800, height: 600)
        var drag = DragRecognition()
        let observed1 = drag.observe(initial: initial, current: initial, pointerDelta: CGPoint(x: 50, y: 0))
        #expect(!observed1)
        let observed2 = drag.observe(initial: initial, current: initial.offsetBy(dx: 50, dy: 0), pointerDelta: CGPoint(x: 50, y: 0))
        #expect(observed2)
        let observed3 = drag.observe(initial: initial, current: initial.offsetBy(dx: 50, dy: 0), pointerDelta: CGPoint(x: 90, y: 0))
        #expect(observed3)
        #expect(!drag.canFinish(initial: initial, current: initial.offsetBy(dx: 50, dy: 0), pointerDelta: CGPoint(x: 90, y: 0)))
        #expect(drag.canFinish(initial: initial, current: initial.offsetBy(dx: 90, dy: 0), pointerDelta: CGPoint(x: 90, y: 0)))
        #expect(drag.canFinish(initial: initial, current: initial, pointerDelta: .zero))
    }

    @Test func cancelledOrResizedDragCannotReactivate() {
        let initial = CGRect(x: 100, y: 100, width: 800, height: 600)
        let moved = initial.offsetBy(dx: 30, dy: 0)
        for resized in [false, true] {
            var drag = DragRecognition()
            let observed4 = drag.observe(initial: initial, current: moved, pointerDelta: CGPoint(x: 30, y: 0))
            #expect(observed4)
            if resized {
                let observed5 = drag.observe(initial: initial, current: moved.insetBy(dx: 5, dy: 0), pointerDelta: CGPoint(x: 30, y: 0))
                #expect(!observed5)
            } else { drag.cancel() }
            let observed6 = drag.observe(initial: initial, current: moved, pointerDelta: CGPoint(x: 30, y: 0))
            #expect(!observed6)
            #expect(!drag.canFinish(initial: initial, current: moved, pointerDelta: CGPoint(x: 30, y: 0)))
        }
    }

    @Test func dragRequiresTranslationMatchingPointer() {
        let initial = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(DragEvidence.isTranslation(from: initial, to: initial.offsetBy(dx: 30, dy: 20), pointerDelta: CGPoint(x: 30, y: 20)))
        #expect(!DragEvidence.isTranslation(from: initial, to: initial, pointerDelta: CGPoint(x: 30, y: 20)))
        #expect(!DragEvidence.isTranslation(from: initial, to: CGRect(x: 130, y: 120, width: 820, height: 600), pointerDelta: CGPoint(x: 30, y: 20)))
        #expect(!DragEvidence.isTranslation(from: initial, to: initial.offsetBy(dx: 100, dy: 0), pointerDelta: CGPoint(x: 20, y: 0)))
    }
}
