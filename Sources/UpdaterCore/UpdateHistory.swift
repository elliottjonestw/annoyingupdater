import Foundation
import Darwin

public enum SoftwareKind: String, Codable, Sendable {
    case application, macOS, updater
}

/// Fresh installed metadata, independent of catalogs and cached availability.
public struct SoftwareSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var bundleID: String
    public var path: String?
    public var resolvedPath: String?
    public var version: String
    public var build: String
    public var kind: SoftwareKind

    public init(id: String, name: String, bundleID: String = "", path: String? = nil,
                version: String, build: String = "", kind: SoftwareKind = .application, resolvedPath: String? = nil) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.path = path
        self.version = version; self.build = build; self.kind = kind; self.resolvedPath = resolvedPath
    }
    public init(app: InstalledApp) {
        let location = app.installationPath ?? app.path
        self.init(id: location, name: app.name, bundleID: app.bundleID, path: location, version: app.version, build: app.build, resolvedPath: app.path)
    }
    public static func ownApp(at url: URL) -> SoftwareSnapshot? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.annoyingupdater.app",
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return SoftwareSnapshot(id: "self:com.annoyingupdater.app", name: "Annoying Updater", bundleID: "com.annoyingupdater.app",
            path: url.path, version: version, build: info["CFBundleVersion"] as? String ?? "", kind: .updater)
    }
    public static var operatingSystem: SoftwareSnapshot {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        var build = ""
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0, size < 1024 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 { build = String(cString: buffer) }
        }
        return SoftwareSnapshot(id: "system:macos", name: "macOS", version: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                                build: build, kind: .macOS)
    }
}

public struct HistoryObservation: Codable, Sendable {
    public var software: [SoftwareSnapshot]
    public var date: Date
    /// Missing entries below these paths were unreadable, not confirmed removals.
    public var uncertainPaths: [String]
    public init(software: [SoftwareSnapshot], date: Date = Date(), uncertainPaths: [String] = []) {
        self.software = software; self.date = date; self.uncertainPaths = uncertainPaths
    }
}

public enum HistoryChange: String, Codable, Sendable {
    case updated, downgraded, versionChanged, buildChanged
    public var title: String {
        switch self {
        case .updated: return "Updated"
        case .downgraded: return "Downgraded"
        case .versionChanged: return "Version changed"
        case .buildChanged: return "Build changed"
        }
    }
}

public struct UpdateHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let software: SoftwareSnapshot
    public let previousVersion: String
    public let previousBuild: String
    public let change: HistoryChange
    public let detectedAt: Date
    public let previouslyObservedAt: Date
    public let firstDetectedAvailableAt: Date?

    public init(id: String = UUID().uuidString, software: SoftwareSnapshot, previousVersion: String, previousBuild: String = "",
                change: HistoryChange, detectedAt: Date, previouslyObservedAt: Date, firstDetectedAvailableAt: Date? = nil) {
        self.id = id; self.software = software; self.previousVersion = previousVersion; self.previousBuild = previousBuild
        self.change = change; self.detectedAt = detectedAt; self.previouslyObservedAt = previouslyObservedAt
        self.firstDetectedAvailableAt = firstDetectedAvailableAt
    }
}

public struct HistoryOffer: Codable, Hashable, Sendable {
    public let softwareID: String
    public let version: String
    public init(softwareID: String, version: String) { self.softwareID = softwareID; self.version = version }
    public init?(item: UpdateItem, softwareID: String? = nil) {
        guard let version = item.availableVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else { return nil }
        let system = item.source == .system && item.name.lowercased().hasPrefix("macos")
        self.init(softwareID: system ? "system:macos" : (softwareID ?? item.id), version: version)
    }
}

public struct HistoryContents: Sendable {
    public let entries: [UpdateHistoryEntry]
    public let firstDetected: [HistoryOffer: Date]
    public let startedAt: Date?
}

struct HistoryTrackingState: Codable {
    struct Baseline: Codable {
        var software: SoftwareSnapshot
        var observedAt: Date
    }
    var baselines: [String: Baseline] = [:]
    var offers: [HistoryOffer: Date] = [:]
    var startedAt: Date?
    var latestObservationAt: Date?

