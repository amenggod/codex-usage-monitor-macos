import SwiftUI

@main
@MainActor
struct CodexUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: UsageViewModel
    @State private var runtime: AppRuntime

    init() {
        let model = LiveDependencies.makeViewModel()
        _model = State(initialValue: model)
        _runtime = State(initialValue: AppRuntime(starter: model))
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(model: model)
                .frame(width: 520, height: 480)
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
                .task { await runtime.launch() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 460, height: 360)
        }
    }
}
