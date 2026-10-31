import Foundation

/// Stored separately from scan results so monitoring choices survive cache refreshes.
public struct MonitoringPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public var remindersEnabled: Bool { defaults.object(forKey: "remindersEnabled") as? Bool ?? true }
    public func setRemindersEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: "remindersEnabled") }
}
