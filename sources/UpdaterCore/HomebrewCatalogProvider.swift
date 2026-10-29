import Foundation

public enum HomebrewCatalogProvider {
    public static func parse(_ data: Data) throws -> [CatalogCandidate] {
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !records.isEmpty else { throw CheckError.invalidResponse }
        return records.compactMap { record in
            guard let token = record["token"] as? String, let version = record["version"] as? String,
                  record["disabled"] as? Bool != true else { return nil }
            let artifacts = record["artifacts"] as? [[String: Any]] ?? []
            let names = Set(artifacts.flatMap { ($0["app"] as? [Any] ?? []).compactMap { $0 as? String } }
                .map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
            let uninstalls = artifacts.flatMap { $0["uninstall"] as? [[String: Any]] ?? [] }
            let identifiers = Set(uninstalls.flatMap { strings($0["quit"] as Any) }.map { $0.lowercased() })
            let zaps = artifacts.flatMap { $0["zap"] as? [[String: Any]] ?? [] }
            var hints = Set<String>()
            for path in zaps.flatMap({ strings($0["trash"] as Any) }) {
                var component = URL(fileURLWithPath: path).lastPathComponent.lowercased()
                for suffix in [".plist", ".savedstate", ".binarycookies"] where component.hasSuffix(suffix) { component.removeLast(suffix.count) }
                if component.contains(".") && !component.contains("*") { hints.insert(component) }
            }
            let dependencies = record["depends_on"] as? [String: Any] ?? [:]
            let os = dependencies["macos"] as? [String: Any] ?? [:]
            let minimum = (os[">="] as? [String])?.first
            let arch = dependencies["arch"] as? [[String: Any]] ?? []
            let architectures = Set(arch.compactMap { value -> String? in
                switch value["type"] as? String { case "arm": return "arm64"; case "intel": return "x86_64"; default: return nil }
            })
            let channel = token.contains("@") ? String(token.split(separator: "@").last!) : "stable"
            let variations = record["variations"] as? [String: [String: Any]] ?? [:]
            let variableVersions = variations.values.contains { ($0["version"] as? String).map { $0 != version } ?? false }
            let unsupportedOSRule = os.keys.contains { $0 != ">=" }
            return CatalogCandidate(id: token, version: version, homepage: (record["homepage"] as? String).flatMap(URL.init(string:)),
                names: names, identifiers: identifiers, identifierHints: hints, minimumOS: minimum, architectures: architectures, channel: channel,
                uncertainty: variableVersions || unsupportedOSRule ? "The catalog has platform-specific releases that couldn't be resolved for this Mac." : nil)
        }
    }

    public static func check(_ apps: [InstalledApp], cache: MetadataCache = .shared) async -> ([UpdateItem], ProviderReport) {
        guard !apps.isEmpty else { return ([], ProviderReport("Homebrew Catalog", "No apps to check")) }
        do {
            let snapshot = try await cache.load(URL(string: "https://formulae.brew.sh/api/cask.json")!, ttl: 12 * 3600, maxBytes: 40 * 1024 * 1024)
            let candidates = try parse(snapshot.data)
            let items = apps.compactMap { CatalogMatching.match($0, candidates: candidates, source: .homebrewCatalog, checkedAt: snapshot.fetchedAt) }
            return (items, ProviderReport("Homebrew Catalog", "\(candidates.count) entries · \(items.filter { $0.status != .unverified }.count) apps verified · \(items.filter { $0.status == .unverified }.count) uncertain"))
        } catch { return ([], ProviderReport("Homebrew Catalog", error.localizedDescription, hasError: true)) }
    }

    private static func strings(_ value: Any) -> [String] {
        if let string = value as? String { return [string] }
        return value as? [String] ?? []
    }
}
