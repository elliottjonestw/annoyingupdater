import Foundation

/// A lower bound, never a claim of the exact day this particular Mac became eligible.
/// The installed version/build and publisher are part of its scope, not the latest target.
public struct UpdateAgeEvidence: Codable, Equatable, Sendable {
    public var date: Date
    public var version: String
    public var build: String?
    public var source: ReleaseNotesSource
    public var softwareID: String
    public var bundleID: String
    public var kind: SoftwareKind
    public var installedVersion: String
    public var installedBuild: String?

    public init(date: Date, version: String, build: String? = nil, source: ReleaseNotesSource, item: UpdateItem) {
        self.date = date; self.version = version; self.build = build; self.source = source
        softwareID = item.id; bundleID = item.bundleID; kind = item.kind
        installedVersion = item.installedVersion; installedBuild = item.releaseNotes?.installedBuild
    }
    func matchesInstallation(_ item: UpdateItem, at now: Date) -> Bool {
        [.sparkle, .github, .appStore, .electron].contains(source.kind) && PublicURL.isAllowed(source.url)
            && date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 > 0 && date <= now
            && softwareID == item.id && bundleID == item.bundleID && kind == item.kind
            && installedVersion == item.installedVersion && installedBuild == item.releaseNotes?.installedBuild
            && ReleaseNotesRequest(item: item).context.sources.contains(source)
    }
    public func applies(to item: UpdateItem, at now: Date) -> Bool {
        guard matchesInstallation(item, at: now), let target = item.availableVersion else { return false }
        if source.kind == .sparkle, let build, let lower = installedBuild, let upper = item.releaseNotes?.targetBuild {
            return NotesVersions.includes(build, after: lower, through: upper)
        }
        return NotesVersions.includes(version, after: item.installedVersion, through: target)
    }
    public var publisherURL: URL {
        if source.kind == .github, ReleaseNotesService.validGitHub(source) {
            let parts = source.url.path.split(separator: "/")
            return URL(string: "https://github.com/\(parts[1])/\(parts[2])/releases")!
        }
        return source.url
    }
    public static func earliest(_ entries: [ReleaseNote], source: ReleaseNotesSource, item: UpdateItem, at now: Date = Date()) -> Self? {
        // An upload date (e.g. a Mozilla file's created timestamp) isn't a publication date.
        guard [.sparkle, .github, .appStore, .electron].contains(source.kind), item.status == .available else { return nil }
        return entries.compactMap { entry -> Self? in
            guard let date = entry.date else { return nil }
            let evidence = Self(date: date, version: entry.version, build: entry.build, source: source, item: item)
            return evidence.applies(to: item, at: now) ? evidence : nil
        }.min { $0.date < $1.date }
    }
}

public struct UpdateAgeIndicator: Equatable, Sendable {
    public var date: Date
    public var evidence: UpdateAgeEvidence?
    public func label(at now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return evidence == nil ? "Detected just now" : "Newer release just published" }
        let days = Int(elapsed / 86400), hours = Int(elapsed / 3600), minutes = Int(elapsed / 60)
        let count = days > 0 ? days : hours > 0 ? hours : minutes
        let unit = days > 0 ? "day" : hours > 0 ? "hour" : "minute"
        let duration = "\(count) \(unit)\(count == 1 ? "" : "s")"
        return evidence == nil ? "Detected \(duration) ago" : "Outdated for at least \(duration)"
    }
    public var explanation: String {
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        guard let evidence else {
            return "A newer version was first observed for this installed version on \(formatted). Its publication date couldn't be established, so the update may have been available earlier."
        }
        let publisher: String
        switch evidence.source.kind {
        case .github: publisher = "GitHub Releases"
        case .appStore: publisher = "App Store" + (evidence.source.region.map { " (\($0.uppercased()))" } ?? "")
        default: publisher = "the developer's feed"
        }
        return "Based on version \(evidence.version)\(evidence.build.map { " (build \($0))" } ?? ""), published \(formatted) in \(publisher). This is the earliest newer dated release found for your installed version. Earlier releases may be missing, and rollout timing can differ for this Mac."
    }
}

