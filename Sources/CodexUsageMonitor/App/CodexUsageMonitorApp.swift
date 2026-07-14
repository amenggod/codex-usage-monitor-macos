import SwiftUI

@main
@MainActor
struct CodexUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = LiveDependencies.makeViewModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(model: model)
                .frame(width: 520, height: 480)
                .task { await model.start() }
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 460, height: 360)
        }
    }
}
