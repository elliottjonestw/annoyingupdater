import Foundation

public struct InventoryInspection: Codable, Sendable {
    public let apps: [InstalledApp]
    public let uncertainPaths: [String]
}

public enum Inventory {
    public static func discover(in directories: [URL]? = nil) -> [InstalledApp] {
        inspect(in: directories).apps
    }
    public static func inspect(in directories: [URL]? = nil, additionalApps: [URL] = []) -> InventoryInspection {
        var apps: [InstalledApp] = []
        var uncertain: [String] = []
        let roots = directories ?? [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var seen = Set<String>()
        func add(_ url: URL) {
            let path = url.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else { return }
            do { if let app = try inspectApp(at: url) { apps.append(app) } }
            catch { uncertain.append(path); uncertain.append(url.path) }
        }
        for root in roots.map({ $0.resolvingSymlinksInPath() }) {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in
                    uncertain.append(url.path); return true
                }) else { uncertain.append(root.path); continue }
            var visited = 0
            while let url = enumerator.nextObject() as? URL {
                visited += 1
                if visited > 10_000 { uncertain.append(root.path); break }
                let relativeDepth = url.pathComponents.count - root.pathComponents.count
                if relativeDepth > 3 { enumerator.skipDescendants(); continue }
                if !isEligibleLocation(url) { enumerator.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                add(url)
            }
        }
        for url in additionalApps where FileManager.default.fileExists(atPath: url.path) { add(url) }
        return InventoryInspection(apps: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, uncertainPaths: uncertain)
    }
    public static func isEligibleLocation(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        let excluded: Set<String> = [".build", "DerivedData", "node_modules", ".git", ".Trash", ".Trashes", "Backups.backupdb", ".timemachine", "__MACOSX"]
        guard !components.contains(where: { excluded.contains($0) }), !url.path.hasPrefix("/System/") else { return false }
        if components.contains(where: { ["build", "dist", "exports", "target"].contains($0) }) {
            var parent = url.deletingLastPathComponent()
            for _ in 0..<10 {
                if FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) { return false }
                if parent.path == "/" { break }
                parent.deleteLastPathComponent()
            }
        }
        return !components.dropLast().contains { component in
            [".app", ".framework", ".bundle", ".plugin", ".appex", ".xpc"].contains { component.lowercased().hasSuffix($0) }
        }
    }
    public static func volumeIdentity(path: String, volumePath: String, uuid: String) -> String? {
        guard volumePath.hasPrefix("/Volumes/"), path.hasPrefix(volumePath + "/"), !uuid.isEmpty else { return nil }
        return "volume:\(uuid):" + path.dropFirst(volumePath.count)
    }
    public static func inspectApp(at url: URL) throws -> InstalledApp? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app", isEligibleLocation(url) else { return nil }
        let path = url.resolvingSymlinksInPath().path
        guard isEligibleLocation(URL(fileURLWithPath: path)) else { return nil }
        // Read the file each time: Bundle caches Info.plist across external updates.
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { throw CheckError.invalidResponse }
        guard bundleID != "com.annoyingupdater.app" else { return nil }
        // Apple system components are updated by Software Update; embedded/background
        // helpers are part of their owning software, not independent installations.
        guard !(bundleID.hasPrefix("com.apple.") && path.hasPrefix("/Library/")), info["LSBackgroundOnly"] as? Bool != true else { return nil }
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "Unknown"
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        let identity = values?.volume.flatMap { root in
            values?.volumeUUIDString.flatMap { volumeIdentity(path: url.path, volumePath: root.path, uuid: $0) }
        }
        return InstalledApp(path: path, name: name, bundleID: bundleID, version: version,
            build: info["CFBundleVersion"] as? String ?? version,
            feedURL: (info["SUFeedURL"] as? String).flatMap(URL.init(string:)),
            isAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt"),
            installationPath: url.path, installationIdentity: identity)
    }
}
