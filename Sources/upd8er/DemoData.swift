import Foundation
import UpdaterCore

enum DemoData {
    static let items: [UpdateItem] = {
        var items: [UpdateItem] = [
            UpdateItem(id: "demo:macos", name: "macOS", installedVersion: "26.0", availableVersion: "26.0.1", source: .system, status: .available, action: .systemSettings,
                       detail: "This update includes important bug fixes and security updates for your Mac.", checkedAt: Date()),
            UpdateItem(id: "demo:pages", name: "Pages", path: "/Applications/Pages.app", installedVersion: "14.4", availableVersion: "14.5", source: .appStore, status: .available, action: .appStore(nil),
                       detail: "A newer version is available from the App Store.", checkedAt: Date()),
            UpdateItem(id: "demo:signal", name: "Signal", path: "/Applications/Signal.app", installedVersion: "7.67", availableVersion: "7.68", source: .sparkle, status: .available, action: .openApp("/Applications/Signal.app"),
                       detail: "A newer version is available from the developer. Open Signal to finish updating.", checkedAt: Date()),
            UpdateItem(id: "demo:vlc", name: "VLC", path: "/Applications/VLC.app", installedVersion: "3.0.20", availableVersion: "3.0.21", source: .homebrew, status: .available, action: .homebrew(executable: "preview", cask: "vlc"),
                       detail: "Ready to install with Homebrew.", checkedAt: Date()),
            UpdateItem(id: "demo:notes", name: "Notes", path: "/System/Applications/Notes.app", installedVersion: "4.12", source: .system, status: .current, detail: "Included with macOS.", checkedAt: Date()),
            UpdateItem(id: "demo:calendar", name: "Calendar", path: "/System/Applications/Calendar.app", installedVersion: "15.0", source: .system, status: .current, detail: "Included with macOS.", checkedAt: Date()),
            UpdateItem(id: "demo:blender", name: "Blender", path: "/Applications/Blender.app", installedVersion: "4.5", source: .unknown, status: .unsupported, action: .openApp("/Applications/Blender.app"),
                       detail: "This app doesn't expose a supported update source. You might be able to check for updates by opening the app.")
        ]
        let source = ReleaseNotesSource(.sparkle, url: URL(string: "https://example.com/signal/appcast.xml")!)
        items[2].releaseNotes = ReleaseNotesContext(sources: [source])
        items[2].updateAgeEvidence = UpdateAgeEvidence(date: Date().addingTimeInterval(-12 * 86400), version: "7.67.1", source: source, item: items[2])
        items[2].vulnerabilities = VulnerabilityAssessment(requestID: VulnerabilityRequest(item: items[2]).id,
            findings: [VulnerabilityFinding(id: "Sample advisory", summary: "Preview only: a sample security issue affecting the installed version. These aren't actual findings for Signal.", source: "NVD", url: URL(string: "https://nvd.nist.gov/")!, severity: "High", score: 8.1, affectedRange: "Before 7.68", fixedVersions: ["7.68"], targetMatch: .notAffected, knownExploited: true)],
            complete: true, message: "Preview only. These are sample advisories, not a security assessment of your Mac.", identity: "Sample product")
        items[1].vulnerabilities = VulnerabilityAssessment(requestID: VulnerabilityRequest(item: items[1]).id, complete: false, message: "A reliable product identity couldn't be established automatically.")
        return items
    }()
    static var history: [UpdateHistoryEntry] {
        let now = Date()
        return [
            UpdateHistoryEntry(id: "demo-history:signal", software: SoftwareSnapshot(id: "demo:signal", name: "Signal", path: "/Applications/Signal.app", version: "7.67", build: "701"),
                previousVersion: "7.66", previousBuild: "699", change: .updated, detectedAt: now.addingTimeInterval(-3600),
                previouslyObservedAt: now.addingTimeInterval(-7200), firstDetectedAvailableAt: now.addingTimeInterval(-3 * 86400)),
            UpdateHistoryEntry(id: "demo-history:updater", software: SoftwareSnapshot(id: "self:com.annoyingupdater.app", name: "upd8er", version: "1.0", kind: .updater),
                previousVersion: "0.2.1", change: .updated, detectedAt: now.addingTimeInterval(-86400), previouslyObservedAt: now.addingTimeInterval(-90000)),
            UpdateHistoryEntry(id: "demo-history:macos", software: SoftwareSnapshot(id: "system:macos", name: "macOS", version: "26.0", build: "25A354", kind: .macOS),
                previousVersion: "25.6", previousBuild: "24G84", change: .updated, detectedAt: now.addingTimeInterval(-2 * 86400), previouslyObservedAt: now.addingTimeInterval(-3 * 86400)),
            UpdateHistoryEntry(id: "demo-history:pages", software: SoftwareSnapshot(id: "demo:pages", name: "Pages", path: "/Applications/Pages.app", version: "14.4", build: "7040"),
                previousVersion: "14.4", previousBuild: "7038", change: .buildChanged, detectedAt: now.addingTimeInterval(-7 * 86400), previouslyObservedAt: now.addingTimeInterval(-8 * 86400))
        ]
    }
    static let reports = [ProviderReport("macOS", "Software Update"), ProviderReport("App Store", "1 app checked"), ProviderReport("Developer feeds", "1 app checked"), ProviderReport("Homebrew", "1 app checked")]
}
