import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let catalog = WindowCatalog()
    private lazy var switcher = SwitcherController(catalog: catalog)
    private let focusTracker = FocusTracker()
    private let updater = Updater()
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?
    private var tracking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AX.setGlobalTimeout(0.25)
        NSApp.mainMenu = Self.makeMainMenu()
        setUpStatusItem()

        hotKey = HotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.hotKeyPressed() }
        }
        if hotKey?.status != noErr {
            showAlert(title: "⌥Space is already in use",
                      message: "Another app has claimed Option+Space, so Hop can't use it. You can still open Hop from the menu bar icon.")
        }

        catalog.onWindowsDiscovered = { [weak self] in
            MainActor.assumeIsolated { self?.switcher.refreshIfVisible() }
        }
        focusTracker.onFocusedWindow = { [weak self] window in
            self?.catalog.noteFocused(window: window)
        }

        updater.start()

        if AX.isTrusted(prompt: true) {
            startTracking()
        } else {
            // Light polling only until permission is granted, then it stops for good.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard AX.isTrusted(prompt: false) else { return }
                    timer.invalidate()
                    self?.startTracking()
                }
            }
        }
    }

    private func hotKeyPressed() {
        guard AX.isTrusted(prompt: false) else {
            requestAccessibility()
            return
        }
        switcher.toggle()
    }

    private func startTracking() {
        guard !tracking else { return }
        tracking = true

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self?.catalog.recordFocusedWindow(ofPID: app.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.focusTracker.observe(app) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.focusTracker.forget(app.processIdentifier) }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // Give the window server a moment to settle, then remember what's visible here.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { self?.catalog.harvestVisible(apps: AppInfo.regularApps()) }
            }
        }

        for app in NSWorkspace.shared.runningApplications {
            focusTracker.observe(app)
        }
        catalog.warmUp(apps: AppInfo.regularApps())
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Hop")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "Open Switcher", action: #selector(openSwitcher), keyEquivalent: " ")
        open.keyEquivalentModifierMask = .option
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        if AX.isTrusted(prompt: false) {
            let allowed = NSMenuItem(title: "Accessibility Access Allowed", action: nil, keyEquivalent: "")
            allowed.state = .on
            allowed.isEnabled = false
            menu.addItem(allowed)
        } else {
            let grant = NSMenuItem(title: "Allow Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "Hop \(Updater.currentVersionString)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)

        let updateTitle = updater.available.map { "Update to Hop \($0.version)…" } ?? "Check for Updates…"
        let update = NSMenuItem(title: updateTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        let quit = NSMenuItem(title: "Quit Hop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func openSwitcher() {
        // Let the status menu finish closing before taking focus.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.hotKeyPressed() } }
    }

    @objc private func checkForUpdates() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.updater.check(userInitiated: true) } }
    }

    @objc private func openAccessibilitySettings() {
        _ = AX.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(title: "Couldn't change Launch at Login", message: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func requestAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Hop needs Accessibility access"
        alert.informativeText = "Hop uses Accessibility to list and focus your windows. Turn on Hop in System Settings › Privacy & Security › Accessibility."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openAccessibilitySettings() }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Accessory apps have no visible menu bar, but Edit shortcuts (⌘V, ⌘A…) in the
    /// search field only work if the main menu defines them.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }
}
