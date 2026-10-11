import AppKit

@MainActor final class KeyboardButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override func keyDown(with event: NSEvent) {
        if [36, 76, 49].contains(event.keyCode), isEnabled { performClick(nil) }
        else { super.keyDown(with: event) }
    }
}

@MainActor final class SettingsWindow: NSWindow {
    weak var tabs: NSTabView?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, event.keyCode == 48, attachedSheet == nil, let tabs else {
            super.sendEvent(event)
            return
        }
        let backwards = event.modifierFlags.contains(.shift)
        if event.modifierFlags.contains(.control) {
            let index = tabs.indexOfTabViewItem(tabs.selectedTabViewItem!)
            tabs.selectTabViewItem(at: (index + (backwards ? -1 : 1) + tabs.numberOfTabViewItems) % tabs.numberOfTabViewItems)
            makeFirstResponder(self)
            return
        }
        func controls(in view: NSView) -> [NSControl] {
            guard !view.isHiddenOrHasHiddenAncestor else { return [] }
            if let control = view as? NSControl, control.isEnabled,
               control is NSButton || control is NSPopUpButton { return [control] }
            return view.subviews.flatMap { controls(in: $0) }
        }
        guard let view = tabs.selectedTabViewItem?.view else { return }
        let available = controls(in: view)
        guard !available.isEmpty else { return }
        let current = available.firstIndex { $0 === firstResponder }
        let next = current.map { ($0 + (backwards ? -1 : 1) + available.count) % available.count }
            ?? (backwards ? available.count - 1 : 0)
        makeFirstResponder(available[next])
    }
}
