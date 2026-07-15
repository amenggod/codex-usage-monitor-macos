import AppKit

extension Notification.Name {
    static let codexUsageMonitorReopenRequested = Notification.Name(
        "codexUsageMonitor.reopenRequested"
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        NotificationCenter.default.post(name: .codexUsageMonitorReopenRequested, object: nil)
        return true
    }
}
