import Foundation
import Testing
@testable import UpdaterCore

@Suite("Installed apps are refreshed after external updates")
struct InventoryTests {
    @Test func rescanReadsUpdatedVersionAndBuildInSameProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = root.appendingPathComponent("Tailscale.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = contents.appendingPathComponent("Info.plist")
        func write(version: String, build: String) throws {
            let info = ["CFBundleIdentifier": "io.tailscale.ipn.macos", "CFBundleName": "Tailscale",
                        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": build]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
        }
        try write(version: "1.104.2", build: "277.300.83000")
        #expect(Inventory.discover(in: [root]).first?.version == "1.104.2")

        // Simulate the App Store replacing the app while the updater keeps running.
        try write(version: "1.104.4", build: "277.300.83095")
        let rescanned = try #require(Inventory.discover(in: [root]).first)
        #expect(rescanned.version == "1.104.4")
        #expect(rescanned.build == "277.300.83095")
    }
}
