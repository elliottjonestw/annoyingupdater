import Foundation

/// A Finder request contains file URLs, never shell commands or remote URLs.
public enum ApplicationSelection {
    public static func paths(from urls: [URL]) -> [String] {
        var seen = Set<String>()
        return urls.prefix(100).compactMap { url in
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.pathExtension.lowercased() == "app", Inventory.isEligibleLocation(url) else { return nil }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.pathExtension.lowercased() == "app", Inventory.isEligibleLocation(resolved),
                  FileManager.default.fileExists(atPath: resolved.appendingPathComponent("Contents/Info.plist").path),
                  seen.insert(resolved.path).inserted else { return nil }
            return resolved.path
        }
    }
}
