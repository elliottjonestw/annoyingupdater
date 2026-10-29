import Foundation

public struct GitHubRepository: Equatable, Sendable {
    public let owner: String
    public let name: String
    public var latestURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases/latest")! }
    public var website: URL { URL(string: "https://github.com/\(owner)/\(name)/releases/latest")! }
    public static func parse(_ address: String) -> GitHubRepository? {
        var address = address
        if address.hasPrefix("git+") { address.removeFirst(4) }
        if address.hasPrefix("git@github.com:") { address = "https://github.com/" + address.dropFirst(15) }
        guard let url = URL(string: address), url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        guard parts.allSatisfy({ $0 != "." && $0 != ".." && $0.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,99}$"#, options: .regularExpression) != nil }) else { return nil }
        return GitHubRepository(owner: parts[0], name: parts[1])
    }
}

public struct RepositoryMetadata: Sendable {
    public let repository: GitHubRepository
    public let productNames: [String]
}

/// Reads only the archive's root package.json. Dependencies and scripts are never loaded.
public enum RootPackage {
    public static func data(in app: InstalledApp) throws -> Data? {
        let resources = URL(fileURLWithPath: app.path).appendingPathComponent("Contents/Resources")
        for path in ["app/package.json", "package.json"] {
            let file = resources.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: file.path) {
                guard file.resolvingSymlinksInPath().path.hasPrefix(resources.resolvingSymlinksInPath().path + "/") else { throw CheckError.invalidResponse }
                return try ElectronProvider.boundedFile(file, maxBytes: 512 * 1024)
            }
        }
        let archive = resources.appendingPathComponent("app.asar")
        guard FileManager.default.fileExists(atPath: archive.path) else { return nil }
        return try readASAR(archive)
    }

    public static func readASAR(_ url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = try handle.seekToEnd(); try handle.seek(toOffset: 0)
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8, uint32(prefix, at: 0) == 4 else { throw CheckError.invalidResponse }
        let headerSize = Int(uint32(prefix, at: 4))
        guard headerSize >= 8, headerSize <= 8 * 1024 * 1024, UInt64(headerSize) + 8 <= total,
              let header = try handle.read(upToCount: headerSize), header.count == headerSize else { throw CheckError.invalidResponse }
        let length = Int(uint32(header, at: 4))
        guard length <= headerSize - 8, Int(uint32(header, at: 0)) <= headerSize - 4,
              let root = try JSONSerialization.jsonObject(with: header.subdata(in: 8..<(8 + length))) as? [String: Any],
              let files = root["files"] as? [String: Any] else { throw CheckError.invalidResponse }
        guard let entry = files["package.json"] as? [String: Any] else { return nil }
        guard entry["link"] == nil, entry["unpacked"] as? Bool != true,
              let size = entry["size"] as? Int, size > 0, size <= 512 * 1024,
              let offsetString = entry["offset"] as? String, let offset = UInt64(offsetString), offset <= total else { throw CheckError.invalidResponse }
        let base = UInt64(8 + headerSize)
        guard base <= total, offset <= total - base, UInt64(size) <= total - base - offset else { throw CheckError.invalidResponse }
        try handle.seek(toOffset: base + offset)
        guard let data = try handle.read(upToCount: size), data.count == size else { throw CheckError.invalidResponse }
        return data
    }
    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
}

public enum GitHubProvider {
    public static func metadata(_ data: Data, app: InstalledApp) throws -> RepositoryMetadata? {
        guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = package["version"] as? String,
              let localVersion = ReleaseVersions.numeric(app.version), let packageVersion = ReleaseVersions.numeric(version),
              Versions.compare(localVersion, packageVersion) == .orderedSame else { return nil }
        let address = package["repository"] as? String ?? (package["repository"] as? [String: Any])?["url"] as? String
        guard let address, let repository = GitHubRepository.parse(address) else { return nil }
        let names = [app.name, package["productName"] as? String, package["name"] as? String].compactMap { $0 }
        return RepositoryMetadata(repository: repository, productNames: names)
    }

