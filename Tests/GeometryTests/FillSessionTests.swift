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
