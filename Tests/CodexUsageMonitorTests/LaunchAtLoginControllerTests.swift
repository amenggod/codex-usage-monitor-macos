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

        #expect(legacy.operations == [.unregister])
        #expect(helper.operations == [.register])
        #expect(helper.registrationStatus == .enabled)
    }

    @Test func applyingEnabledPreferenceAfterEnabledMigrationRegistersHelperOnlyOnce() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let legacy = LaunchAtLoginAdapterSpy(status: .enabled)
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        let enabled = try controller.applyUserPreference(enabled: true)

        #expect(enabled)
        #expect(helper.operations == [.register])
        #expect(legacy.operations == [.unregister])
        #expect(controller.lastErrorDescription == nil)
    }

    @Test func applyingDisabledPreferenceAfterDeclinedMigrationDoesNotUnregisterTwice() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(status: .requiresApproval)
        let legacy = LaunchAtLoginAdapterSpy(status: .requiresApproval)
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        let enabled = try controller.applyUserPreference(enabled: false)

        #expect(!enabled)
        #expect(helper.operations == [.unregister])
        #expect(legacy.operations == [.unregister])
    }

    @Test(arguments: [true, false])
    func applyingAlreadySatisfiedPreferenceIsIdempotent(enabled: Bool) throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(status: enabled ? .enabled : .notRegistered)
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            defaults: suite.defaults
        )

        let actual = try controller.applyUserPreference(enabled: enabled)

        #expect(actual == enabled)
        #expect(helper.operations.isEmpty)
    }

    @Test func applyingPreferenceStopsAtMigrationFailureAndCanRetry() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let failedHelper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let failedLegacy = LaunchAtLoginAdapterSpy(
            status: .enabled,
            unregisterError: LaunchAtLoginTestFailure(message: "无法迁移旧登录项")
        )
        let failedController = LaunchAtLoginController(
            adapter: failedHelper,
            legacyAdapter: failedLegacy,
            defaults: suite.defaults
        )

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try failedController.applyUserPreference(enabled: true)
        }
        #expect(failedHelper.operations == [.register, .unregister])
        #expect(failedController.hasMigrationError)
        #expect(failedController.lastErrorDescription == "无法迁移旧登录项")

        let retryHelper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let retryLegacy = LaunchAtLoginAdapterSpy(status: .enabled)
        let retryController = LaunchAtLoginController(
            adapter: retryHelper,
            legacyAdapter: retryLegacy,
            defaults: suite.defaults
        )

        let enabled = try retryController.applyUserPreference(enabled: true)

        #expect(enabled)
        #expect(retryHelper.operations == [.register])
        #expect(retryLegacy.operations == [.unregister])
        #expect(!retryController.hasMigrationError)
        #expect(retryController.lastErrorDescription == nil)
    }

    @Test func applyingPreferenceReturnsFinalHelperStateWhenSystemDoesNotReachTarget() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(
            status: .notRegistered,
            registrationResultStatus: .requiresApproval
        )
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            defaults: suite.defaults
        )

        let enabled = try controller.applyUserPreference(enabled: true)

        #expect(!enabled)
        #expect(helper.operations == [.register])
        #expect(helper.registrationStatus == .requiresApproval)
    }

    @Test func applyingPreferenceFailsVisiblyForUnknownHelperStatus() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let controller = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .unknown),
            legacyAdapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            defaults: suite.defaults
        )

        #expect(throws: LaunchAtLoginPreferenceError.self) {
            try controller.applyUserPreference(enabled: false)
        }

        #expect(controller.lastErrorDescription == "登录项返回未知状态，无法确认设置是否生效")
        #expect(!controller.hasMigrationError)
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
        let helper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        try controller.migrateLegacyRegistrationIfNeeded()

        #expect(helper.operations.isEmpty)
        #expect(helper.registrationStatus == .notRegistered)
        #expect(legacy.operations == [.unregister])
    }

    @Test func helperRegisterFailurePreservesEnabledLegacyRegistration() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(
            status: .notRegistered,
            registerError: LaunchAtLoginTestFailure(message: "无法注册 helper")
        )
        let legacy = LaunchAtLoginAdapterSpy(status: .enabled)
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try controller.migrateLegacyRegistrationIfNeeded()
        }

        #expect(helper.operations == [.register])
        #expect(legacy.operations.isEmpty)
        #expect(legacy.registrationStatus == .enabled)

        let retryHelper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let retryLegacy = LaunchAtLoginAdapterSpy(status: .enabled)
        try LaunchAtLoginController(
            adapter: retryHelper,
            legacyAdapter: retryLegacy,
            defaults: suite.defaults
        ).migrateLegacyRegistrationIfNeeded()
        #expect(retryHelper.operations == [.register])
        #expect(retryLegacy.operations == [.unregister])
    }

    @Test func helperMustBecomeEnabledBeforeLegacyRegistrationIsRemoved() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(
            status: .notRegistered,
            registrationResultStatus: .requiresApproval
        )
        let legacy = LaunchAtLoginAdapterSpy(status: .enabled)
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        #expect(throws: LaunchAtLoginMigrationError.self) {
            try controller.migrateLegacyRegistrationIfNeeded()
        }

        #expect(helper.operations == [.register, .unregister])
        #expect(legacy.operations.isEmpty)
        #expect(legacy.registrationStatus == .enabled)
    }

    @Test func legacyUnregisterFailureRollsBackNewlyRegisteredHelper() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let legacy = LaunchAtLoginAdapterSpy(
            status: .enabled,
            unregisterError: LaunchAtLoginTestFailure(message: "无法注销旧登录项")
        )
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try controller.migrateLegacyRegistrationIfNeeded()
        }

        #expect(helper.operations == [.register, .unregister])
        #expect(helper.registrationStatus == .notRegistered)
        #expect(legacy.registrationStatus == .enabled)
    }

    @Test func rollbackFailureSurfacesBothErrorsAndDoesNotCompleteMigration() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(
            status: .notRegistered,
            unregisterError: LaunchAtLoginTestFailure(message: "无法回滚新登录项")
        )
        let legacy = LaunchAtLoginAdapterSpy(
            status: .enabled,
            unregisterError: LaunchAtLoginTestFailure(message: "无法注销旧登录项")
        )
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        #expect(throws: LaunchAtLoginMigrationError.self) {
            try controller.migrateLegacyRegistrationIfNeeded()
        }

        #expect(helper.operations == [.register, .unregister])
        #expect(controller.lastErrorDescription?.contains("无法注销旧登录项") == true)
        #expect(controller.lastErrorDescription?.contains("无法回滚新登录项") == true)

        let retryHelper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let retryLegacy = LaunchAtLoginAdapterSpy(status: .enabled)
        try LaunchAtLoginController(
            adapter: retryHelper,
            legacyAdapter: retryLegacy,
            defaults: suite.defaults
        ).migrateLegacyRegistrationIfNeeded()
        #expect(retryHelper.operations == [.register])
        #expect(retryLegacy.operations == [.unregister])
    }

    @Test func preEnabledHelperIsNotRolledBackWhenLegacyUnregisterFails() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let helper = LaunchAtLoginAdapterSpy(status: .enabled)
        let legacy = LaunchAtLoginAdapterSpy(
            status: .enabled,
            unregisterError: LaunchAtLoginTestFailure(message: "无法注销旧登录项")
        )
        let controller = LaunchAtLoginController(
            adapter: helper,
            legacyAdapter: legacy,
            defaults: suite.defaults
        )

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try controller.migrateLegacyRegistrationIfNeeded()
        }

        #expect(helper.operations.isEmpty)
        #expect(helper.registrationStatus == .enabled)
        #expect(legacy.operations == [.unregister])
    }

    @Test func unknownLegacyStatusFailsWithoutCompletingMigration() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let controller = LaunchAtLoginController(
            adapter: LaunchAtLoginAdapterSpy(status: .notRegistered),
            legacyAdapter: LaunchAtLoginAdapterSpy(status: .unknown),
            defaults: suite.defaults
        )

        #expect(throws: LaunchAtLoginMigrationError.self) {
            try controller.migrateLegacyRegistrationIfNeeded()
        }

        let retryHelper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let retryLegacy = LaunchAtLoginAdapterSpy(status: .enabled)
        try LaunchAtLoginController(
            adapter: retryHelper,
            legacyAdapter: retryLegacy,
            defaults: suite.defaults
        ).migrateLegacyRegistrationIfNeeded()
        #expect(retryHelper.operations == [.register])
        #expect(retryLegacy.operations == [.unregister])
    }

    @Test func successfulLegacyMigrationPersistsAndRunsOnlyOnce() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let firstLegacy = LaunchAtLoginAdapterSpy(status: .enabled)
        let firstHelper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let firstController = LaunchAtLoginController(
            adapter: firstHelper,
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
        #expect(firstHelper.operations == [.register])
        #expect(secondLegacy.operations.isEmpty)
    }

    @Test func failedLegacyMigrationDoesNotPersistCompletion() throws {
        let suite = try isolatedDefaults()
        defer { UserDefaults(suiteName: suite.name)?.removePersistentDomain(forName: suite.name) }
        let failingLegacy = LaunchAtLoginAdapterSpy(
            status: .enabled,
            unregisterError: LaunchAtLoginTestFailure(message: "无法迁移旧登录项")
        )
        let failingHelper = LaunchAtLoginAdapterSpy(status: .notRegistered)
        let failingController = LaunchAtLoginController(
            adapter: failingHelper,
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
        #expect(failingHelper.operations == [.register, .unregister])
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
        #expect(controller.isEnabled)
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
    private let registrationResultStatus: LaunchAtLoginRegistrationStatus
    private let registerError: (any Error)?
    private let unregisterError: (any Error)?
    private var recordedOperations: [Operation] = []

    init(
        status: LaunchAtLoginRegistrationStatus,
        registrationResultStatus: LaunchAtLoginRegistrationStatus = .enabled,
        registerError: (any Error)? = nil,
        unregisterError: (any Error)? = nil
    ) {
        storedStatus = status
        self.registrationResultStatus = registrationResultStatus
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
            storedStatus = registrationResultStatus
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
