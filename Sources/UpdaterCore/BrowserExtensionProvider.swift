import Foundation

public struct BrowserCheck: Sendable {
    public var items: [UpdateItem] = []
    public var snapshots: [SoftwareSnapshot] = []
    public var uncertainPaths: [String] = []
    public var report: ProviderReport
}
public enum BrowserExtensionProvider {
    public static func check(enabled: Bool, store: BrowserInventoryStore = BrowserInventoryStore(), cache: MetadataCache = .shared, at date: Date = Date()) async -> BrowserCheck {
        var result = BrowserCheck(report: ProviderReport("Browser Extensions", "Enable the optional browser companion in Settings to check Chromium and Firefox profiles. Safari extensions are checked through their containing apps."))
        guard enabled else { result.uncertainPaths = ["browser-extension"]; return result }
        let inventory = store.read()
        if inventory.failed { result.uncertainPaths.append("browser-extension") }
        var requests: [(BrowserProfile, BrowserExtension)] = []
        for profile in inventory.profiles {
            if profile.isFresh(at: date) {
                result.snapshots += profile.extensions.map { ext in
                    SoftwareSnapshot(id: profile.namespace + "/" + ext.id, name: name(ext, in: profile), bundleID: ext.id,
                        path: profile.namespace + "/" + ext.id, version: ext.version, kind: .browserExtension)
                }
            } else { result.uncertainPaths.append(profile.namespace) }
            requests += profile.extensions.map { (profile, $0) }
        }
        requests.sort { $0.0.namespace + "/" + $0.1.id < $1.0.namespace + "/" + $1.1.id }
        // Rotate large inventories hourly so the request cap cannot starve a profile.
        if requests.count > 100 {
            let offset = (Int(date.timeIntervalSince1970 / 3600) * 100) % requests.count
            requests = Array(requests.dropFirst(offset)) + Array(requests.prefix(offset))
        }
        let started = Date()
        for start in stride(from: 0, to: requests.count, by: 4) {
            let batch = Array(requests[start..<min(start + 4, requests.count)])
            let allowRequest = start < 100 && Date().timeIntervalSince(started) < 45
            let items = await withTaskGroup(of: UpdateItem.self, returning: [UpdateItem].self) { group in
                for (profile, ext) in batch {
                    group.addTask {
                        var item = base(ext, profile: profile)
                        guard profile.isFresh(at: date) else {
                            item.status = .unverified; item.detail += " Open this browser profile to refresh its installed versions. The last inventory is older than three minutes."; return item
                        }
                        guard ext.installType != "admin", ext.installType != "development", ext.installType != "sideload" else {
                            item.detail += " This extension is managed or installed outside its store; a compatible public update couldn't be established."; return item
                        }
                        guard allowRequest else { item.status = .unverified; item.detail += " This check was deferred to limit store requests. It will retry during a later scan."; return item }
                        do {
                            let url = try queryURL(ext, profile: profile)
                            let metadata = try await cache.load(url, ttl: 900, maxBytes: 1024 * 1024, at: date)
                            item = try profile.browser == .firefox ? parseFirefox(metadata.data, ext: ext, profile: profile) : parseChromium(metadata.data, ext: ext, profile: profile)
                            item.checkedAt = metadata.fetchedAt
                        } catch { item.status = .unverified; item.verificationIssue = .unavailable; item.detail += " A compatible public store version couldn't be verified. \(error.localizedDescription)" }
                        return item
                    }
                }
                var items: [UpdateItem] = []; for await item in group { items.append(item) }; return items
            }
            result.items += items
        }
        let finished = date.addingTimeInterval(Date().timeIntervalSince(started))
        for index in result.items.indices {
            if let profile = inventory.profiles.first(where: { result.items[index].id.hasPrefix($0.namespace + "/") }), !profile.isFresh(at: finished) {
                result.items[index].status = .unverified
                result.items[index].detail = "\(profile.browser.title) · \(profile.label). Open this profile to refresh its installed versions before checking again."
            }
        }
        let stale = inventory.profiles.filter { !$0.isFresh(at: finished) }.count
        let issue = inventory.failed || stale > 0 || result.items.contains { $0.status == .unverified }
        let message = inventory.profiles.isEmpty ? "No browser profile connected. Install the optional companion once in each profile you want monitored."
            : "\(inventory.profiles.count) profiles · \(result.items.count) extensions. \(stale) profiles need to be reopened. Public store metadata is checked; browsers install their own extension updates."
        result.report = ProviderReport("Browser Extensions", message, hasError: issue)
        return result
    }
    private static func name(_ ext: BrowserExtension, in profile: BrowserProfile) -> String { "\(ext.name) (\(profile.browser.title) · \(profile.label))" }
    private static func base(_ ext: BrowserExtension, profile: BrowserProfile) -> UpdateItem {
        UpdateItem(id: profile.namespace + "/" + ext.id, name: name(ext, in: profile), bundleID: ext.id,
            path: profile.namespace + "/" + ext.id, installedVersion: ext.version, source: .browserExtensions, status: .unsupported,
            action: .browserExtensions(profile.browser.rawValue), detail: "\(profile.browser.title) · \(profile.label).\(ext.enabled ? "" : " This extension is disabled.") Choose this profile in your browser to manage updates.", softwareKind: .browserExtension)
    }
    public static func queryURL(_ ext: BrowserExtension, profile: BrowserProfile) throws -> URL {
        guard BrowserProfile.numeric(ext.version), BrowserProfile.numeric(profile.browserVersion) else { throw CheckError.invalidResponse }
        if profile.browser == .firefox {
            var url = URLComponents(string: "https://addons.mozilla.org")!
            url.path = "/api/v5/addons/addon/\(ext.id)/"
            return url.url!
        }
        guard ext.id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil,
              let update = ext.updateURL.flatMap(URL.init(string:)), update.scheme == "https",
              ["clients2.google.com", "clients2.googleusercontent.com"].contains(update.host ?? ""), update.path == "/service/update2/crx" else {
            throw CheckError.failed("This extension doesn't advertise the Chrome Web Store update service.")
        }
        var url = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        url.queryItems = [URLQueryItem(name: "response", value: "updatecheck"), URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "prodversion", value: profile.browserVersion), URLQueryItem(name: "x", value: "id=\(ext.id)&v=\(ext.version)&uc")]
        return url.url!
    }
    public static func parseChromium(_ data: Data, ext: BrowserExtension, profile: BrowserProfile) throws -> UpdateItem {
        guard !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw CheckError.invalidResponse }
        let delegate = ExtensionUpdateXML(id: ext.id)
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.matches == 1, delegate.appOK, let status = delegate.status else { throw CheckError.invalidResponse }
        var item = base(ext, profile: profile)
        item.releaseNotes = ReleaseNotesContext(sources: [ReleaseNotesSource(.website, url: URL(string: "https://chromewebstore.google.com/detail/" + ext.id)!)])
        if status == "noupdate" { item.status = .current; item.detail += " The browser's store update service reports no compatible update."; return item }
        guard status == "ok", let version = delegate.version, BrowserProfile.numeric(version), BrowserProfile.numeric(ext.version) else { throw CheckError.invalidResponse }
        item.availableVersion = Versions.newer(version, than: ext.version) ? version : nil
        item.status = item.availableVersion == nil ? .current : .available
        item.detail += " The browser's store update service reports version \(version) for this browser version. A staged rollout or browser policy may affect installation."
        return item
    }
    public static func parseFirefox(_ data: Data, ext: BrowserExtension, profile: BrowserProfile) throws -> UpdateItem {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["guid"] as? String == ext.id,
              root["is_disabled"] as? Bool != true, let current = root["current_version"] as? [String: Any],
              let version = current["version"] as? String, BrowserProfile.numeric(version), BrowserProfile.numeric(ext.version),
              let file = current["file"] as? [String: Any], file["status"] as? String == "public",
              let compatibility = current["compatibility"] as? [String: [String: String]], let firefox = compatibility["firefox"],
              let minimum = firefox["min"], BrowserProfile.numeric(minimum), BrowserProfile.numeric(profile.browserVersion) else { throw CheckError.invalidResponse }
        var item = base(ext, profile: profile)
        let maximum = firefox["max"] ?? "*"
        if Versions.compare(profile.browserVersion, minimum) == .orderedAscending ||
            (current["is_strict_compatibility_enabled"] as? Bool != false && maximum != "*" &&
             (!BrowserProfile.numeric(maximum) || Versions.compare(profile.browserVersion, maximum) == .orderedDescending)) {
            item.status = .unverified; item.verificationIssue = .platform; item.detail += " The latest public version isn't compatible with this Firefox version."; return item
        }
        item.releaseNotes = ReleaseNotesContext(sources: [ReleaseNotesSource(.firefox, url: URL(string: "https://addons.mozilla.org/firefox/addon/" + ext.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!, identifier: ext.id)])
        item.availableVersion = Versions.newer(version, than: ext.version) ? version : nil
        item.status = item.availableVersion == nil ? .current : .available
        item.detail += " Mozilla Add-ons lists compatible public version \(version). Firefox manages installation."
        return item
    }
}
private final class ExtensionUpdateXML: NSObject, XMLParserDelegate {
    let id: String
    var matches = 0, appOK = false, active = false
    var status: String?, version: String?
    init(id: String) { self.id = id }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if element == "app" { active = attributes["appid"] == id; if active { matches += 1; appOK = attributes["status"] == "ok" } }
        if element == "updatecheck", active { if status != nil { parser.abortParsing() }; status = attributes["status"]; version = attributes["version"] }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) { if element == "app" { active = false } }
}
