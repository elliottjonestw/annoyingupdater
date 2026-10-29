import Foundation

public enum ScanService {
    public static func scan(country: String = "US") async -> ScanResult {
        let apps = await Task.detached(priority: .utility) { Inventory.discover() }.value
        async let system = SystemProvider.check()
        async let brew = HomebrewProvider.check(apps)
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
        let (brewItems, brewReport) = await brew
        let storeItems = await store
        let (homebrewCatalogItems, homebrewCatalogReport) = await homebrewCatalog
        let (appCatalogItems, appCatalogReport) = await appCatalog
        let (electronItems, electronReport) = await electron
        let (githubItems, githubReport) = await github
        let items = DiscoveryMerger.merge(apps: apps, homebrewCatalog: homebrewCatalogItems, appCatalog: appCatalogItems,
            managed: brewItems, repositories: githubItems, publisher: developer + electronItems, store: storeItems)
        var reports = [systemReport, brewReport, ProviderReport("App Store", "\(storeItems.count) apps checked against the catalog"),
                       ProviderReport("Developer feeds", "\(developer.count) apps with published update feeds"),
                       homebrewCatalogReport, appCatalogReport, electronReport, githubReport]
        let mau = "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"
        reports.append(ProviderReport("Microsoft AutoUpdate", FileManager.default.fileExists(atPath: mau) ? "Use Microsoft AutoUpdate for apps without a published feed" : "Not installed"))
        // MAU's listing schema and external Sparkle installation need a real-device
        // feasibility pass. Do not fabricate support or execute unverified installers.
        return ScanResult(items: systemItems + items, reports: reports)
    }
}
