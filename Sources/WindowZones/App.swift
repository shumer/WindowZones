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
    private var pickerLayoutID = BuiltInLayouts.focused.id
    private var sessionLayouts: [UInt32: UUID] = [:]
    private var picker: PickerWindow?
    private var pickerDisplay: NSPopUpButton?
    private var pickerHint: NSTextField?
    private var pickerContent: ZonePickerContent?
    private var pickerSnapshot: WindowSnapshot?
    private var pickerCapture: Cancellation?
    private var pickerDisplays: [Display] = []
    private var operationDisplays: [Display] = []
    private var operation: Cancellation?
    private var operationPID: pid_t?
    private var busy = false
    private var undo: (snapshot: WindowSnapshot, display: Display, actual: CGRect)?
    private let overlay = Overlay()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var dragEnabled = true
    private let dragBar = DragBar()
    private var dragBarInteraction = DragBarInteraction()
    private var dragMenuItem: NSMenuItem!
    private var dragToken: Cancellation?
    private var dragSnapshot: WindowSnapshot?
    private var dragStart = CGPoint.zero
    private var dragDisplays: [Display] = []
    private var dragRecognition = DragRecognition()
    private var dragHadShift = false
    private var dragChecking = false
    private var dragTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.instance = self
        NSApp.setActivationPolicy(.accessory)
        settings = ApplicationSettings()
        makeMenu()
        makeDiagnostics()
        loadLayouts()
        installHotkey(option: true)
        installMonitors()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(contextChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(contextChanged), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(targetApplicationTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        record("Запуск: чужие окна не изменялись. Перетаскивание вверх и Shift-drag включены.")
        if !AXIsProcessTrusted() { settings.show() }
        if CommandLine.arguments.contains("--smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        operation?.cancel()
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
                library = loaded.collection
                layoutStore = store
                if loaded.source == .backup { libraryWarning = "Восстановлено из копии" }
            } catch {
                libraryWarning = "Сохранение недоступно"
                record("Хранилище раскладок недоступно. Встроенные варианты работают без записи файлов.")
            }
        }
    }

    private func activeLayout(for display: Display) -> Layout {
        let key = display.uniqueStorageKey(in: Display.connected())
        let id = sessionLayouts[display.id] ?? key.flatMap { library.activeByDisplay[$0] }
        return library.layouts.first { $0.id == id }
            ?? library.layouts.first { $0.id == BuiltInLayouts.focused.id }
            ?? library.layouts[0]
    }

    private func resolvedZones(_ layout: Layout, on display: Display) -> [CGRect] {
        (try? LayoutGeometry.zones(for: layout, in: display.visible, scale: display.scale).map(\.frame)) ?? []
    }

    private func activeZones(on display: Display) -> [CGRect] {
        resolvedZones(activeLayout(for: display), on: display)
    }

    private func saveActiveLayout(_ id: UUID, displayKey: String?) async {
        guard let displayKey, let layoutStore else {
            record("Раскладка выбрана для текущего сеанса, постоянное сохранение недоступно.")
            return
        }
        do {
            let updated = try library.committingPlacement(layoutID: id, displayKey: displayKey, succeeded: true)
            try await layoutStore.save(updated)
            library = updated
            libraryWarning = nil
        } catch {
            libraryWarning = "Выбор не сохранён"
            record("Окно размещено, но выбор раскладки не сохранён. Текущий выбор действует до завершения сеанса.")
        }
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▥"
        statusItem.button?.setAccessibilityLabel("WindowZones")
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        _ = add("Выбрать зону для активного окна", #selector(pick))
        _ = add("Отменить последнее размещение", #selector(undoPlacement))
        menu.addItem(.separator())
        dragMenuItem = add("Перетаскивание: верхняя полоска и Shift", #selector(toggleDrag))
        dragMenuItem.state = dragEnabled ? .on : .off
        _ = add("Сменить shortcut: Ctrl+Shift / Ctrl+Option + Space", #selector(changeShortcut))
        _ = add("Настройки…", #selector(showSettings))
        _ = add("Проверить обновления…", #selector(checkUpdates))
        _ = add("Диагностика и разрешение", #selector(showDiagnostics))
        menu.addItem(.separator())
        _ = add("Завершить WindowZones", #selector(quit))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { refreshReport() }

    private func makeDiagnostics() {
        diagnostics = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        diagnostics.title = "WindowZones: этап 0"
        diagnostics.isReleasedWhenClosed = false
        let stack = verticalStack()
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Accessibility нужен для перемещения и изменения размера выбранного окна. Разрешение выдаётся вручную. Содержимое окон и нажатые клавиши не сохраняются."))
        let buttons = NSStackView()
        for (title, action) in [("Открыть Accessibility", #selector(openPermissions)), ("Обновить статус", #selector(refreshPermissions)), ("Отменить размещение", #selector(undoPlacement))] {
            buttons.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(buttons)
        let testRow = NSStackView()
        testRow.spacing = 8
        testApplication = NSPopUpButton()
        testApplication.setAccessibilityLabel("Приложение для проверки окна")
        testRow.addArrangedSubview(testApplication)
        testRow.addArrangedSubview(NSButton(title: "Обновить список", target: self, action: #selector(refreshTestApplications)))
        testRow.addArrangedSubview(NSButton(title: "Открыть выбор зон", target: self, action: #selector(pickTestApplication)))
        stack.addArrangedSubview(testRow)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Проверка: выбери запущенное приложение. Панель откроется для его активного обычного окна. До выбора зоны окно не перемещается."))
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
            testApplication.addItem(withTitle: app.localizedName ?? app.bundleIdentifier ?? "Приложение")
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
        guard libraryLoaded, !busy else { record("Дождись завершения текущей операции"); return }
        guard let pid = testApplication.selectedItem?.representedObject as? Int32,
              let app = testApplications.first(where: { $0.processIdentifier == pid }), !app.isTerminated else {
            record("Выбранное приложение недоступно. Обнови список.")
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
        guard let frame else { return "нет" }
        return String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", frame.minX, frame.minY, frame.width, frame.height)
    }
    private func refreshReport() {
        guard reportView != nil else { return }
        let displays = Display.connected().map { "display \($0.id), scale \($0.scale), visible \(format($0.visible))" }.joined(separator: "\n")
        reportView.string = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nAccessibility: \(AXIsProcessTrusted() ? "разрешён" : "не разрешён")\nShortcut: \(shortcut) \(shortcutStatus)\nShift-drag: \(dragEnabled ? "включён" : "выключен")\n\(displays)\n\n" + reports.joined(separator: "\n\n")
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
                    AppController.instance?.record("Получена команда shortcut")
                    AppController.instance?.pick()
                }
                return noErr
            }, 1, &event, nil, &handler)
            guard handlerStatus == noErr else {
                shortcutStatus = "обработчик недоступен: \(handlerStatus)"
                return
            }
        }
        let modifiers = UInt32(controlKey | (option ? optionKey : shiftKey))
        let result = RegisterEventHotKey(UInt32(kVK_Space), modifiers, EventHotKeyID(signature: 0x575A3030, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        shortcut = option ? "Control+Option+Space" : "Control+Shift+Space"
        shortcutStatus = result == noErr ? "зарегистрирован" : "конфликт или ошибка \(result); выбери другое сочетание в меню"
    }
    @objc private func changeShortcut() {
        installHotkey(option: shortcut == "Control+Shift+Space")
        refreshReport()
    }

    @objc func pick() {
        guard libraryLoaded else { record("Раскладки ещё загружаются"); return }
        guard !busy else { record("Команда отклонена: предыдущая операция ещё выполняется"); return }
        if picker != nil { cancelPicker(); return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            record("Сначала активируй чужое обычное окно, затем нажми \(shortcut).")
            return
        }
        beginPicker(for: app, fromDiagnostics: false)
    }

    private func beginPicker(for app: NSRunningApplication, fromDiagnostics: Bool) {
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
        record("Выбор окна приложения: \(app.bundleIdentifier ?? "unknown")")
        Task {
            defer {
                busy = false
                if pickerCapture === token { pickerCapture = nil }
            }
            do {
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
        record("\(issue?.status ?? "failed"): \(issue?.message ?? "Ошибка AX")")
        showDiagnostics()
    }

    private func showPicker(_ snapshot: WindowSnapshot) {
        pickerDisplays = Display.connected()
        guard !pickerDisplays.isEmpty else { record("Нет доступного экрана"); return }
        let window = PickerWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Разместить выбранное окно"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = ZonePickerContent(applicationName: NSRunningApplication(processIdentifier: snapshot.pid)?.localizedName ?? "Приложение", layouts: library.layouts)
        let popup = content.displayPopup
        for (index, display) in pickerDisplays.enumerated() { popup.addItem(withTitle: "Экран \(index + 1): \(Int(display.visible.width)) × \(Int(display.visible.height))") }
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
        let zones = pickerZones(on: display)
        picker.zoneCount = zones.count
        picker.selected = min(max(0, picker.selected), max(0, zones.count - 1))
        let name = library.layouts.first { $0.id == pickerLayoutID }?.name ?? "Раскладка"
        pickerHint?.stringValue = zones.isEmpty ? "Раскладка не помещается на этом экране" : "\(name) · Зона \(picker.selected + 1)"
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
            record("Конфигурация экранов изменилась или зона недоступна")
            return
        }
        cancelPicker()
        perform(snapshot, target: display.ax(zones[index]), display: display, isUndo: false, layoutID: layoutID, displayKey: displayKey)
    }

    private func perform(_ snapshot: WindowSnapshot, target: CGRect, display: Display, isUndo: Bool, layoutID: UUID? = nil, displayKey: String? = nil) {
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
                report(result, context: "Поздний результат завершённой сессии, undo не обновлён")
                return
            }
            if result.succeeded, let actual = result.actual {
                if isUndo { undo = nil }
                else {
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
        }
    }

    @objc private func undoPlacement() {
        guard !busy, let undo else { record("Нет доступной операции undo"); return }
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
            record("Undo: геометрия исходного экрана изменилась, frame скорректирован")
        }
        perform(undo.snapshot, target: target, display: display, isUndo: true)
    }

    @objc private func screenChanged() {
        let current = Display.connected()
        sessionLayouts = sessionLayouts.filter { id, _ in current.contains { $0.id == id } }
        var baselines: [[Display]] = []
        if picker != nil { baselines.append(pickerDisplays) }
        if dragToken != nil { baselines.append(dragDisplays) }
        if busy { baselines.append(operationDisplays) }
        guard baselines.contains(where: { !Display.compatible($0, current) }) else {
            refreshReport()
            return
        }
        cancelForContextChange("Конфигурация экранов изменилась")
    }

    @objc private func contextChanged(_ notification: Notification) {
        let reason = notification.name == NSWorkspace.willSleepNotification ? "Переход в сон" : "Смена Space"
        cancelForContextChange(reason)
    }

    @objc private func targetApplicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if undo?.snapshot.pid == pid { undo = nil }
        guard pickerSnapshot?.pid == pid || dragSnapshot?.pid == pid || (busy && operationPID == pid) else { return }
        cancelForContextChange("Целевое приложение завершено")
    }

    private func cancelForContextChange(_ reason: String) {
        let hadInteraction = picker != nil || pickerCapture != nil || dragToken != nil || busy
        dismissPicker(restoreFocus: false)
        cancelDrag()
        if hadInteraction { record("\(reason): взаимодействие отменено без возврата фокуса") }
        else { refreshReport() }
    }

    @objc private func toggleDrag() {
        dragEnabled.toggle()
        dragMenuItem.state = dragEnabled ? .on : .off
        cancelDrag()
        record("Перетаскивание \(dragEnabled ? "включено" : "выключено"). Верхняя полоска и Shift, обычный заголовок окна.")
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
            if picker != nil || pickerCapture != nil { cancelPicker() }
            cancelDrag()
            return
        }
        guard dragEnabled, libraryLoaded, !busy, picker == nil else { return }
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
            dragHadShift = event.modifierFlags.contains(.shift)
            Task { [self] in
                do {
                    let snapshot = try await access.captureDrag(at: point, cancellation: token)
                    guard !token.cancelled, dragToken === token, let now = axPointer(),
                          let targetApp = NSRunningApplication(processIdentifier: snapshot.pid), !targetApp.isTerminated,
                          hypot(now.x - point.x, now.y - point.y) <= 3 else {
                        if dragToken === token { cancelDrag() }
                        return
                    }
                    dragSnapshot = snapshot
                    dragTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.checkDrag() }
                    }
                } catch {
                    if dragToken === token { cancelDrag() }
                }
            }
        } else if event.type == .flagsChanged {
            if event.modifierFlags.contains(.shift) { dragHadShift = true }
            else if dragHadShift { cancelDrag() }
        } else if event.type == .leftMouseDragged {
            if event.modifierFlags.contains(.shift) { dragHadShift = true }
            checkDrag()
        } else if event.type == .leftMouseUp {
            finishDrag(shift: event.modifierFlags.contains(.shift))
        }
    }

    private func checkDrag() {
        guard let snapshot = dragSnapshot, let token = dragToken, !dragChecking else { return }
        guard AXIsProcessTrusted(), Display.compatible(dragDisplays, Display.connected()),
              NSEvent.pressedMouseButtons & 1 != 0 else { cancelDrag(); return }
        if dragHadShift && !NSEvent.modifierFlags.contains(.shift) { cancelDrag(); return }
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
                    if NSEvent.modifierFlags.contains(.shift) {
                        dragBar.hide()
                        dragBarInteraction = DragBarInteraction()
                        let zones = activeZones(on: display)
                        overlay.show(display: display, selected: zones.firstIndex(where: { $0.contains(location) }), zones: zones)
                    } else {
                        let geometry = DragBarGeometry(layouts: library.layouts, area: display.visible, scale: display.scale)
                        dragBarInteraction.update(pointer: location, screen: display.id, geometry: geometry)
                        dragBar.show(geometry: geometry, interaction: dragBarInteraction)
                        if let choice = dragBarInteraction.selected {
                            overlay.show(display: display, selected: 0, zones: [choice.target], showsLabels: false)
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
        if shift {
            guard let target = activeZones(on: display).first(where: { $0.contains(location) }) else { cancelDrag(); return }
            zone = target
            layoutID = nil
        } else {
            let geometry = DragBarGeometry(layouts: library.layouts, area: display.visible, scale: display.scale)
            guard let choice = dragBarInteraction.drop(at: location, screen: display.id, geometry: geometry) else { cancelDrag(); return }
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
                perform(snapshot, target: display.ax(zone), display: display, isUndo: false, layoutID: layoutID, displayKey: displayKey)
            } catch {
                busy = false
                if !token.cancelled { recordAccessError(error) }
            }
        }
    }

    private func cancelDrag() {
        dragToken?.cancel()
        dragToken = nil
        dragSnapshot = nil
        dragRecognition.cancel()
        dragRecognition = DragRecognition()
        dragHadShift = false
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
