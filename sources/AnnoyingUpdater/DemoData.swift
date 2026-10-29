import Foundation
import UpdaterCore

enum DemoData {
    static let items: [UpdateItem] = [
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
    static let reports = [ProviderReport("macOS", "Software Update"), ProviderReport("App Store", "1 app checked"), ProviderReport("Developer feeds", "1 app checked"), ProviderReport("Homebrew", "1 app checked")]
}
