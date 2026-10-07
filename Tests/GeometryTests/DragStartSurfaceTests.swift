import CoreGraphics
import Testing
@testable import Geometry

struct DragStartSurfaceTests {
    let window = CGRect(x: 100, y: 100, width: 1200, height: 800)
    let toolbar = CGRect(x: 325, y: 100, width: 975, height: 60)

    @Test func acceptsBothTitleAndPassiveUnifiedToolbar() {
        #expect(DragStartSurface.contains(CGPoint(x: 250, y: 125), window: window, role: "AXWindow", toolbar: nil))
        #expect(DragStartSurface.contains(CGPoint(x: 500, y: 125), window: window, role: "AXStaticText", toolbar: nil))
        #expect(DragStartSurface.contains(CGPoint(x: 600, y: 145), window: window, role: "AXToolbar", toolbar: toolbar))
        #expect(DragStartSurface.contains(CGPoint(x: 600, y: 145), window: window, role: "AXGroup", toolbar: toolbar))
    }

    @Test func rejectsControlsContentTabsAndResizeEdges() {
        for role in ["AXButton", "AXTextField", "AXSearchField", "AXTabGroup", "AXRadioButton", "AXImage", "AXRow"] {
            #expect(!DragStartSurface.allowsTraversal(role))
            #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 125), window: window, role: role, toolbar: toolbar))
        }
        #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 180), window: window, role: "AXGroup", toolbar: toolbar))
        #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 145), window: window, role: "AXGroup", toolbar: nil))
        #expect(!DragStartSurface.contains(CGPoint(x: 1299, y: 120), window: window, role: "AXToolbar", toolbar: toolbar))
    }
}
