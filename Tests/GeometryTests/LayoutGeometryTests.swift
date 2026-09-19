import CoreGraphics
import Foundation
import Testing
@testable import Geometry

struct LayoutGeometryTests {
    private func leaf(_ name: String = "Zone") -> LayoutNode {
        .zone(id: UUID(), name: name)
    }

    private func balancedTree(leaves: Int) -> LayoutNode {
        guard leaves > 1 else { return leaf() }
        let firstCount = leaves / 2
        return .split(axis: .vertical, ratio: 0.5,
                      first: balancedTree(leaves: firstCount),
                      second: balancedTree(leaves: leaves - firstCount))
    }

    @Test func halvesSharePixelAlignedBoundariesWithoutLosingWidth() throws {
        let layout = Layout(name: "Halves", root: .split(axis: .vertical, ratio: 0.5,
                            first: leaf("Left"), second: leaf("Right")))
        let area = CGRect(x: 0, y: 0, width: 1001, height: 800)
        let zones = try LayoutGeometry.zones(for: layout, in: area, scale: 2)
        #expect(zones.count == 2)
        #expect(zones[0].frame == CGRect(x: 8, y: 8, width: 488.5, height: 784))
        #expect(zones[1].frame == CGRect(x: 504.5, y: 8, width: 488.5, height: 784))
        #expect(zones[0].frame.width + zones[1].frame.width + 8 + 16 == area.width)
    }

    @Test func horizontalFirstChildOccupiesTopInAppKitCoordinates() throws {
        let layout = Layout(name: "Rows", root: .split(axis: .horizontal, ratio: 0.25,
                            first: leaf("Top"), second: leaf("Bottom")))
        let zones = try LayoutGeometry.zones(for: layout,
                                            in: CGRect(x: -900, y: -300, width: 800, height: 824), scale: 1)
        #expect(zones.map(\.name) == ["Top", "Bottom"])
        #expect(zones[0].frame == CGRect(x: -892, y: 316, width: 784, height: 200))
        #expect(zones[1].frame == CGRect(x: -892, y: -292, width: 784, height: 600))
        #expect(zones[0].frame.minY - zones[1].frame.maxY == 8)
    }

    @Test func nestedSplitsConserveUsableAreaAcrossScalesAndNegativeOrigins() throws {
        let layout = Layout(name: "Nested", root: .split(axis: .vertical, ratio: 0.37,
                            first: leaf("Left"), second: .split(axis: .horizontal, ratio: 0.61,
                            first: leaf("Top right"), second: leaf("Bottom right"))), inset: 7.25, gap: 7.25)
        let area = CGRect(x: -1511.3, y: -982.7, width: 1440.6, height: 900.9)
        for scale: CGFloat in [1, 1.5, 2, 3] {
            let zones = try LayoutGeometry.zones(for: layout, in: area, scale: scale)
            let left = zones[0].frame
            let top = zones[1].frame
            let bottom = zones[2].frame
            let expectedMinX = ceil((area.minX + layout.inset) * scale) / scale
            let expectedMaxX = floor((area.maxX - layout.inset) * scale) / scale
            let expectedMinY = ceil((area.minY + layout.inset) * scale) / scale
            let expectedMaxY = floor((area.maxY - layout.inset) * scale) / scale
            #expect(abs(left.minX - expectedMinX) < 0.000001)
            #expect(abs(top.maxX - expectedMaxX) < 0.000001)
            #expect(abs(bottom.minY - expectedMinY) < 0.000001)
            #expect(abs(top.maxY - expectedMaxY) < 0.000001)
            #expect(top.minX == bottom.minX)
            #expect(top.width == bottom.width)
            let verticalGap = top.minX - left.maxX
            let horizontalGap = top.minY - bottom.maxY
            #expect(abs(verticalGap - layout.gap) <= 1 / scale)
            #expect(abs(horizontalGap - layout.gap) <= 1 / scale)
            let coveredArea = zones.reduce(CGFloat.zero) { $0 + $1.frame.width * $1.frame.height }
            let gapArea = verticalGap * left.height + horizontalGap * top.width
            let insetArea = (expectedMaxX - expectedMinX) * (expectedMaxY - expectedMinY)
            #expect(abs(coveredArea + gapArea - insetArea) < 0.000001)
            for (index, zone) in zones.enumerated() {
                #expect(area.contains(zone.frame))
                for edge in [zone.frame.minX, zone.frame.maxX, zone.frame.minY, zone.frame.maxY] {
                    #expect(abs(edge * scale - (edge * scale).rounded()) < 0.000001)
                }
                for other in zones.dropFirst(index + 1) {
                    let intersection = zone.frame.intersection(other.frame)
                    #expect(intersection.isNull || intersection.width == 0 || intersection.height == 0)
                }
            }
        }
    }

    @Test func identitiesAndDepthFirstNumbersSurviveDifferentDisplaySizes() throws {
        let ids = (0..<3).map { _ in UUID() }
        let layout = Layout(name: "Stable", root: .split(axis: .vertical, ratio: 0.5,
                            first: .zone(id: ids[0], name: "A"),
                            second: .split(axis: .horizontal, ratio: 0.5,
                            first: .zone(id: ids[1], name: "B"), second: .zone(id: ids[2], name: "C"))))
        for width: CGFloat in [800, 1440, 3000] {
            let zones = try LayoutGeometry.zones(for: layout,
                                                in: CGRect(x: 0, y: 0, width: width, height: 900), scale: 2)
            #expect(zones.map(\.id) == ids)
            #expect(zones.map(\.name) == ["A", "B", "C"])
            #expect(zones.map(\.index) == [1, 2, 3])
        }
    }

