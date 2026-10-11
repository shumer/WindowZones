import AppKit
import ApplicationServices
import ServiceManagement
import Sparkle
import LayoutStorage
import UniformTypeIdentifiers

@MainActor final class ApplicationSettings: NSObject, NSTabViewDelegate {
    var onChange: (() -> Void)?
    var shortcutStatus: (() -> String)?
    private let preferences = Preferences()
    private var window: NSWindow?
    private var tabs: NSTabView?
    private var navigation: NSSegmentedControl?
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
        view.spacing = 14
        view.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return view
    }

    private func label(_ text: String) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: L(text))
        view.widthAnchor.constraint(equalToConstant: 520).isActive = true
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

    private func section(_ title: String, _ views: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderType = .lineBorder
        box.borderColor = .separatorColor
        box.borderWidth = 0.5
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        let content = stack()
        let heading = NSTextField(labelWithString: L(title))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        content.addArrangedSubview(heading)
        views.forEach { content.addArrangedSubview($0) }
        box.contentView = content
        box.widthAnchor.constraint(equalToConstant: 552).isActive = true
        return box
    }

    private func help(_ text: String) -> NSTextField {
        let view = label(text)
        view.font = .systemFont(ofSize: 12)
        view.textColor = .secondaryLabelColor
        return view
    }

    private func makeWindow() {
        let panel = SettingsWindow(contentRect: CGRect(x: 0, y: 0, width: 624, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = L("WindowZones Settings")
        panel.isReleasedWhenClosed = false
        let root = stack()
        root.spacing = 12
        let header = NSStackView()
        header.spacing = 12
        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        header.addArrangedSubview(icon)
        let brand = NSStackView()
        brand.orientation = .vertical
        brand.alignment = .leading
        brand.spacing = 2
        let title = NSTextField(labelWithString: "WindowZones")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        brand.addArrangedSubview(title)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let subtitle = NSTextField(labelWithString: LF("Version %@", version))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        brand.addArrangedSubview(subtitle)
        header.addArrangedSubview(brand)
        root.addArrangedSubview(header)
        let tabs = NSTabView()
        tabs.tabViewType = .noTabsNoBorder
        tabs.delegate = self
        self.tabs = tabs
        panel.tabs = tabs
        let names = ["General", "Controls", "Exclusions", "Permissions"]
        let navigation = NSSegmentedControl(labels: names.map { L($0) }, trackingMode: .selectOne,
                                            target: self, action: #selector(selectPage))
        navigation.segmentStyle = .rounded
        navigation.setAccessibilityLabel(L("Settings sections"))
        navigation.selectedSegment = 0
        self.navigation = navigation
        root.addArrangedSubview(navigation)
        navigation.widthAnchor.constraint(equalToConstant: 592).isActive = true
        func add(_ name: String, _ body: NSStackView) {
            let tab = NSTabViewItem(identifier: name)
            tab.label = L(name)
            body.addArrangedSubview(NSView())
            tab.view = body
            tabs.addTabViewItem(tab)
        }
        let general = stack()
        general.addArrangedSubview(help("Drag a window upwards to choose a layout. Only the window you choose is moved."))
        login = KeyboardButton(checkboxWithTitle: L("Launch at login"), target: self, action: #selector(changeLogin))
        automatic = KeyboardButton(checkboxWithTitle: L("Check for updates automatically"), target: self, action: #selector(changeAutomaticUpdates))
        fill = KeyboardButton(checkboxWithTitle: L("Suggest windows for remaining zones"), target: self, action: #selector(changeFill))
        general.addArrangedSubview(section("Everyday use", [login, fill,
            help("After placing a window, choose another app to fill the remaining space.")]))
        message = help("")
        general.addArrangedSubview(section("Updates", [automatic,
            KeyboardButton(title: L("Check for Updates…"), target: self, action: #selector(checkForUpdates)), message]))
        add("General", general)

        let controls = stack()
        drag = KeyboardButton(checkboxWithTitle: L("Enable window dragging"), target: self, action: #selector(changeControls))
        controls.addArrangedSubview(section("Window placement", [drag,
            help("Drag a window towards the menu bar, choose a zone, then release.")]))
        shortcut.addItems(withTitles: ["⌃ ⌥ Space", "⌃ ⇧ Space"])
        shortcut.target = self
        shortcut.action = #selector(changeControls)
        modifier.addItems(withTitles: ["Shift ⇧", "Option ⌥", "Control ⌃"])
        modifier.target = self
        modifier.action = #selector(changeControls)
        shortcutMessage = help("")
        controls.addArrangedSubview(section("Keyboard", [row("Open zone picker", control: shortcut),
            row("Show zones while dragging", control: modifier), shortcutMessage,
            help("The top layout bar works without a modifier. Release the modifier or press Escape to cancel zone snapping.")]))
        controls.addArrangedSubview(help("Undo the last placement from the menu bar. Pausing dragging does not disable the keyboard picker."))
        add("Controls", controls)

        let excluded = stack()
        excluded.addArrangedSubview(help("Excluded apps are ignored by dragging, the zone picker and window suggestions. Undo remains available."))
        exclusions.setAccessibilityLabel(L("Excluded applications"))
        exclusions.target = self
        exclusions.action = #selector(selectExclusion)
        exclusions.widthAnchor.constraint(equalToConstant: 520).isActive = true
        let buttons = NSStackView()
        buttons.addArrangedSubview(KeyboardButton(title: L("Add Application…"), target: self, action: #selector(addExclusion)))
        removeExclusion = KeyboardButton(title: L("Remove"), target: self, action: #selector(deleteExclusion))
        buttons.addArrangedSubview(removeExclusion)
        excluded.addArrangedSubview(section("Excluded applications", [exclusions, buttons,
            help("Settings are saved immediately. Adding an exclusion does not move or close any windows.")]))
        add("Exclusions", excluded)

        let permissions = stack()
        permission = label("")
        capturePermission = label("")
        permissions.addArrangedSubview(section("Move and resize windows", [permission,
            help("Allow Accessibility to place the windows you choose. This permission is required."),
            KeyboardButton(title: L("Open Accessibility Settings"), target: self, action: #selector(openPermissions))]))
        permissions.addArrangedSubview(section("Window previews", [capturePermission,
            help("Screen recording is optional. Without it, suggestions show app icons. Previews are never saved or uploaded."),
            KeyboardButton(title: L("Open Screen Recording Settings"), target: self, action: #selector(openCapturePermissions))]))
        permissions.addArrangedSubview(KeyboardButton(title: L("Refresh Status"), target: self, action: #selector(refresh)))
        add("Permissions", permissions)
        if !AXIsProcessTrusted() { tabs.selectTabViewItem(at: 3) }
        root.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalToConstant: 592).isActive = true
        tabs.heightAnchor.constraint(equalToConstant: 500).isActive = true
        let footer = NSTextField(labelWithString: L("Changes are saved automatically."))
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        root.addArrangedSubview(footer)
        panel.contentView = root
        panel.center()
        window = panel
    }

    @objc private func selectPage() {
        guard let navigation, navigation.selectedSegment >= 0 else { return }
        tabs?.selectTabViewItem(at: navigation.selectedSegment)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if let tabViewItem { navigation?.selectedSegment = tabView.indexOfTabViewItem(tabViewItem) }
    }

    func showIssue(_ text: String) {
        show()
        let alert = NSAlert()
        alert.messageText = L("Could not place the window")
        alert.informativeText = text
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
    }

    @objc private func refresh() {
        guard window != nil else { return }
        fill.state = preferences.fillEnabled ? .on : .off
        drag.state = preferences.dragEnabled ? .on : .off
        shortcut.selectItem(at: preferences.shortcut == .controlOptionSpace ? 0 : 1)
        modifier.selectItem(at: Preferences.DragModifier.allCases.firstIndex(of: preferences.dragModifier) ?? 0)
        shortcutMessage.stringValue = shortcutStatus?() ?? ""
        exclusions.removeAllItems()
        for id in preferences.excludedBundleIDs.sorted() {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            exclusions.addItem(withTitle: name)
            exclusions.lastItem?.representedObject = id
            if let url {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = CGSize(width: 16, height: 16)
                exclusions.lastItem?.image = icon
            }
        }
        exclusions.isEnabled = !preferences.excludedBundleIDs.isEmpty
        if preferences.excludedBundleIDs.isEmpty { exclusions.addItem(withTitle: L("No excluded apps")) }
        removeExclusion.isEnabled = !preferences.excludedBundleIDs.isEmpty
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        automatic.isEnabled = updater != nil
        automatic.state = updater?.updater.automaticallyChecksForUpdates == true ? .on : .off
        permission.stringValue = AXIsProcessTrusted() ? L("Accessibility: allowed") : L("Accessibility: permission required")
        capturePermission.stringValue = CGPreflightScreenCaptureAccess() ? L("Screen recording: allowed") : L("Screen recording: icons only")
        permission.textColor = AXIsProcessTrusted() ? .systemGreen : .systemOrange
        capturePermission.textColor = CGPreflightScreenCaptureAccess() ? .systemGreen : .secondaryLabelColor
        if SMAppService.mainApp.status == .requiresApproval {
            message.stringValue = L("Approve login access in System Settings > General > Login Items.")
        } else if updater == nil {
            message.stringValue = updaterError ?? L("Updates are unavailable in this build.")
        } else {
            message.stringValue = L("You choose when to install an update.")
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
        guard let id = exclusions.selectedItem?.representedObject as? String else { return }
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
