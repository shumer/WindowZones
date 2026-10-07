import Testing
@testable import Geometry

struct FillSessionTests {
    @Test func selectionAndSkipNeverRevisitOccupiedZones() {
        var session = FillSession(count: 4, occupied: [0])
        #expect(session.selected == 1)
        session.select(3)
        session.advance()
        #expect(session.remaining == [1, 2])
        session.select(0)
        #expect(session.selected == 1)
        session.advance()
        session.advance()
        #expect(session.selected == nil)
        #expect(session.remaining.isEmpty)
    }

    @Test func fullyOccupiedAndInvalidCountHaveNoSelection() {
        #expect(FillSession(count: 2, occupied: [0, 1]).selected == nil)
        #expect(FillSession(count: -1, occupied: []).remaining.isEmpty)
    }
}

import Foundation

struct FillRefreshTests {
    @Test func refreshPreservesSelectionAndSkipButReopensVacatedZone() {
        var session = FillSession(count: 4, occupied: [0])
        session.select(2)
        session.advance()
        session.select(3)
        session.reconcile(occupied: [1])
        #expect(session.remaining == [0, 3])
        #expect(session.selected == 3)
        session.reconcile(occupied: [1, 3])
        #expect(session.selected == 0)
    }

    @Test func roundedWindowReservesIntrudedNeighbour() {
        let target = CGRect(x: 8, y: 38, width: 1268, height: 652)
        let actual = CGRect(x: 8, y: 38, width: 1267, height: 662)
        let below = CGRect(x: 8, y: 698, width: 1268, height: 652)
        #expect(FillSession.accepts(actual: actual, target: target))
        #expect(FillSession.occupied(zones: [target, below], frames: [actual]) == [0, 1])
        #expect(!FillSession.accepts(actual: actual.insetBy(dx: -50, dy: 0), target: target))
        #expect(FillSession.occupied(zones: [target, below], frames: []) == [])
    }
}


struct FillPresentationTests {
    @Test func panelUsesFreeHalfOnTargetDisplay() {
        let area = CGRect(x: 2560, y: 30, width: 2560, height: 1328)
        let left = CGRect(x: 2568, y: 38, width: 1268, height: 1312)
        let size = CGSize(width: 720, height: 728)
        let origin = FillSession.panelOrigin(size: size, anchor: left, available: area)
        #expect(origin.x == left.midX - 360)
        #expect(origin.y == left.midY - 364)
        #expect(area.contains(CGRect(origin: origin, size: size)))
    }

    @Test func panelClampsToNegativeOriginRetinaDisplay() {
        let area = CGRect(x: -1512, y: 458, width: 1512, height: 949)
        let quarter = CGRect(x: -1504, y: 940, width: 744, height: 459)
        let size = CGSize(width: 720, height: 728)
        let origin = FillSession.panelOrigin(size: size, anchor: quarter, available: area)
        #expect(area.contains(CGRect(origin: origin, size: size)))
        #expect(origin.y == area.maxY - size.height)
    }
}
