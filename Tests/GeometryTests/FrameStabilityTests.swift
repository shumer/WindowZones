import CoreGraphics
import Testing
@testable import Geometry

struct FrameStabilityTests {
    let frame = CGRect(x: 8, y: 38, width: 1268, height: 1304)

    @Test func shortPlateauDoesNotFinishAnimation() {
        var state = FrameStability()
        let observed0 = state.observe(frame, at: 0)
        #expect(!observed0)
        let observed1 = state.observe(frame, at: 0.025)
        #expect(!observed1)
        let observed2 = state.observe(frame, at: 0.05)
        #expect(!observed2)
        let observed3 = state.observe(frame, at: 0.101)
        #expect(observed3)
    }

    @Test func movementRestartsQuietInterval() {
        var state = FrameStability()
        let observed4 = state.observe(frame, at: 0)
        #expect(!observed4)
        let moved = frame.offsetBy(dx: 2, dy: 0)
        let observed5 = state.observe(moved, at: 0.075)
        #expect(!observed5)
        let observed6 = state.observe(moved, at: 0.15)
        #expect(!observed6)
        let observed7 = state.observe(moved, at: 0.18)
        #expect(observed7)
    }

    @Test func smallStepsCannotAccumulateIntoFalseStability() {
        var state = FrameStability()
        let observed8 = state.observe(frame, at: 0)
        #expect(!observed8)
        let observed9 = state.observe(frame.offsetBy(dx: 0.4, dy: 0), at: 0.05)
        #expect(!observed9)
        let observed10 = state.observe(frame.offsetBy(dx: 0.8, dy: 0), at: 0.1)
        #expect(!observed10)
        let observed11 = state.observe(frame.offsetBy(dx: 1.2, dy: 0), at: 0.15)
        #expect(!observed11)
    }

    @Test func invalidInputAndReversedClockResetEvidence() {
        var state = FrameStability()
        let observed12 = state.observe(frame, at: 1)
        #expect(!observed12)
        let observed13 = state.observe(frame, at: 0)
        #expect(!observed13)
        let observed14 = state.observe(.zero, at: 0.2)
        #expect(!observed14)
        let observed15 = state.observe(frame, at: 0.3)
        #expect(!observed15)
        let observed16 = state.observe(frame, at: .nan)
        #expect(!observed16)
        let observed17 = state.observe(frame, at: 0.5)
        #expect(!observed17)
        let observed18 = state.observe(frame, at: 0.61)
        #expect(observed18)
    }
}
