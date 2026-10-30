import Foundation
import Testing
@testable import UpdaterCore

@Suite("Release notes across version jumps")
struct ReleaseNotesTests {
    let github = ReleaseNotesSource(.github, url: URL(string: "https://api.github.com/repos/example/product/releases")!)
    let feed = ReleaseNotesSource(.sparkle, url: URL(string: "https://example.com/updates/appcast.xml")!)
    func request(installed: String = "1.0", target: String = "2.0", context: ReleaseNotesContext = ReleaseNotesContext()) -> ReleaseNotesRequest {
        ReleaseNotesRequest(item: UpdateItem(id: "/Applications/Example.app", name: "Example", bundleID: "com.example.product", installedVersion: installed,
            availableVersion: target, source: .sparkle, status: .available, releaseNotes: context))
    }
    func record(_ version: String, draft: Bool = false, prerelease: Bool = false, date: String = "2026-10-01T00:00:00Z", body: String = "Changes") -> [String: Any] {
        ["tag_name": version, "draft": draft, "prerelease": prerelease, "body": body, "published_at": date,
         "html_url": "https://github.com/example/product/releases/tag/\(version)"]
    }
    @Test func rangeExcludesInstalledAndFutureVersionsAndDoesNotUseDates() throws {
        let records = [record("v1.0"), record("v1.1", date: "2026-10-29T00:00:00Z"), record("v1.9", date: "2026-09-01T00:00:00Z"),
                       record("v2.0"), record("v2.1"), record("v1.8", draft: true), record("v1.7", prerelease: true), record("v1.6-beta")]
        let result = try ReleaseNotesService.parseGitHub(JSONSerialization.data(withJSONObject: records), request: request(), source: github, page: 1)
        #expect(NotesVersions.sorted(result.entries).map(\.version) == ["2.0", "1.9", "1.1"])
        #expect(result.nextPage == nil)
        #expect(NotesVersions.includes("1.10", after: "1.9", through: "2.0"))
        #expect(!NotesVersions.includes("2.1", after: "1.0", through: "2.0"))
        #expect(!NotesVersions.includes("2.0", after: "Unknown", through: "3.0"))
    }
    @Test func paginatedHistoryKeepsAnExplicitContinuationAndDeduplicates() throws {
        let records = (0..<100).map { record("1.\($0 + 1)") }
        let result = try ReleaseNotesService.parseGitHub(JSONSerialization.data(withJSONObject: records), request: request(target: "3.0"), source: github, page: 1)
        #expect(result.nextPage == 2)
        #expect(NotesVersions.sorted(result.entries + result.entries).count == 100)
        #expect(result.message.contains("haven't been checked"))
        let limited = try ReleaseNotesService.parseGitHub(JSONSerialization.data(withJSONObject: records), request: request(target: "3.0"), source: github, page: 20)
        #expect(limited.nextPage == nil && limited.message.contains("page limit"))
        let invalid = ReleaseNotesSource(.github, url: URL(string: "https://example.com/repos/example/product/releases")!)
        #expect(throws: (any Error).self) { try ReleaseNotesService.parseGitHub(Data("[]".utf8), request: request(), source: invalid, page: 1) }
    }
    @Test func githubProductIdentityPreventsNotesFromOtherProducts() throws {
        var source = github; source.identifier = "Example Product"
        var matching = record("1.5"), other = record("1.6")
        matching["assets"] = [["name": "Example-Product-1.5-mac.dmg"]]
        other["assets"] = [["name": "Other-Product-1.6-mac.dmg"]]
        let result = try ReleaseNotesService.parseGitHub(JSONSerialization.data(withJSONObject: [matching, other]), request: request(), source: source, page: 1)
        #expect(result.entries.map(\.version) == ["1.5"])
    }
    @Test func sparkleUsesBuildBoundsAndReadsCDATAHistoryAndRelativeURLs() throws {
        let context = ReleaseNotesContext(sources: [feed], installedBuild: "100", targetBuild: "140")
        func item(_ version: String, _ build: String, channel: String = "", body: String = "Changes") -> String {
            "<item><sparkle:version>\(build)</sparkle:version><sparkle:shortVersionString>\(version)</sparkle:shortVersionString><sparkle:channel>\(channel)</sparkle:channel><description><![CDATA[<p>\(body)</p><ul><li>Fixed &amp; improved</li></ul>]]></description><sparkle:releaseNotesLink>notes/\(build).html</sparkle:releaseNotesLink><sparkle:fullReleaseNotesLink>https://example.com/history</sparkle:fullReleaseNotesLink></item>"
        }
        let xml = "<rss xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'><channel>" + item("1.0", "100") + item("1.0", "110") + item("1.5", "130") + item("2.0", "140") + item("3.0", "150") + item("1.6", "135", channel: "beta") + "</channel></rss>"
        let result = try ReleaseNotesService.parseSparkle(Data(xml.utf8), request: request(context: context), source: feed)
        #expect(result.entries.map { $0.build! } == ["110", "130", "140"])
        #expect(result.entries[0].text.contains("Fixed & improved"))
        #expect(result.entries[0].url?.absoluteString == "https://example.com/updates/notes/110.html")
        #expect(result.sourceURL?.absoluteString == "https://example.com/history")
        #expect(result.entries.allSatisfy { $0.allowsLinkedContent })
    }
    @Test func truncatedFeedsAndRepeatedChangelogURLsAreLabelledWithoutLoadingThem() throws {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><sparkle:version>120</sparkle:version><sparkle:shortVersionString>1.2</sparkle:shortVersionString><sparkle:releaseNotesLink>https://example.com/history.html</sparkle:releaseNotesLink></item>
          <item><sparkle:version>140</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString><sparkle:releaseNotesLink>https://example.com/history.html</sparkle:releaseNotesLink></item>
        </channel></rss>
        """
        let result = try ReleaseNotesService.parseSparkle(Data(xml.utf8), request: request(), source: feed)
        #expect(result.message.contains("Older release notes may be missing"))
        #expect(!result.entries.contains(where: { $0.allowsLinkedContent }))
        #expect(throws: (any Error).self) { try ReleaseNotesService.parseSparkle(Data("<!DOCTYPE x><rss/>".utf8), request: request(), source: feed) }
    }
    @Test func electronSupportsVersionedArraysAndSingleLatestNotesWithoutIncludingFutureNotes() throws {
        let source = ReleaseNotesSource(.electron, url: URL(string: "https://example.com/latest-mac.yml")!)
        let history = """
        version: 3.0
        releaseNotes:
          - version: 1.0
            note: old
          - version: 1.1
            note: Intermediate changes
          - version: 2.0
            note: Selected changes
          - version: 3.0
            note: Future changes
        """
        let result = try ReleaseNotesService.parseElectron(Data(history.utf8), request: request(), source: source)
        #expect(result.entries.map(\.version) == ["1.1", "2.0"])
        let latest = try ReleaseNotesService.parseElectron(Data("version: 2.0\nreleaseNotes: Latest fixes".utf8), request: request(), source: source)
        #expect(latest.entries.count == 1 && latest.message.contains("latest release only"))
        #expect(try ReleaseNotesService.parseElectron(Data("version: 3.0\nreleaseNotes: Future fixes".utf8), request: request(), source: source).entries.isEmpty)
    }
    @Test func appStoreRequiresExactIdentityAndTargetAndDisclosesLatestOnlyCoverage() throws {
        let source = ReleaseNotesSource(.appStore, url: URL(string: "https://apps.apple.com/app/id123")!, identifier: "123", region: "TW", bundleID: "com.example.product")
        func data(_ version: String, bundle: String = "com.example.product") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["results": [["trackId": 123, "bundleId": bundle, "version": version, "releaseNotes": "Publisher's latest notes"]]])
        }
        let result = try ReleaseNotesService.parseAppStore(data("2.0"), request: request(), source: source)
        #expect(result.entries.count == 1 && result.message.contains("Intervening versions") == false)
        #expect(result.message.contains("intervening versions"))
        #expect(!result.entries[0].allowsLinkedContent)
        #expect(try ReleaseNotesService.parseAppStore(data("3.0"), request: request(), source: source).entries.isEmpty)
        #expect(throws: (any Error).self) { try ReleaseNotesService.parseAppStore(data("2.0", bundle: "wrong.app"), request: request(), source: source) }
    }
    @Test func firefoxUsesPublicVersionNotesAndRetainsPagination() throws {
        let source = ReleaseNotesSource(.firefox, url: URL(string: "https://addons.mozilla.org/firefox/addon/example/")!, identifier: "example@test.org")
        let root: [String: Any] = ["next": "https://addons.mozilla.org/api/v5/addons/addon/example/versions/?page=2", "results": [
            ["version": "1.1", "release_notes": ["en-US": "<p>Intermediate fixes</p>"], "file": ["status": "public"]],
            ["version": "2.0", "release_notes": ["en-US": "Selected fixes"], "file": ["status": "public"]],
            ["version": "1.5", "release_notes": ["en-US": "Disabled release"], "file": ["status": "disabled"]],
            ["version": "3.0", "release_notes": ["en-US": "Future release"], "file": ["status": "public"]]]]
        let result = try ReleaseNotesService.parseFirefox(JSONSerialization.data(withJSONObject: root), request: request(), source: source, page: 1)
        #expect(result.entries.map(\.version) == ["1.1", "2.0"])
        #expect(result.entries[0].text == "Intermediate fixes")
        #expect(result.nextPage == 2)
    }
    @Test func htmlAndMarkdownDoNotRetainExecutableOrRemoteImageContent() {
        let body = NotesText.readable("<head>Tracking</head><script>evil()</script><style>invisible</style><p>Fixed &amp; improved &#x2014; &#128512;</p><ul><li>One</li><li>Two</li></ul><img src='https://example.com/tracking.png'>", html: true)
        #expect(body.contains("Fixed & improved — 😀"))
        #expect(body.contains("• One") && body.contains("• Two"))
        #expect(!body.contains("evil") && !body.contains("Tracking") && !body.contains("tracking.png"))
        #expect(NotesText.readable("Changes ![Tracking](https://example.com/image.png)") == "Changes Tracking")
    }
    @Test func provenSourcesSurviveMergingWithoutOverridingAvailabilityOrBuildDomain() {
        let app = InstalledApp(path: "/Applications/Example.app", name: "Example", bundleID: "com.example", version: "1.0", build: "100", feedURL: feed.url)
        var catalog = app.item; catalog.status = .available; catalog.availableVersion = "2.0"; catalog.source = .appCatalog
        var repo = app.item; repo.status = .unverified; repo.releaseNotes?.prepend(github)
        let merged = DiscoveryMerger.merge(apps: [app], appCatalog: [catalog], repositories: [repo])
        #expect(merged[0].source == .appCatalog && merged[0].availableVersion == "2.0")
        #expect(merged[0].releaseNotes?.sources.contains(github) == true)
        #expect(merged[0].releaseNotes?.installedBuild == "100")
    }
    @Test func legacyCachedItemsDecodeAndNewContextsRoundTrip() throws {
        let legacy = Data(#"{"id":"app","name":"App","bundleID":"test","installedVersion":"1.0","source":"Developer","status":"current","action":{"none":{}},"detail":""}"#.utf8)
        #expect(try JSONDecoder().decode(UpdateItem.self, from: legacy).releaseNotes == nil)
        let item = UpdateItem(id: "app", name: "App", installedVersion: "1.0", availableVersion: "2.0", source: .sparkle, status: .available, releaseNotes: ReleaseNotesContext(sources: [feed], installedBuild: "100", targetBuild: "200"))
        #expect(try JSONDecoder().decode(UpdateItem.self, from: JSONEncoder().encode(item)) == item)
    }
    @Test func loadsAdditionalPagesOnDemandAndSharesCachedMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try JSONSerialization.data(withJSONObject: (0..<100).map { record("3.\($0)") })
        let second = try JSONSerialization.data(withJSONObject: [record("2.0"), record("1.5"), record("1.0")])
        let cache = MetadataCache(directory: root, loader: { url, _ in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value == "1" ? first : second
        })
        let request = request(context: ReleaseNotesContext(sources: [github]))
        let page = try await ReleaseNotesService.load(request, cache: cache)
        #expect(page.entries.isEmpty && page.nextPage == 2)
        let earlier = try await ReleaseNotesService.load(request, source: page.source, page: 2, cache: cache)
        #expect(earlier.entries.map(\.version) == ["2.0", "1.5"])
        #expect(earlier.nextPage == nil)
    }
}

@Suite("Release notes history and source integrity")
struct ReleaseNotesHistoryTests {
    @Test func historicalRangeUsesObservedVersionsAndBuildsRatherThanTheNextPendingUpdate() throws {
        let context = ReleaseNotesContext(sources: [ReleaseNotesTests().feed], installedBuild: "200", targetBuild: "300")
        let snapshot = SoftwareSnapshot(id: "app", name: "Example", version: "2.0", build: "200", releaseNotes: context)
        let entry = UpdateHistoryEntry(software: snapshot, previousVersion: "1.0", previousBuild: "100", change: .updated, detectedAt: Date(), previouslyObservedAt: Date())
        let request = try #require(ReleaseNotesRequest(history: entry))
        #expect(request.installedVersion == "1.0" && request.targetVersion == "2.0")
        #expect(request.context.installedBuild == "100" && request.context.targetBuild == "200")
        #expect(try JSONDecoder().decode(SoftwareSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        let legacy = Data(#"{"id":"app","name":"Example","bundleID":"test","version":"1.0","build":"100","kind":"application"}"#.utf8)
        #expect(try JSONDecoder().decode(SoftwareSnapshot.self, from: legacy).releaseNotes == nil)
    }
    @Test func samePublicVersionBuildChangesHaveDistinctRequestIDsAndBuildOrdering() {
        let fixture = ReleaseNotesTests()
        let one = fixture.request(installed: "1.0", target: "1.0", context: ReleaseNotesContext(installedBuild: "100", targetBuild: "110"))
        let two = fixture.request(installed: "1.0", target: "1.0", context: ReleaseNotesContext(installedBuild: "110", targetBuild: "120"))
        #expect(one.id != two.id)
        let sourceOne = fixture.request(context: ReleaseNotesContext(sources: [fixture.feed]))
        let sourceTwo = fixture.request(context: ReleaseNotesContext(sources: [fixture.github]))
        #expect(sourceOne.id != sourceTwo.id)
        let entries = [ReleaseNote(version: "2.0", build: "110"), ReleaseNote(version: "1.0", build: "120")]
        #expect(NotesVersions.sorted(entries).map(\.build) == ["120", "110"])
    }
    @Test func linkedGithubNotesUseTheApiAndCannotSwitchToANewerRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try JSONSerialization.data(withJSONObject: ["draft": false, "prerelease": false, "tag_name": "v2.0", "body": "## Actual notes\n\nFixed something"])
        let cache = MetadataCache(directory: root, loader: { url, _ in
            #expect(url.host == "api.github.com" && url.path == "/repos/example/product/releases/tags/v2.0")
            return payload
        })
        let url = URL(string: "https://github.com/example/product/releases/tag/v2.0")!
        #expect(try await ReleaseNotesService.linkedContent(url, expectedVersion: "2.0", cache: cache).contains("Actual notes"))
        await #expect(throws: (any Error).self) { try await ReleaseNotesService.linkedContent(url, expectedVersion: "1.0", cache: cache) }
    }
    @Test func notesRequestsDoNotChangeUpdateAvailability() async throws {
        let fixture = ReleaseNotesTests(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = UpdateItem(id: "app", name: "Example", installedVersion: "1.0", availableVersion: "2.0", source: .github, status: .available,
            releaseNotes: ReleaseNotesContext(sources: [fixture.github]))
        let cache = MetadataCache(directory: root, loader: { _, _ in throw CheckError.failed("Offline") })
        await #expect(throws: (any Error).self) { try await ReleaseNotesService.load(ReleaseNotesRequest(item: item), cache: cache) }
        #expect(item.status == .available && item.availableVersion == "2.0")
        #expect(try await ReleaseNotesService.load(fixture.request()).entries.isEmpty)
    }
}

@Suite("Publisher history links")
struct PublisherHistoryLinkTests {
    @Test func firefoxUsesTheVerifiedCanonicalPublisherUrlRatherThanGuessingAGuidSlug() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ReleaseNotesSource(.firefox, url: URL(string: "https://addons.mozilla.org/firefox/addon/addon@example.org")!, identifier: "addon@example.org")
        let identity = Data(#"{"guid":"addon@example.org","url":"https://addons.mozilla.org/en-US/firefox/addon/actual-published-slug/"}"#.utf8)
        let versions = Data(#"{"next":null,"results":[{"version":"2.0","file":{"status":"public"},"release_notes":{"en-US":"Fixed things"}}]}"#.utf8)
        let cache = MetadataCache(directory: root, loader: { url, _ in url.path.hasSuffix("/versions") ? versions : identity })
        let request = ReleaseNotesTests().request(context: ReleaseNotesContext(sources: [source]))
        let result = try await ReleaseNotesService.load(request, cache: cache)
        #expect(result.sourceURL?.path == "/en-US/firefox/addon/actual-published-slug/versions")
        #expect(result.entries[0].url == result.sourceURL)
    }
}

@Suite("Only offer notes that exist")
struct ReleaseNotesAvailabilityTests {
    @Test func noSourceOrHomepageDoesNotQualifyAndDoesNotFetchAnything() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MetadataCache(directory: root, loader: { _, _ in Issue.record("A homepage is not release notes"); throw CheckError.invalidResponse })
        let fixture = ReleaseNotesTests()
        #expect(try await !ReleaseNotesService.hasPublishedNotes(fixture.request(), cache: cache))
        let request = fixture.request(context: ReleaseNotesContext(sources: [ReleaseNotesSource(.website, url: URL(string: "https://example.com")!)]))
        #expect(try await !ReleaseNotesService.hasPublishedNotes(request, cache: cache))
    }
    @Test func anEmptyReleaseBodyDoesNotQualifyButOlderVersionNotesDo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ReleaseNotesTests(), request = fixture.request(context: ReleaseNotesContext(sources: [fixture.github]))
        let empty = try JSONSerialization.data(withJSONObject: [fixture.record("2.0", body: " \n ")])
        let noNotes = MetadataCache(directory: root.appendingPathComponent("empty"), loader: { _, _ in empty })
        #expect(try await !ReleaseNotesService.hasPublishedNotes(request, cache: noNotes))
        let history = try JSONSerialization.data(withJSONObject: [fixture.record("2.0", body: ""), fixture.record("1.5", body: "Actual intermediate changes")])
        let notes = MetadataCache(directory: root.appendingPathComponent("notes"), loader: { _, _ in history })
        #expect(try await ReleaseNotesService.hasPublishedNotes(request, cache: notes))
    }
    @Test func explicitDeveloperNotesLinksQualifyButEmptyStoreRecordsDoNot() {
        let explicit = ReleaseNote(version: "2.0", url: URL(string: "https://example.com/notes/2.0.html")!)
        #expect(ReleaseNotesResult(entries: [explicit], message: "", source: ReleaseNotesTests().feed).hasPublishedNotes)
        #expect(!ReleaseNotesResult(entries: [explicit], message: "", source: ReleaseNotesSource(.appStore, url: URL(string: "https://apps.apple.com/app/id123")!)).hasPublishedNotes)
    }
}

@Suite("Target notes across version domains")
struct TargetReleaseNotesTests {
    @Test func historyBuildNumbersDoNotHideVersionOnlyPublisherNotes() {
        let request = ReleaseNotesTests().request(context: ReleaseNotesContext(installedBuild: "100", targetBuild: "200"))
        #expect(NotesVersions.isTarget(ReleaseNote(version: "2.0"), for: request))
        #expect(NotesVersions.isTarget(ReleaseNote(version: "2.0", build: "200"), for: request))
        #expect(!NotesVersions.isTarget(ReleaseNote(version: "2.0", build: "300"), for: request))
        #expect(!NotesVersions.isTarget(ReleaseNote(version: "1.5"), for: request))
    }
}

@Suite("Notes availability request limits")
struct NotesRequestLimitTests {
    private actor Meter {
        var active = 0, peak = 0, completed = 0
        func enter() { active += 1; peak = max(peak, active) }
        func leave() { active -= 1; completed += 1 }
    }
    @Test func manyPendingUpdatesCannotFloodPublisherServersWithNotesProbes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meter = Meter()
        let data = try JSONSerialization.data(withJSONObject: [ReleaseNotesTests().record("2.0")])
        let cache = MetadataCache(directory: root, loader: { _, _ in
            await meter.enter(); try await Task.sleep(for: .milliseconds(20)); await meter.leave(); return data
        })
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<12 {
                let source = ReleaseNotesSource(.github, url: URL(string: "https://api.github.com/repos/example/product-\(index)/releases")!)
                let request = ReleaseNotesTests().request(context: ReleaseNotesContext(sources: [source]))
                group.addTask { try await ReleaseNotesService.hasPublishedNotes(request, cache: cache) }
            }
            for try await found in group { #expect(found) }
        }
        #expect(await meter.peak <= 4)
        #expect(await meter.completed == 12)
    }
}
