import Foundation
import Testing
@testable import UpdaterCore

@Suite("Portable application discovery")
struct ApplicationDiscoveryTests {
    func writeApp(_ url: URL, version: String = "1.0", id: String = "com.example.portable") throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id,
            "CFBundleName": "Portable", "CFBundleShortVersionString": version, "CFBundleVersion": version], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    }
    @Test func explicitRunningLocationsCoverDeepUnindexedAppsAndDeduplicateAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("custom/deep/folder/Portable.app")
        try writeApp(app)
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        let result = Inventory.inspect(in: [], additionalApps: [app, alias, app])
        #expect(result.apps.count == 1)
        #expect(result.apps.first?.installationPath == app.path)
        #expect(result.apps.first?.item.installationPath == app.path)
        #expect(result.apps.first?.version == "1.0")
        try writeApp(app, version: "2.0")
        #expect(try Inventory.inspectApp(at: app)?.version == "2.0")
    }
    @Test func boundedFoldersFindPortableCopiesButDoNotIncludeEmbeddedHelpers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("Downloads/Portable.app")
        let second = root.appendingPathComponent("External/Portable.app")
        let helper = first.appendingPathComponent("Contents/Helpers/Helper.app")
        try writeApp(first); try writeApp(second); try writeApp(helper, id: "com.example.helper")
        let result = Inventory.inspect(in: [root], additionalApps: [helper])
        #expect(result.apps.count == 2)
        #expect(Set(result.apps.map(\.bundleID)) == ["com.example.portable"])
        #expect(Set(result.apps.map(\.path)).count == 2)
        #expect(try Inventory.inspectApp(at: helper) == nil)
    }
    @Test func developmentArtifactsTrashAndSystemAppsAreNotInstallations() {
        for path in ["/tmp/project/.build/Test.app", "/tmp/project/DerivedData/Test.app", "/Volumes/Backup/Backups.backupdb/Test.app",
                     "/Users/test/.Trash/Test.app", "/System/Applications/Notes.app", "/tmp/Outer.app/Contents/Helper.app", "/Library/Frameworks/Engine.framework/Helpers/Engine.app"] {
            #expect(!Inventory.isEligibleLocation(URL(fileURLWithPath: path)))
        }
        #expect(Inventory.isEligibleLocation(URL(fileURLWithPath: "/Volumes/Portable Apps/Test.app")))
        #expect(Inventory.isEligibleLocation(URL(fileURLWithPath: "/Users/test/Downloads/Test.app")))
    }
    @Test func volumeIdentitySurvivesMountNameChangesAndOfflineHistory() {
        let firstID = Inventory.volumeIdentity(path: "/Volumes/Drive/Apps/Test.app", volumePath: "/Volumes/Drive", uuid: "volume-123")!
        let nextID = Inventory.volumeIdentity(path: "/Volumes/Drive 1/Apps/Test.app", volumePath: "/Volumes/Drive 1", uuid: "volume-123")!
        #expect(firstID == nextID)
        #expect(firstID != Inventory.volumeIdentity(path: "/Volumes/Drive/Apps/Test.app", volumePath: "/Volumes/Drive", uuid: "another-volume"))
        let app = InstalledApp(path: "/Volumes/Drive/Apps/Test.app", name: "Test", bundleID: "com.example", version: "1", build: "1", installationIdentity: firstID)
        let snapshot = SoftwareSnapshot(app: app)
        let start = Date(timeIntervalSince1970: 100)
        var state = HistoryTrackingState()
        _ = state.apply(HistoryObservation(software: [snapshot], date: start), items: [], checkedAt: start)
        #expect(state.apply(HistoryObservation(software: [], date: start.addingTimeInterval(1), uncertainPaths: ["/Volumes/Drive"]), items: [], checkedAt: start).isEmpty)
        var changed = snapshot; changed.path = "/Volumes/Drive 1/Apps/Test.app"; changed.version = "2"
        let changes = state.apply(HistoryObservation(software: [changed], date: start.addingTimeInterval(2)), items: [], checkedAt: start)
        #expect(changes.count == 1)
        #expect(changes.first?.change == .updated)
    }
    @Test func unreadableBundleIsUncertainAndMissingLocalAppIsNotInvented() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("Bad.app")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        let result = Inventory.inspect(in: [], additionalApps: [invalid, root.appendingPathComponent("Missing.app")])
        #expect(result.apps.isEmpty)
        #expect(result.uncertainPaths.contains(invalid.path))
        #expect(!result.uncertainPaths.contains(root.appendingPathComponent("Missing.app").path))
    }
    @Test func repositoryBuildOutputsAreNotPortableInstallations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("build/Test.app")
        try writeApp(artifact)
        #expect(!Inventory.isEligibleLocation(artifact))
        #expect(Inventory.inspect(in: [], additionalApps: [artifact]).apps.isEmpty)
    }
}
