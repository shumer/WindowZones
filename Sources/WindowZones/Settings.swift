import AppKit
import ApplicationServices
import ServiceManagement
import Sparkle

@MainActor final class ApplicationSettings: NSObject {
    private var window: NSWindow?
    private var login: NSButton!
    private var automatic: NSButton!
    private var message: NSTextField!
    private var permission: NSTextField!
    private var updater: SPUStandardUpdaterController?
    private var updaterError: String?

    override init() {
        super.init()
        let info = Bundle.main.infoDictionary ?? [:]
        if let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), url.scheme == "https",
           let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 {
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            do {
                try controller.updater.start()
                updater = controller
            } catch {
                updaterError = "Не удалось запустить проверку обновлений."
            }
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
            message.stringValue = updaterError ?? "Обновления станут доступны после настройки канала релизов."
            return
        }
        updater.checkForUpdates(nil)
    }

    private func makeWindow() {
        let panel = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 490, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Настройки WindowZones"
        panel.isReleasedWhenClosed = false
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let header = NSStackView()
        header.spacing = 14
        let image = NSImageView(image: NSApp.applicationIconImage)
        image.widthAnchor.constraint(equalToConstant: 60).isActive = true
        image.heightAnchor.constraint(equalToConstant: 60).isActive = true
        header.addArrangedSubview(image)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let title = NSTextField(labelWithString: "WindowZones \(version)\nРаскладки окон для macOS")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        header.addArrangedSubview(title)
        root.addArrangedSubview(header)
        login = NSButton(checkboxWithTitle: "Запускать при входе в систему", target: self, action: #selector(changeLogin))
        root.addArrangedSubview(login)
        automatic = NSButton(checkboxWithTitle: "Проверять обновления автоматически", target: self, action: #selector(changeAutomaticUpdates))
        root.addArrangedSubview(automatic)
        root.addArrangedSubview(NSButton(title: "Проверить обновления…", target: self, action: #selector(checkForUpdates)))
        permission = NSTextField(wrappingLabelWithString: "")
        root.addArrangedSubview(permission)
        root.addArrangedSubview(NSButton(title: "Открыть Accessibility", target: self, action: #selector(openPermissions)))
        message = NSTextField(wrappingLabelWithString: "")
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(message)
        panel.contentView = root
        root.widthAnchor.constraint(equalToConstant: 490).isActive = true
        panel.center()
        window = panel
    }

    @objc private func refresh() {
        guard window != nil else { return }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        automatic.isEnabled = updater != nil
        automatic.state = updater?.updater.automaticallyChecksForUpdates == true ? .on : .off
        permission.stringValue = AXIsProcessTrusted() ? "Accessibility разрешён. Можно размещать окна." : "Для перемещения окон разреши Accessibility."
        if SMAppService.mainApp.status == .requiresApproval {
            message.stringValue = "Подтверди автозапуск в Системных настройках > Основные > Объекты входа."
        } else if updater == nil {
            message.stringValue = updaterError ?? "Канал обновлений ещё не настроен для этой сборки."
        } else {
            message.stringValue = "Проверка и установка обновлений выполняются через Sparkle."
        }
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
                message.stringValue = "Не удалось изменить автозапуск. Установи приложение в «Программы» и повтори."
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
}
