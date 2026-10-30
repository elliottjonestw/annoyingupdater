import Foundation
import Testing
@testable import UpdaterCore

@Suite("Finder application selections")
struct ApplicationSelectionTests {
    @Test func acceptsMultipleRealBundlesAndDeduplicatesAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First App 日本語.app"), second = root.appendingPathComponent("Second.app")
        let fixture = ApplicationDiscoveryTests()
        try fixture.writeApp(first); try fixture.writeApp(second)
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        #expect(ApplicationSelection.paths(from: [first, second, alias, first]) == [first.path, second.path])
        #expect(ApplicationSelection.paths(from: Array(repeating: first, count: 200)).count == 1)
    }
    @Test func rejectsRemoteMissingHelpersAndBuildArtifacts() {
        #expect(ApplicationSelection.paths(from: [URL(string: "https://example.com/Test.app")!,
            URL(string: "file://remote-server/Share/Test.app")!, URL(fileURLWithPath: "/tmp/Missing.app"),
            URL(fileURLWithPath: "/tmp/Main.app/Contents/Helper.app"), URL(fileURLWithPath: "/tmp/.build/Test.app"),
            URL(fileURLWithPath: "/System/Applications/Notes.app")]).isEmpty)
    }
}
