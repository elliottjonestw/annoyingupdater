import Foundation
import CSQLite
import Testing
@testable import UpdaterCore

@Suite("Installed software update history")
struct UpdateHistoryTests {
    private func software(_ version: String, build: String = "100", path: String = "/Applications/Example.app",
                          bundleID: String = "test.example", name: String = "Example") -> SoftwareSnapshot {
        SoftwareSnapshot(id: path, name: name, bundleID: bundleID, path: path, version: version, build: build)
    }
    private func offer(_ version: String = "2", path: String = "/Applications/Example.app", status: UpdateStatus = .available,
                       source: UpdateSource = .sparkle) -> UpdateItem {
        UpdateItem(id: path, name: "Example", installedVersion: "1", availableVersion: version, source: source, status: status)
    }
    private func at(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func observation(_ software: [SoftwareSnapshot], _ date: Double, uncertain: [String] = []) -> HistoryObservation {
        HistoryObservation(software: software, date: at(date), uncertainPaths: uncertain)
    }
    private func database() throws -> (URL, UpdateHistoryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-history-" + UUID().uuidString)
        return (root, try UpdateHistoryStore(url: root.appendingPathComponent("history.sqlite")))
    }
    private func sql(_ text: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CheckError.failed("Test database couldn't be opened") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw CheckError.failed("Test SQL failed") }
    }

