import Combine
import Foundation
import Sparkle

/// Sparkle owns download verification, app replacement, and relaunching.
/// Preview never creates an updater for the real app bundle.
@MainActor
final class SelfUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyInstalls = true
    private let isDemo: Bool
    private var controller: SPUStandardUpdaterController?

    init(isDemo: Bool) { self.isDemo = isDemo; super.init() }

    func start() {
        guard !isDemo, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            .assign(to: &$automaticallyInstalls)
        // startUpdater reports configuration failures through Sparkle's native UI.
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyInstalls(_ enabled: Bool) {
        guard let updater = controller?.updater else { automaticallyInstalls = enabled; return }
        updater.automaticallyDownloadsUpdates = enabled
    }
}

enum AppVersion {
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4"
        #if DEBUG
        return "\(version) · Development build"
        #else
        return version
        #endif
    }
}
