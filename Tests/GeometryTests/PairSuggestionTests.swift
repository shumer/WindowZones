import Foundation
import Testing
@testable import Geometry

struct PairSuggestionTests {
    let zones = [CGRect(x: 8, y: 8, width: 700, height: 884), CGRect(x: 716, y: 8, width: 700, height: 884)]
    @Test func alignedNeighborWinsOverRecentWindow() {
        let result = PairSuggestion.choose(frames: [CGRect(x: 100, y: 100, width: 900, height: 600), zones[0]], zones: zones)
        #expect(result?.candidate == 1)
        #expect(result?.neighborZone == 0)
    }
    @Test func recentWindowIsFallbackAndEmptyInputDoesNotSuggest() {
        let result = PairSuggestion.choose(frames: [CGRect(x: 100, y: 100, width: 900, height: 600)], zones: zones)
        #expect(result?.candidate == 0)
        #expect(result?.neighborZone == 1)
        #expect(PairSuggestion.choose(frames: [], zones: zones) == nil)
        #expect(PairSuggestion.choose(frames: zones, zones: []) == nil)
    }
    @Test func reservedNeighborCannotReceiveDropAndOrdinaryHalfRemainsAvailable() {
        let geometry = DragBarGeometry(layouts: [PairSuggestion.layout, BuiltInLayouts.halves],
            area: CGRect(x: 0, y: 0, width: 1512, height: 949), scale: 2, reservedPairZone: 1)
        var interaction = DragBarInteraction()
        for cell in geometry.cells {
            let point = CGPoint(x: cell.frame.midX, y: cell.frame.midY)
            interaction.update(pointer: CGPoint(x: geometry.activation.midX, y: geometry.activation.midY), screen: 1, geometry: geometry)
            interaction.update(pointer: point, screen: 1, geometry: geometry)
            let blocked = cell.layoutID == PairSuggestion.layoutID && cell.zoneIndex == 1
            #expect((interaction.selected == nil) == blocked)
            #expect((interaction.drop(at: point, screen: 1, geometry: geometry) == nil) == blocked)
        }
    }
}