    @Test func firstScanEstablishesBaselineWithoutBackfill() throws {
        var state = HistoryTrackingState()
        let entries = state.apply(observation([software("1")], 10), items: [offer()], checkedAt: at(11))
        #expect(entries.isEmpty)
        #expect(state.startedAt == at(10))
        #expect(state.offers[HistoryOffer(item: offer())!] == at(11))
    }
    @Test func externalUpdateIsRecordedEvenWhenAvailabilityCannotBeChecked() throws {
        var state = HistoryTrackingState()
        _ = state.apply(observation([software("1")], 10), items: [offer()], checkedAt: at(11))
        let entries = state.apply(observation([software("2")], 20), items: [offer(status: .unverified)], checkedAt: at(21))
        let event = try #require(entries.first)
        #expect(event.change == .updated)
        #expect(event.previousVersion == "1")
        #expect(event.software.version == "2")
        #expect(event.previouslyObservedAt == at(10))
        #expect(event.detectedAt == at(20))
        #expect(event.firstDetectedAvailableAt == at(11))
    }
    @Test func availabilityChangesAndFailedChecksNeverImplyInstallation() {
        var state = HistoryTrackingState()
        _ = state.apply(observation([software("1")], 10), items: [offer()], checkedAt: at(11))
        #expect(state.apply(observation([software("1")], 20), items: [], checkedAt: at(21)).isEmpty)
        #expect(state.apply(observation([software("1")], 30), items: [offer("3", status: .unverified)], checkedAt: at(31)).isEmpty)
        #expect(state.offers[HistoryOffer(item: offer())!] == at(11))
        #expect(state.offers[HistoryOffer(item: offer("3"))!] == nil)
        #expect(state.apply(observation([software("1")], 40), items: [offer(source: .homebrewCatalog)], checkedAt: at(41)).isEmpty)
        #expect(state.offers[HistoryOffer(item: offer())!] == at(11))
    }
    @Test func eachAvailableVersionHasItsOwnFirstDetectedDate() {
        var state = HistoryTrackingState()
        _ = state.apply(observation([software("1")], 10), items: [offer()], checkedAt: at(11))
        _ = state.apply(observation([software("1")], 20), items: [offer("3")], checkedAt: at(21))
        _ = state.apply(observation([software("1")], 30), items: [offer("3")], checkedAt: at(31))
        #expect(state.offers[HistoryOffer(item: offer())!] == at(11))
        #expect(state.offers[HistoryOffer(item: offer("3"))!] == at(21))
        let entries = state.apply(observation([software("3")], 40), items: [], checkedAt: at(41))
        #expect(entries.first?.firstDetectedAvailableAt == at(21))
        #expect(entries.first?.previousVersion == "1") // Never fabricate an intermediate 1 -> 2 change.
    }
    @Test func unknownAvailabilityDoesNotPreventTrackingInstalledChanges() {
        var state = HistoryTrackingState()
        _ = state.apply(observation([software("1")], 10), items: [], checkedAt: at(11))
        let entries = state.apply(observation([software("2")], 20), items: [], checkedAt: at(21))
        #expect(entries.count == 1)
        #expect(entries.first?.firstDetectedAvailableAt == nil)
    }
    @Test func buildsDowngradesAndUnfamiliarVersionsAreLabeledAccurately() {
        var state = HistoryTrackingState()
        _ = state.apply(observation([software("2", build: "100")], 10), items: [], checkedAt: at(11))
        #expect(state.apply(observation([software("2", build: "101")], 20), items: [], checkedAt: at(21)).first?.change == .buildChanged)
        #expect(state.apply(observation([software("1", build: "1")], 30), items: [], checkedAt: at(31)).first?.change == .downgraded)
        #expect(state.apply(observation([software("nightly-A")], 40), items: [], checkedAt: at(41)).first?.change == .versionChanged)
        #expect(state.apply(observation([software("nightly-B")], 50), items: [], checkedAt: at(51)).first?.change == .versionChanged)
    }
    @Test func semanticVersionFormattingAndUnknownValuesDoNotCreateEvents() {
        var state = HistoryTrackingState()
        _ = state.apply(observation([software("v1.0")], 10), items: [], checkedAt: at(11))
        #expect(state.apply(observation([software("1.0.0")], 20), items: [], checkedAt: at(21)).isEmpty)
        #expect(state.apply(observation([software("Unknown")], 30), items: [], checkedAt: at(31)).isEmpty)
        #expect(state.apply(observation([software("2")], 40), items: [], checkedAt: at(41)).isEmpty)
    }
    @Test func unchangedMovePreservesFirstSeenButChangedNewPathDoesNotInventUpdate() {
        var state = HistoryTrackingState()
        _ = state.apply(observation([software("1")], 10), items: [offer()], checkedAt: at(11))
        let path = "/Users/example/Applications/Example.app"
        #expect(state.apply(observation([software("1", path: path)], 20), items: [offer(path: path)], checkedAt: at(21)).isEmpty)
        #expect(state.offers[HistoryOffer(item: offer(path: path))!] == at(11))
        #expect(state.apply(observation([software("2", path: "/Applications/Renamed.app")], 30), items: [], checkedAt: at(31)).isEmpty)
    }
    @Test func duplicateCopiesAndReplacementIdentitiesStaySeparate() {
        var state = HistoryTrackingState()
        let other = "/Users/example/Applications/Example.app"
        _ = state.apply(observation([software("1"), software("5", path: other)], 10), items: [offer()], checkedAt: at(11))
        let entries = state.apply(observation([software("2"), software("5", path: other)], 20), items: [], checkedAt: at(21))
        #expect(entries.count == 1)
        #expect(entries.first?.software.path == "/Applications/Example.app")
        #expect(state.apply(observation([software("9", bundleID: "test.other"), software("5", path: other)], 30), items: [], checkedAt: at(31)).isEmpty)
        #expect(state.offers.isEmpty)
    }
    @Test func removalAndReinstallAreNotAnUpdateButUnreadableAppsKeepBaseline() {
        var state = HistoryTrackingState()
        _ = state.apply(observation([software("1")], 10), items: [offer()], checkedAt: at(11))
        #expect(state.apply(observation([], 20, uncertain: ["/Applications"]), items: [], checkedAt: at(21)).isEmpty)
        #expect(state.offers[HistoryOffer(item: offer())!] == at(11))
        #expect(state.apply(observation([software("2")], 30), items: [], checkedAt: at(31)).count == 1)
        #expect(state.apply(observation([], 40), items: [], checkedAt: at(41)).isEmpty)
        #expect(state.apply(observation([software("3")], 50), items: [], checkedAt: at(51)).isEmpty)
    }
    @Test func osAndSelfUpdatesUseStableInstalledIdentities() {
        var state = HistoryTrackingState()
        let os = SoftwareSnapshot(id: "system:macos", name: "macOS", version: "26.0", build: "25A1", kind: .macOS)
        let own = SoftwareSnapshot(id: "self:com.annoyingupdater.app", name: "upd8er", version: "1.0", kind: .updater)
        let systemOffer = UpdateItem(id: "system:macOS 26.1:26.1", name: "macOS 26.1", installedVersion: "26.0", availableVersion: "26.1", source: .system, status: .available)
        _ = state.apply(observation([os, own], 10), items: [systemOffer], checkedAt: at(11))
        var nextOS = os; nextOS.version = "26.1"; nextOS.build = "25B1"
        var nextOwn = own; nextOwn.version = "1.1"
        let events = state.apply(observation([nextOS, nextOwn], 20), items: [], checkedAt: at(21))
        #expect(events.count == 2)
        #expect(events.first { $0.software.kind == .macOS }?.firstDetectedAvailableAt == at(11))
        #expect(events.allSatisfy { $0.change == .updated })
    }
    @Test func outOfOrderAndRepeatedObservationsDoNotCreateDowngrades() {
        var state = HistoryTrackingState()
        _ = state.apply(observation([software("1")], 10), items: [], checkedAt: at(11))
        #expect(state.apply(observation([software("2")], 20), items: [], checkedAt: at(21)).count == 1)
        #expect(state.apply(observation([software("1")], 15), items: [offer()], checkedAt: at(22)).isEmpty)
        #expect(state.apply(observation([software("2")], 20), items: [], checkedAt: at(23)).isEmpty)
        #expect(state.apply(observation([software("2")], 30), items: [], checkedAt: at(31)).isEmpty)
    }
    @Test func sqlitePersistsBaselinesFirstSeenAndHistoryAcrossStoreInstances() async throws {
        let (root, store) = try database(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.record(observation([software("1")], 10), items: [offer()], checkedAt: at(11))
        let reopened = try UpdateHistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let before = try await reopened.contents()
        #expect(before.entries.isEmpty)
        #expect(before.firstDetected[HistoryOffer(item: offer())!] == at(11))
        let after = try await reopened.record(observation([software("2")], 20), items: [], checkedAt: at(21))
        #expect(after.entries.count == 1)
        #expect(after.entries.first?.firstDetectedAvailableAt == at(11))
        let duplicate = try await store.record(observation([software("2")], 30), items: [], checkedAt: at(31))
        #expect(duplicate.entries.count == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("history.sqlite").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    @Test func concurrentWritersDoNotDuplicateEvents() async throws {
        let (root, first) = try database(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await first.record(observation([software("1")], 10), items: [], checkedAt: at(11))
        let second = try UpdateHistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let next = observation([software("2")], 20)
        async let a = first.record(next, items: [], checkedAt: at(21))
        async let b = second.record(next, items: [], checkedAt: at(21))
        let results = try await [a, b]
        #expect(results.allSatisfy { $0.entries.count == 1 })
    }
    @Test func failedTransactionDoesNotAdvanceBaselineOrLoseFirstSeen() async throws {
        let (root, store) = try database(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.sqlite")
        _ = try await store.record(observation([software("1")], 10), items: [offer()], checkedAt: at(11))
        try sql("CREATE TRIGGER fail_insert BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'test failure'); END", at: file)
        var failed = false
        do { _ = try await store.record(observation([software("2")], 20), items: [], checkedAt: at(21)) }
        catch { failed = true }
        #expect(failed)
        #expect(try await store.contents().entries.isEmpty)
        try sql("DROP TRIGGER fail_insert", at: file)
        let result = try await store.record(observation([software("2")], 20), items: [], checkedAt: at(21))
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.previousVersion == "1")
        #expect(result.entries.first?.firstDetectedAvailableAt == at(11))
    }
    @Test func clearResetsDatesAndKeepsCurrentVersionsAsBaseline() async throws {
        let (root, store) = try database(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.record(observation([software("1")], 10), items: [offer()], checkedAt: at(11))
        let current = observation([software("2")], 20)
        _ = try await store.record(current, items: [offer("3")], checkedAt: at(21))
        let cleared = try await store.clear(observation: current, items: [offer("3")], at: at(25))
        #expect(cleared.entries.isEmpty)
        #expect(cleared.firstDetected[HistoryOffer(item: offer("3"))!] == at(25))
        #expect(cleared.startedAt == at(25))
        let same = try await store.record(observation([software("2")], 30), items: [offer("3")], checkedAt: at(31))
        #expect(same.entries.isEmpty)
        let next = try await store.record(observation([software("3")], 40), items: [], checkedAt: at(41))
        #expect(next.entries.count == 1)
        #expect(next.entries.first?.previousVersion == "2")
        #expect(next.entries.first?.firstDetectedAvailableAt == at(25))
    }
    @Test func corruptAndFutureDatabasesAreNotSilentlyReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.sqlite")
        let bytes = Data("not a database".utf8); try bytes.write(to: file)
        #expect(throws: (any Error).self) { try UpdateHistoryStore(url: file) }
        #expect(try Data(contentsOf: file) == bytes)
        try FileManager.default.removeItem(at: file)
        try sql("PRAGMA user_version = 99", at: file)
        #expect(throws: (any Error).self) { try UpdateHistoryStore(url: file) }
    }
    @Test func legacyScanCacheWithoutObservationStillDecodes() throws {
        let legacy = Data(#"{"items":[],"reports":[],"date":0}"#.utf8)
        let result = try JSONDecoder().decode(ScanResult.self, from: legacy)
        #expect(result.observation == nil)
        #expect(result.items.isEmpty)
    }
}

@Suite("History calendar and metadata boundaries")
struct HistoryBoundaryTests {
    @Test func groupingUsesLocalDaysAndNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let parser = ISO8601DateFormatter()
        let first = try #require(parser.date(from: "2026-10-28T16:30:00Z"))
        let second = try #require(parser.date(from: "2026-10-29T15:30:00Z"))
        let third = try #require(parser.date(from: "2026-10-29T16:30:00Z"))
        let app = SoftwareSnapshot(id: "app", name: "Example", version: "2")
        let entries = [first, third, second].map { UpdateHistoryEntry(software: app, previousVersion: "1", change: .updated, detectedAt: $0, previouslyObservedAt: $0) }
        let grouped = UpdateHistoryDay.grouped(entries, calendar: calendar)
        #expect(grouped.count == 2)
        #expect(grouped[0].entries.map(\.detectedAt) == [third])
        #expect(grouped[1].entries.map(\.detectedAt) == [second, first])
    }
    @Test func unreadableBundleMetadataIsReportedWithoutClaimingRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Unreadable.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = Inventory.inspect(in: [root])
        #expect(result.apps.isEmpty)
        #expect(result.uncertainPaths.contains(app.path))
    }
    @Test func samePathWithNewBundleIdentityDoesNotInheritOldFirstSeen() {
        var state = HistoryTrackingState()
        let old = SoftwareSnapshot(id: "app", name: "Example", bundleID: "one", version: "1")
        let available = UpdateItem(id: "app", name: "Example", installedVersion: "1", availableVersion: "2", source: .sparkle, status: .available)
        _ = state.apply(HistoryObservation(software: [old], date: Date(timeIntervalSince1970: 10)), items: [available], checkedAt: Date(timeIntervalSince1970: 11))
        var other = old; other.bundleID = "two"
        #expect(state.apply(HistoryObservation(software: [other], date: Date(timeIntervalSince1970: 20)), items: [], checkedAt: Date(timeIntervalSince1970: 21)).isEmpty)
        #expect(state.offers.isEmpty)
    }
}

@Suite("Versioned installation paths")
struct VersionedHistoryTests {
    @Test func homebrewStyleSymlinkReplacementKeepsIdentityAndFirstSeen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func target(_ version: String) throws -> URL {
            let app = root.appendingPathComponent("Caskroom/\(version)/Example.app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.example", "CFBundleName": "Example", "CFBundleShortVersionString": version, "CFBundleVersion": version], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return app
        }
        let link = applications.appendingPathComponent("Example.app")
        let one = try target("1.0")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: one)
        let first = try #require(Inventory.discover(in: [applications]).first)
        #expect(first.path == one.path)
        let location = try #require(first.installationPath)
        let installation = URL(fileURLWithPath: location)
        #expect(installation.lastPathComponent == "Example.app")
        #expect(installation.deletingLastPathComponent().resolvingSymlinksInPath().path == applications.resolvingSymlinksInPath().path)
        #expect(location != first.path)
        let store = try UpdateHistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let item = UpdateItem(id: first.path, name: "Example", installedVersion: "1.0", availableVersion: "2.0", source: .homebrew, status: .available)
        let start = Date(timeIntervalSince1970: 10)
        let baseline = try await store.record(HistoryObservation(software: [SoftwareSnapshot(app: first)], date: start), items: [item], checkedAt: start)
        #expect(baseline.firstDetected[HistoryOffer(item: item)!] == start)
        let two = try target("2.0")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: two)
        let updated = try #require(Inventory.discover(in: [applications]).first)
        #expect(updated.path != first.path)
        let result = try await store.record(HistoryObservation(software: [SoftwareSnapshot(app: updated)], date: Date(timeIntervalSince1970: 20)), items: [], checkedAt: Date(timeIntervalSince1970: 21))
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.previousVersion == "1.0")
        #expect(result.entries.first?.software.version == "2.0")
        #expect(result.entries.first?.software.path == location)
        #expect(result.entries.first?.firstDetectedAvailableAt == start)
    }
}

