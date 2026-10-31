import AppKit
import Combine
import ServiceManagement
import UpdaterCore

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarPage? = .updates
    @Published var releaseNotesRequest: ReleaseNotesRequest?
    @Published var vulnerabilityItem: UpdateItem?
    @Published private(set) var vulnerabilityChecksEnabled: Bool
    @Published private(set) var isCheckingVulnerabilities = false
    private var vulnerabilityTask: Task<Void, Never>?
    private var vulnerabilityGeneration = UUID()
    @Published private var releaseNotesAvailability: [String: Bool] = [:]
    private var checkingNotes: Set<String> = []
    private var checkingAges: Set<String> = []
    @Published var search = ""
    @Published var finderSelectedPaths: Set<String> = []
    @Published var historySearch = ""
    @Published var historyEntries: [UpdateHistoryEntry] = []
    @Published var historyStartedAt: Date?
    @Published var historyError: String?
    @Published var isClearingHistory = false
    @Published var showClearHistoryConfirmation = false
    @Published var expandedHistoryIDs: Set<String> = []
    @Published private var firstDetected: [HistoryOffer: Date] = [:]
    @Published var expandedIDs: Set<String> = []
    @Published var items: [UpdateItem] = []
    @Published var reports: [ProviderReport] = []
    @Published var lastCheck: Date?
    @Published var isChecking = false
    @Published private(set) var hasCompletedScan = false
    @Published var installingID: String?
    @Published private(set) var snoozeDuration: SnoozeDuration
    @Published private(set) var scanInterval: ScanInterval
    @Published private(set) var remindersEnabled: Bool
    @Published var policy = ReminderPolicy()
    @Published var message: String?
    @Published var messageIsError = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginNeedsApproval = false
    @Published var browserMonitoring: Bool
    @Published var country: String
    @Published private(set) var appearance: AppAppearance
    @Published var now = Date()
    let isDemo: Bool
    var demoRemindersEnabled = false
    var presentReminder: (() -> Void)?
    var hideReminder: (() -> Void)?
    var reminderVisible: (() -> Bool)?
    var statusDidChange: (() -> Void)?
    var appearanceDidChange: ((AppAppearance) -> Void)?
    private let defaults: UserDefaults
    private let monitoringPreferences: MonitoringPreferences
    private let loginItems: LoginItemController
    private var heartbeat: Timer?
    private var historyStore: UpdateHistoryStore?
    private var lastObservation: HistoryObservation?
    private var observers: [NSObjectProtocol] = []
    private var sessionAvailable = true
    private var discoveryRefresh: Task<Void, Never>?
    private var discoveryRefreshPending = false
    private var finderCheckPending = false
    private var browserFingerprint = ""
    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Annoying Updater/last-scan.json")
    }
    var updates: [UpdateItem] { items.filter { $0.status == .available && (browserMonitoring || $0.kind != .browserExtension) } }
    var unsupported: [UpdateItem] { items.filter { $0.status == .unsupported } }
    var unverified: [UpdateItem] { items.filter { $0.status == .unverified } }
    var checkedCount: Int { items.filter { $0.status == .available || $0.status == .current }.count }
    var isLoadingResults: Bool { isChecking || !hasCompletedScan }
    var isSnoozed: Bool { policy.isSnoozed(at: now) }
    var snoozeDescription: String {
        guard remindersEnabled else { return "Reminders are off" }
        guard let until = policy.snoozedUntil, until > now else { return "Every \(snoozeDuration.recurrenceLabel) while updates are available" }
        let minutes = max(1, Int(ceil(until.timeIntervalSince(now) / 60)))
        return "Snoozed · \(minutes) min remaining"
    }

    init(isDemo: Bool) {
        self.isDemo = isDemo
        defaults = isDemo ? UserDefaults(suiteName: "com.annoyingupdater.preview")! : .standard
        monitoringPreferences = MonitoringPreferences(defaults: defaults)
        remindersEnabled = monitoringPreferences.remindersEnabled
        snoozeDuration = monitoringPreferences.snoozeDuration
        scanInterval = monitoringPreferences.scanInterval
        loginItems = LoginItemController(service: SystemLoginItemService(), defaults: defaults)
        browserMonitoring = defaults.bool(forKey: "browserMonitoring")
        vulnerabilityChecksEnabled = defaults.object(forKey: "vulnerabilityChecksEnabled") as? Bool ?? true
        country = defaults.string(forKey: "storeCountry") ?? Locale.current.region?.identifier ?? "US"
        appearance = defaults.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .light
        if isDemo {
            hasCompletedScan = true
            launchAtLogin = true
            items = DemoData.items
            historyEntries = DemoData.history
            historyStartedAt = Date().addingTimeInterval(-14 * 86400)
            firstDetected = Dictionary(items.filter { $0.status == .available }.compactMap { item in
                HistoryOffer(item: item).map { ($0, Date().addingTimeInterval(-2 * 86400)) }
            }, uniquingKeysWith: { first, _ in first })
            reports = DemoData.reports
            lastCheck = Date()
        } else {
            policy = ReminderPolicy(snoozedUntil: defaults.object(forKey: "snoozedUntil") as? Date,
                snoozedDuration: (defaults.object(forKey: "snoozedDurationMinutes") as? Int).flatMap(SnoozeDuration.init(rawValue:)))
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
        now = Date()
    }

    func start() {
        browserFingerprint = BrowserInventoryStore().fingerprint()
        configureDefaultLoginItem()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didMountNotification,
                      NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleDiscoveryRefresh() }
            })
        }
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
        if !isDemo { Task { await loadHistory(); await check() } }
    }

    func tick() {
        now = Date(); statusDidChange?()
        if browserMonitoring && !isDemo {
            let fingerprint = BrowserInventoryStore().fingerprint(at: now)
            if fingerprint != browserFingerprint { browserFingerprint = fingerprint; scheduleDiscoveryRefresh(); return }
        }
        guard !isDemo || demoRemindersEnabled else { return }
        guard sessionAvailable, installingID == nil, !isChecking, !isClearingHistory else { return }
        if finderCheckPending { Task { await check() }; return }
        if !isDemo && scanInterval.isDue(lastCheck: lastCheck, at: now) {
            Task { await check() }; return
        }
        guard policy.shouldPresent(at: now, confirmedUpdates: updates.count, isInstalling: false, windowVisible: reminderVisible?() ?? false, remindersEnabled: remindersEnabled) else { return }
        // Reminders use the latest completed check, without shortening the user's scan schedule.
        presentReminder?()
    }

    func check() async {
        guard !isChecking, installingID == nil, !isClearingHistory else { return }
        vulnerabilityTask?.cancel(); vulnerabilityGeneration = UUID(); isCheckingVulnerabilities = false
        isChecking = true; finderCheckPending = false; statusDidChange?()
        if isDemo {
            try? await Task.sleep(for: .milliseconds(700))
            lastCheck = Date()
            hasCompletedScan = true; isChecking = false; statusDidChange?(); return
        }
        let knownPaths = items.filter { $0.kind == .application }.compactMap { $0.installationPath ?? $0.path } + (defaults.stringArray(forKey: "finderAppPaths") ?? [])
        let result = await ScanService.scan(country: country, ownApp: SoftwareSnapshot.ownApp(at: Bundle.main.bundleURL), knownAppPaths: knownPaths, browserMonitoring: browserMonitoring)
        if let observation = result.observation {
            lastObservation = observation
            if let historyStore {
                do {
                    applyHistory(try await historyStore.record(observation, items: result.items, checkedAt: result.date))
                    historyError = nil
                } catch { historyError = "History couldn't be saved. Update checks are still working. \(error.localizedDescription)" }
            }
        }
        let merged = result.preservingLastFindings(from: items)
        items = merged.items.filter { browserMonitoring || $0.kind != .browserExtension }; reports = result.reports; lastCheck = result.date
        now = Date(); hasCompletedScan = true; isChecking = false
        saveCache(); statusDidChange?(); startVulnerabilityChecks()
        if updates.isEmpty { hideReminder?() }
        tick()
        if finderCheckPending { Task { await check() } }
        else if discoveryRefreshPending { discoveryRefreshPending = false; scheduleDiscoveryRefresh() }
    }

    func hasReleaseNotes(_ request: ReleaseNotesRequest) -> Bool { releaseNotesAvailability[request.id] == true }
    func prepareReleaseNotes(_ request: ReleaseNotesRequest) async {
        guard !checkingNotes.contains(request.id) else { return }
        checkingNotes.insert(request.id)
        defer { checkingNotes.remove(request.id) }
        if isDemo { releaseNotesAvailability[request.id] = true; return }
        releaseNotesAvailability[request.id] = (try? await ReleaseNotesService.hasPublishedNotes(request)) ?? false
    }

    func updateAge(for item: UpdateItem) -> UpdateAgeIndicator? {
        let snapshot = lastObservation?.software.first { $0.id == item.id || (item.path != nil && $0.resolvedPath == item.path) || (item.kind == .macOS && $0.id == "system:macos") }
        let detected = UpdateAge.detectionDate(for: item, offers: firstDetected, entries: historyEntries, snapshot: snapshot)
        return UpdateAge.indicator(for: item, detectedAt: detected, at: now)
    }
    func prepareUpdateAge(_ item: UpdateItem) async {
        let requestID = ReleaseNotesRequest(item: item).id
        guard !isDemo, item.status == .available, !checkingAges.contains(requestID) else { return }
        checkingAges.insert(requestID)
        defer { checkingAges.remove(requestID) }
        guard let evidence = await UpdateAge.refine(item),
              let index = items.firstIndex(where: { $0.id == item.id }), items[index].status == .available,
              ReleaseNotesRequest(item: items[index]).id == requestID, evidence.applies(to: items[index], at: Date()) else { return }
        if let current = items[index].updateAgeEvidence, current.date <= evidence.date { return }
        items[index].updateAgeEvidence = evidence
        saveCache()
    }

    func vulnerabilityAssessment(for item: UpdateItem) -> VulnerabilityAssessment? {
        guard vulnerabilityChecksEnabled, let assessment = item.vulnerabilities,
              assessment.requestID == VulnerabilityRequest(item: item).id else { return nil }
        return assessment
    }
    func setVulnerabilityChecks(_ enabled: Bool) {
        vulnerabilityChecksEnabled = enabled; defaults.set(enabled, forKey: "vulnerabilityChecksEnabled")
        vulnerabilityTask?.cancel(); vulnerabilityGeneration = UUID(); isCheckingVulnerabilities = false
        let generation = vulnerabilityGeneration
        Task { [weak self] in
            guard let self, self.vulnerabilityGeneration == generation else { return }
            await VulnerabilityService.cache.cancelPending()
            guard self.vulnerabilityGeneration == generation else { return }
            if self.vulnerabilityChecksEnabled { self.startVulnerabilityChecks() }
        }
    }
    private func startVulnerabilityChecks() {
        guard vulnerabilityChecksEnabled, !isDemo, !isChecking else { return }
        vulnerabilityTask?.cancel()
        let generation = UUID(); vulnerabilityGeneration = generation
        let candidates = items.filter { item in
            VulnerabilityRequest(item: item).canCheck
                && (item.vulnerabilities?.requestID != VulnerabilityRequest(item: item).id || item.vulnerabilities?.needsRefresh(at: Date()) != false)
        }.sorted {
            if ($0.status == .available) != ($1.status == .available) { return $0.status == .available }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard !candidates.isEmpty else { isCheckingVulnerabilities = false; return }
        isCheckingVulnerabilities = true
        vulnerabilityTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.vulnerabilityGeneration == generation { self.isCheckingVulnerabilities = false } }
            for item in candidates {
                guard !Task.isCancelled, self.vulnerabilityChecksEnabled, self.vulnerabilityGeneration == generation else { return }
                let request = VulnerabilityRequest(item: item)
                var assessment = await VulnerabilityService.check(request)
                guard !Task.isCancelled, self.vulnerabilityGeneration == generation,
                      let index = self.items.firstIndex(where: { $0.id == item.id }),
                      VulnerabilityRequest(item: self.items[index]).id == request.id else { continue }
                // Retain an older positive finding on failure, explicitly stale in the UI.
                if assessment.failureReason != nil, let previous = self.items[index].vulnerabilities, previous.requestID == request.id, !previous.findings.isEmpty {
                    assessment.findings = VulnerabilityService.deduplicate(assessment.findings + previous.findings)
                    assessment.checkedAt = min(assessment.checkedAt, previous.checkedAt)
                }
                self.now = Date()
                self.items[index].vulnerabilities = assessment
                self.saveCache()
            }
        }
    }

    func setBrowserMonitoring(_ enabled: Bool) {
        browserMonitoring = enabled; defaults.set(enabled, forKey: "browserMonitoring")
        if !enabled {
            items.removeAll { $0.kind == .browserExtension }
            if updates.isEmpty { hideReminder?() }
        }
        browserFingerprint = BrowserInventoryStore().fingerprint(); scheduleDiscoveryRefresh()
    }
    func prepareBrowserCompanion(_ browser: BrowserFamily) throws {
        let app = Bundle.main.bundleURL
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
        guard app.path.hasPrefix("/Applications/") || app.path.hasPrefix(userApps) else {
            throw CheckError.failed("Move Annoying Updater to Applications before preparing the browser bridge.")
        }
        let executable = app.appendingPathComponent("Contents/MacOS/BrowserBridge").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw CheckError.failed("The browser bridge is missing. Reinstall Annoying Updater.") }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(browser.supportPath + "/NativeMessagingHosts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try BrowserInventoryStore.hostManifest(browser: browser, executable: executable)
            .write(to: directory.appendingPathComponent(BrowserInventoryStore.hostName + ".json"), options: .atomic)
        setBrowserMonitoring(true)
    }
    func openBrowserExtensions(_ browser: BrowserFamily) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            showError("\(browser.title) isn't installed in a location macOS recognizes."); return
        }
        NSWorkspace.shared.open([browser.extensionsURL], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.showError(error.localizedDescription) } }
        }
    }

    func checkFinderApplications(_ paths: [String]) {
        selection = .updates; search = ""; finderSelectedPaths = Set(paths)
        let previous = defaults.stringArray(forKey: "finderAppPaths") ?? []
        defaults.set(Array(Set(previous + paths)).sorted(), forKey: "finderAppPaths")
        finderCheckPending = true
        Task { await check() }
    }

    private func scheduleDiscoveryRefresh() {
        guard !isDemo else { return }
        discoveryRefresh?.cancel()
        discoveryRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            if self.isChecking || self.installingID != nil || self.isClearingHistory {
                self.discoveryRefreshPending = true
            } else { await self.check() }
        }
    }

    func setRemindersEnabled(_ enabled: Bool) {
        remindersEnabled = enabled; monitoringPreferences.setRemindersEnabled(enabled)
        if !enabled { hideReminder?() }
        statusDidChange?()
        if enabled { tick() }
    }

    func setSnoozeDuration(_ duration: SnoozeDuration) {
        snoozeDuration = duration; monitoringPreferences.setSnoozeDuration(duration)
        statusDidChange?()
    }

    func setScanInterval(_ interval: ScanInterval) {
        scanInterval = interval; monitoringPreferences.setScanInterval(interval)
        tick()
    }

    func snooze() {
        guard remindersEnabled else { return }
        now = Date(); policy.snooze(at: now, duration: snoozeDuration)
        if !isDemo {
            defaults.set(policy.snoozedUntil, forKey: "snoozedUntil")
            defaults.set(snoozeDuration.rawValue, forKey: "snoozedDurationMinutes")
        }
        hideReminder?(); statusDidChange?()
    }

    func update(_ item: UpdateItem) async {
        guard installingID == nil, !isChecking, !isClearingHistory else { return }
        message = nil
        if case .copyCommand(let command) = item.action {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            messageIsError = false; message = "Update command copied. Paste it into Terminal when you're ready."
            return
        }
        if isDemo {
            installingID = item.id; hideReminder?()
            try? await Task.sleep(for: .seconds(1.2))
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                let version = item.availableVersion ?? item.installedVersion
                let snapshot = SoftwareSnapshot(id: item.id, name: item.name, bundleID: item.bundleID,
                    path: item.path, version: version, kind: item.source == .system ? .macOS : .application)
                historyEntries.insert(UpdateHistoryEntry(software: snapshot, previousVersion: item.installedVersion,
                    change: .updated, detectedAt: Date(), previouslyObservedAt: lastCheck ?? Date(),
                    firstDetectedAvailableAt: firstDetectedDate(for: item)), at: 0)
                items[index].installedVersion = version
                items[index].availableVersion = nil; items[index].status = .current
                items[index].detail = "Updated in preview. No installed software was changed."
            }
            installingID = nil; statusDidChange?(); return
        }
        switch item.action {
        case .browserExtensions(let family):
            if let browser = BrowserFamily(rawValue: family) { openBrowserExtensions(browser); snooze() }
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
        case .copyCommand: break
        case .microsoft, .none:
            showError("Direct installation isn't available for this app yet. Open its own updater to continue.")
        }
    }

    func firstDetectedDate(for item: UpdateItem) -> Date? {
        guard item.status == .available || item.status == .unverified, let offer = HistoryOffer(item: item) else { return nil }
        return firstDetected[offer]
    }
    private func applyHistory(_ contents: HistoryContents) {
        historyEntries = contents.entries; firstDetected = contents.firstDetected; historyStartedAt = contents.startedAt
    }
    func loadHistory() async {
        guard !isDemo else { return }
        do {
            if historyStore == nil {
                historyStore = try UpdateHistoryStore(url: cacheURL.deletingLastPathComponent().appendingPathComponent("history.sqlite"))
            }
            if let historyStore { applyHistory(try await historyStore.contents()) }
            historyError = nil
        } catch { historyError = "History couldn't be opened. Update checks are still working. \(error.localizedDescription)" }
    }
    func clearHistory() async {
        guard !isChecking, !isClearingHistory else { return }
        isClearingHistory = true
        defer { isClearingHistory = false }
        if isDemo {
            historyEntries = []; expandedHistoryIDs = []; historySearch = ""; historyStartedAt = Date()
            firstDetected = Dictionary(items.filter { $0.status == .available }.compactMap { item in
                HistoryOffer(item: item).map { ($0, Date()) }
            }, uniquingKeysWith: { first, _ in first })
            return
        }
        guard let historyStore else { return }
        do {
            applyHistory(try await historyStore.clear(observation: lastObservation, items: items))
            expandedHistoryIDs = []; historySearch = ""; historyError = nil
        } catch { historyError = "History couldn't be cleared. \(error.localizedDescription)" }
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
    func setAppearance(_ appearance: AppAppearance) {
        self.appearance = appearance
        defaults.set(appearance.rawValue, forKey: "appearance")
        appearanceDidChange?(appearance)
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
