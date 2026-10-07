import CoreGraphics

public enum DragStartSurface {
    public static func allowsTraversal(_ role: String) -> Bool {
        ["AXWindow", "AXTitleBar", "AXToolbar", "AXGroup", "AXStaticText"].contains(role)
    }

    public static func contains(_ point: CGPoint, window: CGRect, role: String, toolbar: CGRect?) -> Bool {
        guard allowsTraversal(role) else { return false }
        let title = CGRect(x: window.minX + 16, y: window.minY + 5,
                           width: max(0, window.width - 32), height: 27)
        if ["AXWindow", "AXTitleBar", "AXStaticText"].contains(role), title.contains(point) { return true }
        guard let toolbar else { return false }
        // Restrict unified toolbars to the top of the window, excluding content and resize edges.
        let header = CGRect(x: window.minX + 16, y: window.minY + 5,
                            width: max(0, window.width - 32), height: 59)
        return toolbar.intersection(header).contains(point)
    }
}
