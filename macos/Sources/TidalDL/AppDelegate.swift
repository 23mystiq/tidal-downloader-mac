import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var main: MainWindowController!
    private var login: LoginController?
    private lazy var about = AboutWindowController()
    private lazy var settingsWindow = SettingsWindowController()
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        main = MainWindowController()
        main.showWindow(nil)
        main.window?.makeKeyAndOrderFront(nil)

        let backend = Backend.shared
        backend.onEvent = { AppState.shared.handle(event: $0, data: $1) }
        backend.onExit = { [weak self] status, stderr in self?.backendDied(status: status, stderr: stderr) }
        do {
            try backend.start()
        } catch {
            fatal("Cannot start the downloader engine", "\(error)")
            return
        }
        initialize()
    }

    /// Port of `MainWindow.init_tidal` + the startup update check.
    private func initialize() {
        Backend.shared.call("init") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fatal("Could not start", "\(error)")
            case .success(let value):
                let d = value as? [String: Any] ?? [:]
                AppState.shared.version = d["version"] as? String ?? ""
                if let settings = d["settings"] as? [String: Any] { AppState.shared.applySettings(settings) }
                let loggedIn = d["loggedIn"] as? Bool ?? false
                AppState.shared.setAccount(loggedIn: loggedIn, isPkce: d["isPkce"] as? Bool ?? false)
                if !loggedIn { self.presentLogin(required: true) }
                self.checkForUpdates(onStartup: true)
            }
        }
    }

    private func presentLogin(required: Bool) {
        guard login == nil, let window = main.window else { return }
        let controller = LoginController(required: required) { [weak self] outcome in
            self?.login = nil
            if outcome == .cancelled, required { NSApp.terminate(nil) }
            self?.main.rebuildMenusAfterLogin()
        }
        login = controller
        controller.begin(on: window)
    }

    private func checkForUpdates(onStartup: Bool) {
        Backend.shared.call("update.check") { [weak self] result in
            guard case .success(let value) = result, let d = value as? [String: Any] else { return }
            let info = AboutWindowController.UpdateInfo(d)
            if !onStartup || info.available { self?.about.show(update: info) }
        }
    }

    private func backendDied(status: Int32, stderr: String) {
        guard !terminating else { return }
        let lastLines = stderr.split(separator: "\n").suffix(8).joined(separator: "\n")
        fatal("The downloader engine stopped unexpectedly (\(status))", lastLines.isEmpty ? "No details were reported." : lastLines)
    }

    private func fatal(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        if let window = main.window {
            alert.beginSheetModal(for: window) { _ in NSApp.terminate(nil) }
        } else {
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    // MARK: Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Port of `closeEvent`: abort running downloads and stop the backend.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Backend.shared.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Menu actions

    @objc func showAbout(_ sender: Any?) { about.show(update: nil) }

    @objc func checkUpdates(_ sender: Any?) { checkForUpdates(onStartup: false) }

    @objc func showSettings(_ sender: Any?) { settingsWindow.show() }

    @objc func signInForLossless(_ sender: Any?) { presentLogin(required: !AppState.shared.loggedIn) }

    /// Port of `on_logout`: removes the token and quits.
    @objc func logout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Log out of TIDAL?"
        alert.informativeText = "Your saved login is removed and the app quits. You’ll sign in again next time."
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let proceed = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            Backend.shared.call("logout") { _ in NSApp.terminate(nil) }
        }
        if let window = main.window { alert.beginSheetModal(for: window, completionHandler: proceed) } else { proceed(alert.runModal()) }
    }

    @objc func focusSearch(_ sender: Any?) { main.focusSearch() }

    @objc func focusFilters(_ sender: Any?) { main.split.results.focusFilters() }

    @objc func downloadSelection(_ sender: Any?) { main.split.results.downloadSelected() }

    @objc func downloadLists(_ sender: Any?) { main.split.sidebar.downloadSelectedLists() }

    @objc func reloadLists(_ sender: Any?) { AppState.shared.reloadLists() }

    @objc func toggleQueue(_ sender: Any?) { main.split.inspector.toggleQueue() }

    @objc func removeFromQueue(_ sender: Any?) { main.split.inspector.removeSelected() }

    @objc func clearFinished(_ sender: Any?) { AppState.shared.clearFinished() }

    @objc func clearAll(_ sender: Any?) { AppState.shared.clearAll() }

    @objc func openDownloads(_ sender: Any?) {
        let path = (AppState.shared.settings?.string("download_base_path") ?? "~") as NSString
        NSWorkspace.shared.open(URL(fileURLWithPath: path.expandingTildeInPath))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let ready = AppState.shared.settings != nil
        switch item.action {
        case #selector(toggleQueue(_:)):
            item.title = AppState.shared.queueRunning ? "Pause Downloads" : "Resume Downloads"
            return ready
        case #selector(showSettings(_:)), #selector(openDownloads(_:)):
            return ready
        case #selector(logout(_:)):
            return AppState.shared.loggedIn
        case #selector(signInForLossless(_:)):
            item.title = AppState.shared.isPkce ? "Sign In Again…" : "Sign In with Browser for Lossless…"
            return ready && login == nil
        case #selector(downloadSelection(_:)), #selector(downloadLists(_:)), #selector(reloadLists(_:)), #selector(focusSearch(_:)):
            return AppState.shared.loggedIn
        default:
            return true
        }
    }

    // MARK: Menu bar

    private func buildMenu() -> NSMenu {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let host = NSMenuItem()
            host.submenu = menu
            bar.addItem(host)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, symbol: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            return item
        }

        let appName = "TIDAL Downloader"
        let services = NSMenu()
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        _ = menu(appName, [
            item("About \(appName)", #selector(showAbout(_:))),
            item("Check for Updates…", #selector(checkUpdates(_:))),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ","),
            .separator(),
            item("Sign In with Browser for Lossless…", #selector(signInForLossless(_:))),
            item("Log Out…", #selector(logout(_:))),
            .separator(),
            servicesItem,
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = menu("File", [
            item("Search…", #selector(focusSearch(_:)), "f", symbol: "magnifyingglass"),
            item("Filter Results", #selector(focusFilters(_:)), "f", [.command, .option], symbol: "line.3.horizontal.decrease"),
            .separator(),
            item("Show Downloads Folder", #selector(openDownloads(_:)), "o", [.command, .shift], symbol: "folder"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = menu("View", [
            item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Show Inspector", #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        _ = menu("Downloads", [
            item("Download Selection", #selector(downloadSelection(_:)), "d", symbol: "arrow.down.circle"),
            item("Download Selected Lists", #selector(downloadLists(_:)), "d", [.command, .shift], symbol: "music.note.list"),
            .separator(),
            item("Pause Downloads", #selector(toggleQueue(_:)), "p", [.command, .option], symbol: "playpause"),
            item("Remove from Queue", #selector(removeFromQueue(_:)), symbol: "minus.circle"),
            item("Clear Finished", #selector(clearFinished(_:)), symbol: "checkmark.circle"),
            item("Clear All", #selector(clearAll(_:)), symbol: "trash"),
            .separator(),
            item("Reload Lists", #selector(reloadLists(_:)), "r", symbol: "arrow.clockwise"),
        ])
        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        NSApp.helpMenu = menu("Help", [])
        return bar
    }
}

extension MainWindowController {
    func rebuildMenusAfterLogin() {
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}
