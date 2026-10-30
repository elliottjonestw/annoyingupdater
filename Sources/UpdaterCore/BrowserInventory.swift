import Foundation
import CryptoKit

public enum BrowserFamily: String, Codable, CaseIterable, Sendable {
    case chrome, brave, chromium, firefox
    public var title: String { switch self { case .chrome: return "Chrome"; case .brave: return "Brave"; case .chromium: return "Chromium"; case .firefox: return "Firefox" } }
    public var bundleID: String { switch self { case .chrome: return "com.google.Chrome"; case .brave: return "com.brave.Browser"; case .chromium: return "org.chromium.Chromium"; case .firefox: return "org.mozilla.firefox" } }
    // Brave overrides native host discovery to Chrome locations on macOS.
    // https://github.com/brave/brave-core/blob/master/app/brave_main_delegate.cc
    public var supportPath: String { switch self { case .chrome: return "Google/Chrome"; case .brave: return "Google/Chrome"; case .chromium: return "Chromium"; case .firefox: return "Mozilla" } }
    public var extensionsURL: URL { URL(string: self == .firefox ? "about:addons" : "chrome://extensions/")! }
}
public struct BrowserExtension: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var enabled: Bool
    public var installType: String
    public var updateURL: String?
    public init(id: String, name: String, version: String, enabled: Bool = true, installType: String = "normal", updateURL: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.enabled = enabled; self.installType = installType; self.updateURL = updateURL
    }
}
public struct BrowserProfile: Codable, Sendable {
    public var protocolVersion: Int
    public var profileID: String
    public var label: String
    public var browser: BrowserFamily
    public var browserVersion: String
    public var extensions: [BrowserExtension]
    public var receivedAt: Date?
    public var namespace: String { "browser-extension/\(browser.rawValue)/\(profileID.lowercased())" }
    public init(profileID: String, label: String, browser: BrowserFamily, browserVersion: String, extensions: [BrowserExtension], receivedAt: Date? = nil) {
        protocolVersion = 1; self.profileID = profileID; self.label = label; self.browser = browser; self.browserVersion = browserVersion
        self.extensions = extensions; self.receivedAt = receivedAt
    }
    public func isFresh(at date: Date) -> Bool {
        guard let receivedAt else { return false }; let age = date.timeIntervalSince(receivedAt)
        return age >= 0 && age < 180
    }
    public func validated() throws -> BrowserProfile {
        guard protocolVersion == 1, UUID(uuidString: profileID) != nil, label.count <= 80, !label.isEmpty, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Self.numeric(browserVersion), extensions.count <= 500,
              Set(extensions.map(\.id)).count == extensions.count else { throw CheckError.invalidResponse }
        for item in extensions {
            guard !item.id.isEmpty, item.id != ".", item.id != "..", item.id.utf8.count <= 200, !item.id.contains("/"), !item.id.contains("\\"),
                  !item.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !item.name.isEmpty, item.name.count <= 200, !item.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !item.version.isEmpty, item.version.count <= 80, item.installType.count <= 30, (item.updateURL?.count ?? 0) < 2048,
                  browser == .firefox || item.id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil else { throw CheckError.invalidResponse }
        }
        return self
    }
    public static func numeric(_ value: String) -> Bool { value.count <= 80 && value.range(of: "^[0-9]+(?:\\.[0-9]+){0,5}$", options: .regularExpression) != nil }
}
public struct BrowserInventoryStore: Sendable {
    public static let hostName = "com.annoyingupdater.browser"
    public static let firefoxID = "browser-companion@annoyingupdater.app"
    // Public manifest key gives unpacked Chromium builds a stable origin.
    public static let chromiumID = "cnciihpabdhnhlijmcbfkapfmfgaocjp"
    public let directory: URL
    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Annoying Updater/Browser Profiles")) { self.directory = directory }
    public func save(_ payload: Data, at date: Date = Date()) throws {
        guard payload.count <= 512 * 1024 else { throw CheckError.invalidResponse }
        var profile = try JSONDecoder().decode(BrowserProfile.self, from: payload).validated()
        profile.receivedAt = date // Do not trust a timestamp supplied by a browser.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("\(profile.browser.rawValue)-\(profile.profileID.lowercased()).json")
        try JSONEncoder().encode(profile).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func read() -> (profiles: [BrowserProfile], failed: Bool) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], false) }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return ([], true) }
        var profiles: [BrowserProfile] = [], failed = files.count > 100
        for file in files.prefix(100) where file.pathExtension == "json" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1024,
                  let data = try? Data(contentsOf: file), let profile = try? JSONDecoder().decode(BrowserProfile.self, from: data).validated(),
                  file.lastPathComponent == "\(profile.browser.rawValue)-\(profile.profileID.lowercased()).json" else { failed = true; continue }
            profiles.append(profile)
        }
        return (profiles, failed)
    }
    public func fingerprint(at date: Date = Date()) -> String {
        let result = read()
        let values = result.profiles.sorted { $0.namespace < $1.namespace }.map { profile -> String in
            let entries = profile.extensions.sorted { $0.id < $1.id }.map { "\($0.id):\($0.version):\($0.enabled):\($0.installType):\($0.updateURL ?? "")" }.joined(separator: "|")
            return "\(profile.namespace):\(profile.label):\(profile.browserVersion):\(profile.isFresh(at: date)):\(entries)"
        }.joined(separator: "\n") + "\(result.failed)"
        return SHA256.hash(data: Data(values.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func hostManifest(browser: BrowserFamily, executable: String) throws -> Data {
        guard executable.hasPrefix("/") else { throw CheckError.invalidResponse }
        var result: [String: Any] = ["name": hostName, "description": "Annoying Updater extension inventory", "path": executable, "type": "stdio"]
        if browser == .firefox { result["allowed_extensions"] = [firefoxID] }
        else { result["allowed_origins"] = ["chrome-extension://\(chromiumID)/"] }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }
}
public enum NativeMessage {
    public static let maximumSize = 512 * 1024
    public static func read(from handle: FileHandle) throws -> Data? {
        func exact(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else { break }
                data.append(part)
            }
            return data
        }
        let header = try exact(4)
        if header.isEmpty { return nil }
        guard header.count == 4 else { throw CheckError.invalidResponse }
        let length = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        guard length > 0, length <= maximumSize else { throw CheckError.invalidResponse }
        let payload = try exact(Int(length)); guard payload.count == Int(length) else { throw CheckError.invalidResponse }
        return payload
    }
    public static func write(_ data: Data, to handle: FileHandle) throws {
        guard data.count <= maximumSize else { throw CheckError.invalidResponse }
        let count = UInt32(data.count)
        try handle.write(contentsOf: Data((0..<4).map { UInt8(truncatingIfNeeded: count >> (8 * $0)) }) + data)
    }
}
