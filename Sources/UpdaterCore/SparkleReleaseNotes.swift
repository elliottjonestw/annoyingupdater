import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

private struct NotesAppcastItem {
    var version = "", build = "", channel = "", minimum = "", maximum = "", hardware = "", body = "", link = "", fullHistory = "", date = ""
    var notesLinks: [(String, String)] = []
}
private final class NotesAppcastParser: NSObject, XMLParserDelegate {
    var items: [NotesAppcastItem] = []
    var item: NotesAppcastItem?
    var stack: [String] = [], buffers: [String] = []
    var language = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard stack.count < 32 else { parser.abortParsing(); return }
        stack.append(name); buffers.append("")
        if name == "item" { item = NotesAppcastItem() }
        if name == "enclosure", stack.dropLast().last == "item", var current = item {
            current.build = attributes["sparkle:version"] ?? current.build
            current.version = attributes["sparkle:shortVersionString"] ?? current.version
            item = current
        }
        if name == "sparkle:releaseNotesLink" { language = attributes["xml:lang"] ?? "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !buffers.isEmpty { buffers[buffers.count - 1] += string } }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { if !buffers.isEmpty { buffers[buffers.count - 1] += String(decoding: data, as: UTF8.self) } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let raw = buffers.popLast() ?? ""; _ = stack.popLast()
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if stack.last == "item" {
            switch name {
            case "sparkle:version": item?.build = value
            case "sparkle:shortVersionString": item?.version = value
            case "sparkle:channel": item?.channel = value
            case "sparkle:minimumSystemVersion": item?.minimum = value
            case "sparkle:maximumSystemVersion": item?.maximum = value
            case "sparkle:hardwareRequirements": item?.hardware = value
            case "sparkle:releaseNotesLink": item?.notesLinks.append((language, value))
            case "sparkle:fullReleaseNotesLink": item?.fullHistory = value
            case "description": item?.body = raw
            case "link": item?.link = value
            case "pubDate": item?.date = value
            default: break
            }
        }
        if name == "item" { if let item { items.append(item) }; item = nil }
        // Preserve nested markup inside descriptions as harmless text separators.
        if !buffers.isEmpty { buffers[buffers.count - 1] += raw + (["p", "div", "li", "br"].contains(name) ? "\n" : "") }
    }
}
extension ReleaseNotesService {
    static func sparkle(_ request: ReleaseNotesRequest, source: ReleaseNotesSource, cache: MetadataCache) async throws -> ReleaseNotesResult {
        let data = try await cache.load(source.url, ttl: 3600).data
        return try parseSparkle(data, request: request, source: source)
    }
    public static func parseSparkle(_ data: Data, request: ReleaseNotesRequest, source: ReleaseNotesSource, platform: MacCompatibility = .current) throws -> ReleaseNotesResult {
        guard !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw CheckError.invalidResponse }
        let delegate = NotesAppcastParser(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.items.isEmpty else { throw CheckError.invalidResponse }
        let all = delegate.items.filter { $0.channel.isEmpty && ($0.minimum.isEmpty || Versions.compare(platform.os, $0.minimum) != .orderedAscending)
            && ($0.maximum.isEmpty || Versions.compare(platform.os, $0.maximum) != .orderedDescending) && ($0.hardware.isEmpty || $0.hardware == platform.architecture) }
        let buildBounds = request.context.installedBuild.flatMap(NotesVersions.numeric).flatMap { lower in request.context.targetBuild.flatMap(NotesVersions.numeric).map { (lower, $0) } }
        let chosen = all.filter { item in
            if let (lower, upper) = buildBounds { return NotesVersions.includes(item.build, after: lower, through: upper) }
            return NotesVersions.includes(item.version.isEmpty ? item.build : item.version, after: request.installedVersion, through: request.targetVersion)
        }
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        func address(_ text: String) -> URL? {
            guard !text.isEmpty, let url = URL(string: text, relativeTo: source.url)?.absoluteURL, PublicURL.isAllowed(url) else { return nil }
            return url
        }
        let preferred = Locale.preferredLanguages.first?.lowercased().prefix(2) ?? "en"
        let linkedAddresses = all.flatMap { $0.notesLinks.compactMap { address($0.1) } }
        let entries = chosen.map { item -> ReleaseNote in
            let link = item.notesLinks.first { $0.0.lowercased().hasPrefix(preferred) } ?? item.notesLinks.first { $0.0.isEmpty || $0.0.lowercased().hasPrefix("en") } ?? item.notesLinks.first
            let noteURL = link.flatMap { address($0.1) }
            let shared = noteURL.map { url in linkedAddresses.filter { $0 == url }.count > 1 } ?? false
            return ReleaseNote(version: item.version.isEmpty ? item.build : item.version, build: item.build.isEmpty ? nil : item.build,
                date: date.date(from: item.date), text: NotesText.readable(item.body, html: true), url: noteURL, allowsLinkedContent: noteURL != nil && !shared)
        }
        let history = all.compactMap { address($0.fullHistory) }.first ?? all.compactMap { address($0.link) }.first
        let usesBuild = buildBounds != nil
        let hasBaseline = all.contains {
            usesBuild ? $0.build == request.context.installedBuild : Versions.compare($0.version.isEmpty ? $0.build : $0.version, request.installedVersion) != .orderedDescending
        }
        var message = hasBaseline ? "Showing the matching stable releases retained in the developer's feed. The publisher may omit individual releases."
            : "The feed doesn't reach your installed version. Older release notes may be missing."
        if !usesBuild && request.context.installedBuild != nil { message += " This history is matched by public version because a build range couldn't be established." }
        return ReleaseNotesResult(entries: entries, message: message, sourceName: "Developer Feed", sourceURL: history ?? source.url)
    }
    public static func linkedContent(_ url: URL, expectedVersion: String? = nil, cache: MetadataCache = .shared) async throws -> String {
        let parts = url.path.split(separator: "/")
        if url.host == "github.com", parts.count >= 5, parts[2] == "releases", parts[3] == "tag",
           GitHubRepository.parse("https://github.com/\(parts[0])/\(parts[1])") != nil {
            var api = URLComponents(string: "https://api.github.com")!
            api.path = "/repos/\(parts[0])/\(parts[1])/releases/tags/" + parts.dropFirst(4).joined(separator: "/")
            let data = try await cache.load(api.url!, ttl: 3600).data
            guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["draft"] as? Bool == false, record["prerelease"] as? Bool == false,
                  let tag = record["tag_name"] as? String else { throw CheckError.invalidResponse }
            if let expectedVersion {
                let version = tag.replacingOccurrences(of: #"^release[-/]"#, with: "", options: [.regularExpression, .caseInsensitive])
                guard let parsed = NotesVersions.numeric(version), Versions.compare(parsed, expectedVersion) == .orderedSame else { throw CheckError.invalidResponse }
            }
            return NotesText.readable(record["body"] as? String ?? "")
        }
        let data = try await cache.load(url, ttl: 3600, maxBytes: 512 * 1024).data
        guard let text = String(data: data, encoding: .utf8) else { throw CheckError.invalidResponse }
        return NotesText.readable(text, html: true)
    }
}