public enum UpdateAge {
    public static func publicationDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    public static func indicator(for item: UpdateItem, detectedAt: Date?, at now: Date = Date()) -> UpdateAgeIndicator? {
        guard item.status == .available else { return nil }
        if let evidence = item.updateAgeEvidence, evidence.applies(to: item, at: now) {
            return UpdateAgeIndicator(date: evidence.date, evidence: evidence)
        }
        guard let detectedAt, detectedAt <= now else { return nil }
        return UpdateAgeIndicator(date: detectedAt, evidence: nil)
    }
    /// Existing offers are retained across target releases. Bound them by the most recent
    /// observed installed change so a partial upgrade doesn't inherit its predecessor's age.
    public static func detectionDate(for item: UpdateItem, offers: [HistoryOffer: Date], entries: [UpdateHistoryEntry], snapshot: SoftwareSnapshot? = nil) -> Date? {
        guard let current = HistoryOffer(item: item) else { return nil }
        let identity = snapshot?.id ?? current.softwareID
        let identities = Set([identity, current.softwareID])
        let lastChange = entries.filter { $0.software.id == identity }.map(\.detectedAt).max()
        let dates = offers.compactMap { offer, date -> Date? in
            guard identities.contains(offer.softwareID), offer.version == current.version || NotesVersions.includes(offer.version, after: item.installedVersion, through: current.version) else { return nil }
            return lastChange.map { max($0, date) } ?? date
        }
        return dates.min()
    }

    /// Bounded background refinement; failures leave both availability and local tracking intact.
    public static func refine(_ item: UpdateItem, cache: MetadataCache = .shared, at now: Date = Date()) async -> UpdateAgeEvidence? {
        guard item.status == .available, item.kind == .application,
              let source = ReleaseNotesRequest(item: item).context.sources.first(where: { $0.kind == .github }), ReleaseNotesService.validGitHub(source) else { return nil }
        await PublisherLookupGate.shared.acquire()
        var best = item.updateAgeEvidence.flatMap { $0.applies(to: item, at: now) ? $0 : nil }
        for page in 1...3 {
            do {
                try Task.checkCancellation()
                var url = URLComponents(url: source.url, resolvingAgainstBaseURL: false)!
                url.queryItems = [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
                let data = try await cache.load(url.url!, ttl: 3600).data
                let candidate = try githubEvidence(data, source: source, item: item, at: now)
                if let candidate, best == nil || candidate.date < best!.date { best = candidate }
                guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], records.count == 100 else { break }
            } catch { break }
        }
        await PublisherLookupGate.shared.release()
        return best
    }
    public static func githubEvidence(_ data: Data, source: ReleaseNotesSource, item: UpdateItem, at now: Date = Date(), platform: MacCompatibility = .current) throws -> UpdateAgeEvidence? {
        guard ReleaseNotesService.validGitHub(source), let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CheckError.invalidResponse }
        let parts = source.url.path.split(separator: "/")
        let repository = GitHubRepository.parse("https://github.com/\(parts[1])/\(parts[2])")!
        let metadata = RepositoryMetadata(repository: repository, productNames: source.identifier?.components(separatedBy: "|") ?? [item.name])
        let app = InstalledApp(path: item.path ?? item.id, name: item.name, bundleID: item.bundleID, version: item.installedVersion, build: item.releaseNotes?.installedBuild ?? "")
        let entries = records.compactMap { record -> ReleaseNote? in
            guard let candidate = try? GitHubProvider.evaluate(JSONSerialization.data(withJSONObject: record), app: app, metadata: metadata, platform: platform),
                  candidate.status == .available, let version = candidate.availableVersion,
                  let date = (record["published_at"] as? String).flatMap(UpdateAge.publicationDate) else { return nil }
            return ReleaseNote(version: version, date: date)
        }
        return UpdateAgeEvidence.earliest(entries, source: source, item: item, at: now)
    }
}
