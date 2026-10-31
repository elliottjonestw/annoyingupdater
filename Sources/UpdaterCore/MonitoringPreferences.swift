import Foundation

/// Stored separately from scan results so monitoring choices survive cache refreshes.
public struct MonitoringPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public var remindersEnabled: Bool { defaults.object(forKey: "remindersEnabled") as? Bool ?? true }
    public func setRemindersEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: "remindersEnabled") }
    public var snoozeDuration: SnoozeDuration {
        (defaults.object(forKey: "snoozeDurationMinutes") as? Int).flatMap(SnoozeDuration.init(rawValue:)) ?? .fifteenMinutes
    }
    public func setSnoozeDuration(_ duration: SnoozeDuration) { defaults.set(duration.rawValue, forKey: "snoozeDurationMinutes") }
}

public enum SnoozeDuration: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fiveMinutes = 5, fifteenMinutes = 15, thirtyMinutes = 30, oneHour = 60
    case twoHours = 120, fourHours = 240, eightHours = 480, oneDay = 1440
    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    public var recurrenceLabel: String { self == .oneHour ? "hour" : self == .oneDay ? "day" : label }
    public var label: String {
        if rawValue < 60 { return "\(rawValue) minutes" }
        if rawValue == 1440 { return "1 day" }
        return rawValue == 60 ? "1 hour" : "\(rawValue / 60) hours"
    }
}
