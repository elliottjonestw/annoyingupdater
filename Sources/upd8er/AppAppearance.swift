import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"

    var id: Self { self }
    @MainActor
    var nativeAppearance: NSAppearance? {
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch (self, increasedContrast) {
        case (.light, false): return NSAppearance(named: .aqua)
        case (.dark, false): return NSAppearance(named: .darkAqua)
        case (.light, true): return NSAppearance(named: .accessibilityHighContrastAqua)
        case (.dark, true): return NSAppearance(named: .accessibilityHighContrastDarkAqua)
        }
    }
}
