import Foundation

public enum Inventory {
    public static func discover(in directories: [URL]? = nil) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        let roots = directories ?? [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            var visited = 0
            while let url = enumerator.nextObject() as? URL {
                visited += 1
                if visited > 10_000 { break }
                let relativeDepth = url.pathComponents.count - root.pathComponents.count
                if relativeDepth > 3 { enumerator.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                enumerator.skipDescendants()
                let path = url.resolvingSymlinksInPath().path
                // Bundle caches Info.plist for the lifetime of the process, even when
                // another updater replaces the app. Always read the current file.
                let infoURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
                guard seen.insert(path).inserted,
                      let data = try? Data(contentsOf: infoURL),
                      let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                      let bundleID = info["CFBundleIdentifier"] as? String,
                      bundleID != "com.annoyingupdater.app" else { continue }
                let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
                let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "Unknown"
                let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
                apps.append(InstalledApp(path: path, name: name, bundleID: bundleID, version: version,
                    build: info["CFBundleVersion"] as? String ?? version, feedURL: feed,
                    isAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
