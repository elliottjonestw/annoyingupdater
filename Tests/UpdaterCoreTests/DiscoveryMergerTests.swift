import Foundation
import Testing
@testable import UpdaterCore

@Suite("Combining discovered update sources")
struct DiscoveryMergerTests {
    let app = InstalledApp(path: "/Applications/Example.app", name: "Example", bundleID: "com.example.app", version: "1.0.0", build: "1")
    func item(_ source: UpdateSource, _ status: UpdateStatus, issue: VerificationIssue? = nil) -> UpdateItem {
        UpdateItem(id: app.path, name: app.name, installedVersion: app.version, availableVersion: status == .available ? "2.0.0" : nil,
                   source: source, status: status, action: .openApp(app.path), verificationIssue: issue)
    }
    @Test func publisherCurrentOverridesNewerCatalogRelease() {
        let result = DiscoveryMerger.merge(apps: [app], homebrewCatalog: [item(.homebrewCatalog, .available)], publisher: [item(.sparkle, .current)])
        #expect(result.count == 1); #expect(result[0].status == .current); #expect(result[0].source == .sparkle)
    }
    @Test func stagedRolloutDoesNotGetBypassedByCatalog() {
        let result = DiscoveryMerger.merge(apps: [app], appCatalog: [item(.appCatalog, .available)],
            publisher: [item(.electron, .unverified, issue: .stagedRollout)])
        #expect(result[0].status == .unverified)
        #expect(!ReminderPolicy().shouldPresent(at: Date(), confirmedUpdates: result.filter { $0.status == .available }.count, isInstalling: false, windowVisible: false))
    }
    @Test func failedGitHubRequestDoesNotEraseValidCatalogFinding() {
        let result = DiscoveryMerger.merge(apps: [app], appCatalog: [item(.appCatalog, .available)], repositories: [item(.github, .unverified)])
        #expect(result[0].status == .available); #expect(result[0].source == .appCatalog)
    }
    @Test func olderRepositoryOrCatalogCannotEraseVerifiedNewerRelease() {
        let result = DiscoveryMerger.merge(apps: [app], homebrewCatalog: [item(.homebrewCatalog, .current)],
            appCatalog: [item(.appCatalog, .available)], repositories: [item(.github, .current)])
        #expect(result[0].status == .available); #expect(result[0].source == .appCatalog)
    }
    @Test func exactBundleIDResolvesWeakFilenameCandidate() {
        let result = DiscoveryMerger.merge(apps: [app], homebrewCatalog: [item(.homebrewCatalog, .unverified, issue: .identity)], appCatalog: [item(.appCatalog, .available)])
        #expect(result[0].status == .available); #expect(result[0].source == .appCatalog)
    }
    @Test func unresolvedEditionCannotBeBypassedByLessSpecificCatalog() {
        let result = DiscoveryMerger.merge(apps: [app], homebrewCatalog: [item(.homebrewCatalog, .unverified, issue: .ambiguousEdition)], appCatalog: [item(.appCatalog, .available)])
        #expect(result[0].status == .unverified)
    }
    @Test func appStoreWinsAndUnknownIDsCannotInjectApps() {
        var foreign = item(.appCatalog, .available); foreign.id = "not-installed"
        let result = DiscoveryMerger.merge(apps: [app], appCatalog: [foreign, item(.appCatalog, .available)], store: [item(.appStore, .current)])
        #expect(result.count == 1); #expect(result[0].source == .appStore); #expect(result[0].status == .current)
    }
    @Test func compatibleHomebrewInstallationActionIsPreserved() {
        var managed = item(.homebrew, .available); managed.action = .homebrew(executable: "/opt/homebrew/bin/brew", cask: "example")
        let result = DiscoveryMerger.merge(apps: [app], managed: [managed], publisher: [item(.sparkle, .available)])
        #expect(result[0].action.isDirect); #expect(result[0].source == .sparkle)
    }
    @Test func legacySavedScanDecodesWithoutNewVerificationField() throws {
        let old = Data(#"{"id":"app","name":"Example","bundleID":"com.example.app","installedVersion":"1.0.0","source":"Homebrew","status":"current","action":{"none":{}},"detail":"Checked"}"#.utf8)
        #expect(try JSONDecoder().decode(UpdateItem.self, from: old).verificationIssue == nil)
    }
    @Test func versionUpdatedOutsideAppDoesNotKeepOldTargetAfterNetworkFailure() {
        let old = item(.homebrewCatalog, .available)
        var unknown = item(.homebrewCatalog, .unverified); unknown.installedVersion = "2.0.0"
        let result = ScanResult(items: [unknown], reports: []).preservingLastFindings(from: [old])
        #expect(result.items[0].availableVersion == nil); #expect(result.items[0].status == .unverified)
    }
    @Test func actualArtifactResolvesSharedIdentifierEditions() {
        let regular = CatalogCandidate(id: "example", version: "2.0.0", names: ["example.app"], identifiers: ["com.example.app"])
        let other = CatalogCandidate(id: "other", version: "99.0.0", names: ["other.app"], identifiers: ["com.example.app"])
        #expect(CatalogMatching.match(app, candidates: [regular, other], source: .homebrewCatalog, checkedAt: Date())?.availableVersion == "2.0.0")
        #expect(ReleaseVersions.status(candidate: "2.11.194", installed: "2.11", build: "194") == .current)
    }
}
