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

    init(adapter: any LaunchAtLoginServiceAdapting = MainAppLaunchAtLoginAdapter()) {
        self.adapter = adapter
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
