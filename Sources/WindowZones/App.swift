import AppKit
import ApplicationServices
import Carbon
import Geometry
import LayoutStorage

@MainActor final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static weak var instance: AppController?
    let access = WindowAccess()
    private var statusItem: NSStatusItem!
    private var settings: ApplicationSettings!
    private var diagnostics: NSWindow!
    private var reportView: NSTextView!
    private var testApplication: NSPopUpButton!
    private var testApplications: [NSRunningApplication] = []
    private var diagnosticPicker = false
    private var reports: [String] = []
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var shortcut = "Control+Shift+Space"
    private var shortcutStatus = ""
    private var library = LayoutCollection()
    private var layoutStore: LayoutStore?
    private var libraryLoaded = false
    private var libraryWarning: String?
    private var pickerLayoutID = BuiltInLayouts.halves.id
    private var sessionLayouts: [UInt32: UUID] = [:]
    private var picker: PickerWindow?
    private var pickerDisplay: NSPopUpButton?
    private var pickerHint: NSTextField?
    private var pickerContent: ZonePickerContent?
    private var pickerSnapshot: WindowSnapshot?
    private var pickerCapture: Cancellation?
    private var pickerWatchToken: Cancellation?
    private var pickerWatchTimer: Timer?
    private var pickerWatchChecking = false
    private var pickerDisplays: [Display] = []
    private var operationDisplays: [Display] = []
    private var operation: Cancellation?
    private var operationPID: pid_t?
    private var busy = false
    private struct SuggestedPair {
        let candidate: FillCandidate
        let neighborZone: Int
    }
    private struct GroupRestore {
        let snapshot: WindowSnapshot
        let display: Display
    }
    private var pairSuggestions: [CGDirectDisplayID: SuggestedPair] = [:]
    private var pairScanned = Set<CGDirectDisplayID>()
    private var pairFrozen = Set<CGDirectDisplayID>()
    private var recentApps: [pid_t] = []
    private var groupUndo: [GroupRestore] = []
    private var groupPIDs = Set<pid_t>()
    private var undo: (snapshot: WindowSnapshot, display: Display, actual: CGRect)?
    private let overlay = Overlay()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fillAssistant: FillAssistant?
    private var fillToken: Cancellation?
    private var fillDisplays: [Display] = []
    private var fillUsed: [WindowSnapshot] = []
    private var fillLoadingID = UUID()
    private var fillRefreshTask: Task<Void, Never>?
    private var fillRefreshing = false
    private var fillScanSummary = ""
    private var dragCaptureSummary = ""
    private var fillPrevious: [FillCandidate] = []
    private let preferences = Preferences()
    private var dragEnabled: Bool { preferences.dragEnabled }
    private var dragModifier: NSEvent.ModifierFlags {
        switch preferences.dragModifier {
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        }
    }
    private let dragBar = DragBar()
    private var dragBarInteraction = DragBarInteraction()
    private var dragMenuItem: NSMenuItem!
    private var dragToken: Cancellation?
    private var dragSnapshot: WindowSnapshot?
    private var dragStart = CGPoint.zero
    private var dragDisplays: [Display] = []
    private var dragRecognition = DragRecognition()
    private var dragHadModifier = false
    private var dragChecking = false
    private var dragTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.instance = self
        NSApp.setActivationPolicy(.accessory)
        settings = ApplicationSettings()
        makeMenu()
        makeDiagnostics()
        loadLayouts()
        installHotkey(option: preferences.shortcut == .controlOptionSpace)
        settings.onChange = { [weak self] in self?.preferencesChanged() }
        settings.shortcutStatus = { [weak self] in self?.shortcutStatus ?? "" }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        installMonitors()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(contextChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(contextChanged), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(targetApplicationTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        record("Startup: no windows changed.")
        if !AXIsProcessTrusted() || !UserDefaults.standard.bool(forKey: "hasSeenSettingsIntroduction") {
            settings.show()
            UserDefaults.standard.set(true, forKey: "hasSeenSettingsIntroduction")
        }
        if CommandLine.arguments.contains("--settings") { settings.show() }
        if CommandLine.arguments.contains("--diagnostics") { showDiagnostics() }
        if CommandLine.arguments.contains("--smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A reopen event may arrive while capture or placement temporarily hides the picker.
        if !flag, !busy, picker == nil, dragToken == nil,
           !NSApp.windows.contains(where: { $0.isVisible }) {
            settings.show()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeFillAssistant()
        operation?.cancel()
        stopPickerWatch()
        cancelDrag()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func loadLayouts() {
        Task {
            defer { libraryLoaded = true }
            do {
                let store = LayoutStore(directory: try LayoutStore.applicationSupportDirectory())
                let loaded = try await store.load()
                let upgraded = loaded.collection.upgradingStandardPresets()
                if upgraded != loaded.collection { try await store.save(upgraded) }
                library = upgraded
                layoutStore = store
                if loaded.source == .backup { libraryWarning = L("Восстановлено из копии") }
            } catch {
                libraryWarning = L("Сохранение недоступно")
                record(L("Хранилище раскладок недоступно. Встроенные варианты работают без записи файлов."))
            }
        }
    }

    private func activeLayout(for display: Display) -> Layout {
        let key = display.uniqueStorageKey(in: Display.connected())
        let id = sessionLayouts[display.id] ?? key.flatMap { library.activeByDisplay[$0] }
        let suggested = library.suggestedLayouts(in: display.visible)
        return suggested.first { $0.id == id } ?? suggested[0]
    }

    private func resolvedZones(_ layout: Layout, on display: Display) -> [CGRect] {
        (try? LayoutGeometry.zones(for: layout, in: display.visible, scale: display.scale).map(\.frame)) ?? []
    }

    private func activeZones(on display: Display) -> [CGRect] {
        resolvedZones(activeLayout(for: display), on: display)
    }

    private func saveActiveLayout(_ id: UUID, displayKey: String?) async {
        guard let displayKey, let layoutStore else {
            record(L("Раскладка выбрана для текущего сеанса, постоянное сохранение недоступно."))
            return
        }
        do {
            let updated = try library.committingPlacement(layoutID: id, displayKey: displayKey, succeeded: true)
            try await layoutStore.save(updated)
            library = updated
            libraryWarning = nil
        } catch {
            libraryWarning = L("Выбор не сохранён")
            record(L("Окно размещено, но выбор раскладки не сохранён. Текущий выбор действует до завершения сеанса."))
        }
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("WindowZones")
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        _ = add(L("Выбрать зону для активного окна"), #selector(pick))
        _ = add(L("Отменить последнее размещение"), #selector(undoPlacement))
        menu.addItem(.separator())
        dragMenuItem = add(L("Перетаскивание окон"), #selector(toggleDrag))
        dragMenuItem.state = dragEnabled ? .on : .off
        _ = add(L("Сменить shortcut: Ctrl+Shift / Ctrl+Option + Space"), #selector(changeShortcut))
        _ = add(L("Настройки…"), #selector(showSettings))
        _ = add(L("Проверить обновления…"), #selector(checkUpdates))
        if CommandLine.arguments.contains("--diagnostics") {
            _ = add(L("Диагностика и разрешение"), #selector(showDiagnostics))
        }
        menu.addItem(.separator())
        _ = add(L("Завершить WindowZones"), #selector(quit))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { refreshReport() }

    private func makeDiagnostics() {
        diagnostics = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        diagnostics.title = L("WindowZones: этап 0")
        diagnostics.isReleasedWhenClosed = false
        let stack = verticalStack()
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: L("Accessibility нужен для перемещения и изменения размера выбранного окна. Разрешение выдаётся вручную. Содержимое окон и нажатые клавиши не сохраняются.")))
        let buttons = NSStackView()
        for (title, action) in [(L("Открыть Accessibility"), #selector(openPermissions)), (L("Обновить статус"), #selector(refreshPermissions)), (L("Отменить размещение"), #selector(undoPlacement))] {
            buttons.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(buttons)
        let testRow = NSStackView()
        testRow.spacing = 8
        testApplication = NSPopUpButton()
        testApplication.setAccessibilityLabel(L("Приложение для проверки окна"))
        testRow.addArrangedSubview(testApplication)
        testRow.addArrangedSubview(NSButton(title: L("Обновить список"), target: self, action: #selector(refreshTestApplications)))
        testRow.addArrangedSubview(NSButton(title: L("Открыть выбор зон"), target: self, action: #selector(pickTestApplication)))
        stack.addArrangedSubview(testRow)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: L("Проверка: выбери запущенное приложение. Панель откроется для его активного обычного окна. До выбора зоны окно не перемещается.")))
        refreshTestApplications()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        reportView = NSTextView(frame: CGRect(x: 0, y: 0, width: 640, height: 340))
        reportView.isEditable = false
        reportView.isSelectable = true
        reportView.isHorizontallyResizable = false
        reportView.autoresizingMask = [.width]
        reportView.textContainer?.widthTracksTextView = true
        reportView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = reportView
        stack.addArrangedSubview(scroll)
        diagnostics.contentView = stack
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true
        diagnostics.center()
    }

    @objc private func refreshTestApplications() {
        let previousPID = testApplication.selectedItem?.representedObject as? Int32
        testApplications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        testApplication.removeAllItems()
        for app in testApplications {
            testApplication.addItem(withTitle: app.localizedName ?? app.bundleIdentifier ?? L("Приложение"))
            testApplication.lastItem?.representedObject = app.processIdentifier
        }
        if let index = testApplications.firstIndex(where: { $0.processIdentifier == previousPID }) {
            testApplication.selectItem(at: index)
        } else if let index = testApplications.firstIndex(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            testApplication.selectItem(at: index)
        }
        testApplication.isEnabled = !testApplications.isEmpty
    }

    @objc private func pickTestApplication() {
        guard libraryLoaded, !busy else { record(L("Дождись завершения текущей операции")); return }
        guard let pid = testApplication.selectedItem?.representedObject as? Int32,
              let app = testApplications.first(where: { $0.processIdentifier == pid }), !app.isTerminated else {
            record(L("Выбранное приложение недоступно. Обнови список."))
            return
        }
        beginPicker(for: app, fromDiagnostics: true)
    }

    @objc private func showDiagnostics() {
        refreshTestApplications()
        refreshReport()
        diagnostics.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    @objc private func refreshPermissions() { refreshReport() }
    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func showSettings() { settings.show() }
    @objc private func checkUpdates() { settings.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func record(_ message: String) {
        statusItem?.button?.toolTip = message
        reports.append(message)
        reports = Array(reports.suffix(30))
        refreshReport()
    }
    private func format(_ frame: CGRect?) -> String {
        guard let frame else { return L("нет") }
        return String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", frame.minX, frame.minY, frame.width, frame.height)
    }
    private func refreshReport() {
        guard reportView != nil else { return }
        let displays = Display.connected().map { "display \($0.id), scale \($0.scale), visible \(format($0.visible))" }.joined(separator: "\n")
        reportView.string = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nAccessibility: \(AXIsProcessTrusted() ? L("разрешён") : L("не разрешён"))\nShortcut: \(shortcut) \(shortcutStatus)\nDrag (\(preferences.dragModifier.rawValue)): \(dragEnabled ? L("включён") : L("выключен"))\n\(displays)\n\n" + fillScanSummary + "\n" + dragCaptureSummary + "\n\n" + reports.joined(separator: "\n\n")
    }
    private func report(_ result: PlacementResult, context: String) {
        let steps = result.samples.map { "\($0.stage): \(format($0.frame))" }.joined(separator: "\n")
        record("\(context): \(result.status), \(result.milliseconds) ms\n\(result.message)\noriginal: \(format(result.original))\nexpected: \(format(result.expected))\nactual: \(format(result.actual))\n\(steps)")
    }

    private func installHotkey(option: Bool = false) {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in
                    AppController.instance?.record(L("Получена команда shortcut"))
                    AppController.instance?.pick()
                }
                return noErr
            }, 1, &event, nil, &handler)
            guard handlerStatus == noErr else {
                shortcutStatus = LF("Shortcut unavailable (error %d). Choose another combination.", handlerStatus)
                return
            }
        }
        let modifiers = UInt32(controlKey | (option ? optionKey : shiftKey))
        let result = RegisterEventHotKey(UInt32(kVK_Space), modifiers, EventHotKeyID(signature: 0x575A3030, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        shortcut = option ? "Control+Option+Space" : "Control+Shift+Space"
        shortcutStatus = result == noErr ? L("Shortcut is registered.") : LF("Shortcut unavailable (error %d). Choose another combination.", result)
    }
    @objc private func changeShortcut() {
        preferences.shortcut = preferences.shortcut == .controlOptionSpace ? .controlShiftSpace : .controlOptionSpace
        preferencesChanged()
        refreshReport()
    }

    @objc func pick() {
        guard AXIsProcessTrusted() else { settings.show(); return }
        guard libraryLoaded else { record(L("Раскладки ещё загружаются")); return }
        guard !busy else { record(L("Команда отклонена: предыдущая операция ещё выполняется")); return }
        if picker != nil { cancelPicker(); return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            record(LF("Activate an ordinary app window, then press %@.", shortcut))
            return
        }
        beginPicker(for: app, fromDiagnostics: false)
    }

    private func beginPicker(for app: NSRunningApplication, fromDiagnostics: Bool) {
        guard AXIsProcessTrusted() else { settings.show(); return }
        guard !preferences.excludes(app.bundleIdentifier) else { NSSound.beep(); return }
        closeFillAssistant()
        cancelPicker()
        cancelDrag()
        let token = Cancellation()
        operation = token
        pickerCapture = token
        diagnosticPicker = fromDiagnostics
        if fromDiagnostics { diagnostics.orderOut(nil) }
        operationDisplays = Display.connected()
        busy = true
        let pid = app.processIdentifier
        operationPID = pid
        record(LF("Selecting app window: %@", app.bundleIdentifier ?? "unknown"))
        Task {
            defer {
                busy = false
                if pickerCapture === token { pickerCapture = nil }
            }
            do {
                guard !token.cancelled else { return }
                if fromDiagnostics {
                    // Match shortcut capture by activating the explicitly selected application first.
                    NSApp.yieldActivation(to: app)
                    app.activate(from: .current, options: [])
                    try await Task.sleep(for: .milliseconds(150))
                    guard !token.cancelled else { return }
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                        throw AccessFailure(status: "failed", message: L("Выбранное приложение не стало активным. Захват окна отменён."))
                    }
                }
                let snapshot = try await access.capture(pid: pid, cancellation: token)
                guard !token.cancelled,
                      let targetApp = NSRunningApplication(processIdentifier: snapshot.pid), !targetApp.isTerminated else { return }
                pickerSnapshot = snapshot
                showPicker(snapshot)
            } catch {
                if !token.cancelled { recordAccessError(error) }
            }
        }
    }

    private func recordAccessError(_ error: Error) {
        let issue = error as? AccessFailure
        record("\(issue?.status ?? "failed"): \(issue?.message ?? L("Ошибка AX"))")
        if diagnosticPicker { showDiagnostics() }
        else { settings.showIssue(issue?.message ?? L("Ошибка AX")) }
    }

    private func showPicker(_ snapshot: WindowSnapshot) {
        pickerDisplays = Display.connected()
        guard !pickerDisplays.isEmpty else { record(L("Нет доступного экрана")); return }
        let window = PickerWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Разместить выбранное окно")
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = ZonePickerContent(applicationName: NSRunningApplication(processIdentifier: snapshot.pid)?.localizedName ?? L("Приложение"), layouts: library.layouts)
        let popup = content.displayPopup
        for (index, display) in pickerDisplays.enumerated() { popup.addItem(withTitle: LF("Display %d: %d × %d", index + 1, Int(display.visible.width), Int(display.visible.height))) }
        let selected = pickerDisplays.indices.max { a, b in
            let lhs = pickerDisplays[a].axVisible.intersection(snapshot.frame)
            let rhs = pickerDisplays[b].axVisible.intersection(snapshot.frame)
            return (lhs.isNull ? 0 : lhs.width * lhs.height) < (rhs.isNull ? 0 : rhs.width * rhs.height)
        } ?? 0
        popup.selectItem(at: selected)
        popup.target = self
        popup.action = #selector(pickerDisplayChanged)
        popup.isHidden = pickerDisplays.count == 1
        pickerDisplay = popup
        pickerHint = content.hint
        pickerContent = content
        content.choose = { [weak self] layoutID, index in
            self?.pickerLayoutID = layoutID
            self?.applyPicker(index)
        }
        content.cancel = { [weak self] in self?.cancelPicker() }
        content.preview = { [weak self, weak window] layoutID, index in
            self?.pickerLayoutID = layoutID
            window?.selected = index
            self?.updatePickerPreview()
        }
        window.contentView = content
        window.choose = { [weak self] index in self?.applyPicker(index) }
        window.cancel = { [weak self] in self?.cancelPicker() }
        window.moveSelection = { [weak self, weak window] delta in
            guard let window else { return }
            guard window.zoneCount > 0 else { return }
            window.selected = (window.selected + delta + window.zoneCount) % window.zoneCount
            self?.updatePickerPreview()
            if let self { self.pickerContent?.focusSelection(layoutID: self.pickerLayoutID, index: window.selected) }
        }
        picker = window
        pickerLayoutID = activeLayout(for: pickerDisplays[selected]).id
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window)
        NSApp.activate()
        updatePickerPreview()
        startPickerWatch(snapshot)
    }

    private func startPickerWatch(_ snapshot: WindowSnapshot) {
        stopPickerWatch()
        let token = Cancellation()
        pickerWatchToken = token
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pickerWatchToken === token, !self.pickerWatchChecking else { return }
                self.pickerWatchChecking = true
                defer { if self.pickerWatchToken === token { self.pickerWatchChecking = false } }
                do {
                    try await self.access.validateTarget(snapshot, cancellation: token)
                } catch {
                    guard !token.cancelled, self.pickerWatchToken === token else { return }
                    let issue = error as? AccessFailure
                    let showReport = self.diagnosticPicker
                    self.dismissPicker(restoreFocus: false)
                    if showReport { self.diagnostics.orderFront(nil) }
                    self.record(LF("Zone selection cancelled: %@", issue?.message ?? L("целевое окно недоступно")))
                }
            }
        }
        pickerWatchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPickerWatch() {
        pickerWatchToken?.cancel()
        pickerWatchToken = nil
        pickerWatchTimer?.invalidate()
        pickerWatchTimer = nil
        pickerWatchChecking = false
    }

    @objc private func pickerDisplayChanged() {
        guard let popup = pickerDisplay, pickerDisplays.indices.contains(popup.indexOfSelectedItem) else { return }
        pickerLayoutID = activeLayout(for: pickerDisplays[popup.indexOfSelectedItem]).id
        picker?.selected = 0
        updatePickerPreview()
    }

    private func pickerZones(on display: Display) -> [CGRect] {
        guard let layout = library.layouts.first(where: { $0.id == pickerLayoutID }) else { return [] }
        return resolvedZones(layout, on: display)
    }

    @objc private func updatePickerPreview() {
        guard let popup = pickerDisplay, pickerDisplays.indices.contains(popup.indexOfSelectedItem), let picker else { return }
        let display = pickerDisplays[popup.indexOfSelectedItem]
        pickerContent?.setLayouts(library.suggestedLayouts(in: display.visible))
        let zones = pickerZones(on: display)
        picker.zoneCount = zones.count
        picker.selected = min(max(0, picker.selected), max(0, zones.count - 1))
        let name = library.layouts.first { $0.id == pickerLayoutID }?.displayName ?? L("Раскладка")
        pickerHint?.stringValue = zones.isEmpty ? L("Раскладка не помещается на этом экране") : LF("%@ · Zone %d", name, picker.selected + 1)
        if let libraryWarning { pickerHint?.stringValue += " · \(libraryWarning)" }
        let available = Set(library.layouts.filter { !resolvedZones($0, on: display).isEmpty }.map(\.id))
        pickerContent?.updateDisplay(area: display.visible, scale: display.scale)
        pickerContent?.select(layoutID: pickerLayoutID, index: picker.selected, availableLayoutIDs: available)
        overlay.show(display: display, selected: picker.selected, zones: zones)
    }
    @objc private func cancelPicker() {
        dismissPicker(restoreFocus: true)
    }

    private func dismissPicker(restoreFocus: Bool) {
        stopPickerWatch()
        if restoreFocus, picker != nil, let snapshot = pickerSnapshot,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            NSRunningApplication(processIdentifier: snapshot.pid)?.activate(from: .current, options: [])
        }
        picker?.orderOut(nil)
        if diagnosticPicker && restoreFocus { diagnostics.orderFront(nil) }
        diagnosticPicker = false
        picker = nil
        pickerContent = nil
        pickerSnapshot = nil
        pickerCapture?.cancel()
        pickerCapture = nil
        operation?.cancel()
        overlay.hide()
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === picker { cancelPicker() }
    }
    private func applyPicker(_ index: Int) {
        guard !busy, let snapshot = pickerSnapshot, let popup = pickerDisplay,
              pickerDisplays.indices.contains(popup.indexOfSelectedItem) else { return }
        let display = pickerDisplays[popup.indexOfSelectedItem]
        let zones = pickerZones(on: display)
        let layoutID = pickerLayoutID
        let displayKey = display.uniqueStorageKey(in: pickerDisplays)
        guard zones.indices.contains(index), Display.compatible(pickerDisplays, Display.connected()) else {
            cancelPicker()
            record(L("Конфигурация экранов изменилась или зона недоступна"))
            return
        }
        cancelPicker()
        perform(snapshot, target: display.ax(zones[index]), display: display, isUndo: false, layoutID: layoutID, displayKey: displayKey)
    }

    private func perform(_ snapshot: WindowSnapshot, target: CGRect, display: Display, isUndo: Bool, layoutID: UUID? = nil, displayKey: String? = nil, completion: ((CGRect?) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        operationDisplays = Display.connected()
        operationPID = snapshot.pid
        let token = Cancellation()
        operation = token
        Task {
            defer { busy = false }
            guard !token.cancelled, operation === token else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != snapshot.pid {
                NSRunningApplication(processIdentifier: snapshot.pid)?.activate(from: .current, options: [])
            }
            try? await Task.sleep(for: .milliseconds(100))
            guard !token.cancelled else { return }
            let result = await access.place(snapshot, at: target, visibleArea: isUndo ? nil : display.axVisible, cancellation: token)
            guard !token.cancelled, operation === token,
                  let targetApp = NSRunningApplication(processIdentifier: snapshot.pid), !targetApp.isTerminated else {
                report(result, context: L("Поздний результат завершённой сессии, undo не обновлён"))
                return
            }
            if result.succeeded, let actual = result.actual {
                if isUndo { undo = nil }
                else {
                    groupUndo = []
                    let source = Display.connected().max { lhs, rhs in
                        let a = lhs.axVisible.intersection(snapshot.frame)
                        let b = rhs.axVisible.intersection(snapshot.frame)
                        return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
                    } ?? display
                    undo = (snapshot, source, actual)
                    if let layoutID {
                        sessionLayouts[display.id] = layoutID
                        await saveActiveLayout(layoutID, displayKey: displayKey)
                    }
                }
            }
            let appID = NSRunningApplication(processIdentifier: snapshot.pid)?.bundleIdentifier ?? "unavailable"
            report(result, context: "\(isUndo ? "Undo" : "Snap") [\(appID)]")
            busy = false
            if let completion { completion(result.succeeded && result.actual.map { FillSession.accepts(actual: $0, target: target) } == true ? result.actual : nil) }
            else if !isUndo, result.succeeded, let actual = result.actual,
                    FillSession.accepts(actual: actual, target: target) {
                let layout = layoutID.flatMap { id in library.layouts.first { $0.id == id } } ?? activeLayout(for: display)
                beginFillAssistant(layout: layout, display: display, target: target, placed: snapshot)
            }
        }
    }

    private func closeFillAssistant() {
        guard fillToken != nil else { return }
        fillRefreshTask?.cancel()
        fillRefreshTask = nil
        fillPrevious = []
        fillToken?.cancel()
        fillToken = nil
        fillLoadingID = UUID()
        fillAssistant?.close()
        fillAssistant = nil
        fillUsed = []
        if busy { operation?.cancel() }
    }

    private func fillDisplayIsCurrent() -> Bool {
        let current = Display.connected().filter { $0.id == fillDisplays.first?.id }
        return Display.compatible(fillDisplays, current)
    }

    private func beginFillAssistant(layout: Layout, display: Display, target: CGRect, placed: WindowSnapshot) {
        guard preferences.fillEnabled else { return }
        closeFillAssistant()
        let zones = resolvedZones(layout, on: display)
        guard let index = zones.firstIndex(where: { GeometryEngine.close(display.ax($0), target) }), zones.count > 1 else { return }
        let token = Cancellation()
        fillToken = token
        fillDisplays = [display]
        fillUsed = [placed]
        loadFillCandidates(layout: layout, display: display, initialIndex: index, token: token)
        fillRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.fillToken === token else { return }
                if !self.busy && self.fillAssistant?.isBusy != true {
                    self.loadFillCandidates(layout: layout, display: display, initialIndex: index, token: token)
                }
            }
        }
    }

    private func loadFillCandidates(layout: Layout, display: Display, initialIndex: Int, token: Cancellation) {
        guard !fillRefreshing, !busy, fillAssistant?.isBusy != true else { return }
        fillRefreshing = true
        let request = UUID()
        fillLoadingID = request
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && !preferences.excludes($0.bundleIdentifier)
        }
        // Scan apps with visible windows first so background apps cannot exhaust the AX budget.
        let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visiblePIDs = Set(metadata.compactMap { item -> pid_t? in
            guard (item[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.intersects(display.axVisible) else { return nil }
            return item[kCGWindowOwnerPID as String] as? Int32
        })
        let pids = apps.map(\.processIdentifier).sorted { visiblePIDs.contains($0) && !visiblePIDs.contains($1) }
        let used = fillUsed
        Task {
            defer { fillRefreshing = false }
            let candidates = await access.fillCandidates(pids: pids, area: display.axVisible, excluding: [], previous: fillPrevious, cancellation: token)
            let unusedIDs = await access.unusedCandidateIDs(candidates, excluding: used)
            guard !token.cancelled, fillToken === token, fillLoadingID == request,
                  fillDisplayIsCurrent() else { return }
            let zones = resolvedZones(layout, on: display)
            // Limit suggestions to currently onscreen windows using public window metadata.
            let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let available = candidates.filter { candidate in
                candidate.minimized || visible.contains { item in
                    guard (item[kCGWindowOwnerPID as String] as? Int32) == candidate.snapshot.pid,
                          (item[kCGWindowLayer as String] as? Int) == 0,
                          let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                          let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
                    return GeometryEngine.close(rect, candidate.snapshot.frame)
                }
            }
            let knownIDs = Set(fillPrevious.map(\.id))
            fillPrevious.append(contentsOf: candidates.filter { !knownIDs.contains($0.id) })
            let wasOpen = fillAssistant != nil
            let placedFrames = available.filter { !$0.minimized && !unusedIDs.contains($0.id) }.map { $0.snapshot.frame }
            var occupied = FillSession.occupied(zones: zones.map { display.ax($0) }, frames: placedFrames)
            let alignedFrames = available.filter { candidate in
                !candidate.minimized && zones.contains { FillSession.accepts(actual: candidate.snapshot.frame, target: display.ax($0)) }
            }.map { $0.snapshot.frame }
            occupied.formUnion(FillSession.occupied(zones: zones.map { display.ax($0) }, frames: alignedFrames))
            if fillAssistant == nil {
                occupied.insert(initialIndex)
                for candidate in available where !candidate.minimized {
                    for (index, zone) in zones.enumerated() where GeometryEngine.close(candidate.snapshot.frame, display.ax(zone)) {
                        occupied.insert(index)
                    }
                }
                let panel = FillAssistant(zones: zones, area: display.visible, occupied: occupied)
                guard !panel.isComplete else {
                    fillScanSummary = LF("Fill: display %d, all %d zones occupied or overlapping", display.id, zones.count)
                    refreshReport()
                    closeFillAssistant()
                    return
                }
                fillAssistant = panel
                panel.onClose = { [weak self = self] in self?.closeFillAssistant() }
                panel.onUndo = { [weak self = self] in self?.undoPlacement() }
                panel.onRefresh = { [weak self = self] in
                    self?.loadFillCandidates(layout: layout, display: display, initialIndex: initialIndex, token: token)
                }
                panel.onChoose = { [weak self = self, weak panel] candidate, index in
                    guard let self, !token.cancelled, self.fillToken === token, zones.indices.contains(index),
                          self.fillDisplayIsCurrent(),
                          let app = NSRunningApplication(processIdentifier: candidate.snapshot.pid), !app.isTerminated else {
                        panel?.failed()
                        return
                    }
                    self.fillLoadingID = UUID()
                    panel?.panel.orderOut(nil)
                    NSApp.yieldActivation(to: app)
                    Task { [weak self, weak panel] in
                        guard let self else { return }
                        do {
                            try await self.access.restoreForFill(candidate, cancellation: token)
                            let frame = try await self.access.currentFrame(candidate.snapshot, cancellation: token)
                            guard !token.cancelled, self.fillToken === token else { return }
                            let snapshot = WindowSnapshot(reference: candidate.snapshot.reference, frame: frame, pid: candidate.snapshot.pid)
                            self.perform(snapshot, target: display.ax(zones[index]), display: display, isUndo: false) { [weak self, weak panel] actual in
                                guard let self, !token.cancelled, self.fillToken === token else { return }
                                if let actual {
                                    self.fillUsed.append(snapshot)
                                    panel?.placed(candidate.id, blocked: FillSession.occupied(zones: zones.map { display.ax($0) }, frames: [actual]))
                                } else { panel?.failed() }
                                if self.fillToken === token { panel?.setBusy(false); panel?.show() }
                            }
                        } catch {
                            guard !token.cancelled else { return }
                            panel?.failed()
                            panel?.show()
                        }
                    }
                }
            }
            let occupiedWindows = available.filter { candidate in
                unusedIDs.contains(candidate.id) && (candidate.minimized || !zones.contains { FillSession.accepts(actual: candidate.snapshot.frame, target: display.ax($0)) })
            }
            fillScanSummary = "Fill: display \(display.id), apps=\(pids.count), AX=\(candidates.count), visible=\(available.count), used=\(placedFrames.count), occupied=\(occupied.count)/\(zones.count), cards=\(occupiedWindows.count)"
            refreshReport()
            fillAssistant?.reconcile(occupied: occupied)
            fillAssistant?.update(occupiedWindows)
            if !wasOpen { fillAssistant?.show() }
        }
    }

    @objc private func undoPlacement() {
        closeFillAssistant()
        guard !busy else { return }
        if !groupUndo.isEmpty {
            cancelPicker()
            cancelDrag()
            restoreGroup()
            return
        }
        guard let undo else { record(L("Нет доступной операции undo")); return }
        cancelPicker()
        cancelDrag()
        let displays = Display.connected()
        guard let first = displays.first else { return }
        let originalDisplay = displays.first { $0.id == undo.display.id }
        let display = originalDisplay ?? first
        let target = GeometryEngine.undoTarget(undo.snapshot.frame,
            sourceScreen: undo.display.ax(undo.display.frame),
            currentScreen: originalDisplay.map { $0.ax($0.frame) }, available: display.axVisible)
        if target != undo.snapshot.frame {
            record(L("Undo: геометрия исходного экрана изменилась, frame скорректирован"))
        }
        perform(undo.snapshot, target: target, display: display, isUndo: true)
    }

    @objc private func screenChanged() {
        let current = Display.connected()
        sessionLayouts = sessionLayouts.filter { id, _ in current.contains { $0.id == id } }
        var baselines: [[Display]] = []
        if fillToken != nil, !fillDisplayIsCurrent() {
            cancelForContextChange(L("Целевой экран заполнения изменился"))
            return
        }
        if picker != nil { baselines.append(pickerDisplays) }
        if dragToken != nil { baselines.append(dragDisplays) }
        if busy { baselines.append(operationDisplays) }
        guard baselines.contains(where: { !Display.compatible($0, current) }) else {
            refreshReport()
            return
        }
        cancelForContextChange(L("Конфигурация экранов изменилась"))
    }

    @objc private func contextChanged(_ notification: Notification) {
        let reason = notification.name == NSWorkspace.willSleepNotification ? L("Переход в сон") : L("Смена Space")
        cancelForContextChange(reason)
    }

    @objc private func targetApplicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if undo?.snapshot.pid == pid { undo = nil }
        groupUndo.removeAll { $0.snapshot.pid == pid }
        if busy && groupPIDs.contains(pid) { operation?.cancel() }
        guard pickerSnapshot?.pid == pid || dragSnapshot?.pid == pid || (busy && operationPID == pid) else { return }
        cancelForContextChange(L("Целевое приложение завершено"))
    }

    private func cancelForContextChange(_ reason: String) {
        let hadInteraction = fillToken != nil || picker != nil || pickerCapture != nil || dragToken != nil || busy
        closeFillAssistant()
        dismissPicker(restoreFocus: false)
        cancelDrag()
        if hadInteraction { record(LF("%@: interaction cancelled without restoring focus", reason)) }
        else { refreshReport() }
    }

    private func preferencesChanged() {
        operation?.cancel()
        closeFillAssistant()
        cancelPicker()
        cancelDrag()
        installHotkey(option: preferences.shortcut == .controlOptionSpace)
        dragMenuItem.state = dragEnabled ? .on : .off
        refreshReport()
    }

    @objc private func toggleDrag() {
        preferences.dragEnabled = !preferences.dragEnabled
        dragMenuItem.state = dragEnabled ? .on : .off
        cancelDrag()
        record("Dragging: \(dragEnabled), modifier: \(preferences.dragModifier.rawValue)")
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                    self?.cancelDrag()
                    if event.window === self?.diagnostics { self?.dismissPicker(restoreFocus: false) }
                }
                else if event.type == .keyDown && event.keyCode == 53 {
                    self?.closeFillAssistant()
                    if self?.pickerCapture != nil { self?.cancelPicker() }
                    self?.cancelDrag()
                }
            }
            return event
        }
    }

    private func axPointer() -> CGPoint? {
        guard let display = Display.connected().first else { return nil }
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: display.primaryTop - point.y)
    }

    private func handle(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), picker != nil {
            dismissPicker(restoreFocus: false)
            return
        }
        if event.type == .keyDown, event.keyCode == 53 {
            closeFillAssistant()
            if picker != nil || pickerCapture != nil { cancelPicker() }
            cancelDrag()
            return
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), fillToken != nil {
            closeFillAssistant()
        }
        guard dragEnabled, libraryLoaded, !busy, picker == nil, fillToken == nil else { return }
        if event.type == .keyDown {
            if event.keyCode == 53 { cancelDrag() }
            return
        }
        if event.type == .leftMouseDown {
            cancelDrag()
            guard AXIsProcessTrusted(), let point = axPointer() else { return }
            let token = Cancellation()
            dragToken = token
            dragStart = point
            dragDisplays = Display.connected()
            dragHadModifier = event.modifierFlags.contains(dragModifier)
            Task { [self] in
                do {
                    let snapshot = try await access.captureDragCandidate(at: point, cancellation: token)
                    guard !token.cancelled, dragToken === token, let now = axPointer(),
                          let targetApp = NSRunningApplication(processIdentifier: snapshot.pid), !targetApp.isTerminated,
                          !preferences.excludes(targetApp.bundleIdentifier),
                          hypot(now.x - point.x, now.y - point.y) <= 3 else {
                        if dragToken === token {
                            dragCaptureSummary = "Drag: baseline moved before capture"
                            refreshReport()
                            cancelDrag()
                        }
                        return
                    }
                    // The baseline is now frozen; movement during capability checks is valid drag evidence.
                    try await access.validateTarget(snapshot, cancellation: token)
                    guard !token.cancelled, dragToken === token,
                          NSEvent.pressedMouseButtons & 1 != 0 else {
                        if dragToken === token { cancelDrag() }
                        return
                    }
                    dragCaptureSummary = "Drag: captured"
                    refreshReport()
                    dragSnapshot = snapshot
                    dragTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.checkDrag() }
                    }
                    checkDrag()
                } catch {
                    if dragToken === token {
                        dragCaptureSummary = "Drag: " + ((error as? AccessFailure)?.message ?? "capture cancelled")
                        refreshReport()
                        cancelDrag()
                    }
                }
            }
        } else if event.type == .flagsChanged {
            if event.modifierFlags.contains(dragModifier) { dragHadModifier = true }
            else if dragHadModifier { cancelDrag() }
        } else if event.type == .leftMouseDragged {
            if event.modifierFlags.contains(dragModifier) { dragHadModifier = true }
            checkDrag()
        } else if event.type == .leftMouseUp {
            finishDrag(shift: event.modifierFlags.contains(dragModifier))
        }
    }

    private func checkDrag() {
        guard let snapshot = dragSnapshot, let token = dragToken, !dragChecking else { return }
        guard AXIsProcessTrusted(), Display.compatible(dragDisplays, Display.connected()),
              NSEvent.pressedMouseButtons & 1 != 0 else { cancelDrag(); return }
        if dragHadModifier && !NSEvent.modifierFlags.contains(dragModifier) { cancelDrag(); return }
        guard let pointer = axPointer() else { cancelDrag(); return }
        dragChecking = true
        Task {
            defer { if dragToken === token { dragChecking = false } }
            do {
                let current = try await access.currentFrame(snapshot, cancellation: token)
                guard !token.cancelled, dragToken === token else { return }
                guard abs(current.width - snapshot.frame.width) <= 2, abs(current.height - snapshot.frame.height) <= 2 else {
                    cancelDrag()
                    return
                }
                let delta = CGPoint(x: pointer.x - dragStart.x, y: pointer.y - dragStart.y)
                guard dragRecognition.observe(initial: snapshot.frame, current: current, pointerDelta: delta) else { return }
                let location = NSEvent.mouseLocation
                if let display = dragDisplays.first(where: { $0.frame.contains(location) }) {
                    if NSEvent.modifierFlags.contains(dragModifier) {
                        dragBar.hide()
                        dragBarInteraction = DragBarInteraction()
                        let zones = activeZones(on: display)
                        overlay.show(display: display, selected: zones.firstIndex(where: { $0.contains(location) }), zones: zones)
                    } else {
                        loadPairSuggestion(snapshot: snapshot, display: display, token: token)
                        let geometry = dragGeometry(on: display)
                        dragBarInteraction.update(pointer: location, screen: display.id, geometry: geometry)
                        if dragBarInteraction.expanded { pairFrozen.insert(display.id) }
                        let pair = pairSuggestions[display.id]
                        let neighbor = pair.flatMap { NSRunningApplication(processIdentifier: $0.candidate.snapshot.pid) }
                        let dragged = NSRunningApplication(processIdentifier: snapshot.pid)?.localizedName ?? L("Приложение")
                        dragBar.show(geometry: geometry, interaction: dragBarInteraction,
                            neighborIcon: neighbor?.icon, neighborZone: pair?.neighborZone,
                            pairCaption: neighbor?.localizedName.map { dragged + " + " + $0 })
                        if let choice = dragBarInteraction.selected {
                            let isPair = choice.layoutID == PairSuggestion.layoutID
                            overlay.show(display: display, selected: 0,
                                zones: isPair ? resolvedZones(BuiltInLayouts.halves, on: display) : [choice.target],
                                showsLabels: false, highlightsAll: isPair)
                        } else { overlay.hide() }
                    }
                } else {
                    overlay.hide()
                    dragBar.hide()
                    dragBarInteraction = DragBarInteraction()
                }
            } catch { if dragToken === token { cancelDrag() } }
        }
    }

    private func finishDrag(shift: Bool) {
        let location = NSEvent.mouseLocation
        guard dragRecognition.isConfirmed, let snapshot = dragSnapshot, let pointer = axPointer(),
              Display.compatible(dragDisplays, Display.connected()),
              let display = dragDisplays.first(where: { $0.frame.contains(location) }) else { cancelDrag(); return }
        let zone: CGRect
        let layoutID: UUID?
        var selectedPair: SuggestedPair?
        if shift {
            guard let target = activeZones(on: display).first(where: { $0.contains(location) }) else { cancelDrag(); return }
            zone = target
            layoutID = nil
        } else {
            let geometry = dragGeometry(on: display)
            guard let choice = dragBarInteraction.drop(at: location, screen: display.id, geometry: geometry) else { cancelDrag(); return }
            if choice.layoutID == PairSuggestion.layoutID {
                guard let pair = pairSuggestions[display.id], choice.zoneIndex != pair.neighborZone else { cancelDrag(); return }
                selectedPair = pair
            }
            zone = choice.target
            layoutID = choice.layoutID
        }
        let displayKey = display.uniqueStorageKey(in: dragDisplays)
        let start = dragStart
        let recognition = dragRecognition
        let displays = dragDisplays
        cancelDrag()
        let token = Cancellation()
        operation = token
        busy = true
        operationDisplays = displays
        operationPID = snapshot.pid
        Task {
            do {
                let current = try await access.currentFrame(snapshot, cancellation: token)
                guard !token.cancelled, Display.compatible(displays, Display.connected()),
                      recognition.canFinish(initial: snapshot.frame, current: current,
                                                pointerDelta: CGPoint(x: pointer.x - start.x, y: pointer.y - start.y)) else {
                    busy = false
                    return
                }
                busy = false
                if let selectedPair {
                    performPair(snapshot, pair: selectedPair, display: display)
                } else {
                    perform(snapshot, target: display.ax(zone), display: display, isUndo: false, layoutID: layoutID, displayKey: displayKey)
                }
            } catch {
                busy = false
                if !token.cancelled { recordAccessError(error) }
            }
        }
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        recentApps.removeAll { $0 == app.processIdentifier }
        recentApps.insert(app.processIdentifier, at: 0)
        recentApps = Array(recentApps.prefix(30))
    }

    private func dragGeometry(on display: Display) -> DragBarGeometry {
        var layouts = library.suggestedLayouts(in: display.visible)
        if pairSuggestions[display.id] != nil { layouts.insert(PairSuggestion.layout, at: 0) }
        return DragBarGeometry(layouts: layouts, area: display.visible, scale: display.scale, top: display.menuBarBottom,
            reservedPairZone: pairSuggestions[display.id]?.neighborZone)
    }

    private func loadPairSuggestion(snapshot: WindowSnapshot, display: Display, token: Cancellation) {
        guard !pairScanned.contains(display.id) else { return }
        pairScanned.insert(display.id)
        guard library.suggestedLayouts(in: display.visible).contains(BuiltInLayouts.halves),
              !dragBarInteraction.expanded else { return }
        let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visible = metadata.compactMap { item -> (pid_t, CGRect)? in
            guard (item[kCGWindowLayer as String] as? Int) == 0,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32, pid != snapshot.pid,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 0, frame.height > 0,
                  !frame.intersection(display.axVisible).isNull,
                  frame.intersection(display.axVisible).width * frame.intersection(display.axVisible).height > frame.width * frame.height * 0.5,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  pid != ProcessInfo.processInfo.processIdentifier, !preferences.excludes(app.bundleIdentifier) else { return nil }
            return (pid, frame)
        }
        var pids: [pid_t] = []
        for pid in recentApps + visible.map({ $0.0 }) where visible.contains(where: { $0.0 == pid }) {
            if !pids.contains(pid) { pids.append(pid) }
        }
        Task {
            let candidates = await access.fillCandidates(pids: pids, area: display.axVisible, excluding: [snapshot], cancellation: token)
                .filter { candidate in
                    !candidate.minimized && visible.contains {
                        $0.0 == candidate.snapshot.pid && pairFramesMatch($0.1, candidate.snapshot.frame)
                    }
                }
            guard !token.cancelled, dragToken === token, !pairFrozen.contains(display.id),
                  let pointerDisplay = dragDisplays.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
                  pointerDisplay.id == display.id else { return }
            let zones = resolvedZones(BuiltInLayouts.halves, on: display).map { display.ax($0) }
            if let chosen = PairSuggestion.choose(frames: candidates.map { $0.snapshot.frame }, zones: zones) {
                pairSuggestions[display.id] = SuggestedPair(candidate: candidates[chosen.candidate], neighborZone: chosen.neighborZone)
            }
        }
    }

    private func pairFramesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        [abs(lhs.minX - rhs.minX), abs(lhs.minY - rhs.minY), abs(lhs.width - rhs.width), abs(lhs.height - rhs.height)].allSatisfy { $0 <= 2 }
    }

    private func sourceDisplay(_ snapshot: WindowSnapshot, fallback: Display) -> Display {
        Display.connected().max { lhs, rhs in
            let a = lhs.axVisible.intersection(snapshot.frame)
            let b = rhs.axVisible.intersection(snapshot.frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        } ?? fallback
    }

    private func performPair(_ dragged: WindowSnapshot, pair: SuggestedPair, display: Display) {
        guard !busy else { return }
        let zones = resolvedZones(BuiltInLayouts.halves, on: display).map { display.ax($0) }
        guard zones.count == 2 else { return }
        let neighbor = pair.candidate.snapshot
        busy = true
        let token = Cancellation()
        operation = token
        operationDisplays = Display.connected()
        groupPIDs = [dragged.pid, neighbor.pid]
        operationPID = dragged.pid
        Task {
            defer { busy = false; groupPIDs = [] }
            var attempted: [(restore: GroupRestore, rollback: CGRect)] = []
            let oldUndo = undo
            let oldGroupUndo = groupUndo
            do {
                try await access.validateTarget(dragged, cancellation: token)
                try await access.validateTarget(neighbor, cancellation: token)
                let neighborFrame = try await access.currentFrame(neighbor, cancellation: token)
                guard pairFramesMatch(neighborFrame, neighbor.frame) else {
                    throw AccessFailure(status: "cancelled", message: L("The suggested window changed. Try dragging again."))
                }
                for (snapshot, target) in [(dragged, zones[1 - pair.neighborZone]), (neighbor, zones[pair.neighborZone])] {
                    guard !token.cancelled, Display.compatible(operationDisplays, Display.connected()),
                          !preferences.excludes(NSRunningApplication(processIdentifier: snapshot.pid)?.bundleIdentifier) else {
                        throw AccessFailure(status: "cancelled", message: L("Pair placement cancelled."))
                    }
                    let before = try await access.currentFrame(snapshot, cancellation: token)
                    attempted.append((GroupRestore(snapshot: snapshot, display: sourceDisplay(snapshot, fallback: display)), before))
                    undo = nil
                    groupUndo = attempted.map(\.restore)
                    let result = await access.place(snapshot, at: target, visibleArea: display.axVisible, cancellation: token)
                    report(result, context: "Pair snap")
                    guard !token.cancelled, result.succeeded, let actual = result.actual,
                          FillSession.accepts(actual: actual, target: target) else {
                        throw AccessFailure(status: "failed", message: L("Could not arrange both windows. Previous positions will be restored where possible."))
                    }
                }
                sessionLayouts[display.id] = BuiltInLayouts.halves.id
                await saveActiveLayout(BuiltInLayouts.halves.id, displayKey: display.uniqueStorageKey(in: operationDisplays))
                if !token.cancelled { NSRunningApplication(processIdentifier: dragged.pid)?.activate(from: .current, options: []) }
            } catch {
                var unresolved = attempted.map(\.restore)
                if !token.cancelled, Display.compatible(operationDisplays, Display.connected()) {
                    for entry in attempted.reversed() {
                        guard !token.cancelled else { break }
                        let result = await access.place(entry.restore.snapshot, at: entry.rollback, visibleArea: nil, cancellation: token)
                        report(result, context: "Pair rollback")
                        if result.succeeded, let actual = result.actual, pairFramesMatch(actual, entry.rollback) {
                            unresolved.removeAll { $0.snapshot.reference === entry.restore.snapshot.reference }
                        }
                    }
                }
                unresolved.removeAll { NSRunningApplication(processIdentifier: $0.snapshot.pid) == nil }
                groupUndo = unresolved.isEmpty ? oldGroupUndo : unresolved
                undo = unresolved.isEmpty ? oldUndo : nil
                if !token.cancelled { settings.showIssue((error as? AccessFailure)?.message ?? L("Pair placement cancelled.")) }
            }
        }
    }

    private func restoreGroup() {
        guard !busy, !groupUndo.isEmpty else { return }
        let entries = groupUndo
        busy = true
        let token = Cancellation()
        operation = token
        operationDisplays = Display.connected()
        groupPIDs = Set(entries.map { $0.snapshot.pid })
        Task {
            defer { busy = false; groupPIDs = [] }
            for entry in entries.reversed() {
                guard !token.cancelled, let first = Display.connected().first else { break }
                let original = Display.connected().first { $0.id == entry.display.id }
                let display = original ?? first
                let target = GeometryEngine.undoTarget(entry.snapshot.frame, sourceScreen: entry.display.ax(entry.display.frame),
                    currentScreen: original.map { $0.ax($0.frame) }, available: display.axVisible)
                let result = await access.place(entry.snapshot, at: target, visibleArea: nil, cancellation: token)
                report(result, context: "Pair Undo")
                if !token.cancelled, result.succeeded, let actual = result.actual, pairFramesMatch(actual, target) {
                    groupUndo.removeAll { $0.snapshot.reference === entry.snapshot.reference }
                }
            }
            if !token.cancelled, !groupUndo.isEmpty { settings.showIssue(L("Some windows could not be restored. Undo is still available for them.")) }
        }
    }

    private func cancelDrag() {
        pairSuggestions = [:]
        pairScanned = []
        pairFrozen = []
        dragToken?.cancel()
        dragToken = nil
        dragSnapshot = nil
        dragRecognition.cancel()
        dragRecognition = DragRecognition()
        dragHadModifier = false
        dragChecking = false
        dragTimer?.invalidate()
        dragTimer = nil
        dragBarInteraction.cancel()
        dragBarInteraction = DragBarInteraction()
        dragBar.hide()
        overlay.hide()
    }
}

@main struct WindowZonesMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--probe") {
            print("Accessibility=\(AXIsProcessTrusted())")
            for display in Display.connected() {
                print("display=\(display.id) frame=\(display.frame) visible=\(display.visible) scale=\(display.scale)")
            }
            return
        }
        let controller = AppController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
