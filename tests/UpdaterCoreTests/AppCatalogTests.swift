import Foundation
import Testing
@testable import UpdaterCore

@Suite("Bundle identifier app catalog")
struct AppCatalogTests {
    let app = InstalledApp(path: "/Applications/Renamed.app", name: "Renamed", bundleID: "com.example.app", version: "1.0.0", build: "1")
    func page(_ records: String, cursor: String = "null", date: Date = Date(), degraded: Bool = false) -> Data {
        let timestamp = ISO8601DateFormatter().string(from: date)
        return Data("""
        {"schemaVersion":"1","lastUpdated":"\(timestamp)","sync":{"status":"\(degraded ? "degraded" : "healthy")"},
         "data":[\(records)],"pagination":{"nextCursor":\(cursor)}}
        """.utf8)
    }
    let record = #"{"id":"example","bundleId":"com.example.app","version":"2.0.0","homepage":"https://example.com/"}"#
    @Test func exactIDMatchesRenamedApp() throws {
        let parsed = try AppCatalogProvider.parse(page(record))
        #expect(CatalogMatching.match(app, candidates: parsed.candidates, source: .appCatalog, checkedAt: parsed.publishedAt)?.status == .available)
    }
    @Test func missingOrNullIdentifiersNeverMatchByName() throws {
        let parsed = try AppCatalogProvider.parse(page(#"{"id":"renamed","name":"Renamed","bundleId":null,"version":"9.0.0"}"#))
        #expect(parsed.candidates.isEmpty)
    }
    @Test func staleFutureAndUnsupportedSchemaFailExplicitly() {
        for date in [Date().addingTimeInterval(-49 * 3600), Date().addingTimeInterval(3600)] {
            #expect(throws: (any Error).self) { try AppCatalogProvider.parse(page(record, date: date)) }
        }
        #expect(throws: (any Error).self) { try AppCatalogProvider.parse(Data("{}".utf8)) }
    }
    @Test func partialSyncIsExposed() throws { #expect(try AppCatalogProvider.parse(page(record, degraded: true)).degraded) }
    @Test func paginationFindsAppsBeyondFirstPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = page("", cursor: "\"next\"")
        let last = page(record)
        let cache = MetadataCache(directory: root, loader: { url, _ in url.query?.contains("cursor=") == true ? last : first })
        let (items, report) = await AppCatalogProvider.check([app], cache: cache)
        #expect(items.first?.status == .available); #expect(!report.hasError)
    }
    @Test func loopingPaginationNeverProducesPartialSuccess() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repeated = page(record, cursor: "\"again\"")
        let cache = MetadataCache(directory: root, loader: { _, _ in repeated })
        let (items, report) = await AppCatalogProvider.check([app], cache: cache)
        #expect(items.isEmpty); #expect(report.hasError)
    }
}
