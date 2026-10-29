import Foundation
import Testing
@testable import UpdaterCore

@Suite("Reminder behavior")
struct ReminderTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    @Test func snoozeBoundary() {
        var policy = ReminderPolicy(); policy.snooze(at: start)
        #expect(!policy.shouldPresent(at: start.addingTimeInterval(899), confirmedUpdates: 1, isInstalling: false, windowVisible: false))
        #expect(policy.shouldPresent(at: start.addingTimeInterval(900), confirmedUpdates: 1, isInstalling: false, windowVisible: false))
    }
    @Test func persistedDeadlineSurvivesRelaunch() throws {
        var policy = ReminderPolicy(); policy.snooze(at: start)
        let restored = try JSONDecoder().decode(ReminderPolicy.self, from: JSONEncoder().encode(policy))
        #expect(restored.isSnoozed(at: start.addingTimeInterval(500)))
        #expect(!restored.isSnoozed(at: start.addingTimeInterval(3600)))
    }
    @Test func noDuplicateOrInstallingReminder() {
        let policy = ReminderPolicy()
        #expect(!policy.shouldPresent(at: start, confirmedUpdates: 2, isInstalling: false, windowVisible: true))
        #expect(!policy.shouldPresent(at: start, confirmedUpdates: 2, isInstalling: true, windowVisible: false))
        #expect(!policy.shouldPresent(at: start, confirmedUpdates: 0, isInstalling: false, windowVisible: false))
    }
    @Test func newSnoozeStartsAnotherFullInterval() {
        var policy = ReminderPolicy(); policy.snooze(at: start); policy.snooze(at: start.addingTimeInterval(850))
        #expect(policy.isSnoozed(at: start.addingTimeInterval(900)))
        #expect(!policy.isSnoozed(at: start.addingTimeInterval(1750)))
    }
}

@Suite("System update parsing")
struct SystemTests {
    @Test func parsesMultipleUpdatesAndKeepsSystemComponentsDistinct() throws {
        let text = """
        Software Update found the following new or updated software:
        * Label: macOS-26.0.1
          Title: macOS Tahoe 26.0.1, Version: 26.0.1, Size: 12345KiB, Recommended: YES, Action: restart,
        * Label: CommandLineTools-1
          Title: Command Line Tools for Xcode, Version: 26.0, Size: 123KiB, Recommended: YES,
        """
        let items = try SystemProvider.parse(text, installedVersion: "26.0")
        #expect(items.count == 2)
        #expect(items[0].availableVersion == "26.0.1")
        #expect(items[0].installedVersion == "26.0")
        #expect(items[1].installedVersion == "System component")
    }
    @Test func acceptsExplicitNoUpdates() throws {
        #expect(try SystemProvider.parse("Software Update Tool\nNo new software available.", installedVersion: "26.0").isEmpty)
    }
    @Test func unknownOutputNeverMeansUpToDate() {
        #expect(throws: (any Error).self) { try SystemProvider.parse("Finding available software\nServer disconnected.", installedVersion: "26.0") }
    }
    @Test func acceptsNoUpdatesOnStderr() throws {
        let result = CommandResult(output: Data("Software Update Tool\nFinding available software".utf8), errorOutput: Data("No new software available.".utf8), status: 0)
        #expect(try SystemProvider.parse(result, installedVersion: "26.0").isEmpty)
    }
    @Test func failedExitCannotBeMistakenForNoUpdates() {
        let result = CommandResult(output: Data("No new software available.".utf8), errorOutput: Data("Service failure".utf8), status: 1)
        #expect(throws: (any Error).self) { try SystemProvider.parse(result, installedVersion: "26.0") }
    }
}

