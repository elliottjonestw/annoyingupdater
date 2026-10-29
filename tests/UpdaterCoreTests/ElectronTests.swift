import Foundation
import Testing
@testable import UpdaterCore

@Suite("Electron metadata discovery")
struct ElectronTests {
    let app = InstalledApp(path: "/Applications/Example.app", name: "Example", bundleID: "com.example.app", version: "1.0.0", build: "1")
    let feed = URL(string: "https://updates.example.com/latest-mac.yml")!
    func manifest(_ extra: String = "", version: String = "1.1.0", file: String = "Example-universal.zip") -> Data {
        Data("version: \(version)\nfiles:\n  - url: \(file)\n\(extra)".utf8)
    }
    @Test func configurationDiscoversGenericFeedWithoutAppSpecificMapping() throws {
        let config = try ElectronProvider.parseConfiguration(Data("provider: generic\nurl: https://updates.example.com/desktop\n".utf8))
        #expect(try ElectronProvider.manifestURL(config).absoluteString == "https://updates.example.com/desktop/latest-mac.yml")
        #expect(try ElectronProvider.evaluate(manifest(), app: app, feed: feed).status == .available)
    }
    @Test func updatesMadeOutsideAppClearReminder() throws {
        #expect(try ElectronProvider.evaluate(manifest(version: "1.0.0"), app: app, feed: feed).status == .current)
    }
    @Test func githubAndPublicStorageProviders() throws {
        for (yaml, expected) in [
            ("provider: github\nowner: example\nrepo: app\n", "https://github.com/example/app/releases/latest/download/latest-mac.yml"),
            ("provider: s3\nbucket: example\nregion: eu-west-1\npath: releases\n", "https://example.s3.eu-west-1.amazonaws.com/releases/latest-mac.yml"),
            ("provider: spaces\nname: example\nregion: nyc3\n", "https://example.nyc3.digitaloceanspaces.com/latest-mac.yml")
        ] {
            #expect(try ElectronProvider.manifestURL(ElectronProvider.parseConfiguration(Data(yaml.utf8))).absoluteString == expected)
        }
    }
    @Test func rejectsPrivateCredentialsUnsafeFeedsAndCustomCode() {
        for yaml in ["provider: github\nprivate: true\n", "provider: generic\nurl: https://localhost/\n", "provider: custom\n", "provider: generic\ntoken: secret\n"] {
            #expect(throws: (any Error).self) { try ElectronProvider.manifestURL(ElectronProvider.parseConfiguration(Data(yaml.utf8))) }
        }
    }
    @Test func stagedRolloutCannotTriggerAnUnverifiedReminder() throws {
        #expect(try ElectronProvider.evaluate(manifest("stagingPercentage: 10\n"), app: app, feed: feed).status == .unverified)
    }
    @Test func kernelRequirementUsesDarwinVersion() throws {
        #expect(try ElectronProvider.evaluate(manifest("minimumSystemVersion: 25.0.0\n"), app: app, feed: feed, kernelVersion: "24.2.0").status == .unverified)
        #expect(try ElectronProvider.evaluate(manifest("minimumSystemVersion: 24.0.0\n"), app: app, feed: feed, kernelVersion: "24.2.0").status == .available)
    }
    @Test func rejectsWrongPlatformAndArchitecture() throws {
        #expect(try ElectronProvider.evaluate(manifest(file: "Example.exe"), app: app, feed: feed).status == .unverified)
        #expect(try ElectronProvider.evaluate(manifest(file: "Example-arm64.zip"), app: app, feed: feed, platform: .init(os: "14.0", architecture: "x86_64")).status == .unverified)
    }
    @Test func malformedManifestAndPrereleaseNeverConfirmUpdate() throws {
        #expect(throws: (any Error).self) { try ElectronProvider.evaluate(Data("version: [".utf8), app: app, feed: feed) }
        #expect(try ElectronProvider.evaluate(manifest(version: "2.0.0-beta.1"), app: app, feed: feed).status == .unverified)
    }
}
