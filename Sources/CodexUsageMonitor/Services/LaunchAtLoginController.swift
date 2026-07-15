import Foundation
import ServiceManagement

protocol LaunchAtLoginServicing: AnyObject, Sendable {
    var isEnabled: Bool { get }
    var lastErrorDescription: String? { get }
    var hasMigrationError: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    func migrateLegacyRegistrationIfNeeded() throws
}

enum LaunchAtLoginRegistrationStatus: Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

enum LaunchAtLoginMigrationError: LocalizedError, Sendable {
    case unknownRegistrationStatus
    case helperDidNotBecomeEnabled
    case rollbackFailed(migration: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .unknownRegistrationStatus:
            "登录项返回未知状态，已保留原设置并将在下次重试"
        case .helperDidNotBecomeEnabled:
            "新的登录项未能启用，已保留旧登录项"
        case let .rollbackFailed(migration, rollback):
            "登录项迁移失败：\(migration)；回滚新登录项失败：\(rollback)"
        }
    }
}

protocol LaunchAtLoginServiceAdapting: Sendable {
    var registrationStatus: LaunchAtLoginRegistrationStatus { get }
    func register() throws
    func unregister() throws
}

final class LaunchAtLoginController: LaunchAtLoginServicing, Sendable {
    private let adapter: any LaunchAtLoginServiceAdapting
    private let legacyAdapter: any LaunchAtLoginServiceAdapting
    private let migrationStore: LaunchAtLoginMigrationStore

    init(
        adapter: any LaunchAtLoginServiceAdapting = LoginItemLaunchAtLoginAdapter(),
        legacyAdapter: any LaunchAtLoginServiceAdapting = MainAppLaunchAtLoginAdapter(),
        defaults: UserDefaults = .standard
    ) {
        self.adapter = adapter
        self.legacyAdapter = legacyAdapter
        migrationStore = LaunchAtLoginMigrationStore(defaults: defaults)
    }

    var isEnabled: Bool {
        adapter.registrationStatus == .enabled
    }

    var lastErrorDescription: String? {
        migrationStore.lastErrorDescription
    }

    var hasMigrationError: Bool {
        migrationStore.hasMigrationError
    }

    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try adapter.register()
            } else {
                try adapter.unregister()
            }
            migrationStore.setLastErrorDescription(nil, isMigrationError: false)
        } catch {
            migrationStore.setLastErrorDescription(
                error.localizedDescription,
                isMigrationError: false
            )
            throw error
        }
    }

    func migrateLegacyRegistrationIfNeeded() throws {
        do {
            guard !migrationStore.didMigrate else {
                migrationStore.setLastErrorDescription(nil, isMigrationError: false)
                return
            }
            switch legacyAdapter.registrationStatus {
            case .notRegistered, .notFound:
                break
            case .enabled:
                try migrateEnabledLegacyRegistration()
            case .requiresApproval:
                try migrateDeclinedLegacyRegistration()
            case .unknown:
                throw LaunchAtLoginMigrationError.unknownRegistrationStatus
            }
            migrationStore.markMigrated()
            migrationStore.setLastErrorDescription(nil, isMigrationError: false)
        } catch {
            migrationStore.setLastErrorDescription(
                error.localizedDescription,
                isMigrationError: true
            )
            throw error
        }
    }

    private func migrateEnabledLegacyRegistration() throws {
        let helperWasNewlyRegistered: Bool
        switch adapter.registrationStatus {
        case .enabled:
            helperWasNewlyRegistered = false
        case .notRegistered, .notFound:
            try adapter.register()
            helperWasNewlyRegistered = true
            guard adapter.registrationStatus == .enabled else {
                let migrationError = LaunchAtLoginMigrationError.helperDidNotBecomeEnabled
                try rollbackNewHelper(after: migrationError)
                throw migrationError
            }
        case .requiresApproval:
            throw LaunchAtLoginMigrationError.helperDidNotBecomeEnabled
        case .unknown:
            throw LaunchAtLoginMigrationError.unknownRegistrationStatus
        }

        do {
            try legacyAdapter.unregister()
        } catch where isServiceManagementJobNotFound(error) {
            return
        } catch {
            if helperWasNewlyRegistered {
                try rollbackNewHelper(after: error)
            }
            throw error
        }
    }

    private func migrateDeclinedLegacyRegistration() throws {
        switch adapter.registrationStatus {
        case .enabled, .requiresApproval:
            do {
                try adapter.unregister()
            } catch where isServiceManagementJobNotFound(error) {}
        case .notRegistered, .notFound:
            break
        case .unknown:
            throw LaunchAtLoginMigrationError.unknownRegistrationStatus
        }

        do {
            try legacyAdapter.unregister()
        } catch where isServiceManagementJobNotFound(error) {}
    }

    private func rollbackNewHelper(after migrationError: any Error) throws {
        do {
            try adapter.unregister()
        } catch where isServiceManagementJobNotFound(error) {
            return
        } catch {
            throw LaunchAtLoginMigrationError.rollbackFailed(
                migration: migrationError.localizedDescription,
                rollback: error.localizedDescription
            )
        }
    }
}

private func isServiceManagementJobNotFound(_ error: any Error) -> Bool {
    let error = error as NSError
    guard error.code == Int(kSMErrorJobNotFound) else { return false }
    if #available(macOS 15.0, *) {
        return error.domain == SMAppServiceErrorDomain
    }
    return true
}

private final class LaunchAtLoginMigrationStore: @unchecked Sendable {
    private static let key = "didMigrateLoginItemV2"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var storedLastErrorDescription: String?
    private var storedHasMigrationError = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var didMigrate: Bool {
        defaults.bool(forKey: Self.key)
    }

    func markMigrated() {
        defaults.set(true, forKey: Self.key)
    }

    var lastErrorDescription: String? {
        lock.withLock { storedLastErrorDescription }
    }

    var hasMigrationError: Bool {
        lock.withLock { storedHasMigrationError }
    }

    func setLastErrorDescription(
        _ description: String?,
        isMigrationError: Bool
    ) {
        lock.withLock {
            storedLastErrorDescription = description
            storedHasMigrationError = description != nil && isMigrationError
        }
    }
}

private struct LoginItemLaunchAtLoginAdapter: LaunchAtLoginServiceAdapting {
    private var service: SMAppService {
        SMAppService.loginItem(
            identifier: "com.amenggod.CodexUsageMonitor.LoginItem"
        )
    }

    var registrationStatus: LaunchAtLoginRegistrationStatus {
        LaunchAtLoginRegistrationStatus(service.status)
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

private struct MainAppLaunchAtLoginAdapter: LaunchAtLoginServiceAdapting {
    var registrationStatus: LaunchAtLoginRegistrationStatus {
        LaunchAtLoginRegistrationStatus(SMAppService.mainApp.status)
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

private extension LaunchAtLoginRegistrationStatus {
    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered:
            self = .notRegistered
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .unknown
        }
    }
}
