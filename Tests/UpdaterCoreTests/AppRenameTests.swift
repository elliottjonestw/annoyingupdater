import Foundation
import Testing
@testable import UpdaterCore

@Suite("Product rename compatibility")
struct AppRenameTests {
    @Test func oldHistoryUsesCurrentNameWithoutChangingItsStoredIdentity() throws {
        let original = SoftwareSnapshot(id: "self:com.annoyingupdater.app", name: "Annoying Updater",
            bundleID: "com.annoyingupdater.app", version: "1.3", kind: .updater)
        let restored = try JSONDecoder().decode(SoftwareSnapshot.self, from: JSONEncoder().encode(original))
        #expect(restored.displayName == "upd8er")
        #expect(restored.name == original.name && restored.id == original.id)
        let other = SoftwareSnapshot(id: "other", name: "Another Updater", version: "1", kind: .application)
        #expect(other.displayName == other.name)
    }
    @Test func existingBrowserConnectionsMoveWithoutChangingTheirPermissions() throws {
        for browser in BrowserFamily.allCases {
            let old = try BrowserInventoryStore.hostManifest(browser: browser, executable: "/Applications/Annoying Updater.app/Contents/MacOS/BrowserBridge")
            let destination = "/Applications/upd8er.app/Contents/MacOS/BrowserBridge"
            let migrated = try #require(try BrowserInventoryStore.relocatedHostManifest(old, executable: destination))
            let before = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
            var after = try #require(try JSONSerialization.jsonObject(with: migrated) as? [String: Any])
            #expect(after["path"] as? String == destination)
            #expect(after["description"] as? String == "upd8er extension inventory")
            after["path"] = before["path"]; after["description"] = before["description"]
            #expect(NSDictionary(dictionary: before).isEqual(to: after))
            #expect(try BrowserInventoryStore.relocatedHostManifest(migrated, executable: destination) == nil)
        }
    }
    @Test func unrelatedOrMalformedBrowserConnectionsAreNotOverwritten() throws {
        for path in ["/Applications/Other.app/Contents/MacOS/BrowserBridge", "/Applications/Annoying Updater.app/Other/BrowserBridge", "relative/BrowserBridge"] {
            let data = try JSONSerialization.data(withJSONObject: ["name": BrowserInventoryStore.hostName, "type": "stdio", "path": path])
            #expect(try BrowserInventoryStore.relocatedHostManifest(data, executable: "/Applications/upd8er.app/Contents/MacOS/BrowserBridge") == nil)
        }
        let otherHost = try JSONSerialization.data(withJSONObject: ["name": "other.host", "type": "stdio", "path": "/Applications/Annoying Updater.app/Contents/MacOS/BrowserBridge"])
        #expect(try BrowserInventoryStore.relocatedHostManifest(otherHost, executable: "/Applications/upd8er.app/Contents/MacOS/BrowserBridge") == nil)
    }
}