@Suite("Outstanding updates survive partial installation")
struct PartialHistoryTests {
    @Test func partialExternalUpdateWhileOfflinePreservesLaterReleaseDate() throws {
        var state = HistoryTrackingState()
        func snapshot(_ version: String) -> SoftwareSnapshot { SoftwareSnapshot(id: "app", name: "Example", version: version, build: "100") }
        func observed(_ version: String, _ time: Double) -> HistoryObservation {
            HistoryObservation(software: [snapshot(version)], date: Date(timeIntervalSince1970: time))
        }
        let pending = UpdateItem(id: "app", name: "Example", installedVersion: "1", availableVersion: "3", source: .sparkle, status: .available)
        let first = Date(timeIntervalSince1970: 11)
        _ = state.apply(observed("1", 10), items: [pending], checkedAt: first)
        let partial = state.apply(observed("2", 20), items: [], checkedAt: Date(timeIntervalSince1970: 21))
        #expect(partial.first?.firstDetectedAvailableAt == nil)
        #expect(state.offers[HistoryOffer(item: pending)!] == first)
        _ = state.apply(observed("2", 30), items: [pending], checkedAt: Date(timeIntervalSince1970: 31))
        #expect(state.offers[HistoryOffer(item: pending)!] == first)
        let completed = state.apply(observed("3", 40), items: [], checkedAt: Date(timeIntervalSince1970: 41))
        #expect(completed.first?.firstDetectedAvailableAt == first)
        #expect(state.offers.isEmpty)
    }
}
