import SwiftUI

@main
struct CodexUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Codex Usage Monitor", systemImage: "gauge.with.dots.needle.33percent") {
            Text("Codex Usage Monitor")
        }
    }
}
