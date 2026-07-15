import Foundation
import ServiceManagement
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
            LoginItemMainApplicationLocator.mainApplicationURL(from: helper)?.path
                == "/Applications/Codex Usage Monitor.app"
        )
    }

    @Test(
        arguments: [
            "/Applications/Codex Usage Monitor.app/Contents/Library/LoginItems/CodexUsageMonitorLoginItem",
            "/Applications/Codex Usage Monitor.app/Contents/Library/Helpers/CodexUsageMonitorLoginItem.app",
            "/Applications/Codex Usage Monitor.app/Contents/Resources/LoginItems/CodexUsageMonitorLoginItem.app",
            "/Applications/Codex Usage Monitor.app/Package/Library/LoginItems/CodexUsageMonitorLoginItem.app",
            "/Applications/Codex Usage Monitor/Contents/Library/LoginItems/CodexUsageMonitorLoginItem.app",
            "/CodexUsageMonitorLoginItem.app",
        ]
    )
    func loginHelperRejectsInvalidContainingApplicationStructures(path: String) {
        let helper = URL(fileURLWithPath: path)

        #expect(LoginItemMainApplicationLocator.mainApplicationURL(from: helper) == nil)
    }

    @Test func loginHelperRejectsNonFileURL() {
        let helper = URL(string: "https://example.com/CodexUsageMonitorLoginItem.app")!

        #expect(LoginItemMainApplicationLocator.mainApplicationURL(from: helper) == nil)
    }

    @Test func controllerUsesHelperServiceAndUnregistersLegacyMainApp() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let legacy = LaunchAtLoginAdapterSpy(status: .enabled)
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

    @Test(arguments: [
        LaunchAtLoginRegistrationStatus.notRegistered,
        LaunchAtLoginRegistrationStatus.notFound,
    ])
    func missingLegacyRegistrationCompletesMigrationWithoutUnregister(
        status: LaunchAtLoginRegistrationStatus
    ) throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let missingLegacy = LaunchAtLoginAdapterSpy(status: status)
        let controller = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            legacyAdapter: missingLegacy,
            defaults: suite.defaults
        )

        try controller.migrateLegacyRegistrationIfNeeded()

        let laterLegacy = LaunchAtLoginAdapterSpy(status: .enabled)
        try LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            legacyAdapter: laterLegacy,
            defaults: suite.defaults
        ).migrateLegacyRegistrationIfNeeded()
        #expect(missingLegacy.operations.isEmpty)
        #expect(laterLegacy.operations.isEmpty)
    }

    @Test func requiresApprovalLegacyRegistrationIsUnregistered() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let legacy = LaunchAtLoginAdapterSpy(status: .requiresApproval)
        let controller = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        try controller.migrateLegacyRegistrationIfNeeded()

        #expect(legacy.operations == [.unregister])
    }

    @Test func successfulLegacyMigrationPersistsAndRunsOnlyOnce() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let firstLegacy = LaunchAtLoginAdapterSpy(status: .enabled)
        let firstController = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            legacyAdapter: firstLegacy,
            defaults: suite.defaults
        )

        try firstController.migrateLegacyRegistrationIfNeeded()

        let secondLegacy = LaunchAtLoginAdapterSpy(status: .enabled)
        let secondController = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
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
        let failingLegacy = LaunchAtLoginAdapterSpy(
            status: .enabled,
            unregisterError: LaunchAtLoginTestFailure(message: "无法迁移旧登录项")
        )
        let failingController = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            legacyAdapter: failingLegacy,
            defaults: suite.defaults
        )

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try failingController.migrateLegacyRegistrationIfNeeded()
        }

        let retryLegacy = LaunchAtLoginAdapterSpy(status: .enabled)
        let retryController = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            legacyAdapter: retryLegacy,
            defaults: suite.defaults
        )
        try retryController.migrateLegacyRegistrationIfNeeded()

        #expect(failingLegacy.operations == [.unregister])
        #expect(retryLegacy.operations == [.unregister])
        #expect(failingController.lastErrorDescription == "无法迁移旧登录项")
    }

    @Test func jobNotFoundDuringLegacyUnregisterCompletesMigration() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let legacy = LaunchAtLoginAdapterSpy(
            status: .enabled,
            unregisterError: NSError(
                domain: "SMAppServiceErrorDomain",
                code: Int(kSMErrorJobNotFound)
            )
        )
        let controller = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        try controller.migrateLegacyRegistrationIfNeeded()

        let laterLegacy = LaunchAtLoginAdapterSpy(status: .enabled)
        try LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            legacyAdapter: laterLegacy,
            defaults: suite.defaults
        ).migrateLegacyRegistrationIfNeeded()
        #expect(legacy.operations == [.unregister])
        #expect(laterLegacy.operations.isEmpty)
    }

    @Test func successfulMigrationRetryClearsVisibleError() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let legacy = LaunchAtLoginAdapterSpy(
            status: .enabled,
            unregisterError: LaunchAtLoginTestFailure(message: "无法迁移旧登录项")
        )
        let controller = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            legacyAdapter: legacy,
            defaults: suite.defaults
        )
        #expect(throws: LaunchAtLoginTestFailure.self) {
            try controller.migrateLegacyRegistrationIfNeeded()
        }
        legacy.registrationStatus = .notRegistered

        try controller.migrateLegacyRegistrationIfNeeded()

        #expect(controller.lastErrorDescription == nil)
    }

    @Test func reflectsAdapterStateAndRoutesEnableAndDisable() throws {
        let adapter = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let controller = LaunchAtLoginController(adapter: adapter)

        #expect(!controller.isEnabled)
        try controller.setEnabled(true)
        #expect(controller.isEnabled)
        try controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(adapter.operations == [.register, .unregister])
    }

    @Test func registerErrorPropagates() {
        let adapter = LaunchAtLoginAdapterSpy(
            status: .notRegistered,
            registerError: LaunchAtLoginTestFailure()
        )
        let controller = LaunchAtLoginController(adapter: adapter)

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try controller.setEnabled(true)
        }
        #expect(!controller.isEnabled)
    }

    @Test func unregisterErrorPropagates() {
        let adapter = LaunchAtLoginAdapterSpy(
            status: .enabled,
            unregisterError: LaunchAtLoginTestFailure()
        )
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
    private var storedStatus: LaunchAtLoginRegistrationStatus
    private let registerError: (any Error)?
    private let unregisterError: (any Error)?
    private var recordedOperations: [Operation] = []

    init(
        status: LaunchAtLoginRegistrationStatus,
        registerError: (any Error)? = nil,
        unregisterError: (any Error)? = nil
    ) {
        storedStatus = status
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    var registrationStatus: LaunchAtLoginRegistrationStatus {
        get { lock.withLock { storedStatus } }
        set { lock.withLock { storedStatus = newValue } }
    }

    var operations: [Operation] {
        lock.withLock { recordedOperations }
    }

    func register() throws {
        try lock.withLock {
            recordedOperations.append(.register)
            if let registerError { throw registerError }
            storedStatus = .enabled
        }
    }

    func unregister() throws {
        try lock.withLock {
            recordedOperations.append(.unregister)
            if let unregisterError { throw unregisterError }
            storedStatus = .notRegistered
        }
    }
}

private struct LaunchAtLoginTestFailure: LocalizedError {
    var message = "登录项测试失败"
    var errorDescription: String? { message }
}
