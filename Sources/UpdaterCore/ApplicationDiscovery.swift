import AppKit
import Foundation

public struct ApplicationDiscoveryResult: Sendable {
    public var inventory: InventoryInspection
    public var report: ProviderReport
}

public enum ApplicationDiscovery {
    @MainActor
    private static func runningLocations() -> [URL] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
    }
    public static func inspect(knownPaths: [String] = []) async -> ApplicationDiscoveryResult {
        let running = await runningLocations()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"), home.appendingPathComponent("Downloads")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsInternalKey], options: []) ?? []
        roots += volumes.filter {
            guard $0.path.hasPrefix("/Volumes/") else { return false }
            let values = try? $0.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey])
            // Do not walk protected internal maintenance volumes such as Recovery.
            // Spotlight and running-app discovery still cover other internal disks.
            return values?.volumeIsLocal != false && values?.volumeIsInternal != true
        }
        var candidates = running + knownPaths.map { URL(fileURLWithPath: $0) }
        var spotlightFailed = false
        do {
            let data = try await CommandRunner.run("/usr/bin/mdfind", ["-0", "kMDItemContentType == 'com.apple.application-bundle'"], timeout: 15).requireSuccess()
            candidates += String(decoding: data, as: UTF8.self).split(separator: "\0").prefix(10_000).map { URL(fileURLWithPath: String($0)) }
        } catch { spotlightFailed = true }
        // A separate process can be stopped even while macOS is waiting for folder
        // permission or a volume is stuck in a filesystem call. Keep other results.
        var found: [InstalledApp] = [], uncertain: [String] = []
        for root in roots.prefix(16) {
            let part = await InventoryWorker.inspect(roots: [root.path], paths: [], timeout: 8)
            found += part.apps; uncertain += part.uncertainPaths
        }
        let additional = await InventoryWorker.inspect(roots: [], paths: Array(candidates.prefix(10_000)).map(\.path), timeout: 15)
        found += additional.apps; uncertain += additional.uncertainPaths
        var seen = Set<String>()
        var inspection = InventoryInspection(apps: found.filter { seen.insert($0.path).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, uncertainPaths: Array(Set(uncertain)))
        // An absent volume is unavailable, rather than proof its apps were removed.
        let missingVolumes = knownPaths.filter { path in
            guard path.hasPrefix("/Volumes/") else { return false }
            let components = URL(fileURLWithPath: path).pathComponents
            guard components.count > 2 else { return false }
            return !FileManager.default.fileExists(atPath: "/Volumes/" + components[2])
        }
        inspection = InventoryInspection(apps: inspection.apps, uncertainPaths: inspection.uncertainPaths + missingVolumes)
        let issues = !inspection.uncertainPaths.isEmpty || spotlightFailed
        let message = "\(inspection.apps.count) apps discovered from Applications, Downloads, running apps, mounted drives, and Spotlight."
            + (issues ? " Some locations were unavailable or unindexed; running apps and accessible folders are still checked." : "")
        return ApplicationDiscoveryResult(inventory: inspection, report: ProviderReport("App Discovery", message, hasError: issues))
    }
}
