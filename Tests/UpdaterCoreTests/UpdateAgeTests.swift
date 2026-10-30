import Foundation
import Testing
@testable import UpdaterCore

@Suite("Honest update age")
struct UpdateAgeTests {
    let now = Date(timeIntervalSince1970: 1_792_627_200)
    let source = ReleaseNotesSource(.github, url: URL(string: "https://api.github.com/repos/example/product/releases")!, identifier: "Example")
    func item(installed: String = "1.0", target: String = "3.0", build: String = "100") -> UpdateItem {
        UpdateItem(id: "/Applications/Example.app", name: "Example", bundleID: "com.example.app", path: "/Applications/Example.app", installedVersion: installed,
            availableVersion: target, source: .github, status: .available, releaseNotes: ReleaseNotesContext(sources: [source], installedBuild: build))
    }
    func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
    func evidence(_ item: UpdateItem, days: Double = 12, version: String = "1.1") -> UpdateAgeEvidence {
        UpdateAgeEvidence(date: daysAgo(days), version: version, source: source, item: item)
    }
    func record(_ version: String, days: Double, file: String = "Example-universal.dmg", prerelease: Bool = false) -> [String: Any] {
        ["tag_name": version, "draft": false, "prerelease": prerelease, "published_at": ISO8601DateFormatter().string(from: daysAgo(days)),
         "assets": [["name": file, "state": "uploaded", "browser_download_url": "https://github.com/example/product/releases/download/\(version)/\(file)"]]]
    }
    @Test func earliestSuccessorNotLatestReleaseOrInstalledReleaseDate() throws {
        let data = try JSONSerialization.data(withJSONObject: [record("1.0", days: 100), record("1.1", days: 30), record("2.0", days: 15), record("3.0", days: 2)])
        let found = try #require(try UpdateAge.githubEvidence(data, source: source, item: item(), at: now))
        #expect(found.date == daysAgo(30) && found.version == "1.1")
        var current = item(); current.updateAgeEvidence = found
        let indicator = try #require(UpdateAge.indicator(for: current, detectedAt: daysAgo(1), at: now))
        #expect(indicator.label(at: now) == "Outdated for at least 30 days")
        #expect(indicator.explanation.contains("Earlier releases may be missing"))
        #expect(indicator.explanation.contains("GitHub Releases"))
    }
    @Test func rejectsFutureDraftPrereleaseOtherProductAndWrongArchitectureDates() throws {
        var draft = record("1.1", days: 90); draft["draft"] = true
        let data = try JSONSerialization.data(withJSONObject: [draft, record("1.2", days: 80, prerelease: true), record("1.3", days: 70, file: "Other-universal.dmg"),
            record("1.4", days: 60, file: "Example-x64.dmg"), record("1.5", days: 50, file: "Example-windows.zip"), record("2.0", days: 10), record("3.0", days: -2), record("4.0", days: 20)])
        let found = try #require(try UpdateAge.githubEvidence(data, source: source, item: item(), at: now, platform: .init(os: "14", architecture: "arm64")))
        #expect(found.version == "2.0" && found.date == daysAgo(10))
    }
    @Test func missingPublicationDateDoesNotUseCreationOrUploadDates() throws {
        var release = record("2.0", days: 5)
        release.removeValue(forKey: "published_at"); release["created_at"] = "2020-01-01T00:00:00Z"
        #expect(try UpdateAge.githubEvidence(JSONSerialization.data(withJSONObject: [release]), source: source, item: item(), at: now) == nil)
        let mozilla = ReleaseNotesSource(.firefox, url: URL(string: "https://addons.mozilla.org/addon/example")!)
        #expect(UpdateAgeEvidence.earliest([ReleaseNote(version: "2.0", date: daysAgo(20))], source: mozilla, item: item(), at: now) == nil)
    }
    @Test func targetChangesAndTrimmedHistoryDoNotResetProvenAge() {
        var previous = item(target: "2.0"); previous.updateAgeEvidence = evidence(previous)
        var fresh = item(); fresh.updateAgeEvidence = evidence(fresh, days: 2, version: "3.0")
        let merged = ScanResult(items: [fresh], reports: [], date: now).preservingLastFindings(from: [previous]).items[0]
        #expect(merged.updateAgeEvidence?.date == daysAgo(12))
        #expect(UpdateAge.indicator(for: merged, detectedAt: nil, at: now)?.label(at: now) == "Outdated for at least 12 days")
    }
    @Test func installedChangesAndIdentityOrSourceChangesInvalidateOldEvidence() {
        let previous = item(); let old = evidence(previous)
        var mutations = [item(installed: "1.5"), item(build: "101"), item(target: "1.0")]
        var copy = item(); copy.id = "/Volumes/Other/Example.app"; mutations.append(copy)
        copy = item(); copy.bundleID = "com.other.app"; mutations.append(copy)
        copy = item(); copy.releaseNotes?.sources = []; mutations.append(copy)
        for changed in mutations { #expect(!old.applies(to: changed, at: now)) }
        var changed = item(installed: "1.5"); changed.updateAgeEvidence = old
        let indicator = UpdateAge.indicator(for: changed, detectedAt: daysAgo(1), at: now)
        #expect(indicator?.evidence == nil && indicator?.label(at: now) == "Detected 1 day ago")
    }
    @Test func unavailableResultsNeverShowAnOverdueBadgeButCanRetainEvidence() {
        var previous = item(); previous.updateAgeEvidence = evidence(previous)
        var failed = item(); failed.status = .unverified
        let cached = ScanResult(items: [failed], reports: [], date: now).preservingLastFindings(from: [previous]).items[0]
        #expect(cached.updateAgeEvidence == previous.updateAgeEvidence)
        #expect(UpdateAge.indicator(for: cached, detectedAt: daysAgo(1), at: now) == nil)
        #expect(ScanResult(items: [item()], reports: [], date: now).preservingLastFindings(from: [cached]).items[0].updateAgeEvidence == previous.updateAgeEvidence)
    }
    @Test func localAgeSurvivesNewTargetsButResetsAfterPartialUpgrade() {
        let current = item()
        let offers = [HistoryOffer(softwareID: current.id, version: "2.0"): daysAgo(20), HistoryOffer(softwareID: current.id, version: "3.0"): daysAgo(1),
            HistoryOffer(softwareID: "/Volumes/Other/Example.app", version: "2.0"): daysAgo(30), HistoryOffer(softwareID: current.id, version: "4.0"): daysAgo(40)]
        #expect(UpdateAge.detectionDate(for: current, offers: offers, entries: []) == daysAgo(20))
        let changed = item(installed: "1.5", build: "150")
        let entry = UpdateHistoryEntry(software: SoftwareSnapshot(id: current.id, name: "Example", version: "1.5", build: "150"), previousVersion: "1.0", change: .updated, detectedAt: daysAgo(2), previouslyObservedAt: daysAgo(3))
        #expect(UpdateAge.detectionDate(for: changed, offers: offers, entries: [entry]) == daysAgo(2))
        let buildOnly = item(target: "1.0", build: "101")
        let buildChange = UpdateHistoryEntry(software: SoftwareSnapshot(id: current.id, name: "Example", version: "1.0", build: "101"), previousVersion: "1.0", previousBuild: "100", change: .buildChanged, detectedAt: daysAgo(2), previouslyObservedAt: daysAgo(3))
        #expect(UpdateAge.detectionDate(for: buildOnly, offers: [HistoryOffer(softwareID: current.id, version: "1.0"): daysAgo(20)], entries: [buildChange]) == daysAgo(2))
        let partial = item(installed: "2.0")
        #expect(UpdateAge.detectionDate(for: partial, offers: offers, entries: [entry]) == daysAgo(1))
    }
    @Test func localAgeResolvesStableInstallationAndMacOSIdentities() {
        let current = item()
        let snapshot = SoftwareSnapshot(id: "stable:installation", name: "Example", path: current.path, version: "1.0", resolvedPath: current.path)
        let offers = [HistoryOffer(softwareID: snapshot.id, version: "2.0"): daysAgo(3)]
        #expect(UpdateAge.detectionDate(for: current, offers: offers, entries: [], snapshot: snapshot) == daysAgo(3))
        let os = UpdateItem(id: "macos:26.1", name: "macOS", installedVersion: "26.0", availableVersion: "26.1", source: .system, status: .available)
        #expect(UpdateAge.detectionDate(for: os, offers: [HistoryOffer(softwareID: "system:macos", version: "26.1"): daysAgo(4)], entries: []) == daysAgo(4))
    }
    @Test func noDatesNoBadgeAndLocalLabelsRemainDistinct() {
        #expect(UpdateAge.indicator(for: item(), detectedAt: nil, at: now) == nil)
        #expect(UpdateAge.indicator(for: item(), detectedAt: now.addingTimeInterval(1), at: now) == nil)
        #expect(UpdateAge.indicator(for: item(), detectedAt: daysAgo(0.9), at: now)?.label(at: now) == "Detected 21 hours ago")
        #expect(UpdateAge.indicator(for: item(), detectedAt: daysAgo(2), at: now)?.label(at: now) == "Detected 2 days ago")
        var pending = item(); pending.updateAgeEvidence = evidence(pending, days: 1.0 / 24)
        #expect(UpdateAge.indicator(for: pending, detectedAt: nil, at: now)?.label(at: now) == "Outdated for at least 1 hour")
        pending.status = .current
        #expect(UpdateAge.indicator(for: pending, detectedAt: daysAgo(2), at: now) == nil)
    }
    @Test func sparkleBuildOnlyUpdatesAndCompatibilityUseSeparateVersionDomains() throws {
        let feed = ReleaseNotesSource(.sparkle, url: URL(string: "https://example.com/appcast.xml")!)
        var pending = item(installed: "1.0", target: "1.0")
        pending.releaseNotes = ReleaseNotesContext(sources: [feed], installedBuild: "100", targetBuild: "120")
        func release(_ build: String, date: String, extra: String = "") -> String {
            "<item><sparkle:version>\(build)</sparkle:version><sparkle:shortVersionString>1.0</sparkle:shortVersionString><pubDate>\(date)</pubDate>\(extra)</item>"
        }
        let xml = "<rss xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'><channel>"
            + release("100", date: "Thu, 01 Jan 2026 00:00:00 +0000")
            + release("105", date: "Thu, 01 Jan 2026 00:00:00 +0000", extra: "<sparkle:hardwareRequirements>x86_64</sparkle:hardwareRequirements>")
            + release("110", date: "Thu, 01 Oct 2026 00:00:00 +0000")
            + release("115", date: "Thu, 01 Jan 2026 00:00:00 +0000", extra: "<sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>")
            + release("120", date: "Wed, 28 Oct 2026 00:00:00 +0000") + "</channel></rss>"
        let notes = try ReleaseNotesService.parseSparkle(Data(xml.utf8), request: ReleaseNotesRequest(item: pending), source: feed, platform: .init(os: "14", architecture: "arm64"))
        let found = try #require(UpdateAgeEvidence.earliest(notes.entries, source: feed, item: pending, at: now))
        #expect(found.build == "110")
        pending.updateAgeEvidence = found
        #expect(UpdateAge.indicator(for: pending, detectedAt: nil, at: now)?.evidence != nil)
        var failed = pending; failed.status = .unverified; failed.updateAgeEvidence = nil; failed.availableVersion = nil; failed.releaseNotes?.targetBuild = nil
        let retained = ScanResult(items: [failed], reports: [], date: now).preservingLastFindings(from: [pending]).items[0]
        #expect(retained.updateAgeEvidence == found)
        var recovered = pending; recovered.updateAgeEvidence = nil
        #expect(ScanResult(items: [recovered], reports: [], date: now).preservingLastFindings(from: [retained]).items[0].updateAgeEvidence == found)
        pending.releaseNotes?.installedBuild = "110"
        #expect(UpdateAge.indicator(for: pending, detectedAt: nil, at: now) == nil)
    }
    @Test func electronFractionalReleaseDatesAreUsedOnlyAfterAvailabilityIsVerified() throws {
        let app = InstalledApp(path: "/Applications/Example.app", name: "Example", bundleID: "com.example.app", version: "1.0", build: "100")
        let feed = URL(string: "https://example.com/latest-mac.yml")!
        let yaml = "version: 2.0\nreleaseDate: '2026-10-01T12:00:00.123Z'\nfiles:\n  - url: Example-universal.zip\n"
        let checked = try ElectronProvider.evaluate(Data(yaml.utf8), app: app, feed: feed)
        #expect(checked.updateAgeEvidence?.date == UpdateAge.publicationDate("2026-10-01T12:00:00.123Z"))
        #expect(try ElectronProvider.evaluate(Data((yaml + "stagingPercentage: 20\n").utf8), app: app, feed: feed).updateAgeEvidence == nil)
        #expect(try ElectronProvider.evaluate(Data(yaml.replacingOccurrences(of: "2026-10-01", with: "2099-10-01").utf8), app: app, feed: feed).updateAgeEvidence == nil)
    }
    @Test func cachesRoundTripEvidenceAndDecodePreFeatureItems() throws {
        var pending = item(); pending.updateAgeEvidence = evidence(pending)
        let encoded = try JSONEncoder().encode(pending)
        #expect(try JSONDecoder().decode(UpdateItem.self, from: encoded) == pending)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); object.removeValue(forKey: "updateAgeEvidence")
        #expect(try JSONDecoder().decode(UpdateItem.self, from: JSONSerialization.data(withJSONObject: object)).updateAgeEvidence == nil)
    }
    @Test func backgroundLookupPagesHistoryWithoutChangingUpdateStatusAndKeepsEvidenceOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try JSONSerialization.data(withJSONObject: (0..<100).map { _ in record("3.0", days: 1) })
        let older = try JSONSerialization.data(withJSONObject: [record("1.1", days: 30)])
        let cache = MetadataCache(directory: root, loader: { url, _ in url.query?.contains("page=2") == true ? older : first })
        let pending = item()
        #expect(await UpdateAge.refine(pending, cache: cache, at: now)?.date == daysAgo(30))
        #expect(pending.status == .available)
        var saved = pending; saved.updateAgeEvidence = evidence(pending)
        let offline = MetadataCache(directory: root.appendingPathComponent("offline"), loader: { _, _ in throw CheckError.failed("Offline") })
        #expect(await UpdateAge.refine(saved, cache: offline, at: now) == saved.updateAgeEvidence)
    }
    @Test func appStoreLatestDateWorksWithoutNotesButIsOnlyALowerBound() throws {
        let store = ReleaseNotesSource(.appStore, url: URL(string: "https://apps.apple.com/app/id123")!, identifier: "123", region: "TW", bundleID: "com.example.app")
        var pending = item(); pending.releaseNotes?.sources = [store]
        let data = try JSONSerialization.data(withJSONObject: ["results": [["trackId": 123, "bundleId": pending.bundleID, "version": "3.0", "currentVersionReleaseDate": "2026-10-01T00:00:00Z"]]])
        let notes = try ReleaseNotesService.parseAppStore(data, request: ReleaseNotesRequest(item: pending), source: store)
        #expect(!notes.hasPublishedNotes)
        pending.updateAgeEvidence = UpdateAgeEvidence.earliest(notes.entries, source: store, item: pending, at: now)
        #expect(UpdateAge.indicator(for: pending, detectedAt: nil, at: now)?.label(at: now).hasPrefix("Outdated for at least") == true)
        #expect(UpdateAge.indicator(for: pending, detectedAt: nil, at: now)?.explanation.contains("App Store") == true)
        pending.releaseNotes?.sources[0].region = "US"
        #expect(UpdateAge.indicator(for: pending, detectedAt: nil, at: now) == nil)
    }
    @Test func historyResetUsesNewLocalDateWithoutDiscardingPublicPublicationEvidence() {
        var pending = item()
        let resetOffers = [HistoryOffer(softwareID: pending.id, version: "3.0"): now]
        let resetDate = UpdateAge.detectionDate(for: pending, offers: resetOffers, entries: [])
        #expect(UpdateAge.indicator(for: pending, detectedAt: resetDate, at: now)?.label(at: now) == "Detected just now")
        pending.updateAgeEvidence = evidence(pending)
        #expect(UpdateAge.indicator(for: pending, detectedAt: resetDate, at: now)?.date == daysAgo(12))
    }
    @Test func backgroundHistoryHasABoundedPageLimit() async throws {
        actor Counter { var count = 0; func increment() { count += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = try JSONSerialization.data(withJSONObject: (0..<100).map { _ in record("2.0", days: 10) })
        let counter = Counter()
        let cache = MetadataCache(directory: root, loader: { _, _ in await counter.increment(); return records })
        #expect(await UpdateAge.refine(item(), cache: cache, at: now)?.date == daysAgo(10))
        #expect(await counter.count == 3)
    }

    @Test func sparkleDownloadEnclosuresPreserveVersionsWithoutOverlappingAccess() throws {
        // Real appcasts mix enclosure attributes and item-level version elements.
        // Reading and mutating the same optional in one assignment traps in optimized builds.
        let feed = ReleaseNotesSource(.sparkle, url: URL(string: "https://example.com/appcast.xml")!)
        var pending = item(target: "2.0")
        pending.releaseNotes = ReleaseNotesContext(sources: [feed], installedBuild: "100", targetBuild: "200")
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>110</sparkle:version><sparkle:shortVersionString>1.1</sparkle:shortVersionString><pubDate>Thu, 01 Oct 2026 00:00:00 +0000</pubDate><enclosure url="https://example.com/Example-1.1.zip"/></item>
        <item><pubDate>Wed, 28 Oct 2026 00:00:00 +0000</pubDate><enclosure url="https://example.com/Example-2.0.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/></item>
        </channel></rss>
        """
        let result = try ReleaseNotesService.parseSparkle(Data(xml.utf8), request: ReleaseNotesRequest(item: pending), source: feed)
        #expect(result.entries.map(\.version) == ["1.1", "2.0"])
        #expect(result.entries.map(\.build) == ["110", "200"])
        #expect(UpdateAgeEvidence.earliest(result.entries, source: feed, item: pending, at: now)?.version == "1.1")
    }

}
