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
