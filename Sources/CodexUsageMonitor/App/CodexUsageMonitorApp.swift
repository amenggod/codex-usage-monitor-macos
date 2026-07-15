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

    init() {
        let model = LiveDependencies.makeViewModel()
        let runtime = AppRuntime(starter: model)
        let dashboard = DashboardWindowController(model: model)
        let menuBarVisibilityStore = MenuBarVisibilityStore()
        let launchAtLogin = LaunchAtLoginController()
        let launchCoordinator = AppLaunchCoordinator(
            arguments: ProcessInfo.processInfo.arguments,
            runtime: runtime,
            dashboard: dashboard,
            launchAtLogin: launchAtLogin
        )

        _model = State(initialValue: model)
        _menuBarVisibilityStore = State(initialValue: menuBarVisibilityStore)
        self.dashboard = dashboard
        self.launchAtLogin = launchAtLogin
        self.launchCoordinator = launchCoordinator
    }

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarVisibilityBinding) {
            UsagePopoverView(model: model, dashboard: dashboard)
                .frame(width: 520, height: 480)
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                model: model,
                launchAtLogin: launchAtLogin,
                menuBarVisibilityStore: menuBarVisibilityStore
            )
                .frame(width: 460, height: 360)
        }
    }

    private var menuBarVisibilityBinding: Binding<Bool> {
        Binding(
            get: { menuBarVisibilityStore.isVisible },
            set: { menuBarVisibilityStore.setVisible($0) }
        )
    }
}
