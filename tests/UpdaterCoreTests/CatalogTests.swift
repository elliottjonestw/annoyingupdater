import Foundation
import Testing
@testable import UpdaterCore

@Suite("Homebrew catalog discovery")
struct CatalogTests {
    let app = InstalledApp(path: "/Applications/Example.app", name: "Example", bundleID: "com.example.app", version: "1.2.0", build: "12")
    func candidates(_ extra: String = "") throws -> [CatalogCandidate] {
        try HomebrewCatalogProvider.parse(Data("""
        [{"token":"example","version":"1.3.0","homepage":"https://example.com/","artifacts":[
        {"app":["Example.app"]},{"zap":[{"trash":"~/Library/Preferences/com.example.app.plist"}]}]\(extra)}]
        """.utf8))
    }
    @Test func manuallyInstalledAppUsesIdentityAndDeveloperLink() throws {
        let item = try #require(CatalogMatching.match(app, candidates: candidates(), source: .homebrewCatalog, checkedAt: Date()))
        #expect(item.status == .available)
        #expect(item.availableVersion == "1.3.0")
        #expect(item.action == .website("https://example.com/"))
        #expect(!item.action.isDirect)
    }
    @Test func filenameAloneDoesNotTriggerReminder() {
        let candidate = CatalogCandidate(id: "unrelated", version: "9.0.0", names: ["example.app"])
        #expect(CatalogMatching.match(app, candidates: [candidate], source: .homebrewCatalog, checkedAt: Date())?.status == .unverified)
    }
    @Test func wrongIdentifierPrefixDoesNotMatch() throws {
        let other = InstalledApp(path: "/Applications/Other.app", name: "Other", bundleID: "com.example.ap", version: "1.0.0", build: "1")
        #expect(try CatalogMatching.match(other, candidates: candidates(), source: .homebrewCatalog, checkedAt: Date()) == nil)
    }
    @Test func disabledCatalogEntryIsExcluded() throws { #expect(try candidates(",\"disabled\":true").isEmpty) }
    @Test func betaAndAmbiguousEditionsDoNotNag() {
        let stable = CatalogCandidate(id: "example", version: "2.0.0", identifiers: ["com.example.app"])
        let lts = CatalogCandidate(id: "example@lts", version: "1.4.0", identifiers: ["com.example.app"], channel: "lts")
        let beta = CatalogCandidate(id: "example@beta", version: "3.0.0", identifiers: ["com.example.app"], channel: "beta")
        #expect(CatalogMatching.match(app, candidates: [beta], source: .homebrewCatalog, checkedAt: Date())?.status == .unverified)
        #expect(CatalogMatching.match(app, candidates: [stable, lts], source: .homebrewCatalog, checkedAt: Date())?.status == .unverified)
    }
    @Test func incompatibleReleasesDoNotNag() {
        let candidate = CatalogCandidate(id: "example", version: "2.0.0", identifiers: ["com.example.app"], minimumOS: "99.0")
        #expect(CatalogMatching.match(app, candidates: [candidate], source: .homebrewCatalog, checkedAt: Date(), platform: .init(os: "14.0", architecture: "arm64"))?.status == .unverified)
    }
    @Test func platformVersionVariationsDoNotUseWrongRelease() throws {
        let records = try candidates(",\"variations\":{\"ventura\":{\"version\":\"1.1.0\"}}")
        #expect(CatalogMatching.match(app, candidates: records, source: .homebrewCatalog, checkedAt: Date())?.status == .unverified)
    }
    @Test func appStoreInstallationsStayWithAppStore() throws {
        let store = InstalledApp(path: app.path, name: app.name, bundleID: app.bundleID, version: app.version, build: app.build, isAppStore: true)
        #expect(try CatalogMatching.match(store, candidates: candidates(), source: .homebrewCatalog, checkedAt: Date()) == nil)
    }
    @Test func artifactHashesAndVersionDomains() {
        #expect(ReleaseVersions.status(candidate: "3.6.10-ffeefe5d", installed: "3.6.10", build: "a") == .current)
        #expect(ReleaseVersions.status(candidate: "3.6.10-ffeefe5d", installed: "3.6.7", build: "a") == .available)
        #expect(ReleaseVersions.status(candidate: "2.11.194", installed: "2.11", build: "193") == .unverified)
        #expect(ReleaseVersions.status(candidate: "1.98.62.0", installed: "153.1.95.102", build: "153.1.95.102") == .unverified)
        #expect(ReleaseVersions.status(candidate: "latest", installed: "1.0.0", build: "1") == .unverified)
    }
}

private actor FetchCounter {
    var count = 0
    func request(_ url: URL, _ limit: Int) throws -> Data {
        count += 1
        if count > 1 { throw CheckError.failed("Offline") }
        return Data("metadata".utf8)
    }
}

@Suite("Public metadata caching")
struct MetadataTests {
    @Test func cachesFreshDataButNeverConfirmsExpiredOfflineData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = FetchCounter()
        let cache = MetadataCache(directory: root, loader: { try await counter.request($0, $1) })
        let url = URL(string: "https://example.com/catalog.json")!
        let start = Date(timeIntervalSince1970: 1000)
        _ = try await cache.load(url, ttl: 100, at: start)
        _ = try await cache.load(url, ttl: 100, at: start.addingTimeInterval(99))
        #expect(await counter.count == 1)
        do { _ = try await cache.load(url, ttl: 100, at: start.addingTimeInterval(100)); Issue.record("Expired metadata must not be returned while offline") }
        catch { #expect(await counter.count == 2) }
    }
    @Test func rejectsLocalInsecureAndCredentialBearingDiscoveryURLs() {
        for address in ["http://example.com", "https://localhost/a", "https://127.0.0.1/a", "https://10.0.0.1/a", "https://[::1]/a", "https://app.local/a", "https://user:token@example.com/a"] {
            #expect(!PublicURL.isAllowed(URL(string: address)!))
        }
        #expect(PublicURL.isAllowed(URL(string: "https://updates.example.com/latest-mac.yml")!))
    }
}
