import Foundation
import ServiceManagement

protocol LaunchAtLoginServicing: Sendable {
    var isEnabled: Bool { get }
    var lastErrorDescription: String? { get }
    func setEnabled(_ enabled: Bool) throws
    func migrateLegacyRegistrationIfNeeded() throws
}

enum LaunchAtLoginRegistrationStatus: Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

protocol LaunchAtLoginServiceAdapting: Sendable {
    var registrationStatus: LaunchAtLoginRegistrationStatus { get }
    func register() throws
    func unregister() throws
}

struct LaunchAtLoginController: LaunchAtLoginServicing, Sendable {
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

    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try adapter.register()
            } else {
                try adapter.unregister()
            }
            migrationStore.setLastErrorDescription(nil)
        } catch {
            migrationStore.setLastErrorDescription(error.localizedDescription)
            throw error
        }
    }

    func migrateLegacyRegistrationIfNeeded() throws {
        do {
            guard !migrationStore.didMigrate else {
                migrationStore.setLastErrorDescription(nil)
                return
            }
            switch legacyAdapter.registrationStatus {
            case .notRegistered, .notFound:
                break
            case .enabled, .requiresApproval:
                do {
                    try legacyAdapter.unregister()
                } catch where isServiceManagementJobNotFound(error) {
                    break
                }
            }
            migrationStore.markMigrated()
            migrationStore.setLastErrorDescription(nil)
        } catch {
            migrationStore.setLastErrorDescription(error.localizedDescription)
            throw error
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

    func setLastErrorDescription(_ description: String?) {
        lock.withLock {
            storedLastErrorDescription = description
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
            self = .notFound
        }
    }
}
