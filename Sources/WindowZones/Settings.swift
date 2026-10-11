import AppKit
import ApplicationServices
import ServiceManagement
import Sparkle
import LayoutStorage
import UniformTypeIdentifiers

@MainActor final class ApplicationSettings: NSObject {
    var onChange: (() -> Void)?
    var shortcutStatus: (() -> String)?
    private let preferences = Preferences()
    private var window: NSWindow?
    private var login = KeyboardButton()
    private var automatic = KeyboardButton()
    private var fill = KeyboardButton()
    private var drag = KeyboardButton()
    private var shortcut = NSPopUpButton()
    private var modifier = NSPopUpButton()
    private var shortcutMessage = NSTextField(wrappingLabelWithString: "")
    private var exclusions = NSPopUpButton()
    private var removeExclusion = KeyboardButton()
    private var message = NSTextField(wrappingLabelWithString: "")
    private var permission = NSTextField(wrappingLabelWithString: "")
    private var capturePermission = NSTextField(wrappingLabelWithString: "")
    private var updater: SPUStandardUpdaterController?
    private var updaterError: String?

    override init() {
        super.init()
        let info = Bundle.main.infoDictionary ?? [:]
        if let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), url.scheme == "https",
           let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 {
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            do { try controller.updater.start(); updater = controller }
            catch { updaterError = L("Could not start the updater.") }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func show() {
        if window == nil { makeWindow() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func checkForUpdates() {
        guard let updater else {
            show()
            message.stringValue = updaterError ?? L("Updates are unavailable in this build.")
            return
        }
        updater.checkForUpdates(nil)
    }

    private func stack() -> NSStackView {
        let view = NSStackView()
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 16
        view.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return view
    }

    private func label(_ text: String) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: L(text))
        view.widthAnchor.constraint(equalToConstant: 490).isActive = true
        return view
    }

    private func row(_ title: String, control: NSView) -> NSStackView {
        let view = NSStackView()
        view.spacing = 16
        let caption = NSTextField(wrappingLabelWithString: L(title))
        caption.widthAnchor.constraint(equalToConstant: 210).isActive = true
        control.setAccessibilityLabel(L(title))
        view.addArrangedSubview(caption)
        view.addArrangedSubview(control)
        return view
    }

    private func makeWindow() {
        let panel = SettingsWindow(contentRect: CGRect(x: 0, y: 0, width: 570, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = L("WindowZones Settings")
        panel.isReleasedWhenClosed = false
        let tabs = NSTabView()
        panel.tabs = tabs
        func add(_ name: String, _ body: NSStackView) {
            let tab = NSTabViewItem(identifier: name)
            tab.label = L(name)
            tab.view = body
            tabs.addTabViewItem(tab)
        }
        let general = stack()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let title = NSTextField(labelWithString: "WindowZones \(version)")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        general.addArrangedSubview(title)
        general.addArrangedSubview(label("Keyboard: Tab moves between controls; Control-Tab changes tabs."))
        general.addArrangedSubview(label("Drag a window upwards to choose a layout. Only the window you choose is moved."))
        login = KeyboardButton(checkboxWithTitle: L("Launch at login"), target: self, action: #selector(changeLogin))
        automatic = KeyboardButton(checkboxWithTitle: L("Check for updates automatically"), target: self, action: #selector(changeAutomaticUpdates))
        fill = KeyboardButton(checkboxWithTitle: L("Suggest windows for remaining zones"), target: self, action: #selector(changeFill))
        [login, automatic, fill].forEach { general.addArrangedSubview($0) }
        general.addArrangedSubview(KeyboardButton(title: L("Check for Updates…"), target: self, action: #selector(checkForUpdates)))
        message = label("")
        message.textColor = .secondaryLabelColor
        general.addArrangedSubview(message)
        add("General", general)

        let controls = stack()
        drag = KeyboardButton(checkboxWithTitle: L("Enable window dragging"), target: self, action: #selector(changeControls))
        controls.addArrangedSubview(drag)
        shortcut.addItems(withTitles: ["Control + Option + Space", "Control + Shift + Space"])
        shortcut.target = self
        shortcut.action = #selector(changeControls)
        controls.addArrangedSubview(row("Open zone picker", control: shortcut))
        modifier.addItems(withTitles: ["Shift", "Option", "Control"])
        modifier.target = self
        modifier.action = #selector(changeControls)
        controls.addArrangedSubview(row("Show zones while dragging", control: modifier))
        controls.addArrangedSubview(label("The top layout bar works without a modifier. Release the modifier or press Escape to cancel zone snapping."))
        shortcutMessage = label("")
        controls.addArrangedSubview(shortcutMessage)
        controls.addArrangedSubview(label("Undo the last placement from the menu bar. Pausing dragging does not disable the keyboard picker."))
        add("Controls", controls)

        let excluded = stack()
        excluded.addArrangedSubview(label("Excluded apps are ignored by dragging, the zone picker and window suggestions. Undo remains available."))
        exclusions.setAccessibilityLabel(L("Excluded applications"))
        exclusions.target = self
        exclusions.action = #selector(selectExclusion)
        exclusions.widthAnchor.constraint(equalToConstant: 490).isActive = true
        excluded.addArrangedSubview(exclusions)
        let buttons = NSStackView()
        buttons.addArrangedSubview(KeyboardButton(title: L("Add Application…"), target: self, action: #selector(addExclusion)))
        removeExclusion = KeyboardButton(title: L("Remove"), target: self, action: #selector(deleteExclusion))
        buttons.addArrangedSubview(removeExclusion)
        excluded.addArrangedSubview(buttons)
        excluded.addArrangedSubview(label("Settings are saved immediately. Adding an exclusion does not move or close any windows."))
        add("Exclusions", excluded)

        let permissions = stack()
        permissions.addArrangedSubview(label("1. Allow Accessibility so WindowZones can move and resize the window you select. Settings remain available without it."))
        permission = label("")
        permissions.addArrangedSubview(permission)
        permissions.addArrangedSubview(KeyboardButton(title: L("Open Accessibility Settings"), target: self, action: #selector(openPermissions)))
        permissions.addArrangedSubview(label("2. Screen recording is optional. It enables window previews; without it, suggestions use app icons. Previews stay in memory and are not saved or uploaded."))
        capturePermission = label("")
        permissions.addArrangedSubview(capturePermission)
        permissions.addArrangedSubview(KeyboardButton(title: L("Open Screen Recording Settings"), target: self, action: #selector(openCapturePermissions)))
        permissions.addArrangedSubview(KeyboardButton(title: L("Refresh Status"), target: self, action: #selector(refresh)))
        add("Permissions", permissions)
        if !AXIsProcessTrusted() { tabs.selectTabViewItem(at: 3) }
        panel.contentView = tabs
        panel.center()
        window = panel
    }

    @objc private func refresh() {
        guard window != nil else { return }
        fill.state = preferences.fillEnabled ? .on : .off
        drag.state = preferences.dragEnabled ? .on : .off
        shortcut.selectItem(at: preferences.shortcut == .controlOptionSpace ? 0 : 1)
        modifier.selectItem(at: Preferences.DragModifier.allCases.firstIndex(of: preferences.dragModifier) ?? 0)
        shortcutMessage.stringValue = shortcutStatus?() ?? ""
        exclusions.removeAllItems()
        for id in preferences.excludedBundleIDs.sorted() { exclusions.addItem(withTitle: id) }
        removeExclusion.isEnabled = !preferences.excludedBundleIDs.isEmpty
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        automatic.isEnabled = updater != nil
        automatic.state = updater?.updater.automaticallyChecksForUpdates == true ? .on : .off
        permission.stringValue = AXIsProcessTrusted() ? L("Accessibility: allowed") : L("Accessibility: permission required")
        capturePermission.stringValue = CGPreflightScreenCaptureAccess() ? L("Screen recording: allowed") : L("Screen recording: icons only")
        if SMAppService.mainApp.status == .requiresApproval {
            message.stringValue = L("Approve login access in System Settings > General > Login Items.")
        } else if updater == nil {
            message.stringValue = updaterError ?? L("Updates are unavailable in this build.")
        } else {
            message.stringValue = L("Updates connect to GitHub through Sparkle. Automatic checks are optional; installation requires your choice.")
        }
    }

    @objc private func changeControls() {
        preferences.dragEnabled = drag.state == .on
        preferences.shortcut = shortcut.indexOfSelectedItem == 0 ? .controlOptionSpace : .controlShiftSpace
        preferences.dragModifier = Preferences.DragModifier.allCases[modifier.indexOfSelectedItem]
        onChange?()
        refresh()
    }
    @objc private func changeFill() {
        preferences.fillEnabled = fill.state == .on
        onChange?()
    }
    @objc private func selectExclusion() { removeExclusion.isEnabled = exclusions.indexOfSelectedItem >= 0 }
    @objc private func addExclusion() {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.title = L("Add Application…")
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowedContentTypes = [.application]
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = picker.url else { return }
            guard url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else {
                let alert = NSAlert()
                alert.messageText = L("Choose another application bundle.")
                alert.beginSheetModal(for: window)
                return
            }
            self.preferences.excludedBundleIDs.insert(id)
            self.onChange?()
            self.refresh()
        }
    }
    @objc private func deleteExclusion() {
        guard let id = exclusions.titleOfSelectedItem else { return }
        preferences.excludedBundleIDs.remove(id)
        onChange?()
        refresh()
    }
    @objc private func changeLogin() {
        let enable = login.state == .on
        login.isEnabled = false
        Task {
            defer { login.isEnabled = true }
            do {
                if enable { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                refresh()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch {
                refresh()
                message.stringValue = L("Could not change login settings. Install WindowZones in Applications and try again.")
            }
        }
    }
    @objc private func changeAutomaticUpdates() {
        updater?.updater.automaticallyChecksForUpdates = automatic.state == .on
        refresh()
    }
    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openCapturePermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