    public static func evaluate(_ data: Data, app: InstalledApp, metadata: RepositoryMetadata,
                                checkedAt: Date = Date(), platform: MacCompatibility = .current) throws -> UpdateItem {
        guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let draft = release["draft"] as? Bool, let prerelease = release["prerelease"] as? Bool,
              let tag = release["tag_name"] as? String, let assets = release["assets"] as? [[String: Any]] else { throw CheckError.invalidResponse }
        var item = app.item; item.source = .github; item.status = .unverified
        item.action = .website(metadata.repository.website.absoluteString)
        let version = tag.replacingOccurrences(of: #"^release[-/]"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard !draft, !prerelease, ReleaseVersions.numeric(version) != nil else {
            item.detail = "The repository release isn't an identifiable stable version."; return item
        }
        let names = metadata.productNames.map(normalized).filter { $0.count >= 4 }
        let matchingAssets = assets.filter { asset in
            guard asset["state"] as? String == "uploaded", let name = asset["name"] as? String,
                  let address = asset["browser_download_url"] as? String, let url = URL(string: address), PublicURL.isAllowed(url) else { return false }
            let lower = name.lowercased()
            guard lower.hasSuffix(".dmg") || lower.hasSuffix(".zip"),
                  !lower.contains("linux"), !lower.contains("windows"), !lower.contains("win32"),
                  names.contains(where: { normalized(name).hasPrefix($0) }) else { return false }
            guard lower.hasSuffix(".dmg") || lower.hasSuffix(".app.zip")
                    || lower.range(of: #"(?:^|[-_.])(?:mac|macos|darwin|osx)(?:[-_.]|$)"#, options: .regularExpression) != nil else { return false }
            if lower.contains("universal") { return true }
            if lower.contains("arm64") || lower.contains("aarch64") { return platform.architecture == "arm64" }
            if lower.contains("x64") || lower.contains("x86_64") || lower.contains("intel") { return platform.architecture == "x86_64" }
            return true
        }
        guard !matchingAssets.isEmpty else {
            item.detail = "The repository release has no identifiable Mac download for this product and architecture."; return item
        }
        item.status = ReleaseVersions.status(candidate: version, installed: app.version, build: app.build)
        item.availableVersion = item.status == .available ? ReleaseVersions.numeric(version) : nil
        item.checkedAt = checkedAt
        item.detail = item.status == .unverified ? "The repository's version format couldn't be compared reliably."
            : "Checked stable releases in the repository declared by this app, with a matching Mac download."
        return item
    }

    public static func check(_ apps: [InstalledApp], cache: MetadataCache = .shared) async -> ([UpdateItem], ProviderReport) {
        var items: [UpdateItem] = []
        for app in apps where !app.isAppStore && app.feedURL == nil && ElectronProvider.configuration(in: app) == nil {
            do {
                guard let data = try RootPackage.data(in: app), let metadata = try metadata(data, app: app) else { continue }
                do {
                    let snapshot = try await cache.load(metadata.repository.latestURL, ttl: 6 * 3600)
                    items.append(try evaluate(snapshot.data, app: app, metadata: metadata, checkedAt: snapshot.fetchedAt))
                } catch {
                    var item = app.item; item.source = .github; item.status = .unverified
                    item.action = .website(metadata.repository.website.absoluteString)
                    item.detail = "GitHub releases couldn't be checked. \(error.localizedDescription)"
                    items.append(item)
                }
            } catch {
                // Malformed root package metadata does not establish a repository source.
                continue
            }
        }
        let errors = items.filter { $0.status == .unverified }.count
        return (items, ProviderReport("GitHub", "\(items.count) repositories discovered · \(items.count - errors) apps verified · \(errors) couldn't be verified", hasError: errors > 0))
    }

    private static func normalized(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }
}
