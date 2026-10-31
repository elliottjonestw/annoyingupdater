import Foundation
import Testing
@testable import UpdaterCore

@Suite("Monitoring preferences")
struct MonitoringPreferencesTests {
    @Test func remindersDefaultOnAndPersistAcrossLaunches() throws {
        let suite = "test.monitoring.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MonitoringPreferences(defaults: defaults)
        #expect(settings.remindersEnabled)
        settings.setRemindersEnabled(false)
        #expect(!MonitoringPreferences(defaults: defaults).remindersEnabled)
        settings.setRemindersEnabled(true)
        #expect(MonitoringPreferences(defaults: defaults).remindersEnabled)
    }
    @Test func disabledRemindersCannotPresentAndPreserveTheirSnoozeDeadline() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        var policy = ReminderPolicy(); policy.snooze(at: date)
        let deadline = policy.snoozedUntil
        let later = date.addingTimeInterval(3600)
        #expect(!policy.shouldPresent(at: later, confirmedUpdates: 3, isInstalling: false, windowVisible: false, remindersEnabled: false))
        #expect(policy.snoozedUntil == deadline)
        #expect(policy.shouldPresent(at: later, confirmedUpdates: 3, isInstalling: false, windowVisible: false, remindersEnabled: true))
        #expect(!policy.shouldPresent(at: later, confirmedUpdates: 0, isInstalling: false, windowVisible: false, remindersEnabled: true))
    }
}
