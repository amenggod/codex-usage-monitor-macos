import Foundation
import ServiceManagement

protocol LaunchAtLoginServicing: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

protocol LaunchAtLoginServiceAdapting: Sendable {
    var isEnabled: Bool { get }
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
        adapter.isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try adapter.register()
        } else {
            try adapter.unregister()
        }
    }

    func migrateLegacyRegistrationIfNeeded() throws {
        guard !migrationStore.didMigrate else { return }
        try legacyAdapter.unregister()
        migrationStore.markMigrated()
    }
}

private final class LaunchAtLoginMigrationStore: @unchecked Sendable {
    private static let key = "didMigrateLoginItemV2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var didMigrate: Bool {
        defaults.bool(forKey: Self.key)
    }

    func markMigrated() {
        defaults.set(true, forKey: Self.key)
    }
}

private struct LoginItemLaunchAtLoginAdapter: LaunchAtLoginServiceAdapting {
    private var service: SMAppService {
        SMAppService.loginItem(
            identifier: "com.amenggod.CodexUsageMonitor.LoginItem"
        )
    }

    var isEnabled: Bool {
        service.status == .enabled
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

private struct MainAppLaunchAtLoginAdapter: LaunchAtLoginServiceAdapting {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
