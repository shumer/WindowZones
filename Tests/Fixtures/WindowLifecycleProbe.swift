import AppKit

// A disposable window for delayed lifecycle checks without touching user documents.
@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "Choose a delayed action, then open the zone picker.")

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 150, y: 200, width: 900, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "WindowZones Lifecycle Probe"
        window.isReleasedWhenClosed = false
        let stack = NSStackView(views: [
            status,
            NSButton(title: "Close in 8 seconds", target: self, action: #selector(closeLater)),
            NSButton(title: "Minimize in 8 seconds", target: self, action: #selector(minimizeLater))
        ])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
        window.contentView = stack
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func closeLater() {
        status.stringValue = "The test window will close in 8 seconds."
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.window.close() }
    }

    @objc private func minimizeLater() {
        status.stringValue = "The test window will minimize in 8 seconds."
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.window.miniaturize(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

@main struct ProbeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let applicationMenu = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Lifecycle Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationMenu.submenu = submenu
        menu.addItem(applicationMenu)
        app.mainMenu = menu
        app.run()
    }
}
