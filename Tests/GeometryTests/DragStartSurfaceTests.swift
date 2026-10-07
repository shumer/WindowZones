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

    @Test func acceptsPassiveWebTitleButNotWebContent() {
        for role in ["AXGroup", "AXWebArea"] {
            #expect(DragStartSurface.contains(CGPoint(x: 600, y: 120), window: window, role: role, toolbar: nil))
            #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 145), window: window, role: role, toolbar: nil))
            #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 300), window: window, role: role, toolbar: nil))
            #expect(!DragStartSurface.contains(CGPoint(x: 101, y: 120), window: window, role: role, toolbar: nil))
        }
    }

    @Test func traversesWebScrollContainerWithoutAcceptingItsContent() {
        #expect(DragStartSurface.allowsAncestorTraversal("AXScrollArea"))
        #expect(!DragStartSurface.allowsTraversal("AXScrollArea"))
        #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 125), window: window, role: "AXScrollArea", toolbar: toolbar))
        for role in ["AXTab", "AXRadioButton", "AXButton", "AXTextField"] {
            #expect(!DragStartSurface.allowsAncestorTraversal(role))
        }
    }

    @Test func acceptsOnlyProvenGapsInTabStrip() {
        let strip = CGRect(x: 100, y: 100, width: 1200, height: 44)
        let children = [CGRect(x: 180, y: 100, width: 200, height: 44),
                        CGRect(x: 390, y: 100, width: 30, height: 44)]
        #expect(DragStartSurface.isEmptyTabStrip(CGPoint(x: 600, y: 125), strip: strip, children: children))
        #expect(!DragStartSurface.isEmptyTabStrip(CGPoint(x: 200, y: 125), strip: strip, children: children))
        #expect(!DragStartSurface.isEmptyTabStrip(CGPoint(x: 400, y: 125), strip: strip, children: children))
        #expect(!DragStartSurface.isEmptyTabStrip(CGPoint(x: 600, y: 160), strip: strip, children: children))
        #expect(DragStartSurface.contains(CGPoint(x: 600, y: 135), window: window, role: "AXTabGroup", toolbar: nil, emptyTabStrip: true))
        #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 135), window: window, role: "AXTabGroup", toolbar: toolbar))
        #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 180), window: window, role: "AXTabGroup", toolbar: toolbar, emptyTabStrip: true))
    }

    @Test func rejectsControlsContentTabsAndResizeEdges() {
        for role in ["AXButton", "AXTextField", "AXSearchField", "AXTab", "AXRadioButton", "AXImage", "AXRow"] {
            #expect(!DragStartSurface.allowsTraversal(role))
            #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 125), window: window, role: role, toolbar: toolbar))
        }
        #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 180), window: window, role: "AXGroup", toolbar: toolbar))
        #expect(!DragStartSurface.contains(CGPoint(x: 600, y: 145), window: window, role: "AXGroup", toolbar: nil))
        #expect(!DragStartSurface.contains(CGPoint(x: 1299, y: 120), window: window, role: "AXToolbar", toolbar: toolbar))
    }
}
