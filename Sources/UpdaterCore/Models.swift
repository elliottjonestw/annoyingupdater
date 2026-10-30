import Foundation

public enum UpdateSource: String, Codable, CaseIterable, Sendable {
    case system = "macOS", appStore = "App Store", sparkle = "Developer", homebrew = "Homebrew", microsoft = "Microsoft", unknown = "Unrecognized"
    case homebrewCatalog = "Homebrew Catalog", appCatalog = "App Catalog", electron = "Electron", github = "GitHub"
    case homebrewFormula = "Homebrew Tools", npm = "npm Tools"
}

public enum UpdateStatus: String, Codable, Sendable {
    case current, available, unverified, unsupported
    public var title: String {
        switch self {
        case .current: return "Up to date"
        case .available: return "Update available"
        case .unverified: return "Couldn't verify"
        case .unsupported: return "Couldn't check"
        }
    }
}

public enum VerificationIssue: String, Codable, Sendable {
    case identity, ambiguousEdition, versionFormat, platform, stagedRollout, unavailable
}

public enum UpdateAction: Codable, Equatable, Sendable {
    case systemSettings
    case appStore(String?)
    case openApp(String)
    case website(String)
    case homebrew(executable: String, cask: String)
    case microsoft(executable: String, appID: String)
    case none
    case copyCommand(String)

    public var isDirect: Bool {
        switch self { case .homebrew, .microsoft: return true; default: return false }
    }
    public var title: String {
        switch self {
        case .systemSettings: return "Open Software Update"
        case .appStore: return "Open App Store"
        case .openApp: return "Open App"
        case .website: return "Visit Developer"
        case .copyCommand: return "Copy Update Command"
        case .homebrew, .microsoft: return "Update"
        case .none: return "Unavailable"
        }
    }
}

public struct UpdateItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundleID: String
    public var path: String?
    public var installedVersion: String
    public var availableVersion: String?
    public var source: UpdateSource
    public var status: UpdateStatus
    public var action: UpdateAction
    public var detail: String
    public var checkedAt: Date?
    public var verificationIssue: VerificationIssue?
    public var softwareKind: SoftwareKind?
    public var kind: SoftwareKind { softwareKind ?? (source == .system ? .macOS : .application) }

    public init(id: String, name: String, bundleID: String = "", path: String? = nil, installedVersion: String,
                availableVersion: String? = nil, source: UpdateSource, status: UpdateStatus, action: UpdateAction = .none,
                detail: String = "", checkedAt: Date? = nil, verificationIssue: VerificationIssue? = nil, softwareKind: SoftwareKind? = nil) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.path = path
        self.installedVersion = installedVersion; self.availableVersion = availableVersion
        self.source = source; self.status = status; self.action = action; self.detail = detail; self.checkedAt = checkedAt
        self.verificationIssue = verificationIssue
        self.softwareKind = softwareKind
    }
}

public struct InstalledApp: Sendable {
    public let path: String
    public let name: String
    public let bundleID: String
    public let version: String
    public let build: String
    public let feedURL: URL?
    public let isAppStore: Bool
    /// The stable visible location, before resolving a Homebrew/versioned symlink.
    public let installationPath: String?
    public init(path: String, name: String, bundleID: String, version: String, build: String, feedURL: URL? = nil, isAppStore: Bool = false, installationPath: String? = nil) {
        self.path = path; self.name = name; self.bundleID = bundleID; self.version = version
        self.build = build; self.feedURL = feedURL; self.isAppStore = isAppStore; self.installationPath = installationPath
    }
    public var item: UpdateItem {
        UpdateItem(id: path, name: name, bundleID: bundleID, path: path, installedVersion: version,
                   source: .unknown, status: .unsupported, action: .openApp(path),
                   detail: "This app doesn't expose a supported update source. You might be able to check for updates by opening the app.")
    }
}

public struct ProviderReport: Identifiable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let message: String
    public let hasError: Bool
    public init(_ name: String, _ message: String, hasError: Bool = false) {
        self.name = name; self.message = message; self.hasError = hasError
    }
}

