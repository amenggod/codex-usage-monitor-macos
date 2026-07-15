import Foundation
import Testing
@testable import CodexUsageMonitor
@testable import CodexUsageShared

@Suite("LaunchAtLoginControllerTests")
struct LaunchAtLoginControllerTests {
    @Test func loginHelperFindsContainingMainApplication() {
        let helper = URL(
            fileURLWithPath: "/Applications/Codex Usage Monitor.app/Contents/Library/LoginItems/CodexUsageMonitorLoginItem.app"
        )

        #expect(
            LoginItemMainApplicationLocator.mainApplicationURL(from: helper).path
                == "/Applications/Codex Usage Monitor.app"
        )
    }

    @Test func controllerUsesHelperServiceAndUnregistersLegacyMainApp() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(enabled: false)
        let legacy = LaunchAtLoginAdapterSpy(enabled: true)
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        try controller.migrateLegacyRegistrationIfNeeded()
        try controller.setEnabled(true)

        #expect(legacy.operations == [.unregister])
        #expect(helper.operations == [.register])
    }

    @Test func successfulLegacyMigrationPersistsAndRunsOnlyOnce() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let firstLegacy = LaunchAtLoginAdapterSpy(enabled: true)
        let firstController = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(enabled: false),
            legacyAdapter: firstLegacy,
            defaults: suite.defaults
        )

        try firstController.migrateLegacyRegistrationIfNeeded()

        let secondLegacy = LaunchAtLoginAdapterSpy(enabled: true)
        let secondController = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(enabled: false),
            legacyAdapter: secondLegacy,
            defaults: suite.defaults
        )
        try secondController.migrateLegacyRegistrationIfNeeded()

        #expect(firstLegacy.operations == [.unregister])
        #expect(secondLegacy.operations.isEmpty)
    }

    @Test func failedLegacyMigrationDoesNotPersistCompletion() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let failingLegacy = LaunchAtLoginAdapterSpy(enabled: true, unregisterFails: true)
        let failingController = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(enabled: false),
            legacyAdapter: failingLegacy,
            defaults: suite.defaults
        )

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try failingController.migrateLegacyRegistrationIfNeeded()
        }

        let retryLegacy = LaunchAtLoginAdapterSpy(enabled: true)
        let retryController = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(enabled: false),
            legacyAdapter: retryLegacy,
            defaults: suite.defaults
        )
        try retryController.migrateLegacyRegistrationIfNeeded()

        #expect(failingLegacy.operations == [.unregister])
        #expect(retryLegacy.operations == [.unregister])
    }

    @Test func reflectsAdapterStateAndRoutesEnableAndDisable() throws {
        let adapter = LaunchAtLoginAdapterSpy(enabled: false)
        let controller = LaunchAtLoginController(adapter: adapter)

        #expect(!controller.isEnabled)
        try controller.setEnabled(true)
        #expect(controller.isEnabled)
        try controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(adapter.operations == [.register, .unregister])
    }

    @Test func registerErrorPropagates() {
        let adapter = LaunchAtLoginAdapterSpy(enabled: false, registerFails: true)
        let controller = LaunchAtLoginController(adapter: adapter)

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try controller.setEnabled(true)
        }
        #expect(!controller.isEnabled)
    }

    @Test func unregisterErrorPropagates() {
        let adapter = LaunchAtLoginAdapterSpy(enabled: true, unregisterFails: true)
        let controller = LaunchAtLoginController(adapter: adapter)

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try controller.setEnabled(false)
        }
        #expect(controller.isEnabled)
    }
}

private func isolatedDefaults() throws -> (defaults: UserDefaults, name: String) {
    let name = "LaunchAtLoginControllerTests.\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
}

private final class LaunchAtLoginAdapterSpy: @unchecked Sendable, LaunchAtLoginServiceAdapting {
    enum Operation: Equatable {
        case register
        case unregister
    }

    private let lock = NSLock()
    private var enabled: Bool
    private let registerFails: Bool
    private let unregisterFails: Bool
    private var recordedOperations: [Operation] = []

    init(enabled: Bool, registerFails: Bool = false, unregisterFails: Bool = false) {
        self.enabled = enabled
        self.registerFails = registerFails
        self.unregisterFails = unregisterFails
    }

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    var operations: [Operation] {
        lock.withLock { recordedOperations }
    }

    func register() throws {
        try lock.withLock {
            recordedOperations.append(.register)
            if registerFails { throw LaunchAtLoginTestFailure() }
            enabled = true
        }
    }

    func unregister() throws {
        try lock.withLock {
            recordedOperations.append(.unregister)
            if unregisterFails { throw LaunchAtLoginTestFailure() }
            enabled = false
        }
    }
}

private struct LaunchAtLoginTestFailure: Error {}
