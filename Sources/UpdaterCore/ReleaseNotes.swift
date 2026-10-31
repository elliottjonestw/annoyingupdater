import Foundation
import Yams

public struct ReleaseNotesSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case sparkle, github, appStore, electron, firefox, website }
    public var kind: Kind
    public var url: URL
    public var identifier: String?
    public var region: String?
    public var bundleID: String?
    public init(_ kind: Kind, url: URL, identifier: String? = nil, region: String? = nil, bundleID: String? = nil) {
        self.kind = kind; self.url = url; self.identifier = identifier; self.region = region; self.bundleID = bundleID
    }
    public static func publisher(_ url: URL) -> ReleaseNotesSource? {
        guard PublicURL.isAllowed(url) else { return nil }
        if let repo = GitHubRepository.parse(url.absoluteString) {
            return ReleaseNotesSource(.github, url: URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.name)/releases")!)
        }
        return ReleaseNotesSource(.website, url: url)
    }
}
public struct ReleaseNotesContext: Codable, Equatable, Sendable {
    public var sources: [ReleaseNotesSource]
    public var installedBuild: String?
    public var targetBuild: String?
    public init(sources: [ReleaseNotesSource] = [], installedBuild: String? = nil, targetBuild: String? = nil) {
        self.sources = sources; self.installedBuild = installedBuild; self.targetBuild = targetBuild
    }
    public mutating func prepend(_ source: ReleaseNotesSource) {
        sources.removeAll { $0 == source }; sources.insert(source, at: 0)
    }
}
public struct ReleaseNotesRequest: Identifiable, Sendable {
    public var id: String {
        let sources = context.sources.map { $0.kind.rawValue + $0.url.absoluteString + ($0.identifier ?? "") + ($0.region ?? "") + ($0.bundleID ?? "") }.joined(separator: "|")
        return itemID + ":" + installedVersion + ":" + targetVersion + ":" + (context.installedBuild ?? "") + ":" + (context.targetBuild ?? "") + ":" + sources
    }
    public var itemID: String
    public var name: String
    public var installedVersion: String
    public var targetVersion: String
    public var context: ReleaseNotesContext
    public init(item: UpdateItem) {
        itemID = item.id; name = item.name; installedVersion = item.installedVersion; targetVersion = item.availableVersion ?? item.installedVersion
        context = item.releaseNotes ?? ReleaseNotesContext()
        if context.sources.isEmpty, case .website(let address) = item.action, let url = URL(string: address), let source = ReleaseNotesSource.publisher(url) { context.sources = [source] }
    }
}
extension ReleaseNotesRequest {
    public init?(history entry: UpdateHistoryEntry) {
        guard entry.change == .updated || entry.change == .buildChanged, var context = entry.software.releaseNotes, !context.sources.isEmpty else { return nil }
        context.installedBuild = entry.previousBuild.isEmpty ? nil : entry.previousBuild
        context.targetBuild = entry.software.build.isEmpty ? nil : entry.software.build
        self.init(item: UpdateItem(id: entry.software.id, name: entry.software.displayName, bundleID: entry.software.bundleID,
            installedVersion: entry.previousVersion, availableVersion: entry.software.version, source: .unknown, status: .current, releaseNotes: context))
    }
}
public struct ReleaseNote: Identifiable, Codable, Equatable, Sendable {
    public var id: String { version + ":" + (build ?? "") }
    public var version: String
    public var build: String?
    public var date: Date?
    public var text: String
    public var url: URL?
    public var allowsLinkedContent: Bool
    public init(version: String, build: String? = nil, date: Date? = nil, text: String = "", url: URL? = nil, allowsLinkedContent: Bool = false) {
        self.version = version; self.build = build; self.date = date; self.text = text; self.url = url; self.allowsLinkedContent = allowsLinkedContent
    }
}
public struct ReleaseNotesResult: Codable, Sendable {
    public var entries: [ReleaseNote] = []
    public var message: String
    public var sourceName: String = "Publisher"
    public var sourceURL: URL?
    public var nextPage: Int?
    public var source: ReleaseNotesSource?
    public var hasPublishedNotes: Bool {
        entries.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (source?.kind == .sparkle && $0.url != nil) }
    }
    public init(entries: [ReleaseNote] = [], message: String, sourceName: String = "Publisher", sourceURL: URL? = nil, nextPage: Int? = nil, source: ReleaseNotesSource? = nil) {
        self.entries = entries; self.message = message; self.sourceName = sourceName; self.sourceURL = sourceURL; self.nextPage = nextPage; self.source = source
    }
}
public enum NotesVersions {
    public static func numeric(_ value: String) -> String? {
        guard value.count < 100, value.range(of: #"^v?[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        return value.hasPrefix("v") ? String(value.dropFirst()) : value
    }
    public static func includes(_ candidate: String, after installed: String, through target: String) -> Bool {
        guard let value = numeric(candidate), let lower = numeric(installed), let upper = numeric(target), Versions.compare(lower, upper) == .orderedAscending else { return false }
        return Versions.compare(value, lower) == .orderedDescending && Versions.compare(value, upper) != .orderedDescending
    }
    public static func isTarget(_ entry: ReleaseNote, for request: ReleaseNotesRequest) -> Bool {
        guard Versions.compare(entry.version, request.targetVersion) == .orderedSame else { return false }
        // GitHub, App Store, and Firefox notes have public versions, not bundle builds.
        guard let build = entry.build, let targetBuild = request.context.targetBuild else { return true }
        return build == targetBuild
    }
    public static func sorted(_ entries: [ReleaseNote]) -> [ReleaseNote] {
        var unique: [String: ReleaseNote] = [:]
        for entry in entries {
            if let old = unique[entry.id], !old.text.isEmpty { continue }
            unique[entry.id] = entry
        }
        return unique.values.sorted {
            let comparison: ComparisonResult
            if let left = $0.build.flatMap(numeric), let right = $1.build.flatMap(numeric) { comparison = Versions.compare(left, right) }
            else { comparison = Versions.compare($0.version, $1.version) }
            return comparison == .orderedSame ? Versions.newer($0.build ?? "", than: $1.build ?? "") : comparison == .orderedDescending
        }
    }
}
/// HTML is converted to text, never handed to a browser or an HTML renderer.
/// Images, scripts, styles, and tracking resources cannot execute or load here.
public enum NotesText {
    public static func readable(_ input: String, html: Bool = false) -> String {
        var text = String(input.prefix(100_000))
        if html {
            text = text.replacingOccurrences(of: #"(?is)<(script|style|iframe|object|head)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"(?is)<!--.*?-->"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"(?i)<li\b[^>]*>"#, with: "\n• ", options: .regularExpression)
            text = text.replacingOccurrences(of: #"(?i)<(?:br\b[^>]*|/(?:p|div|li|h[1-6]|tr)\s*)>"#, with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            for (entity, value) in [("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: value) }
            if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                    guard let full = Range(match.range, in: text), let value = Range(match.range(at: 1), in: text) else { continue }
                    let raw = String(text[value]); let number = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
                    if let number, let scalar = UnicodeScalar(number), !CharacterSet.controlCharacters.contains(scalar) { text.replaceSubrange(full, with: String(scalar)) }
                }
            }
        }
        text = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return text.replacingOccurrences(of: #"\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
public enum ReleaseNotesService {
    public static func hasPublishedNotes(_ request: ReleaseNotesRequest, cache: MetadataCache = .shared) async throws -> Bool {
        guard request.context.sources.contains(where: { $0.kind != .website }) else { return false }
        await PublisherLookupGate.shared.acquire()
        do {
            let found = try await findPublishedNotes(request, cache: cache)
            await PublisherLookupGate.shared.release()
            return found
        } catch {
            await PublisherLookupGate.shared.release()
            throw error
        }
    }
    private static func findPublishedNotes(_ request: ReleaseNotesRequest, cache: MetadataCache) async throws -> Bool {
        try Task.checkCancellation()
        var result = try await load(request, cache: cache)
        for _ in 0..<3 {
            try Task.checkCancellation()
            if result.hasPublishedNotes { return true }
            guard let page = result.nextPage, let source = result.source else { return false }
            result = try await load(request, source: source, page: page, cache: cache)
        }
        return result.hasPublishedNotes
    }
    public static func load(_ request: ReleaseNotesRequest, source selected: ReleaseNotesSource? = nil, page: Int = 1, cache: MetadataCache = .shared) async throws -> ReleaseNotesResult {
        guard page >= 1, page <= 20 else { throw CheckError.failed("The history page limit was reached. Open the publisher's history for more releases.") }
        let sources = selected.map { [$0] } ?? request.context.sources
        var fallback: ReleaseNotesResult?
        var failure: Error?
        for source in sources {
            try Task.checkCancellation()
            guard PublicURL.isAllowed(source.url) else { continue }
            do {
                var result: ReleaseNotesResult
                switch source.kind {
                case .github: result = try await github(request, source: source, page: page, cache: cache)
                case .sparkle: result = try await sparkle(request, source: source, cache: cache)
                case .electron: result = try await electron(request, source: source, cache: cache)
                case .appStore: result = try await appStore(request, source: source, cache: cache)
                case .firefox: result = try await firefox(request, source: source, page: page, cache: cache)
                case .website:
                    result = ReleaseNotesResult(message: "This source doesn't provide a structured release history. Open the publisher's website to look for notes for \(request.targetVersion).", sourceURL: source.url)
                }
                if source.kind == .website, source.url.host == "support.apple.com", source.url.path.hasSuffix("/100100") {
                    result.sourceName = "Apple Security Releases"
                    result.message = "Apple publishes security notes on its support site. These aren't a complete macOS changelog. Software Update may include more information about the selected update."
                }
                let publicRange = NotesVersions.numeric(request.installedVersion).flatMap { lower in NotesVersions.numeric(request.targetVersion).map { Versions.compare(lower, $0) == .orderedAscending } } ?? false
                if !publicRange && source.kind != .sparkle && source.kind != .website {
                    result.message += " A public-version range couldn't be established for this change; build-specific notes may be unavailable."
                }
                result.source = source
                result.entries = NotesVersions.sorted(result.entries)
                if result.hasPublishedNotes || selected != nil { return result }
                if fallback == nil || result.nextPage != nil { fallback = result }
            } catch { failure = error }
        }
        if var fallback {
            if failure != nil { fallback.message += " Another release-note source couldn't be reached. You can retry or open the publisher's history." }
            return fallback
        }
        if let failure { throw failure }
        return ReleaseNotesResult(message: "No published release-notes source was found for this update. You might find notes in the app or on the developer's website.")
    }
    static func validGitHub(_ source: ReleaseNotesSource) -> Bool {
        let parts = source.url.path.split(separator: "/")
        return source.url.host == "api.github.com" && parts.count == 4 && parts[0] == "repos" && parts[3] == "releases"
            && GitHubRepository.parse("https://github.com/\(parts[1])/\(parts[2])") != nil && source.url.query == nil
    }
    static func github(_ request: ReleaseNotesRequest, source: ReleaseNotesSource, page: Int, cache: MetadataCache) async throws -> ReleaseNotesResult {
        guard validGitHub(source) else { throw CheckError.invalidResponse }
        var url = URLComponents(url: source.url, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
        let snapshot = try await cache.load(url.url!, ttl: 3600)
        return try parseGitHub(snapshot.data, request: request, source: source, page: page)
    }
    public static func parseGitHub(_ data: Data, request: ReleaseNotesRequest, source: ReleaseNotesSource, page: Int) throws -> ReleaseNotesResult {
        guard validGitHub(source), let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CheckError.invalidResponse }
        let parts = source.url.path.split(separator: "/")
        let history = URL(string: "https://github.com/\(parts[1])/\(parts[2])/releases")!
        var entries: [ReleaseNote] = []
        for record in records where record["draft"] as? Bool == false && record["prerelease"] as? Bool == false {
            guard let tag = record["tag_name"] as? String else { continue }
            let version = tag.replacingOccurrences(of: #"^release[-/]"#, with: "", options: [.regularExpression, .caseInsensitive])
            guard NotesVersions.includes(version, after: request.installedVersion, through: request.targetVersion) else { continue }
            // Avoid unrelated products in repositories that publish several apps.
            if let product = source.identifier {
                let names = product.split(separator: "|").map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }.filter { $0.count >= 4 }
                let assets = record["assets"] as? [[String: Any]] ?? []
                guard assets.contains(where: { asset in
                    let name = (asset["name"] as? String ?? "").lowercased()
                    return (name.hasSuffix(".dmg") || name.hasSuffix(".zip")) && !name.contains("linux") && !name.contains("windows")
                        && names.contains { name.filter { $0.isLetter || $0.isNumber }.hasPrefix($0) }
                }) else { continue }
            }
            let original = (record["html_url"] as? String).flatMap(URL.init(string:)).flatMap { PublicURL.isAllowed($0) && $0.host == "github.com" && $0.path.hasPrefix("/\(parts[1])/\(parts[2])/releases/") ? $0 : nil }
            entries.append(ReleaseNote(version: NotesVersions.numeric(version)!, date: (record["published_at"] as? String).flatMap(ISO8601DateFormatter().date(from:)),
                text: NotesText.readable(record["body"] as? String ?? ""), url: original))
        }
        let more = records.count == 100 && page < 20
        return ReleaseNotesResult(entries: entries, message: more ? "More publisher releases haven't been checked yet. Load older releases to extend this version range."
            : records.count == 100 ? "The history search reached its page limit. Older notes may be missing; open the publisher's history to continue."
            : "Showing the matching stable releases published in this repository. Missing or deleted releases cannot be recovered here.", sourceName: "GitHub Releases", sourceURL: history, nextPage: more ? page + 1 : nil)
    }
    static func appStore(_ request: ReleaseNotesRequest, source: ReleaseNotesSource, cache: MetadataCache) async throws -> ReleaseNotesResult {
        guard let id = source.identifier, !id.isEmpty, id.allSatisfy(\.isNumber), let region = source.region, region.range(of: "^[A-Za-z]{2}$", options: .regularExpression) != nil else { throw CheckError.invalidResponse }
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        url.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "country", value: region), URLQueryItem(name: "entity", value: "macSoftware")]
        let data = try await cache.load(url.url!, ttl: 3600).data
        return try parseAppStore(data, request: request, source: source)
    }
    public static func parseAppStore(_ data: Data, request: ReleaseNotesRequest, source: ReleaseNotesSource) throws -> ReleaseNotesResult {
        guard let bundleID = source.bundleID, !bundleID.isEmpty, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let records = root["results"] as? [[String: Any]],
              let record = records.first(where: { ($0["trackId"] as? NSNumber)?.stringValue == source.identifier && $0["bundleId"] as? String == bundleID }) else { throw CheckError.invalidResponse }
        var result = ReleaseNotesResult(message: "Apple's public catalog provides only the latest release notes. Notes for intervening versions aren't available from this source.", sourceName: "App Store", sourceURL: source.url)
        guard let version = record["version"] as? String, Versions.compare(version, request.targetVersion) == .orderedSame else {
            result.message = "The store now describes a different version. Open its version history to find the release you selected."; return result
        }
        result.entries = [ReleaseNote(version: version, date: (record["currentVersionReleaseDate"] as? String).flatMap(ISO8601DateFormatter().date(from:)), text: NotesText.readable(record["releaseNotes"] as? String ?? ""), url: source.url)]
        return result
    }
    static func electron(_ request: ReleaseNotesRequest, source: ReleaseNotesSource, cache: MetadataCache) async throws -> ReleaseNotesResult {
        let data = try await cache.load(source.url, ttl: 3600, maxBytes: 512 * 1024).data
        return try parseElectron(data, request: request, source: source)
    }
    public static func parseElectron(_ data: Data, request: ReleaseNotesRequest, source: ReleaseNotesSource) throws -> ReleaseNotesResult {
        guard data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) else { throw CheckError.invalidResponse }
        let manifest = try YAMLDecoder().decode(NotesElectronManifest.self, from: text)
        let version = manifest.version, latest = manifest.notes?.text, history = manifest.notes?.history
        var entries: [ReleaseNote] = []
        if let history {
            entries = history.compactMap { record in
                let v = record.version
                guard NotesVersions.includes(v, after: request.installedVersion, through: request.targetVersion) else { return nil }
                return ReleaseNote(version: v, text: NotesText.readable(record.note ?? "", html: true))
            }
        } else if Versions.compare(version, request.targetVersion) == .orderedSame {
            entries = [ReleaseNote(version: version, text: NotesText.readable(latest ?? "", html: true))]
        }
        return ReleaseNotesResult(entries: entries, message: history == nil ? "This feed publishes notes for its latest release only. Intervening release notes may be missing."
            : "Showing the versioned notes included by the publisher. The feed may not retain every intervening release.", sourceName: "Developer Feed", sourceURL: source.url)
    }
    static func firefox(_ request: ReleaseNotesRequest, source: ReleaseNotesSource, page: Int, cache: MetadataCache) async throws -> ReleaseNotesResult {
        guard source.url.host == "addons.mozilla.org", let id = source.identifier, !id.contains("/"), !id.contains("\\"), id.count <= 200 else { throw CheckError.invalidResponse }
        var url = URLComponents(string: "https://addons.mozilla.org")!
        url.path = "/api/v5/addons/addon/\(id)/"
        let identity = try await cache.load(url.url!, ttl: 3600).data
        guard let root = try JSONSerialization.jsonObject(with: identity) as? [String: Any], root["guid"] as? String == id else { throw CheckError.invalidResponse }
        url.path += "versions/"; url.queryItems = [URLQueryItem(name: "page", value: String(page))]
        let data = try await cache.load(url.url!, ttl: 3600).data
        var verifiedSource = source
        if let address = root["url"] as? String, let canonical = URL(string: address), canonical.host == "addons.mozilla.org", PublicURL.isAllowed(canonical) {
            verifiedSource.url = canonical.appendingPathComponent("versions")
        }
        return try parseFirefox(data, request: request, source: verifiedSource, page: page)
    }
    public static func parseFirefox(_ data: Data, request: ReleaseNotesRequest, source: ReleaseNotesSource, page: Int) throws -> ReleaseNotesResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let records = root["results"] as? [[String: Any]] else { throw CheckError.invalidResponse }
        let entries = records.compactMap { record -> ReleaseNote? in
            guard let version = record["version"] as? String, NotesVersions.includes(version, after: request.installedVersion, through: request.targetVersion),
                  let file = record["file"] as? [String: Any], file["status"] as? String == "public" else { return nil }
            let translated = record["release_notes"] as? [String: String] ?? [:]
            let language = Locale.preferredLanguages.first ?? "en-US"
            let body = translated[language] ?? translated["en-US"] ?? translated.sorted { $0.key < $1.key }.first?.value ?? ""
            return ReleaseNote(version: version, date: (file["created"] as? String).flatMap(ISO8601DateFormatter().date(from:)), text: NotesText.readable(body, html: true), url: source.url)
        }
        return ReleaseNotesResult(entries: entries, message: root["next"] is String && page >= 20
            ? "The history search reached its page limit. Older notes may be missing; open the publisher's history to continue."
            : "Showing public Mozilla Add-ons release notes. The publisher may omit notes for some releases.", sourceName: "Mozilla Add-ons", sourceURL: source.url, nextPage: root["next"] is String && page < 20 ? page + 1 : nil)
    }
}

private struct NotesElectronManifest: Decodable {
    struct VersionNote: Decodable { var version: String; var note: String? }
    struct Notes: Decodable {
        var text: String?
        var history: [VersionNote]?
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let history = try? value.decode([VersionNote].self) { self.history = history }
            else { text = try value.decode(String.self) }
        }
    }
    var version: String
    var notes: Notes?
    enum CodingKeys: String, CodingKey { case version; case notes = "releaseNotes" }
}

actor PublisherLookupGate {
    static let shared = PublisherLookupGate()
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }
}
