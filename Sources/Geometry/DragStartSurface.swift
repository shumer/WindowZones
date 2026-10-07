import CoreGraphics

public enum DragStartSurface {
    public static func isEmptyTabStrip(_ point: CGPoint, strip: CGRect, children: [CGRect]) -> Bool {
        strip.contains(point) && !children.contains { $0.contains(point) }
    }

    public static func allowsTraversal(_ role: String) -> Bool {
        ["AXWindow", "AXTitleBar", "AXToolbar", "AXGroup", "AXStaticText", "AXWebArea", "AXTabGroup"].contains(role)
    }

    public static func allowsAncestorTraversal(_ role: String) -> Bool {
        allowsTraversal(role) || role == "AXScrollArea"
    }

    public static func contains(_ point: CGPoint, window: CGRect, role: String, toolbar: CGRect?, emptyTabStrip: Bool = false) -> Bool {
        guard allowsTraversal(role) else { return false }
        if role == "AXTabGroup" {
            let strip = CGRect(x: window.minX + 16, y: window.minY + 5,
                               width: max(0, window.width - 32), height: 43)
            return emptyTabStrip && strip.contains(point)
        }
        let title = CGRect(x: window.minX + 16, y: window.minY + 5,
                           width: max(0, window.width - 32), height: 27)
        if ["AXWindow", "AXTitleBar", "AXStaticText", "AXGroup", "AXWebArea"].contains(role), title.contains(point) { return true }
        guard let toolbar else { return false }
        // Restrict unified toolbars to the top of the window, excluding content and resize edges.
        let header = CGRect(x: window.minX + 16, y: window.minY + 5,
                            width: max(0, window.width - 32), height: 59)
        return toolbar.intersection(header).contains(point)
    }
}
