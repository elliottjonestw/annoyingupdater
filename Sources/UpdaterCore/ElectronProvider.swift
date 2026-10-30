import Foundation
import Yams

public struct ElectronConfiguration: Decodable, Sendable {
    public var provider: String
    public var url: String?
    public var channel: String?
    public var owner: String?
    public var repo: String?
    public var host: String?
    public var bucket: String?
    public var region: String?
    public var path: String?
    public var name: String?
    public var `private`: Bool?
    public var token: String?
    public var requestHeaders: [String: String]?
}

private struct ElectronManifest: Decodable {
    struct File: Decodable { var url: String }
    var version: String
    var files: [File]?
    var path: String?
    var minimumSystemVersion: String?
    var stagingPercentage: Double?
    var releaseDate: String?
}

public enum ElectronProvider {
    public static func configuration(in app: InstalledApp) -> URL? {
        let url = URL(fileURLWithPath: app.path).appendingPathComponent("Contents/Resources/app-update.yml")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func parseConfiguration(_ data: Data) throws -> ElectronConfiguration {
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else { throw CheckError.invalidResponse }
        let config: ElectronConfiguration
        do { config = try YAMLDecoder().decode(ElectronConfiguration.self, from: text) }
        catch { throw CheckError.failed("The embedded update configuration couldn't be read.") }
        guard config.private != true, config.token == nil, config.requestHeaders?.isEmpty ?? true else {
            throw CheckError.failed("This updater requires private access. Check for updates in the app.")
        }
        return config
    }

    public static func manifestURL(_ config: ElectronConfiguration) throws -> URL {
        let channel = config.channel ?? "latest"
        guard channel.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,50}$"#, options: .regularExpression) != nil else { throw CheckError.invalidResponse }
        let base: URL?
        switch config.provider {
        case "generic": base = config.url.flatMap(URL.init(string:))
        case "github":
            guard config.host == nil || config.host == "github.com", channel == "latest",
                  let owner = config.owner, let repo = config.repo,
                  validRepositoryPart(owner), validRepositoryPart(repo) else {
                throw CheckError.failed("This GitHub updater's host or release channel couldn't be verified.")
            }
            base = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download")
        case "s3":
            guard let bucket = config.bucket, validHostPart(bucket), config.region.map(validHostPart) ?? true else { throw CheckError.invalidResponse }
            let region = config.region.map { ".\($0)" } ?? ""
            base = URL(string: "https://\(bucket).s3\(region).amazonaws.com")
        case "spaces":
            guard let name = config.name, let region = config.region, validHostPart(name), validHostPart(region) else { throw CheckError.invalidResponse }
            base = URL(string: "https://\(name).\(region).digitaloceanspaces.com")
        default: throw CheckError.failed("This Electron updater uses a provider that isn't supported yet.")
        }
        guard var base, PublicURL.isAllowed(base) else { throw CheckError.failed("The app's update feed isn't a public HTTPS address.") }
        if config.provider == "s3" || config.provider == "spaces", let path = config.path {
            guard !path.split(separator: "/").contains("..") else { throw CheckError.invalidResponse }
            base.appendPathComponent(path)
        }
        let result = base.appendingPathComponent(channel + "-mac.yml")
        guard PublicURL.isAllowed(result) else { throw CheckError.invalidResponse }
        return result
    }

