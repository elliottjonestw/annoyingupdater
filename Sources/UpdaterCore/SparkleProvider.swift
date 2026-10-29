import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct AppcastRelease: Sendable {
    public var build = ""
    public var version = ""
    public var minimumOS = ""
    public var maximumOS = ""
    public var channel = ""
    public var hardware = ""
    public var hasDownload = false
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    var releases: [AppcastRelease] = []
    var current: AppcastRelease?
    var field = ""
    var content = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "item" { current = AppcastRelease() }
        field = elementName; content = ""
        if elementName == "enclosure", current != nil {
            current?.build = attributes["sparkle:version"] ?? ""
            current?.version = attributes["sparkle:shortVersionString"] ?? ""
            current?.hasDownload = URL(string: attributes["url"] ?? "")?.scheme == "https"
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { content += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "sparkle:version": current?.build = value
        case "sparkle:shortVersionString": current?.version = value
        case "sparkle:minimumSystemVersion": current?.minimumOS = value
        case "sparkle:maximumSystemVersion": current?.maximumOS = value
        case "sparkle:channel": current?.channel = value
        case "sparkle:hardwareRequirements": current?.hardware = value
        case "item":
            if let release = current, !release.build.isEmpty, release.hasDownload { releases.append(release) }
            current = nil
        default: break
        }
        content = ""; field = ""
    }
}

public enum SparkleProvider {
    public static func parse(_ data: Data, osVersion: String, architecture: String) throws -> [AppcastRelease] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.releases.isEmpty else { throw CheckError.invalidResponse }
        return delegate.releases.filter {
            $0.channel.isEmpty && ($0.minimumOS.isEmpty || Versions.compare(osVersion, $0.minimumOS) != .orderedAscending)
                && ($0.maximumOS.isEmpty || Versions.compare(osVersion, $0.maximumOS) != .orderedDescending)
                && ($0.hardware.isEmpty || $0.hardware == architecture)
        }.sorted { Versions.newer($0.build, than: $1.build) }
    }

    public static func check(_ app: InstalledApp) async -> UpdateItem {
        var item = app.item; item.source = .sparkle
        do {
            guard let feed = app.feedURL, feed.scheme == "https" else {
                throw CheckError.failed("This app's update feed isn't available over HTTPS. Check for updates in the app.")
            }
            let data = try await Network.data(from: feed)
            let os = ProcessInfo.processInfo.operatingSystemVersion
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let releases = try parse(data, osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture)
            guard let latest = releases.first else {
                throw CheckError.failed("The publisher's feed has no compatible stable release for this Mac.")
            }
            let available = Versions.newer(latest.build, than: app.build)
            item.status = available ? .available : .current
            item.availableVersion = available ? (latest.version.isEmpty ? latest.build : latest.version) : nil
            item.detail = available ? "The developer lists a newer compatible release. Open the app and choose Check for Updates to install."
                : "Checked the developer's published update feed."
            item.checkedAt = Date()
        } catch { item.status = .unverified; item.detail = error.localizedDescription }
        return item
    }
}

public enum Network {
    public static func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("AnnoyingUpdater/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.url?.scheme == "https" else {
            throw CheckError.failed("The update service is unavailable. Try again later.")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 4 * 1024 * 1024 { throw CheckError.invalidResponse }
        }
        return data
    }
}
