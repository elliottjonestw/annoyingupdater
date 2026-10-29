import Foundation
import ServiceManagement
import Testing
@testable import UpdaterCore

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var removals = 0
    var failRegistration = false
    var requireApproval = false
    func register() throws {
        registrations += 1
        if failRegistration { throw CheckError.failed("Registration denied") }
        status = requireApproval ? .requiresApproval : .enabled
    }
    func unregister() throws { removals += 1; status = .notRegistered }
}

@Suite("Open at login defaults")
@MainActor
struct LoginItemTests {
    @Test func firstLaunchRegistersOnceAcrossRelaunches() throws {
        let key = "com.annoyingupdater.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service, defaults: defaults)
        #expect(try controller.configureDefault())
        #expect(controller.isEnabled)
        #expect(try !LoginItemController(service: service, defaults: defaults).configureDefault())
        #expect(service.registrations == 1)
    }
    @Test func explicitOptOutPersists() throws {
        let key = "com.annoyingupdater.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service, defaults: defaults)
        try controller.configureDefault()
        try controller.setEnabled(false)
        #expect(try !LoginItemController(service: service, defaults: defaults).configureDefault())
        #expect(service.registrations == 1); #expect(service.removals == 1); #expect(!controller.isEnabled)
    }
    @Test func systemOptOutIsNotReversed() throws {
        let key = "com.annoyingupdater.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service, defaults: defaults)
        try controller.configureDefault()
        service.status = .requiresApproval
        #expect(try !controller.configureDefault())
        #expect(service.registrations == 1); #expect(controller.requiresApproval); #expect(!controller.isEnabled)
    }
    @Test func alreadyRegisteredOrDeniedItemsAreNotRegisteredAgain() throws {
        for status in [SMAppService.Status.enabled, .requiresApproval] {
            let key = "com.annoyingupdater.test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: key)!
            defer { defaults.removePersistentDomain(forName: key) }
            let service = FakeLoginItemService(); service.status = status
            #expect(try !LoginItemController(service: service, defaults: defaults).configureDefault())
            #expect(service.registrations == 0)
        }
    }
    @Test func firstRegistrationAlsoHandlesNotFoundStatus() throws {
        let key = "com.annoyingupdater.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        let service = FakeLoginItemService(); service.status = .notFound
        let controller = LoginItemController(service: service, defaults: defaults)
        #expect(try controller.configureDefault())
        #expect(controller.isEnabled); #expect(service.registrations == 1)
        #expect(try !controller.configureDefault())
    }
    @Test func failedRegistrationDoesNotRepeatButUserCanRetry() throws {
        let key = "com.annoyingupdater.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        let service = FakeLoginItemService(); service.failRegistration = true
        let controller = LoginItemController(service: service, defaults: defaults)
        #expect(throws: (any Error).self) { try controller.configureDefault() }
        #expect(try !controller.configureDefault()); #expect(service.registrations == 1)
        service.failRegistration = false
        try controller.setEnabled(true)
        #expect(controller.isEnabled); #expect(service.registrations == 2)
    }
    @Test func pendingApprovalIsNotReportedAsEnabled() throws {
        let key = "com.annoyingupdater.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        let service = FakeLoginItemService(); service.requireApproval = true
        let controller = LoginItemController(service: service, defaults: defaults)
        try controller.configureDefault()
        #expect(controller.requiresApproval); #expect(!controller.isEnabled)
        try controller.setEnabled(true)
        #expect(service.registrations == 1)
        try controller.setEnabled(false)
        #expect(!controller.requiresApproval)
    }
}