    public static func evaluate(_ data: Data, app: InstalledApp, feed: URL, checkedAt: Date = Date(),
                                platform: MacCompatibility = .current, kernelVersion: String = currentKernelVersion) throws -> UpdateItem {
        guard data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) else { throw CheckError.invalidResponse }
        let manifest: ElectronManifest
        do { manifest = try YAMLDecoder().decode(ElectronManifest.self, from: text) }
        catch { throw CheckError.invalidResponse }
        var item = app.item; item.source = .electron; item.status = .unverified
        let files = manifest.files?.map(\.url) ?? manifest.path.map { [$0] } ?? []
        guard files.contains(where: { compatibleFile($0, architecture: platform.architecture, feed: feed) }) else {
            item.detail = "The publisher's manifest doesn't list a matching Mac download."; item.verificationIssue = .platform; return item
        }
        if let minimum = manifest.minimumSystemVersion {
            guard ReleaseVersions.numeric(minimum) != nil, ReleaseVersions.numeric(kernelVersion) != nil,
                  Versions.compare(kernelVersion, minimum) != .orderedAscending else {
                item.detail = "The publisher's release requires a newer macOS kernel. Check for a compatible version in the app."; item.verificationIssue = .platform; return item
            }
        }
        if let percentage = manifest.stagingPercentage, percentage < 100 || percentage > 100 || !percentage.isFinite {
            item.detail = "The publisher is rolling out this release gradually. Availability for this installation couldn't be confirmed."; item.verificationIssue = .stagedRollout; return item
        }
        item.status = ReleaseVersions.status(candidate: manifest.version, installed: app.version, build: app.build)
        item.verificationIssue = item.status == .unverified ? .versionFormat : nil
        item.availableVersion = item.status == .available ? manifest.version : nil
        item.checkedAt = checkedAt
        item.releaseNotes?.prepend(ReleaseNotesSource(.electron, url: feed))
        if let date = manifest.releaseDate.flatMap(UpdateAge.publicationDate) {
            item.updateAgeEvidence = UpdateAgeEvidence.earliest([ReleaseNote(version: manifest.version, date: date)], source: ReleaseNotesSource(.electron, url: feed), item: item)
        }
        item.detail = item.status == .unverified ? "The publisher's version format couldn't be compared reliably. Check in the app."
            : "Checked the update feed discovered inside this app. Open the app to finish updating."
        return item
    }

    public static func check(_ apps: [InstalledApp], cache: MetadataCache = .shared) async -> ([UpdateItem], ProviderReport) {
        var items: [UpdateItem] = []
        for app in apps where !app.isAppStore {
            guard let file = configuration(in: app) else { continue }
            do {
                let config = try parseConfiguration(try boundedFile(file, maxBytes: 64 * 1024))
                let feed = try manifestURL(config)
                let snapshot = try await cache.load(feed, ttl: 3600, maxBytes: 512 * 1024)
                var item = try evaluate(snapshot.data, app: app, feed: feed, checkedAt: snapshot.fetchedAt)
                if config.provider == "github", let owner = config.owner, let repo = config.repo {
                    item.releaseNotes?.prepend(ReleaseNotesSource(.github, url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases")!, identifier: app.name))
                }
                items.append(item)
            } catch {
                var item = app.item; item.source = .electron; item.status = .unverified
                item.verificationIssue = .unavailable
                item.detail = "The app's Electron update feed couldn't be verified. \(error.localizedDescription)"
                items.append(item)
            }
        }
        return (items, ProviderReport("Electron", "\(items.count) embedded configurations · \(items.filter { $0.status != .unverified }.count) apps verified"))
    }

    public static func boundedFile(_ url: URL, maxBytes: Int) throws -> Data {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes else { throw CheckError.invalidResponse }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { throw CheckError.invalidResponse }
        return data
    }

    public static var currentKernelVersion: String {
        var system = utsname()
        guard uname(&system) == 0 else { return "" }
        return withUnsafeBytes(of: &system.release) { bytes in String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self)) }
    }

    private static func compatibleFile(_ address: String, architecture: String, feed: URL) -> Bool {
        guard let url = URL(string: address, relativeTo: feed)?.absoluteURL, PublicURL.isAllowed(url) else { return false }
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".zip") || name.hasSuffix(".dmg"), !name.contains("linux"), !name.contains("win32"), !name.contains("windows") else { return false }
        if name.contains("universal") { return true }
        if name.contains("arm64") || name.contains("aarch64") { return architecture == "arm64" }
        if name.contains("x64") || name.contains("x86_64") || name.contains("intel") { return architecture == "x86_64" }
        return true // The macOS-specific manifest supplies the platform for unqualified names.
    }
    private static func validRepositoryPart(_ string: String) -> Bool {
        string != "." && string != ".." && string.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,99}$"#, options: .regularExpression) != nil
    }
    private static func validHostPart(_ string: String) -> Bool {
        string.range(of: #"^[a-z0-9][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil
    }
}