@Suite("Developer feed parsing")
struct SparkleTests {
    func feed(_ items: String) -> Data {
        Data("<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>\(items)</channel></rss>".utf8)
    }
    @Test func filtersBetaIncompatibleOSAndArchitecture() throws {
        let xml = feed("""
        <item><enclosure url="https://example.com/v2.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/></item>
        <item><sparkle:channel>beta</sparkle:channel><enclosure url="https://example.com/beta.zip" sparkle:version="400"/></item>
        <item><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion><enclosure url="https://example.com/new.zip" sparkle:version="500"/></item>
        <item><sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements><enclosure url="https://example.com/arm.zip" sparkle:version="600"/></item>
        """)
        let releases = try SparkleProvider.parse(xml, osVersion: "14.0", architecture: "x86_64")
        #expect(releases.count == 1)
        #expect(releases.first?.build == "200")
    }
    @Test func comparesBuildsRatherThanMarketingVersions() throws {
        let xml = feed("""
        <item><enclosure url="https://example.com/a.zip" sparkle:version="9" sparkle:shortVersionString="3.0"/></item>
        <item><enclosure url="https://example.com/b.zip" sparkle:version="10" sparkle:shortVersionString="3.0"/></item>
        """)
        #expect(try SparkleProvider.parse(xml, osVersion: "14.0", architecture: "arm64").first?.build == "10")
    }
    @Test func rejectsMalformedAndInsecureFeeds() {
        #expect(throws: (any Error).self) { try SparkleProvider.parse(Data("not xml".utf8), osVersion: "14.0", architecture: "arm64") }
        #expect(throws: (any Error).self) {
            try SparkleProvider.parse(feed("<item><enclosure url=\"http://example.com/a.zip\" sparkle:version=\"10\"/></item>"), osVersion: "14.0", architecture: "arm64")
        }
    }
}

@Suite("Homebrew safety")
struct HomebrewTests {
    func app(_ version: String, path: String = "/Applications/Example.app") -> InstalledApp {
        InstalledApp(path: path, name: "Example", bundleID: "com.example.app", version: version, build: version)
    }
    let out = Data(#"{"casks":[{"name":"example","installed_versions":["1.0"],"current_version":"2.0"}]}"#.utf8)
    let installed = Data(#"{"casks":[{"token":"example","version":"2.0","artifacts":[{"app":["Example.app"]}]}]}"#.utf8)
    @Test func detectsTargetedUpdate() throws {
        let items = try HomebrewProvider.parse(outdated: out, installed: installed, apps: [app("1.0")], executable: "/opt/homebrew/bin/brew")
        #expect(items.first?.status == .available)
        #expect(items.first?.action == .homebrew(executable: "/opt/homebrew/bin/brew", cask: "example"))
    }
    @Test func neverDowngradesSelfUpdatedBundle() throws {
        let items = try HomebrewProvider.parse(outdated: out, installed: installed, apps: [app("3.0")], executable: "/opt/homebrew/bin/brew")
        #expect(items.first?.status == .unverified)
        #expect(items.first?.action == .openApp("/Applications/Example.app"))
    }
    @Test func ambiguousCopiesDoNotGetAnInstaller() throws {
        let items = try HomebrewProvider.parse(outdated: out, installed: installed,
            apps: [app("1.0"), app("1.0", path: "/Users/test/Applications/Example.app")], executable: "/opt/homebrew/bin/brew")
        #expect(items.isEmpty)
    }
    @Test func unknownVersionIsNeverConfirmedCurrent() throws {
        let latest = Data(#"{"casks":[{"token":"example","version":"latest","artifacts":[{"app":["Example.app"]}]}]}"#.utf8)
        #expect(try HomebrewProvider.parse(outdated: out, installed: latest, apps: [app("1.0")], executable: "/opt/homebrew/bin/brew").first?.status == .unverified)
    }
}

@Suite("Version ordering and subprocesses")
struct UtilityTests {
    @Test func numericVersions() {
        #expect(Versions.newer("2.10", than: "2.9"))
        #expect(Versions.compare("1.0.0", "1.0") == .orderedSame)
        #expect(!Versions.newer("1.0", than: "2.0"))
        #expect(Versions.compare("v2.0", "2") == .orderedSame)
    }
    @Test func commandOutputAndExitCode() async throws {
        let result = try await CommandRunner.run("/usr/bin/printf", ["hello"], timeout: 3)
        #expect(result.status == 0); #expect(result.text == "hello")
    }
    @Test func enforcesTimeout() async {
        do {
            _ = try await CommandRunner.run("/bin/sleep", ["5"], timeout: 0.05)
            Issue.record("Expected a timeout")
        } catch { #expect(error is CheckError) }
    }
}
