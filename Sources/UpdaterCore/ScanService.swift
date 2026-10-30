import Foundation

public enum ScanService {
    public static func scan(country: String = "US", ownApp: SoftwareSnapshot? = nil, knownAppPaths: [String] = [], browserMonitoring: Bool = false) async -> ScanResult {
        let discovery = await ApplicationDiscovery.inspect(knownPaths: knownAppPaths)
        let inventory = discovery.inventory
        let apps = inventory.apps
        var snapshots = apps.map(SoftwareSnapshot.init(app:)) + [SoftwareSnapshot.operatingSystem]
        if let ownApp { snapshots.append(ownApp) }
        var observation = HistoryObservation(software: snapshots, uncertainPaths: inventory.uncertainPaths)
        async let browser = BrowserExtensionProvider.check(enabled: browserMonitoring)
        async let system = SystemProvider.check()
        async let managed = managedSoftware(apps)
        async let store = AppStoreProvider.check(apps.filter(\.isAppStore), country: country)
        let external = apps.filter { !$0.isAppStore }
        async let homebrewCatalog = HomebrewCatalogProvider.check(external)
        async let appCatalog = AppCatalogProvider.check(external)
        async let electron = ElectronProvider.check(external)
        async let github = GitHubProvider.check(external)
        let sparkleApps = apps.filter { !$0.isAppStore && $0.feedURL != nil }
        var developer: [UpdateItem] = []
        // A bounded group avoids hundreds of simultaneous vendor requests.
        for start in stride(from: 0, to: sparkleApps.count, by: 4) {
            let batch = Array(sparkleApps[start..<min(start + 4, sparkleApps.count)])
            let results = await withTaskGroup(of: UpdateItem.self, returning: [UpdateItem].self) { group in
                for app in batch { group.addTask { await SparkleProvider.check(app) } }
                var results: [UpdateItem] = []
                for await result in group { results.append(result) }
                return results
            }
            developer.append(contentsOf: results)
        }
        let (systemItems, systemReport) = await system
        let (tools, brewItems, brewReport) = await managed
        observation.software += tools.snapshots
        observation.uncertainPaths += tools.uncertainPaths
        let storeItems = await store
        let (homebrewCatalogItems, homebrewCatalogReport) = await homebrewCatalog
        let (appCatalogItems, appCatalogReport) = await appCatalog
        let (electronItems, electronReport) = await electron
        let (githubItems, githubReport) = await github
        let items = DiscoveryMerger.merge(apps: apps, homebrewCatalog: homebrewCatalogItems, appCatalog: appCatalogItems,
            managed: brewItems, repositories: githubItems, publisher: developer + electronItems, store: storeItems)
        var reports = [discovery.report, systemReport, brewReport, ProviderReport("App Store", "\(storeItems.count) apps checked against the catalog"),
                       ProviderReport("Developer feeds", "\(developer.count) apps with published update feeds"),
                       homebrewCatalogReport, appCatalogReport, electronReport, githubReport]
        let mau = "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"
        reports.append(ProviderReport("Microsoft AutoUpdate", FileManager.default.fileExists(atPath: mau) ? "Use Microsoft AutoUpdate for apps without a published feed" : "Not installed"))
        // MAU's listing schema and external Sparkle installation need a real-device
        // feasibility pass. Do not fabricate support or execute unverified installers.
        reports += tools.reports
        let browserResult = await browser
        reports.append(browserResult.report)
        observation.software += browserResult.snapshots
        observation.uncertainPaths += browserResult.uncertainPaths
        let allItems = systemItems + items + tools.items + browserResult.items
        for index in observation.software.indices {
            let snapshot = observation.software[index]
            if let matched = allItems.first(where: { $0.id == snapshot.id || $0.id == snapshot.resolvedPath || (snapshot.kind == .macOS && $0.source == .system && $0.name.lowercased().hasPrefix("macos")) }),
               let context = matched.releaseNotes { observation.software[index].releaseNotes = context }
        }
        return ScanResult(items: allItems, reports: reports, observation: observation)
    }
    private static func managedSoftware(_ apps: [InstalledApp]) async -> (ToolCheck, [UpdateItem], ProviderReport) {
        let tools = await CommandLineTools.check()
        let failedRefresh = tools.reports.contains { $0.name.hasPrefix("Homebrew Tools") && $0.hasError }
        let (items, report) = await HomebrewProvider.check(apps, refresh: failedRefresh)
        return (tools, items, report)
    }
}