    @Test func duplicateIdentityIsRejectedEvenAcrossSeparateBranches() {
        let id = UUID()
        let layout = Layout(name: "Duplicate", root: .split(axis: .vertical, ratio: 0.5,
                            first: .zone(id: id, name: "A"),
                            second: .split(axis: .horizontal, ratio: 0.5,
                            first: leaf(), second: .zone(id: id, name: "B"))))
        #expect(throws: LayoutError.duplicateZoneID) { try layout.validate() }
    }

    @Test func ratioLimitsRejectNonFiniteValuesAndAcceptInclusiveBounds() throws {
        for ratio in [Double.nan, .infinity, -.infinity, 0, -0.5, 0.0999, 0.9001, 1] {
            let layout = Layout(name: "Invalid", root: .split(axis: .vertical, ratio: ratio,
                                first: leaf(), second: leaf()))
            #expect(throws: LayoutError.invalidRatio) { try layout.validate() }
        }
        for ratio in [0.1, 0.9] {
            try Layout(name: "Valid", root: .split(axis: .horizontal, ratio: ratio,
                       first: leaf(), second: leaf())).validate()
        }
    }

    @Test func spacingLimitsRejectEachInvalidFieldIndependently() throws {
        for spacing: CGFloat in [.nan, .infinity, -.infinity, -0.01, 32.01] {
            #expect(throws: LayoutError.invalidSpacing) {
                try Layout(name: "Invalid inset", root: leaf(), inset: spacing).validate()
            }
            #expect(throws: LayoutError.invalidSpacing) {
                try Layout(name: "Invalid gap", root: leaf(), gap: spacing).validate()
            }
        }
        for spacing: CGFloat in [0, 32] {
            try Layout(name: "Valid", root: leaf(), inset: spacing, gap: spacing).validate()
        }
    }

    @Test func leafAndDepthLimitsBoundTrees() throws {
        try Layout(name: "One", root: leaf()).validate()
        try Layout(name: "Twelve", root: balancedTree(leaves: 12)).validate()
        #expect(throws: LayoutError.tooManyZones) {
            try Layout(name: "Thirteen", root: balancedTree(leaves: 13)).validate()
        }
        var deepestValid = leaf()
        for _ in 0..<11 {
            deepestValid = .split(axis: .vertical, ratio: 0.5, first: leaf(), second: deepestValid)
        }
        try Layout(name: "Depth twelve", root: deepestValid).validate()
        let tooDeep = LayoutNode.split(axis: .vertical, ratio: 0.5, first: leaf(), second: deepestValid)
        #expect(throws: LayoutError.self) {
            try Layout(name: "Depth thirteen", root: tooDeep).validate()
        }
    }

    @Test func minimumSideIsInclusiveAndIncludesInsetAndGapCosts() throws {
        let layout = Layout(name: "Minimum", root: .split(axis: .vertical, ratio: 0.5,
                            first: leaf(), second: leaf()))
        let zones = try LayoutGeometry.zones(for: layout,
                                            in: CGRect(x: 0, y: 0, width: 264, height: 136), scale: 2)
        #expect(zones.allSatisfy { $0.frame.size == CGSize(width: 120, height: 120) })
        for area in [CGRect(x: 0, y: 0, width: 263, height: 136),
                     CGRect(x: 0, y: 0, width: 264, height: 135)] {
            #expect(throws: LayoutError.tooSmall) {
                try LayoutGeometry.zones(for: layout, in: area, scale: 2)
            }
        }
    }

    @Test func failedResolutionDoesNotCorruptLayoutForLargerDisplay() throws {
        let layout = Layout(name: "Preserved", root: .split(axis: .vertical, ratio: 0.1,
                            first: leaf(), second: leaf()))
        let large = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let before = try LayoutGeometry.zones(for: layout, in: large, scale: 2)
        #expect(throws: LayoutError.tooSmall) {
            try LayoutGeometry.zones(for: layout, in: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2)
        }
        let after = try LayoutGeometry.zones(for: layout, in: large, scale: 2)
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.frame) == before.map(\.frame))
    }

    @Test func invalidAreasAndScalesFailBeforeReturningGeometry() {
        let layout = Layout(name: "Single", root: leaf())
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        for scale: CGFloat in [0, -1, .nan, .infinity, .greatestFiniteMagnitude] {
            #expect(throws: LayoutError.self) {
                try LayoutGeometry.zones(for: layout, in: area, scale: scale)
            }
        }
        for invalidArea in [CGRect.zero, CGRect.null, CGRect.infinite,
                            CGRect(x: CGFloat.nan, y: 0, width: 1000, height: 800),
                            CGRect(x: 0, y: 0, width: -1000, height: 800),
                            CGRect(x: 0, y: 0, width: 1000, height: -800),
                            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 800)] {
            #expect(throws: LayoutError.self) {
                try LayoutGeometry.zones(for: layout, in: invalidArea, scale: 2)
            }
        }
    }
}
