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

@Suite("Configurable snooze")
struct ConfigurableSnoozeTests {
    @Test func defaultsAndInvalidPreferencesAreSafeAndSelectionsPersist() throws {
        let suite = "test.snooze.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MonitoringPreferences(defaults: defaults)
        #expect(preferences.snoozeDuration == .fifteenMinutes)
        for invalid in [0, -15, 123456] {
            defaults.set(invalid, forKey: "snoozeDurationMinutes")
            #expect(preferences.snoozeDuration == .fifteenMinutes)
        }
        for duration in SnoozeDuration.allCases {
            preferences.setSnoozeDuration(duration)
            #expect(MonitoringPreferences(defaults: defaults).snoozeDuration == duration)
        }
    }
    @Test func eachDurationUsesElapsedTimeAndSurvivesRelaunch() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        for duration in SnoozeDuration.allCases {
            var policy = ReminderPolicy(); policy.snooze(at: start, duration: duration)
            #expect(policy.snoozedUntil == start.addingTimeInterval(duration.seconds))
            #expect(policy.isSnoozed(at: start.addingTimeInterval(duration.seconds - 1)))
            #expect(!policy.isSnoozed(at: start.addingTimeInterval(duration.seconds)))
            let restored = try JSONDecoder().decode(ReminderPolicy.self, from: JSONEncoder().encode(policy))
            #expect(restored.snoozedUntil == policy.snoozedUntil && restored.snoozedDuration == duration)
        }
    }
    @Test func changingPreferenceDoesNotMoveAnActiveDeadline() throws {
        let suite = "test.active-snooze.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MonitoringPreferences(defaults: defaults), start = Date()
        var policy = ReminderPolicy(); policy.snooze(at: start, duration: settings.snoozeDuration)
        settings.setSnoozeDuration(.oneDay)
        #expect(policy.snoozedUntil == start.addingTimeInterval(900) && policy.snoozedDuration == .fifteenMinutes)
        policy.snooze(at: start, duration: settings.snoozeDuration)
        #expect(policy.snoozedUntil == start.addingTimeInterval(86400))
    }
    @Test func legacyDeadlineOnlyPolicyStillDecodes() throws {
        let policy = try JSONDecoder().decode(ReminderPolicy.self, from: Data("{\"snoozedUntil\":12345}".utf8))
        #expect(policy.snoozedUntil != nil && policy.snoozedDuration == nil)
    }
}

@Suite("Configurable scan schedule")
struct ConfigurableScanScheduleTests {
    @Test func hourlyDefaultAndSavedIntervalsSurviveRelaunch() throws {
        let suite = "test.scan-interval.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MonitoringPreferences(defaults: defaults)
        #expect(settings.scanInterval == .oneHour)
        for invalid in [0, -60, 1, 123456] {
            defaults.set(invalid, forKey: "scanIntervalMinutes")
            #expect(settings.scanInterval == .oneHour)
        }
        for interval in ScanInterval.allCases {
            settings.setScanInterval(interval)
            #expect(MonitoringPreferences(defaults: defaults).scanInterval == interval)
        }
    }
    @Test func firstCheckAndEachDueBoundaryUseElapsedTime() {
        let completed = Date(timeIntervalSince1970: 1_000_000)
        for interval in ScanInterval.allCases {
            #expect(interval.isDue(lastCheck: nil, at: completed))
            #expect(!interval.isDue(lastCheck: completed, at: completed))
            #expect(!interval.isDue(lastCheck: completed, at: completed.addingTimeInterval(interval.seconds - 1)))
            #expect(interval.isDue(lastCheck: completed, at: completed.addingTimeInterval(interval.seconds)))
            #expect(interval.isDue(lastCheck: completed, at: completed.addingTimeInterval(interval.seconds + 3600)))
            // A clock adjustment must not turn a future last-check date into a long delay.
            #expect(interval.isDue(lastCheck: completed, at: completed.addingTimeInterval(-60)))
        }
    }
    @Test func changingScheduleReevaluatesTheLastCompletedCheckIndependentlyOfReminders() throws {
        let suite = "test.scan-reschedule.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MonitoringPreferences(defaults: defaults)
        let completed = Date(timeIntervalSince1970: 1_000_000), now = completed.addingTimeInterval(1800)
        #expect(!settings.scanInterval.isDue(lastCheck: completed, at: now))
        settings.setScanInterval(.fifteenMinutes)
        #expect(settings.scanInterval.isDue(lastCheck: completed, at: now))
        settings.setRemindersEnabled(false); settings.setSnoozeDuration(.oneDay)
        #expect(settings.scanInterval == .fifteenMinutes)
        #expect(settings.scanInterval.isDue(lastCheck: completed, at: now))
        settings.setScanInterval(.oneDay)
        #expect(!settings.scanInterval.isDue(lastCheck: completed, at: now))
        #expect(!settings.remindersEnabled && settings.snoozeDuration == .oneDay)
    }
}
