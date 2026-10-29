import Foundation
import Testing
@testable import UpdaterCore

@Suite("Failed rechecks preserve history")
struct HistoryTests {
    func old(_ source: UpdateSource = .sparkle, id: String = "app") -> UpdateItem {
        UpdateItem(id: id, name: "Example", installedVersion: "1", availableVersion: "2", source: source,
                   status: .available, checkedAt: Date(timeIntervalSince1970: 100))
    }
    @Test func failedRecheckCannotEraseKnownVersionOrTriggerReminder() {
        let failed = UpdateItem(id: "app", name: "Example", installedVersion: "1", source: .sparkle, status: .unverified, detail: "Offline.")
        let result = ScanResult(items: [failed], reports: []).preservingLastFindings(from: [old()])
        #expect(result.items[0].availableVersion == "2")
        #expect(result.items[0].status == .unverified)
        #expect(result.items[0].checkedAt == Date(timeIntervalSince1970: 100))
        #expect(!ReminderPolicy().shouldPresent(at: Date(), confirmedUpdates: result.items.filter { $0.status == .available }.count, isInstalling: false, windowVisible: false))
    }
    @Test func systemFailureRetainsEachPreviouslyDetectedUpdate() {
        let failed = UpdateItem(id: "system:unknown", name: "macOS", installedVersion: "1", source: .system, status: .unverified, detail: "Timed out.")
        let result = ScanResult(items: [failed], reports: [ProviderReport("macOS", "Timed out", hasError: true)])
            .preservingLastFindings(from: [old(.system, id: "system:release")])
        #expect(result.items.count == 1)
        #expect(result.items[0].id == "system:release")
        #expect(result.items[0].status == .unverified)
        #expect(result.items[0].availableVersion == "2")
    }
    @Test func successfulCheckClearsOldUpdateAndRemovedAppsStayRemoved() {
        let current = UpdateItem(id: "app", name: "Example", installedVersion: "2", source: .sparkle, status: .current)
        let result = ScanResult(items: [current], reports: []).preservingLastFindings(from: [old(), old(id: "deleted")])
        #expect(result.items.count == 1)
        #expect(result.items[0].status == .current)
        #expect(result.items[0].availableVersion == nil)
    }
}
