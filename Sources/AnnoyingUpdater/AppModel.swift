import AppKit
import Combine
import ServiceManagement
import UpdaterCore

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarPage? = .updates
    @Published var search = ""
    @Published var expandedIDs: Set<String> = []
    @Published var items: [UpdateItem] = []
    @Published var reports: [ProviderReport] = []
    @Published var lastCheck: Date?
    @Published var isChecking = false
    @Published var installingID: String?
    @Published var policy = ReminderPolicy()
    @Published var message: String?
    @Published var messageIsError = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginNeedsApproval = false
    @Published var country: String
    @Published var now = Date()
    let isDemo: Bool
    var demoRemindersEnabled = false
    var presentReminder: (() -> Void)?
    var hideReminder: (() -> Void)?
    var reminderVisible: (() -> Bool)?
    var statusDidChange: (() -> Void)?
    private let defaults: UserDefaults
    private let loginItems: LoginItemController
    private var heartbeat: Timer?
    private var observers: [NSObjectProtocol] = []
    private var sessionAvailable = true
    private var lastReminderValidation: Date?
    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Annoying Updater/last-scan.json")
    }
    var updates: [UpdateItem] { items.filter { $0.status == .available } }
    var unsupported: [UpdateItem] { items.filter { $0.status == .unsupported } }
    var unverified: [UpdateItem] { items.filter { $0.status == .unverified } }
    var checkedCount: Int { items.filter { $0.status == .available || $0.status == .current }.count }
    var isSnoozed: Bool { policy.isSnoozed(at: now) }
    var snoozeDescription: String {
        guard let until = policy.snoozedUntil, until > now else { return "Every 15 minutes while updates are available" }
        let minutes = max(1, Int(ceil(until.timeIntervalSince(now) / 60)))
        return "Snoozed · \(minutes) min remaining"
    }

    init(isDemo: Bool) {
        self.isDemo = isDemo
        defaults = isDemo ? UserDefaults(suiteName: "com.annoyingupdater.preview")! : .standard
        loginItems = LoginItemController(service: SystemLoginItemService(), defaults: defaults)
        country = defaults.string(forKey: "storeCountry") ?? Locale.current.region?.identifier ?? "US"
        if isDemo {
            launchAtLogin = true
            items = DemoData.items
            reports = DemoData.reports
            lastCheck = Date()
        } else {
            policy = ReminderPolicy(snoozedUntil: defaults.object(forKey: "snoozedUntil") as? Date)
            if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(ScanResult.self, from: data) {
                items = cache.items.map { old in
                    var item = old
                    if item.status != .unsupported {
                        item.status = .unverified
                        item.detail = "Saved result. Waiting for a fresh check before reminding you."
                    }
                    return item
                }
                lastCheck = cache.date; reports = cache.reports
            }
        }
    }

    func start() {
        configureDefaultLoginItem()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.sessionAvailable = true
                    if !self.isDemo { await self.check() }
                }
            })
        }
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sessionAvailable = false; self?.hideReminder?() }
            })
        }
        if !isDemo { Task { await check() } }
    }

    func tick() {
        now = Date(); statusDidChange?()
        guard !isDemo || demoRemindersEnabled else { return }
        guard sessionAvailable, installingID == nil, !isChecking else { return }
        if !isDemo && (lastCheck == nil || now.timeIntervalSince(lastCheck!) >= 3600) {
            Task { await check() }; return
        }
        guard policy.shouldPresent(at: now, confirmedUpdates: updates.count, isInstalling: false, windowVisible: reminderVisible?() ?? false) else { return }
        // Revalidate before resurfacing, rather than repeating a stale cached finding.
        if !isDemo && (lastReminderValidation == nil || now.timeIntervalSince(lastReminderValidation!) >= ReminderPolicy.snoozeInterval) {
            Task { await check() }; return
        }
        presentReminder?()
    }

    func check() async {
        guard !isChecking, installingID == nil else { return }
        isChecking = true; statusDidChange?()
        if isDemo {
            try? await Task.sleep(for: .milliseconds(700))
            lastCheck = Date(); lastReminderValidation = Date()
            isChecking = false; statusDidChange?(); return
        }
        let result = await ScanService.scan(country: country)
        let merged = result.preservingLastFindings(from: items)
        items = merged.items; reports = result.reports; lastCheck = result.date
        lastReminderValidation = Date(); now = Date(); isChecking = false
        saveCache(); statusDidChange?()
        if updates.isEmpty { hideReminder?() }
        tick()
    }

    func snooze() {
        now = Date(); policy.snooze(at: now)
        if !isDemo { defaults.set(policy.snoozedUntil, forKey: "snoozedUntil") }
        hideReminder?(); statusDidChange?()
    }

    func update(_ item: UpdateItem) async {
        guard installingID == nil, !isChecking else { return }
        message = nil
        if isDemo {
            installingID = item.id; hideReminder?()
            try? await Task.sleep(for: .seconds(1.2))
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].installedVersion = item.availableVersion ?? item.installedVersion
                items[index].availableVersion = nil; items[index].status = .current
                items[index].detail = "Updated in preview. No installed software was changed."
            }
            installingID = nil; statusDidChange?(); return
        }
        switch item.action {
        case .systemSettings:
            open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
            snooze()
        case .appStore(let id):
            open(URL(string: id.map { "macappstore://itunes.apple.com/app/id\($0)" } ?? "macappstore://showUpdatesPage")!)
            snooze()
        case .openApp(let path):
            do { try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) }
            catch { showError(error.localizedDescription) }
            snooze()
        case .website(let address):
            guard let url = URL(string: address), PublicURL.isAllowed(url) else {
                showError("The developer's website couldn't be verified."); return
            }
            open(url); snooze()
        case .homebrew(let executable, let cask):
            guard executable == HomebrewProvider.executable,
                  cask.range(of: #"^[a-z0-9][a-z0-9@+._/-]*$"#, options: .regularExpression) != nil else {
                showError("The app's installation source has changed. Check for updates again."); return
            }
            if let bundleID = Optional(item.bundleID), !bundleID.isEmpty,
               NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { !$0.isTerminated }) {
                let alert = NSAlert()
                alert.messageText = "Quit \(item.name) to update?"
                alert.informativeText = "Save your work first. Annoying Updater will ask the app to quit before updating it."
                alert.addButton(withTitle: "Quit and Update"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
                for _ in 0..<30 {
                    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).allSatisfy(\.isTerminated) { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).allSatisfy(\.isTerminated) else {
                    showError("\(item.name) is still running. Quit the app, then try updating again."); return
                }
            }
            installingID = item.id; hideReminder?(); statusDidChange?()
            do {
                _ = try await CommandRunner.run(executable, ["upgrade", "--cask", "--no-quit", cask], timeout: 1800).requireSuccess()
                messageIsError = false; message = "Installation finished. Checking the installed version…"
            } catch { showError(error.localizedDescription) }
            installingID = nil
            await check()
        case .microsoft, .none:
            showError("Direct installation isn't available for this app yet. Open its own updater to continue.")
        }
    }

    func showError(_ text: String) { messageIsError = true; message = text }
    private func open(_ url: URL) { if !NSWorkspace.shared.open(url) { showError("The updater couldn't be opened. Try opening it from Applications.") } }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isDemo else { launchAtLogin = enabled; return }
        do {
            try loginItems.setEnabled(enabled)
            refreshLoginItemStatus()
            if enabled && loginNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { showError("Open at login couldn't be changed. \(error.localizedDescription)"); refreshLoginItemStatus() }
    }
    private func configureDefaultLoginItem() {
        guard !isDemo else { return }
        do {
            let requested = try loginItems.configureDefault()
            refreshLoginItemStatus()
            if requested && launchAtLogin {
                messageIsError = false
                message = "Open at login is on. You can change this in Settings."
            }
        } catch {
            refreshLoginItemStatus()
            showError("Open at login couldn't be enabled automatically. You can try again in Settings. \(error.localizedDescription)")
        }
    }
    func refreshLoginItemStatus() {
        guard !isDemo else { return }
        launchAtLogin = loginItems.isEnabled
        loginNeedsApproval = loginItems.requiresApproval
    }
    func openLoginItemSettings() { if !isDemo { SMAppService.openSystemSettingsLoginItems() } }
    func setCountry(_ country: String) {
        self.country = country; if !isDemo { defaults.set(country, forKey: "storeCountry") }
    }
    private func saveCache() {
        guard !isDemo, let lastCheck else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ScanResult(items: items, reports: reports, date: lastCheck))
            try data.write(to: cacheURL, options: .atomic)
        } catch { showError("Couldn't save the latest check: \(error.localizedDescription)") }
    }
}
