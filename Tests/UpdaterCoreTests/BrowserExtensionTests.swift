import Foundation
import Testing
@testable import UpdaterCore

@Suite("Browser extension monitoring")
struct BrowserExtensionTests {
    let id = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    func profile(_ browser: BrowserFamily = .chrome, extensions: [BrowserExtension] = [], date: Date? = nil) -> BrowserProfile {
        BrowserProfile(profileID: "AF18F88D-7086-42E3-83C5-A76D468E134A", label: "Work", browser: browser, browserVersion: "156.0", extensions: extensions, receivedAt: date)
    }
    var ext: BrowserExtension { BrowserExtension(id: id, name: "Example", version: "1.0", updateURL: "https://clients2.google.com/service/update2/crx") }
    @Test func validatesAndSeparatesProfilesAndControlsFreshness() throws {
        let first = profile(extensions: [ext]); var second = first
        second.profileID = UUID().uuidString
        #expect(first.namespace != second.namespace)
        second = first; second.browser = .brave
        #expect(first.namespace != second.namespace)
        var invalid = first; invalid.extensions.append(ext)
        #expect(throws: (any Error).self) { try invalid.validated() }
        invalid = first; invalid.profileID = "../../bad"
        #expect(throws: (any Error).self) { try invalid.validated() }
        let date = Date(); let fresh = profile(date: date)
        #expect(fresh.isFresh(at: date.addingTimeInterval(179)))
        #expect(!fresh.isFresh(at: date.addingTimeInterval(180)))
        #expect(!fresh.isFresh(at: date.addingTimeInterval(-1)))
    }
    @Test func storeIgnoresClientTimestampAndFingerprintIgnoresHeartbeats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserInventoryStore(directory: root), date = Date()
        let payload = try JSONEncoder().encode(profile(extensions: [ext], date: .distantFuture))
        try store.save(payload, at: date)
        #expect(store.read().profiles.first?.receivedAt == date)
        let before = store.fingerprint(at: date)
        try store.save(payload, at: date.addingTimeInterval(10))
        #expect(store.fingerprint(at: date.addingTimeInterval(11)) == before)
        #expect(store.fingerprint(at: date.addingTimeInterval(200)) != before)
        let file = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        try Data("broken".utf8).write(to: file)
        #expect(store.read().failed)
    }
    @Test func queryEscapesIdentityAndOnlyUsesRecognizedStores() throws {
        let url = try BrowserExtensionProvider.queryURL(ext, profile: profile())
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(values.first { $0.name == "x" }?.value == "id=\(id)&v=1.0&uc")
        #expect(values.first { $0.name == "prodversion" }?.value == "156.0")
        var other = ext; other.updateURL = "https://example.com/update"
        #expect(throws: (any Error).self) { try BrowserExtensionProvider.queryURL(other, profile: profile()) }
        other.id = "addon@example.org"; other.updateURL = nil
        #expect(try BrowserExtensionProvider.queryURL(other, profile: profile(.firefox)).host == "addons.mozilla.org")
    }
    @Test func chromiumRequiresExactIdentityAndUnderstandsNoUpdate() throws {
        func xml(_ id: String, _ status: String, version: String = "2.0") -> Data {
            Data("<gupdate><app appid='\(id)' status='ok'><updatecheck status='\(status)' version='\(version)'/></app></gupdate>".utf8)
        }
        let item = try BrowserExtensionProvider.parseChromium(xml(id, "ok"), ext: ext, profile: profile())
        #expect(item.status == .available && item.availableVersion == "2.0")
        #expect(item.kind == .browserExtension)
        #expect(try BrowserExtensionProvider.parseChromium(xml(id, "noupdate"), ext: ext, profile: profile()).status == .current)
        #expect(throws: (any Error).self) { try BrowserExtensionProvider.parseChromium(xml("wrong", "ok"), ext: ext, profile: profile()) }
        #expect(throws: (any Error).self) { try BrowserExtensionProvider.parseChromium(xml(id, "error-unknownApplication"), ext: ext, profile: profile()) }
        let malicious = Data("<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><x>&x;</x>".utf8)
        #expect(throws: (any Error).self) { try BrowserExtensionProvider.parseChromium(malicious, ext: ext, profile: profile()) }
    }
    @Test func firefoxChecksGuidPublicStatusAndActualCompatibility() throws {
        var extensionInfo = ext; extensionInfo.id = "addon@example.org"
        func data(guid: String = "addon@example.org", min: String = "140.0", max: String = "*", strict: Bool = true, status: String = "public") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["guid": guid, "current_version": ["version": "2.0", "file": ["status": status],
                "compatibility": ["firefox": ["min": min, "max": max]], "is_strict_compatibility_enabled": strict]])
        }
        let p = profile(.firefox)
        #expect(try BrowserExtensionProvider.parseFirefox(data(), ext: extensionInfo, profile: p).status == .available)
        #expect(try BrowserExtensionProvider.parseFirefox(data(min: "160.0"), ext: extensionInfo, profile: p).status == .unverified)
        #expect(try BrowserExtensionProvider.parseFirefox(data(max: "150.0"), ext: extensionInfo, profile: p).status == .unverified)
        #expect(try BrowserExtensionProvider.parseFirefox(data(max: "150.0", strict: false), ext: extensionInfo, profile: p).status == .available)
        #expect(throws: (any Error).self) { try BrowserExtensionProvider.parseFirefox(data(guid: "wrong"), ext: extensionInfo, profile: p) }
        #expect(throws: (any Error).self) { try BrowserExtensionProvider.parseFirefox(data(status: "disabled"), ext: extensionInfo, profile: p) }
    }
    @Test func staleInventoryAndManagedExtensionsNeverTriggerStoreRequestsOrReminders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserInventoryStore(directory: root), date = Date()
        try store.save(JSONEncoder().encode(profile(extensions: [ext])), at: date.addingTimeInterval(-200))
        let cache = MetadataCache(directory: root.appendingPathComponent("cache"), loader: { _, _ in
            Issue.record("Stale or managed inventory must not make a network request"); throw CheckError.invalidResponse
        })
        let stale = await BrowserExtensionProvider.check(enabled: true, store: store, cache: cache, at: date)
        #expect(stale.items.first?.status == .unverified)
        #expect(stale.snapshots.isEmpty)
        #expect(stale.uncertainPaths == [profile().namespace])
        var managed = ext; managed.installType = "admin"
        try store.save(JSONEncoder().encode(profile(extensions: [managed])), at: date)
        #expect(await BrowserExtensionProvider.check(enabled: true, store: store, cache: cache, at: date).items.first?.status == .unsupported)
        let disabled = await BrowserExtensionProvider.check(enabled: false, store: store, cache: cache, at: date)
        #expect(disabled.items.isEmpty)
    }
    @Test func freshInventoryFeedsUpdateHistoryAndOfflineIntervalsPreserveBaseline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserInventoryStore(directory: root), date = Date()
        let cache = MetadataCache(directory: root.appendingPathComponent("cache"), loader: { _, _ in
            Data("<gupdate><app appid='ddkjiahejlhfcafbddmgiahcphecmpfh' status='ok'><updatecheck status='noupdate'/></app></gupdate>".utf8)
        })
        try store.save(JSONEncoder().encode(profile(extensions: [ext])), at: date)
        let first = await BrowserExtensionProvider.check(enabled: true, store: store, cache: cache, at: date)
        var state = HistoryTrackingState()
        _ = state.apply(HistoryObservation(software: first.snapshots, date: date), items: first.items, checkedAt: date)
        let offline = await BrowserExtensionProvider.check(enabled: true, store: store, cache: cache, at: date.addingTimeInterval(300))
        _ = state.apply(HistoryObservation(software: offline.snapshots, date: date.addingTimeInterval(300), uncertainPaths: offline.uncertainPaths), items: offline.items, checkedAt: date)
        var changed = ext; changed.version = "2.0"
        try store.save(JSONEncoder().encode(profile(extensions: [changed])), at: date.addingTimeInterval(400))
        let next = await BrowserExtensionProvider.check(enabled: true, store: store, cache: cache, at: date.addingTimeInterval(400))
        let events = state.apply(HistoryObservation(software: next.snapshots, date: date.addingTimeInterval(400)), items: next.items, checkedAt: date)
        #expect(events.count == 1 && events.first?.change == .updated)
        #expect(events.first?.software.kind == .browserExtension)
    }
    @Test func nativeProtocolHandlesFramingTruncationLimitsAndOriginAllowLists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: root.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try FileHandle(forUpdating: root); defer { try? handle.close() }
        let payload = Data("{\"ok\":true}".utf8)
        try NativeMessage.write(payload, to: handle); try handle.seek(toOffset: 0)
        #expect(try NativeMessage.read(from: handle) == payload)
        #expect(try NativeMessage.read(from: handle) == nil)
        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([255,255,255,255])); try handle.seek(toOffset: 0)
        #expect(throws: (any Error).self) { try NativeMessage.read(from: handle) }
        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([2,0,0,0,123])); try handle.seek(toOffset: 0)
        #expect(throws: (any Error).self) { try NativeMessage.read(from: handle) }
        #expect(BrowserFamily.brave.supportPath == "Google/Chrome")
        let manifest = try JSONSerialization.jsonObject(with: BrowserInventoryStore.hostManifest(browser: .brave, executable: "/Applications/upd8er.app/Contents/MacOS/BrowserBridge")) as! [String: Any]
        #expect(manifest["allowed_origins"] as? [String] == ["chrome-extension://\(BrowserInventoryStore.chromiumID)/"])
        #expect(manifest["allowed_extensions"] == nil)
    }
}

@Suite("Browser outage handling")
struct BrowserOutageTests {
    @Test func aFreshProfileWithFailedStoreMetadataCannotBecomeAReminder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = BrowserExtensionTests(), store = BrowserInventoryStore(directory: root), date = Date()
        try store.save(JSONEncoder().encode(fixture.profile(extensions: [fixture.ext])), at: date)
        let cache = MetadataCache(directory: root.appendingPathComponent("cache"), loader: { _, _ in throw CheckError.failed("Offline") })
        let failed = await BrowserExtensionProvider.check(enabled: true, store: store, cache: cache, at: date)
        #expect(failed.snapshots.count == 1)
        #expect(failed.items.first?.status == .unverified)
        #expect(failed.report.hasError)
        var previous = failed.items[0]; previous.status = .available; previous.availableVersion = "2.0"
        let merged = ScanResult(items: failed.items, reports: [failed.report]).preservingLastFindings(from: [previous])
        #expect(merged.items[0].availableVersion == "2.0")
        #expect(!ReminderPolicy().shouldPresent(at: date, confirmedUpdates: merged.items.filter { $0.status == .available }.count, isInstalling: false, windowVisible: false))
    }
}
