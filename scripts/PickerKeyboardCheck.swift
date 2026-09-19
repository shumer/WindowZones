import AppKit
import Geometry

@main struct PickerKeyboardCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = PickerWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 420),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        let content = ZonePickerContent(applicationName: "Keyboard check")
        window.contentView = content
        content.displayPopup.addItem(withTitle: "Display")
        content.updateDisplay(area: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
        content.select(layoutID: BuiltInLayouts.halves.id, index: 0,
                       availableLayoutIDs: Set(BuiltInLayouts.all.map(\.id)))
        var chosen = 0
        var cancelled = 0
        var previews = 0
        content.choose = { _, _ in chosen += 1 }
        content.preview = { _, _ in previews += 1 }
        content.cancel = { cancelled += 1 }
        window.cancel = { cancelled += 1 }
        window.choose = { _ in chosen += 1 }
        func send(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ characters: String = "\t") {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: code)!
            window.sendEvent(event)
        }
        func zones(in view: NSView) -> [ZoneChoiceButton] {
            view.subviews.flatMap { subview -> [ZoneChoiceButton] in
                if let button = subview as? ZoneChoiceButton { return [button] }
                return zones(in: subview)
            }
        }
        let buttons = zones(in: content)
        precondition(buttons.count == 12)
        window.makeFirstResponder(window)
        send(48)
        precondition(window.firstResponder === content.displayPopup)
        for button in buttons {
            send(48)
            precondition(window.firstResponder === button)
        }
        send(48)
        let cancel = window.firstResponder as! NSButton
        precondition(cancel.title == "Отмена")
        send(48)
        precondition(window.firstResponder === content.displayPopup)
        send(48, .shift)
        precondition(window.firstResponder === cancel)
        for button in buttons.reversed() {
            send(48, .shift)
            precondition(window.firstResponder === button)
        }
        precondition(chosen == 0 && cancelled == 0 && previews == 24)
        send(36, [], "\r")
        send(49, [], " ")
        precondition(chosen == 2)
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            send(36, modifier, "\r")
            send(49, modifier, " ")
            precondition(chosen == 2 && cancelled == 0)
        }
        window.makeFirstResponder(cancel)
        send(36, [], "\r")
        send(49, [], " ")
        precondition(cancelled == 2 && chosen == 2)
        content.displayPopup.isHidden = true
        buttons[0].isEnabled = false
        buttons[1].isHidden = true
        window.makeFirstResponder(window)
        send(48)
        precondition(window.firstResponder === buttons[2])
        send(48, .shift)
        precondition(window.firstResponder === cancel)
        window.makeFirstResponder(window)
        send(48, .shift)
        precondition(window.firstResponder === cancel)
        content.select(layoutID: BuiltInLayouts.halves.id, index: 0, availableLayoutIDs: [])
        send(48)
        precondition(window.firstResponder === cancel)
        send(48, .shift)
        precondition(window.firstResponder === cancel)
        send(53, [], "\u{1b}")
        precondition(cancelled == 3 && chosen == 2)
        print("Picker keyboard checks passed: forward/reverse traversal, wrap, initial focus, hidden/disabled controls, preview-only Tab, Enter/Space and Escape.")
    }
}