    private static func known(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.lowercased() != "unknown"
    }
    private static func numeric(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^v?[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        return value.hasPrefix("v") ? String(value.dropFirst()) : value
    }
    private static func change(from old: SoftwareSnapshot, to new: SoftwareSnapshot) -> HistoryChange? {
        guard known(old.version), known(new.version) else { return nil }
        if let before = numeric(old.version), let after = numeric(new.version) {
            switch Versions.compare(before, after) {
            case .orderedAscending: return .updated
            case .orderedDescending: return .downgraded
            default: break
            }
        } else if old.version != new.version { return .versionChanged }
        if known(old.build), known(new.build), old.build != new.build { return .buildChanged }
        return nil
    }
    private func availableDate(for current: SoftwareSnapshot, at date: Date) -> Date? {
        offers.filter { offer, firstSeen in
            guard offer.softwareID == current.id, firstSeen <= date else { return false }
            return [current.version, current.build].contains { value in
                if let a = Self.numeric(value), let b = Self.numeric(offer.version) { return Versions.compare(a, b) == .orderedSame }
                return Self.known(value) && value == offer.version
            }
        }.map(\.value).min()
    }

    mutating func apply(_ observation: HistoryObservation, items: [UpdateItem], checkedAt: Date) -> [UpdateHistoryEntry] {
        // A slow scan from another process must not turn a newer observation into a downgrade.
        if let latestObservationAt, observation.date <= latestObservationAt { return [] }
        startedAt = startedAt ?? observation.date
        let current = Dictionary(observation.software.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previous = baselines
        var next: [String: Baseline] = [:]
        var events: [UpdateHistoryEntry] = []
        let aliases = Dictionary(current.values.map { ($0.resolvedPath ?? $0.id, $0.id) }, uniquingKeysWith: { first, _ in first })
        let available = Set(items.filter { $0.status == .available }.compactMap { HistoryOffer(item: $0, softwareID: aliases[$0.id]) })

        for (id, software) in current {
            if let before = previous[id], before.software.bundleID == software.bundleID, before.software.kind == software.kind {
                if let change = Self.change(from: before.software, to: software) {
                    events.append(UpdateHistoryEntry(software: software, previousVersion: before.software.version,
                        previousBuild: before.software.build, change: change, detectedAt: observation.date,
                        previouslyObservedAt: before.observedAt, firstDetectedAvailableAt: availableDate(for: software, at: observation.date)))
                    offers = offers.filter { offer, _ in
                        guard offer.softwareID == id, !available.contains(offer) else { return true }
                        // A partial update during a provider outage must not erase the
                        // first-seen date of a later release that remains outstanding.
                        if offer.version == software.version || offer.version == software.build { return false }
                        return ReleaseVersions.status(candidate: offer.version, installed: software.version, build: software.build) != .current
                    }
                }
            } else if !software.bundleID.isEmpty {
                if previous[id] != nil { offers = offers.filter { $0.key.softwareID != id } }
                // Only migrate an unambiguous move of an unchanged installation. A new
                // path plus a different version cannot establish an update to the old copy.
                let sameIDNow = current.values.filter { $0.bundleID == software.bundleID }
                let sameIDBefore = previous.values.filter { $0.software.bundleID == software.bundleID }
                if sameIDNow.count == 1, sameIDBefore.count == 1, let old = sameIDBefore.first,
                   current[old.software.id] == nil, old.software.version == software.version, old.software.build == software.build {
                    let moved = offers.filter { $0.key.softwareID == old.software.id }
                    for (offer, firstSeen) in moved {
                        offers[HistoryOffer(softwareID: id, version: offer.version)] = firstSeen
                    }
                }
            }
            next[id] = Baseline(software: software, observedAt: observation.date)
        }
        for (id, baseline) in previous where current[id] == nil {
            if let path = baseline.software.path, observation.uncertainPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                next[id] = baseline
            }
        }
        // Forget confirmed removals, preserving past events but not a baseline that
        // could mistake a later reinstall for an update.
        offers = offers.filter { next[$0.key.softwareID] != nil || $0.key.softwareID.hasPrefix("system:") }
        baselines = next
        for offer in available { offers[offer] = offers[offer] ?? checkedAt }
        latestObservationAt = observation.date
        return events
    }
}

/// Calendar days keep grouping correct across local midnight and daylight saving.
public struct UpdateHistoryDay: Identifiable, Sendable {
    public let id: Date
    public let entries: [UpdateHistoryEntry]
    public static func grouped(_ entries: [UpdateHistoryEntry], calendar: Calendar = .current) -> [UpdateHistoryDay] {
        let groups = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.detectedAt) }
        return groups.keys.sorted(by: >).map { UpdateHistoryDay(id: $0, entries: groups[$0]!.sorted {
            if $0.detectedAt != $1.detectedAt { return $0.detectedAt > $1.detectedAt }
            return $0.software.name.localizedStandardCompare($1.software.name) == .orderedAscending
        }) }
    }
}
