import CoreGraphics
import Foundation
import Testing
@testable import Geometry

struct BuiltInLayoutsTests {
    @Test func presetsHaveStableDistinctIdentitiesAndExpectedZoneCounts() throws {
        #expect(BuiltInLayouts.landscape.map(\.id) == [
            UUID(uuidString: "575A0000-0000-4000-8000-000000000001")!,
            UUID(uuidString: "575A0000-0000-4000-8000-000000000008")!,
            UUID(uuidString: "575A0000-0000-4000-8000-000000000002")!,
            UUID(uuidString: "575A0000-0000-4000-8000-000000000009")!,
            UUID(uuidString: "575A0000-0000-4000-8000-000000000007")!,
            UUID(uuidString: "575A0000-0000-4000-8000-000000000003")!
        ])
        var ids = Set<UUID>()
        for (layout, count) in zip(BuiltInLayouts.landscape, [2, 2, 3, 3, 4, 3]) {
            for scale: CGFloat in [1, 2] {
                let zones = try LayoutGeometry.zones(for: layout,
                    in: CGRect(x: -1512, y: 458, width: 1512, height: 949), scale: scale)
                #expect(zones.count == count)
                #expect(zones.map(\.index) == Array(1...count))
                if scale == 1 {
                    #expect(ids.insert(layout.id).inserted)
                    for zone in zones { #expect(ids.insert(zone.id).inserted) }
                }
            }
        }
    }

    @Test func adaptivePresetsUseLogicalWidthAndOrientation() throws {
        #expect(BuiltInLayouts.suggested(in: CGRect(x: 0, y: 0, width: 1439, height: 900)).count == 4)
        #expect(BuiltInLayouts.suggested(in: CGRect(x: -2000, y: 300, width: 1440, height: 960)) == BuiltInLayouts.landscape)
        #expect(BuiltInLayouts.suggested(in: CGRect(x: 0, y: 0, width: 1440, height: 961)).count == 4)
        #expect(BuiltInLayouts.suggested(in: CGRect(x: 0, y: 0, width: 1000, height: 1000)).count == 4)
        #expect(BuiltInLayouts.suggested(in: CGRect(x: 0, y: 0, width: 900, height: 1440)) == [BuiltInLayouts.rows, BuiltInLayouts.threeRows, BuiltInLayouts.quarters])
        let layout = Layout(name: "Rows", root: BuiltInLayouts.threeRows.root, inset: 0, gap: 0)
        let zones = try LayoutGeometry.zones(for: layout, in: CGRect(x: 0, y: 0, width: 900, height: 1500), scale: 2)
        #expect(zones.map(\.frame.minY) == [1000, 500, 0])
        #expect(zones.map(\.frame.height) == [500, 500, 500])
    }

    @Test func newPresetsHaveRequestedAreasAndReadingOrder() throws {
        let area = CGRect(x: 0, y: 0, width: 1600, height: 800)
        func frames(_ preset: Layout) throws -> [CGRect] {
            try LayoutGeometry.zones(for: Layout(name: preset.name, root: preset.root, inset: 0, gap: 0),
                                     in: area, scale: 2).map(\.frame)
        }
        #expect(try frames(BuiltInLayouts.leftHalfRightStack) == [CGRect(x: 0, y: 0, width: 800, height: 800),
            CGRect(x: 800, y: 400, width: 800, height: 400), CGRect(x: 800, y: 0, width: 800, height: 400)])
        let wide = Layout(name: "Wide", root: BuiltInLayouts.twoThirdsLeft.root, inset: 0, gap: 0)
        #expect(try LayoutGeometry.zones(for: wide, in: CGRect(x: 0, y: 0, width: 1800, height: 900), scale: 2).map(\.frame.width) == [1200, 600])
        #expect(try frames(BuiltInLayouts.wideLeft).map(\.width) == [1200, 400])
        #expect(try frames(BuiltInLayouts.rows) == [CGRect(x: 0, y: 400, width: 1600, height: 400),
                                                 CGRect(x: 0, y: 0, width: 1600, height: 400)])
        #expect(try frames(BuiltInLayouts.quarters) == [CGRect(x: 0, y: 400, width: 800, height: 400),
            CGRect(x: 800, y: 400, width: 800, height: 400), CGRect(x: 0, y: 0, width: 800, height: 400),
            CGRect(x: 800, y: 0, width: 800, height: 400)])
    }

    @Test func focusedPresetHasQuarterHalfQuarterWithoutGaps() throws {
        let layout = Layout(id: BuiltInLayouts.focused.id, name: "Focus", root: BuiltInLayouts.focused.root,
                            inset: 0, gap: 0)
        let zones = try LayoutGeometry.zones(for: layout, in: CGRect(x: 0, y: 0, width: 1600, height: 900), scale: 2)
        #expect(zones.map { $0.frame.width } == [400, 800, 400])
        let stacked = try LayoutGeometry.zones(for: BuiltInLayouts.focusedWithStack,
                                              in: CGRect(x: 0, y: 0, width: 1600, height: 900), scale: 2)
        #expect(stacked[2].frame.minX == stacked[3].frame.minX)
        #expect(stacked[2].frame.minY - stacked[3].frame.maxY == 8)
    }

    @Test func descendantGapsDoNotDistortPresetProportions() throws {
        for gap: CGFloat in [0, 8, 32] {
            for scale: CGFloat in [1, 1.25, 1.5, 2] {
                let area = CGRect(x: 0, y: 0, width: 1440, height: 900)
                let layout = Layout(name: "Focus", root: BuiltInLayouts.focused.root, gap: gap)
                let zones = try LayoutGeometry.zones(for: layout, in: area, scale: scale)
                let usable = 1440 - 16 - 2 * gap
                for (zone, ratio) in zip(zones, [0.25, 0.5, 0.25]) {
                    #expect(abs(zone.frame.width - usable * ratio) <= 1 / scale + 0.000001)
                }
                #expect(abs(zones[0].frame.width - zones[2].frame.width) <= 1 / scale + 0.000001)
                let thirds = try LayoutGeometry.zones(for: Layout(name: "Thirds", root: BuiltInLayouts.thirds.root, gap: gap),
                                                     in: area, scale: scale)
                let widths = thirds.map { $0.frame.width }
                #expect(widths.max()! - widths.min()! <= 1 / scale + 0.000001)
            }
        }
        let exact = try LayoutGeometry.zones(for: BuiltInLayouts.focused,
                                             in: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
        #expect(exact.map { $0.frame.width } == [352, 704, 352])
    }
}
