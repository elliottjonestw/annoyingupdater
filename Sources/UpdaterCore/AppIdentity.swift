import Foundation

public enum AppIdentity {
    public static let name = "upd8er"
    // Keep the installed identity and data locations stable across the product rename.
    public static let bundleIdentifier = "com.annoyingupdater.app"
    private static let dataDirectoryName = "Annoying Updater"
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataDirectoryName, isDirectory: true)
    }
    public static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataDirectoryName, isDirectory: true)
    }
}
