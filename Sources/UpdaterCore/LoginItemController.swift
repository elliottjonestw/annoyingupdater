import Foundation
import ServiceManagement

@MainActor
public protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
public struct SystemLoginItemService: LoginItemService {
    public init() {}
    public var status: SMAppService.Status { SMAppService.mainApp.status }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Applies the default once. Subsequent launches respect both app and system opt-outs.
@MainActor
public final class LoginItemController {
    private static let configuredKey = "didConfigureDefaultLoginItem"
    private static let preferenceKey = "openAtLoginPreference"
    private let service: any LoginItemService
    private let defaults: UserDefaults

    public init(service: any LoginItemService, defaults: UserDefaults) {
        self.service = service; self.defaults = defaults
    }
    public var status: SMAppService.Status { service.status }
    public var isEnabled: Bool { status == .enabled }
    public var requiresApproval: Bool { status == .requiresApproval }

    @discardableResult
    public func configureDefault() throws -> Bool {
        guard !defaults.bool(forKey: Self.configuredKey) else { return false }
        // Persist before requesting registration: denial/failure must not become a launch loop.
        defaults.set(true, forKey: Self.configuredKey)
        // mainApp can report notFound before its first registration, including a
        // freshly built app. register() establishes the item in that state too.
        guard defaults.object(forKey: Self.preferenceKey) == nil,
              status == .notRegistered || status == .notFound else { return false }
        defaults.set(true, forKey: Self.preferenceKey)
        try service.register()
        return true
    }

    public func setEnabled(_ enabled: Bool) throws {
        defaults.set(true, forKey: Self.configuredKey)
        defaults.set(enabled, forKey: Self.preferenceKey)
        if enabled {
            if status == .enabled || status == .requiresApproval { return }
            try service.register()
        } else if status == .enabled || status == .requiresApproval {
            try service.unregister()
        }
    }
}
