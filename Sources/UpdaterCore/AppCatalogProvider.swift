import Foundation

public struct AppCatalogPage: Sendable {
    public var candidates: [CatalogCandidate]
    public var nextCursor: String?
    public var publishedAt: Date
    public var degraded: Bool
}

public enum AppCatalogProvider {
    public static func parse(_ data: Data, at now: Date = Date()) throws -> AppCatalogPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schemaVersion"] as? String == "1", let apps = root["data"] as? [[String: Any]],
              let pagination = root["pagination"] as? [String: Any], pagination.keys.contains("nextCursor"),
              let dateString = root["lastUpdated"] as? String, let date = timestamp(dateString),
              now.timeIntervalSince(date) >= -300, now.timeIntervalSince(date) < 48 * 3600 else {
            throw CheckError.failed("The app catalog is missing current metadata. Try again later.")
        }
        let candidates = apps.compactMap { app -> CatalogCandidate? in
            guard let id = app["id"] as? String, !id.isEmpty,
                  let bundleID = app["bundleId"] as? String, !bundleID.isEmpty,
                  let version = app["version"] as? String, !version.isEmpty else { return nil }
            let words = id.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let channel = words.first(where: { ["beta", "nightly", "canary", "preview", "lts"].contains($0) }) ?? "stable"
            return CatalogCandidate(id: id, version: version, homepage: (app["homepage"] as? String).flatMap(URL.init(string:)),
                identifiers: [bundleID.lowercased()], minimumOS: app["minimumOSVersion"] as? String, channel: channel)
        }
        let degraded = (root["sync"] as? [String: Any])?["status"] as? String == "degraded"
        return AppCatalogPage(candidates: candidates, nextCursor: pagination["nextCursor"] as? String, publishedAt: date, degraded: degraded)
    }

    public static func check(_ apps: [InstalledApp], cache: MetadataCache = .shared) async -> ([UpdateItem], ProviderReport) {
        guard !apps.isEmpty else { return ([], ProviderReport("App Catalog", "No apps to check")) }
        do {
            var candidates: [CatalogCandidate] = []
            var cursor: String?
            var seen = Set<String>()
            var degraded = false
            var oldest = Date.distantFuture
            var finished = false
            for _ in 0..<50 {
                var url = URLComponents(string: "https://www.intunebrew.com/api/v1/apps")!
                url.queryItems = [URLQueryItem(name: "limit", value: "200")]
                if let cursor { url.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
                let snapshot = try await cache.load(url.url!, ttl: 12 * 3600)
                let page = try parse(snapshot.data)
                candidates.append(contentsOf: page.candidates)
                oldest = min(oldest, page.publishedAt); degraded = degraded || page.degraded
                guard let next = page.nextCursor else { finished = true; break }
                guard !next.isEmpty, seen.insert(next).inserted else { throw CheckError.invalidResponse }
                cursor = next
            }
            guard finished else { throw CheckError.failed("The app catalog exceeded its page limit.") }
            // Pagination can change between requests; deduplicate identical stable IDs.
            let unique = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let items = apps.compactMap { CatalogMatching.match($0, candidates: Array(unique.values), source: .appCatalog, checkedAt: oldest) }
            let count = items.filter { $0.status != .unverified }.count
            return (items, ProviderReport("App Catalog", "\(unique.count) identified entries · \(count) apps verified"
                + (degraded ? " · Upstream reports a partial sync; some entries may lag" : ""), hasError: degraded))
        } catch { return ([], ProviderReport("App Catalog", error.localizedDescription, hasError: true)) }
    }

    private static func timestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
