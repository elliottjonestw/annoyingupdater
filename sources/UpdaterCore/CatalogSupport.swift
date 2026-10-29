import Foundation

public struct MacCompatibility: Sendable {
    public let os: String
    public let architecture: String
    public init(os: String, architecture: String) { self.os = os; self.architecture = architecture }
    public static var current: MacCompatibility {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return MacCompatibility(os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: arch)
    }
}

/// Catalogs can mix artifact versions with bundle versions; uncertain comparisons never nag.
public enum ReleaseVersions {
    public static func numeric(_ value: String) -> String? {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") { value.removeFirst() }
        value = value.replacingOccurrences(of: #"-[a-fA-F0-9]{7,40}$"#, with: "", options: .regularExpression)
        guard value.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil,
              value.count < 100 else { return nil }
        return value
    }
    public static func status(candidate: String, installed: String, build: String) -> UpdateStatus {
        guard let available = numeric(candidate), let local = numeric(installed) else { return .unverified }
        if Versions.compare(available, local) == .orderedSame { return .current }
        if let localBuild = numeric(build), Versions.compare(available, localBuild) == .orderedSame { return .current }
        if let localBuild = numeric(build), Versions.compare(available, local + "." + localBuild) == .orderedSame { return .current }
        let a = available.split(separator: "."), b = local.split(separator: ".")
        // Do not interpret extra catalog build components as a missing app update.
        if a.count != b.count { return .unverified }
        // E.g. a browser's engine-prefixed bundle version vs its product version.
        if let firstA = Int(a[0]), let firstB = Int(b[0]), min(firstA, firstB) > 0,
           max(firstA, firstB) / min(firstA, firstB) >= 10 { return .unverified }
        return Versions.newer(available, than: local) ? .available : .current
    }
}

public struct CatalogCandidate: Sendable {
    public let id: String
    public let version: String
    public let homepage: URL?
    public let names: Set<String>
    public let identifiers: Set<String>
    public let identifierHints: Set<String>
    public let minimumOS: String?
    public let architectures: Set<String>
    public let channel: String
    public let uncertainty: String?

    public init(id: String, version: String, homepage: URL? = nil, names: Set<String> = [], identifiers: Set<String> = [],
                identifierHints: Set<String> = [], minimumOS: String? = nil, architectures: Set<String> = [], channel: String = "stable", uncertainty: String? = nil) {
        self.id = id; self.version = version; self.homepage = homepage; self.names = names
        self.identifiers = identifiers; self.identifierHints = identifierHints; self.minimumOS = minimumOS
        self.architectures = architectures; self.channel = channel
        self.uncertainty = uncertainty
    }
}

public enum CatalogMatching {
    public static func match(_ app: InstalledApp, candidates: [CatalogCandidate], source: UpdateSource,
                             checkedAt: Date, platform: MacCompatibility = .current) -> UpdateItem? {
        guard !app.isAppStore else { return nil }
        let id = app.bundleID.lowercased()
        let name = URL(fileURLWithPath: app.path).lastPathComponent.lowercased()
        let matches = candidates.filter {
            $0.identifiers.contains(id) || $0.identifierHints.contains(id) || $0.names.contains(name)
        }
        guard !matches.isEmpty else { return nil }
        var verified = matches.filter { $0.identifiers.contains(id) || ($0.identifierHints.contains(id) && $0.names.contains(name)) }
        // Distinguish renamed/alternate editions sharing an identifier using the actual app artifact.
        let named = verified.filter { $0.names.contains(name) }
        if !named.isEmpty { verified = named }
        let stable = verified.filter { $0.channel == "stable" }
        var item = app.item; item.source = source; item.status = .unverified
        item.verificationIssue = .identity
        let editions = verified.filter { $0.channel == "stable" || $0.channel == "lts" }
        guard stable.count == 1, editions.count == 1, let candidate = stable.first else {
            item.verificationIssue = editions.count > 1 ? .ambiguousEdition : .identity
            item.detail = editions.count > 1 ? "Several editions match this app. Update availability couldn't be verified automatically."
                : "A catalog candidate was found, but its app identity or release channel couldn't be verified."
            return item
        }
        if let uncertainty = candidate.uncertainty { item.detail = uncertainty; item.verificationIssue = .platform; return item }
        guard candidate.architectures.isEmpty || candidate.architectures.contains(platform.architecture),
              candidate.minimumOS.map({ Versions.compare(platform.os, $0) != .orderedAscending }) ?? true else {
            item.detail = "The catalog release requires a different Mac or newer macOS. Check the developer for a compatible release."
            item.verificationIssue = .platform
            return item
        }
        item.status = ReleaseVersions.status(candidate: candidate.version, installed: app.version, build: app.build)
        item.verificationIssue = item.status == .unverified ? .versionFormat : nil
        item.checkedAt = checkedAt
        if let url = candidate.homepage, PublicURL.isAllowed(url) { item.action = .website(url.absoluteString) }
        switch item.status {
        case .available:
            item.availableVersion = ReleaseVersions.numeric(candidate.version) ?? candidate.version
            item.detail = "A newer release is listed in \(source.rawValue). Matched using the app's identifier. Open the developer's website to update."
        case .current:
            item.detail = "No newer release is listed in \(source.rawValue). Catalog checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))."
        default:
            item.detail = "The catalog lists \(candidate.version), but its version format couldn't be compared reliably with this installation."
        }
        return item
    }
}
