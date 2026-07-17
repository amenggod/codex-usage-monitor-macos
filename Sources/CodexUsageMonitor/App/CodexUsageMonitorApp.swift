import SwiftUI

@main
@MainActor
struct CodexUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: UsageViewModel
    @State private var menuBarVisibilityStore: MenuBarVisibilityStore
    private let dashboard: DashboardWindowController
    private let launchAtLogin: LaunchAtLoginController
    private let launchCoordinator: AppLaunchCoordinator
    private let menuBarController: AppKitMenuBarController

    init() {
        let model = LiveDependencies.makeViewModel()
        let runtime = AppRuntime(starter: model)
        let launchAtLogin = LaunchAtLoginController()
        let dashboard = DashboardWindowController(
            model: model,
            launchAtLogin: launchAtLogin
        )
        let menuBarVisibilityStore = MenuBarVisibilityStore()
        let launchCoordinator = AppLaunchCoordinator(
            arguments: ProcessInfo.processInfo.arguments,
            runtime: runtime,
            dashboard: dashboard,
            launchAtLogin: launchAtLogin
        )
        let menuBarController = AppKitMenuBarController(
            model: model,
            launchAtLogin: launchAtLogin,
            dashboard: dashboard,
            visibilityStore: menuBarVisibilityStore
        )

        _model = State(initialValue: model)
        _menuBarVisibilityStore = State(initialValue: menuBarVisibilityStore)
        self.dashboard = dashboard
        self.launchAtLogin = launchAtLogin
        self.launchCoordinator = launchCoordinator
        self.menuBarController = menuBarController
        appDelegate.retainLaunchCoordinator(launchCoordinator)
        appDelegate.retainMenuBarController(menuBarController)
    }

    var body: some Scene {
        Settings {
            SettingsView(
                model: model,
                launchAtLogin: launchAtLogin,
                menuBarVisibilityStore: menuBarVisibilityStore
            )
                .frame(width: 460, height: 360)
        }
    }
}
