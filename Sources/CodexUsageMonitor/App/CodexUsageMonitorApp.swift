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
    private let menuBarHelperCoordinator: MenuBarHelperCoordinator

    init() {
        let model = LiveDependencies.makeViewModel()
        let runtime = AppRuntime(starter: model)
        let launchAtLogin = LaunchAtLoginController()
        let settings = SettingsWindowPresenter()
        let dashboard = DashboardWindowController(
            model: model,
            launchAtLogin: launchAtLogin
        )
        let menuBarVisibilityStore = MenuBarVisibilityStore()
        let launchCoordinator = AppLaunchCoordinator(
            arguments: ProcessInfo.processInfo.arguments,
            runtime: runtime,
            dashboard: dashboard,
            launchAtLogin: launchAtLogin,
            refresher: model,
            settings: settings
        )
        let helperURL = Bundle.main.bundleURL
            .appending(path: "Contents/Library/LoginItems")
            .appending(path: "CodexUsageMenuBar.app")
        let menuBarHelperCoordinator = MenuBarHelperCoordinator(
            visibilityStore: menuBarVisibilityStore,
            launcher: WorkspaceMenuBarHelperLauncher(),
            helperURL: helperURL
        )

        _model = State(initialValue: model)
        _menuBarVisibilityStore = State(initialValue: menuBarVisibilityStore)
        self.dashboard = dashboard
        self.launchAtLogin = launchAtLogin
        self.launchCoordinator = launchCoordinator
        self.menuBarHelperCoordinator = menuBarHelperCoordinator
        appDelegate.retainLaunchCoordinator(launchCoordinator)
        appDelegate.retainMenuBarHelperCoordinator(menuBarHelperCoordinator)
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
