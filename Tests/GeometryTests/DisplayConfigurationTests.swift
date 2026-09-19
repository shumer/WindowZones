import CoreGraphics
import Testing
@testable import Geometry

struct DisplayConfigurationTests {
    private func display(id: UInt32 = 1, x: CGFloat = 0, scale: CGFloat = 2,
                         primaryTop: CGFloat = 982, visibleShift: CGFloat = 0) -> DisplayGeometry {
        DisplayGeometry(id: id, frame: CGRect(x: x, y: 0, width: 1512, height: 982),
                        visible: CGRect(x: x, y: 52 + visibleShift, width: 1512, height: 897 - visibleShift),
                        scale: scale, primaryTop: primaryTop)
    }

    @Test func duplicateNotificationsAndScreenOrderAreHarmless() {
        let first = display()
        let second = display(id: 2, x: -1512, scale: 1)
        #expect(DisplayConfiguration.compatible([first, second], [second, first]))
        #expect(DisplayConfiguration.compatible([first], [first]))
    }

    @Test func visibleJitterDoesNotAccumulateAgainstSessionSnapshot() {
        let original = display()
        #expect(DisplayConfiguration.compatible([original], [display(visibleShift: 1)]))
        #expect(DisplayConfiguration.compatible([original], [display(visibleShift: -1)]))
        #expect(!DisplayConfiguration.compatible([original], [display(visibleShift: 2)]))
        #expect(!DisplayConfiguration.compatible([original], [display(visibleShift: 48)]))
    }

    @Test func physicalAndCoordinateChangesInvalidateSession() {
        for changed in [display(id: 2), display(x: 1), display(scale: 1), display(primaryTop: 1080)] {
            #expect(!DisplayConfiguration.compatible([display()], [changed]))
        }
        let resized = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      visible: display().visible, scale: 2, primaryTop: 982)
        #expect(!DisplayConfiguration.compatible([display()], [resized]))
        #expect(!DisplayConfiguration.compatible([display()], []))
        #expect(!DisplayConfiguration.compatible([display()], [display(), display(id: 2)]))
    }

    @Test func visibleEdgesAreComparedRatherThanOnlyOriginAndSize() {
        let before = display()
        let after = DisplayGeometry(id: 1, frame: before.frame,
                                   visible: CGRect(x: 1, y: 52, width: 1513, height: 897),
                                   scale: 2, primaryTop: 982)
        #expect(!DisplayConfiguration.compatible([before], [after]))
    }

    @Test func ambiguousDisplaysAndInvalidToleranceAreRejected() {
        #expect(!DisplayConfiguration.compatible([], []))
        #expect(!DisplayConfiguration.compatible([display(), display()], [display(), display()]))
        for tolerance: CGFloat in [-1, .nan, .infinity] {
            #expect(!DisplayConfiguration.compatible([display()], [display()], visibleTolerance: tolerance))
        }
    }
}
