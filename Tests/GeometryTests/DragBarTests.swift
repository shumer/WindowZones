import Foundation
import Testing
@testable import Geometry

struct DragBarTests {
    let area = CGRect(x: -1512, y: 458, width: 1512, height: 949)

    @Test func dropRequiresExpansionAndCurrentHit() {
        let geometry = DragBarGeometry(layouts: [BuiltInLayouts.halves], area: area, scale: 2)
        let cell = geometry.cells[0]
        let point = CGPoint(x: cell.frame.midX, y: cell.frame.midY)
        var interaction = DragBarInteraction()
        #expect(interaction.drop(at: point, screen: 1, geometry: geometry) == nil)
        interaction.update(pointer: point, screen: 1, geometry: geometry)
        #expect(interaction.selected == cell)
        #expect(interaction.drop(at: point, screen: 1, geometry: geometry) == cell)
        #expect(interaction.drop(at: CGPoint(x: area.minX, y: area.minY), screen: 1, geometry: geometry) == nil)
        #expect(interaction.drop(at: point, screen: 2, geometry: geometry) == nil)
        interaction.cancel()
        interaction.update(pointer: point, screen: 1, geometry: geometry)
        #expect(interaction.selected == nil)
        #expect(interaction.drop(at: point, screen: 1, geometry: geometry) == nil)
    }

    @Test func screenChangeAndLeavingStripClearSelection() {
        let geometry = DragBarGeometry(layouts: [BuiltInLayouts.halves], area: area, scale: 2)
        let point = CGPoint(x: geometry.cells[0].frame.midX, y: geometry.cells[0].frame.midY)
        var interaction = DragBarInteraction()
        interaction.update(pointer: point, screen: 1, geometry: geometry)
        interaction.update(pointer: CGPoint(x: area.midX, y: area.minY), screen: 2, geometry: geometry)
        #expect(!interaction.expanded)
        #expect(interaction.selected == nil)
    }

    @Test func miniatureTargetsMatchRealGeometryAcrossScales() throws {
        for scale in [CGFloat(1), 2] {
            let layout = BuiltInLayouts.halves
            let geometry = DragBarGeometry(layouts: [layout], area: area, scale: scale)
            let zones = try LayoutGeometry.zones(for: layout, in: area, scale: scale)
            #expect(geometry.cells.map(\.target) == zones.map(\.frame))
            #expect(geometry.frame.maxY < area.maxY)
            #expect(geometry.cells.allSatisfy { geometry.frame.contains($0.frame) })
            #expect(!geometry.cells[0].frame.intersects(geometry.cells[1].frame))
        }
    }
}
