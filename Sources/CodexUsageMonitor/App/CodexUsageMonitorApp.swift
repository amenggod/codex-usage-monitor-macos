import SwiftUI

@main
@MainActor
struct CodexUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: UsageViewModel
    @State private var runtime: AppRuntime
    @State private var presentationCoordinator: AppPresentationCoordinator

    init() {
        let model = LiveDependencies.makeViewModel()
        let runtime = AppRuntime(starter: model)
        let displayModeStore = DisplayModeStore()
        let desktopWindowController = DesktopCardWindowController(
            model: model,
            runtime: runtime
        )
        let desktopPresentationController = DesktopCardPresentationController(
            surface: desktopWindowController,
            displayModeStore: displayModeStore
        )
        let presentationCoordinator = AppPresentationCoordinator(
            displayModeStore: displayModeStore,
            desktopPresentationController: desktopPresentationController
        )
        presentationCoordinator.setMode(displayModeStore.mode)

        _model = State(initialValue: model)
        _runtime = State(initialValue: runtime)
        _presentationCoordinator = State(initialValue: presentationCoordinator)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $presentationCoordinator.isMenuBarInserted) {
            UsagePopoverView(model: model)
                .frame(width: 520, height: 480)
        } label: {
            MenuBarLabel(snapshot: model.snapshot, runtime: runtime)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                model: model,
                presentationCoordinator: presentationCoordinator
            )
                .frame(width: 460, height: 360)
        }
    }
}
