import AppKit
import SwiftUI
import UpdaterCore

@main
enum AnnoyingUpdaterApp {
    @MainActor
    static func main() {
        if InventoryWorker.handleCommandLine() { return }
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let model = AppModel(isDemo: ProcessInfo.processInfo.arguments.contains("--demo"))
    private let selfUpdater = SelfUpdater(isDemo: ProcessInfo.processInfo.arguments.contains("--demo"))
    private var dashboard: NSWindow?
    private var reminder: NSWindow?
    private var settings: NSWindow?
    private var statusItem: NSStatusItem?
    private var appearanceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = model.appearance.nativeAppearance
        model.appearanceDidChange = { NSApp.appearance = $0.nativeAppearance }
        appearanceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                NSApp.appearance = self.model.appearance.nativeAppearance
            }
        }
        selfUpdater.start()
        installMenus()
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Annoying Updater")
        status.button?.imagePosition = .imageLeading
        let menu = NSMenu(); menu.delegate = self; status.menu = menu; statusItem = status
        model.presentReminder = { [weak self] in self?.showReminder() }
        model.hideReminder = { [weak self] in self?.reminder?.orderOut(nil) }
        model.reminderVisible = { [weak self] in self?.reminder?.isVisible ?? false }
        model.statusDidChange = { [weak self] in self?.refreshStatus() }
        refreshStatus()
        // Login launches remain in the menu bar; ordinary launches open the dashboard.
        let isLoginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !isLoginLaunch { showDashboard() } else { NSApp.setActivationPolicy(.accessory) }
        model.start()
        if ProcessInfo.processInfo.arguments.contains("--show-reminder") { showReminder() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginItemStatus() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return true }

    @objc func showDashboard() {
        if dashboard == nil {
            let view = DashboardView(model: model, openSettings: { [weak self] in self?.showSettings() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 710),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Annoying Updater"
            window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
            window.contentViewController = NSHostingController(rootView: view)
            window.minSize = NSSize(width: 800, height: 560)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.setFrameAutosaveName("Dashboard"); window.center()
            dashboard = window
        }
        NSApp.setActivationPolicy(.regular)
        dashboard?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings() {
        model.refreshLoginItemStatus()
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Settings"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model, selfUpdater: selfUpdater))
            window.center(); settings = window
        }
        NSApp.setActivationPolicy(.regular)
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showReminder() {
        guard !model.updates.isEmpty else { return }
        model.demoRemindersEnabled = true
        if reminder == nil {
            let view = ReminderView(model: model, openDashboard: { [weak self] in
                self?.model.snooze(); self?.showDashboard()
            })
            let controller = NSHostingController(rootView: view)
            let window = ReminderPanel(contentViewController: controller)
            window.delegate = self
            window.center(); reminder = window
        }
        reminder?.makeKeyAndOrderFront(nil); reminder?.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === reminder { model.snooze(); return false }
        sender.orderOut(nil)
        if !(dashboard?.isVisible ?? false) && !(settings?.isVisible ?? false) { NSApp.setActivationPolicy(.accessory) }
        return false
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let summary = model.isChecking ? "Checking for Updates…" : "\(model.updates.count) Update\(model.updates.count == 1 ? "" : "s") Available"
        let heading = NSMenuItem(title: summary, action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
        if model.isSnoozed { let item = NSMenuItem(title: model.snoozeDescription, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        menu.addItem(.separator())
        add("Open Annoying Updater", #selector(showDashboard), to: menu)
        let check = add("Check for Updates", #selector(checkNow), to: menu); check.isEnabled = !model.isChecking && model.installingID == nil
        let snooze = add("Snooze for 15 Minutes", #selector(snooze), to: menu); snooze.isEnabled = !model.updates.isEmpty
        menu.addItem(.separator())
        add("Settings…", #selector(showSettings), key: ",", to: menu)
        add("Quit Annoying Updater", #selector(quit), key: "q", to: menu)
    }
    private func refreshStatus() {
        statusItem?.button?.title = model.updates.isEmpty ? "" : " \(model.updates.count)"
        statusItem?.button?.toolTip = "Annoying Updater — \(model.updates.count) updates available"
    }
    @objc private func checkForSelfUpdates() { selfUpdater.checkForUpdates() }
    @objc private func checkNow() { Task { await model.check() } }
    @objc private func snooze() { model.snooze() }
    @objc private func quit() {
        if model.installingID != nil {
            let alert = NSAlert(); alert.messageText = "An update is still installing"
            alert.informativeText = "Wait for installation to finish before quitting Annoying Updater."
            alert.addButton(withTitle: "OK"); alert.runModal(); return
        }
        NSApp.terminate(nil)
    }
    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item); return item
    }
    private func installMenus() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); let app = NSMenu(); appItem.submenu = app; bar.addItem(appItem)
        let about = NSMenuItem(title: "About Annoying Updater", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""); app.addItem(about)
        add("Check for Annoying Updater Updates…", #selector(checkForSelfUpdates), to: app)
        app.addItem(.separator()); add("Settings…", #selector(showSettings), key: ",", to: app)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Annoying Updater", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator()); add("Quit Annoying Updater", #selector(quit), key: "q", to: app)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit"); editItem.submenu = edit; bar.addItem(editItem)
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem(); let windows = NSMenu(title: "Window"); windowItem.submenu = windows; bar.addItem(windowItem)
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows; NSApp.mainMenu = bar
    }
}
