import Foundation
import Testing
@testable import UpdaterCore

@Suite("Command-line tool coverage")
struct CommandLineToolsTests {
    func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func brew(_ versions: [String] = ["1.0"], linked: String? = "1.0", pinned: Bool = false) throws -> Data {
        var row: [String: Any] = ["name": "example@1", "full_name": "example@1", "versions": ["stable": "1.0"], "revision": 2,
            "installed": versions.map { ["version": $0, "installed_on_request": false] as [String: Any] }, "pinned": pinned]
        if let linked { row["linked_keg"] = linked }
        return try data(["formulae": [row]])
    }
    func outdated(_ version: String = "1.0_2") throws -> Data {
        try data(["formulae": [["name": "example@1", "current_version": version, "installed_versions": ["1.0"], "pinned": false]]])
    }
    @Test func usesManagerRevisionAndStableInstallationIdentity() throws {
        let result = try CommandLineTools.parseBrew(installed: brew(), outdated: outdated(), executable: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew")
        let item = try #require(result.items.first)
        #expect(item.status == .available)
        #expect(item.availableVersion == "1.0_2")
        #expect(item.kind == .commandLineTool)
        #expect(item.detail.contains("Dependency"))
        #expect(item.action == .copyCommand("'/opt/homebrew/bin/brew' upgrade --formula 'example@1'"))
        #expect(result.snapshots.first?.id == item.id)
        #expect(result.snapshots.first?.version == "1.0")
    }
    @Test func pinnedPackagesRemainVisibleWithoutAnUnpinAction() throws {
        let item = try #require(CommandLineTools.parseBrew(installed: brew(pinned: true), outdated: outdated(), executable: "/usr/local/bin/brew", prefix: "/usr/local").items.first)
        #expect(item.status == .available)
        #expect(item.action == .none)
        #expect(item.detail.contains("Pinned"))
    }
    @Test func resolvesLinkedKegAndDoesNotGuessAnAmbiguousInstallation() throws {
        let linked = try CommandLineTools.parseBrew(installed: brew(["0.9", "1.0"]), outdated: outdated(), executable: "/bin/brew", prefix: "/brew")
        #expect(linked.items.first?.installedVersion == "1.0")
        let ambiguous = try CommandLineTools.parseBrew(installed: brew(["0.8", "0.9"], linked: nil), outdated: outdated(), executable: "/bin/brew", prefix: "/brew")
        #expect(ambiguous.items.first?.status == .unverified)
        #expect(ambiguous.snapshots.isEmpty)
        #expect(ambiguous.uncertainPaths == ["/brew/opt/example@1"])
    }
    @Test func managerFailureCannotBecomeCurrentAndPrefixesStayDistinct() throws {
        let a = try CommandLineTools.parseBrew(installed: brew(), outdated: nil, executable: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew")
        let b = try CommandLineTools.parseBrew(installed: brew(), outdated: nil, executable: "/usr/local/bin/brew", prefix: "/usr/local")
        #expect(a.items.first?.status == .unverified)
        #expect(a.items.first?.id != b.items.first?.id)
        #expect(a.snapshots.count == 1)
        #expect(throws: (any Error).self) {
            try CommandLineTools.parseBrew(installed: brew(), outdated: Data("{}".utf8), executable: "/brew", prefix: "/brew")
        }
    }
    @Test func npmUsesExactGlobalPackageIdentityAndQuotesCommands() throws {
        let inventory = try data(["dependencies": ["@scope/example": ["version": "1.0.0"]]])
        let out = try data(["@scope/example": ["current": "1.0.0", "wanted": "2.0.0", "latest": "2.0.0"]])
        let result = try CommandLineTools.parseNpm(installed: inventory, outdated: out, executable: "/Users/test/Node Tools/bin/npm", root: "/Users/test/Node Tools/lib/node_modules")
        let item = try #require(result.items.first)
        #expect(item.status == .available)
        #expect(item.availableVersion == "2.0.0")
        #expect(item.kind == .commandLineTool)
        #expect(result.snapshots.first?.id == item.id)
        if case .copyCommand(let command) = item.action {
            #expect(command.contains("'/Users/test/Node Tools/bin/node'"))
            #expect(command.hasSuffix("'@scope/example@latest'"))
        } else { Issue.record("Expected a copy-only action") }
        #expect(CommandLineTools.quote("a'b") == "'a'\\''b'")
    }
    @Test func npmOutageOrConflictingInventoryIsNeverCurrent() throws {
        let inventory = try data(["dependencies": ["example": ["version": "1.0.0"]]])
        let noCheck = try CommandLineTools.parseNpm(installed: inventory, outdated: nil, executable: "/bin/npm", root: "/npm")
        #expect(noCheck.items.first?.status == .unverified)
        let conflict = try data(["example": ["current": "0.9.0", "latest": "2.0.0"]])
        #expect(try CommandLineTools.parseNpm(installed: inventory, outdated: conflict, executable: "/bin/npm", root: "/npm").items.first?.status == .unverified)
        #expect(throws: (any Error).self) {
            try CommandLineTools.parseNpm(installed: inventory, outdated: Data(#"{"error":{"code":"E401"}}"#.utf8), executable: "/bin/npm", root: "/npm")
        }
    }
    @Test func rejectsInvalidNamesAndBadInventoryRatherThanReturningAllClear() throws {
        #expect(throws: (any Error).self) {
            try CommandLineTools.parseNpm(installed: Data(#"{"dependencies":"broken"}"#.utf8), outdated: Data("{}".utf8), executable: "/npm", root: "/npm")
        }
        #expect(throws: (any Error).self) {
            try CommandLineTools.parseNpm(installed: data(["dependencies": ["bad;command": ["version": "1"]]]), outdated: nil, executable: "/npm", root: "/npm")
        }
        #expect(throws: (any Error).self) {
            try CommandLineTools.parseBrew(installed: Data("{}".utf8), outdated: nil, executable: "/brew", prefix: "/brew")
        }
    }
    @Test func oldCacheStillDecodesAndManagerOutagePreservesHistory() throws {
        let item = try #require(CommandLineTools.parseBrew(installed: brew(), outdated: outdated(), executable: "/brew/bin/brew", prefix: "/brew").items.first)
        let snapshot = SoftwareSnapshot(id: item.id, name: item.name, path: item.path, version: "1.0", kind: .commandLineTool)
        let first = Date(timeIntervalSince1970: 100)
        var tracking = HistoryTrackingState()
        _ = tracking.apply(HistoryObservation(software: [snapshot], date: first), items: [item], checkedAt: first)
        let unavailable = HistoryObservation(software: [], date: first.addingTimeInterval(1), uncertainPaths: ["/brew"])
        let scan = ScanResult(items: [], reports: [], observation: unavailable).preservingLastFindings(from: [item])
        #expect(scan.items.first?.status == .unverified)
        #expect(tracking.apply(unavailable, items: scan.items, checkedAt: first.addingTimeInterval(1)).isEmpty)
        var newer = snapshot; newer.version = "1.0_2"
        let entries = tracking.apply(HistoryObservation(software: [newer], date: first.addingTimeInterval(2)), items: [], checkedAt: first.addingTimeInterval(2))
        #expect(entries.count == 1)
        #expect(entries.first?.firstDetectedAvailableAt == first)
        let old = Data(#"{"id":"app","name":"Example","bundleID":"com.example","installedVersion":"1","source":"Unrecognized","status":"unsupported","action":{"none":{}},"detail":""}"#.utf8)
        #expect(try JSONDecoder().decode(UpdateItem.self, from: old).kind == .application)
    }
}