public struct ScanResult: Codable, Sendable {
    public var items: [UpdateItem]
    public var reports: [ProviderReport]
    public var date: Date
    public var observation: HistoryObservation?
    public init(items: [UpdateItem], reports: [ProviderReport], date: Date = Date(), observation: HistoryObservation? = nil) {
        self.items = items; self.reports = reports; self.date = date; self.observation = observation
    }

    /// Keep historical findings visible on failure, without making them eligible for a fresh reminder.
    public func preservingLastFindings(from previous: [UpdateItem]) -> ScanResult {
        var merged = self
        // A failed manager must not make previously observed tools silently disappear.
        for old in previous where old.kind == .commandLineTool && !items.contains(where: { $0.id == old.id }) {
            guard let path = old.path, observation?.uncertainPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) == true else { continue }
            var item = old; item.status = .unverified
            item.detail = "\(old.source.rawValue) couldn't be checked. Showing the last observed version."
            item.verificationIssue = .unavailable
            merged.items.append(item)
        }
        for index in merged.items.indices {
            guard let old = previous.first(where: { $0.id == merged.items[index].id }), let version = old.availableVersion else { continue }
            let providerName = old.source == .sparkle ? "Developer feeds" : old.source.rawValue
            let failedProvider = merged.items[index].status == .unsupported && old.source != .unknown
                && reports.contains(where: { $0.name == providerName && $0.hasError })
            if merged.items[index].status == .unverified || failedProvider {
                merged.items[index].status = .unverified
                if failedProvider {
                    merged.items[index].source = old.source; merged.items[index].action = old.action
                    merged.items[index].detail = "\(providerName) couldn't be checked."
                    merged.items[index].verificationIssue = .unavailable
                }
                if let target = ReleaseVersions.numeric(version), let local = ReleaseVersions.numeric(merged.items[index].installedVersion),
                   Versions.compare(local, target) != .orderedAscending {
                    merged.items[index].availableVersion = nil
                } else {
                    merged.items[index].availableVersion = version
                    merged.items[index].detail += " Last detected update: \(version)."
                }
                merged.items[index].checkedAt = old.checkedAt
            }
        }
        if reports.contains(where: { $0.name == "macOS" && $0.hasError }) {
            let oldSystemUpdates = previous.filter { $0.source == .system && $0.availableVersion != nil }
            if !oldSystemUpdates.isEmpty {
                let failure = items.first(where: { $0.source == .system })?.detail ?? "Software Update couldn't be reached."
                merged.items.removeAll { $0.source == .system }
                merged.items.insert(contentsOf: oldSystemUpdates.map { old in
                    var item = old; item.status = .unverified
                    item.detail = failure + " Last detected update: \(old.availableVersion ?? "unknown")."
                    return item
                }, at: 0)
            }
        }
        return merged
    }
}

/// A persisted deadline, rather than a repeating timer, survives sleep and relaunch.
public struct ReminderPolicy: Codable, Sendable {
    public private(set) var snoozedUntil: Date?
    public static let snoozeInterval: TimeInterval = 15 * 60
    public init(snoozedUntil: Date? = nil) { self.snoozedUntil = snoozedUntil }
    public mutating func snooze(at date: Date) { snoozedUntil = date.addingTimeInterval(Self.snoozeInterval) }
    public func isSnoozed(at date: Date) -> Bool { snoozedUntil.map { $0 > date } ?? false }
    public func shouldPresent(at date: Date, confirmedUpdates: Int, isInstalling: Bool, windowVisible: Bool) -> Bool {
        confirmedUpdates > 0 && !isInstalling && !windowVisible && !isSnoozed(at: date)
    }
}

public enum Versions {
    /// Numeric component ordering handles 2.10 > 2.9 and treats trailing zeroes as equal.
    /// Callers must keep marketing and build version domains separate.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func normalized(_ value: String) -> String {
            var parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^v(?=[0-9])", with: "", options: .regularExpression).components(separatedBy: ".")
            while parts.count > 1 && parts.last == "0" { parts.removeLast() }
            return parts.joined(separator: ".")
        }
        return normalized(lhs).compare(normalized(rhs), options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func newer(_ candidate: String, than installed: String) -> Bool { compare(candidate, installed) == .orderedDescending }
}
