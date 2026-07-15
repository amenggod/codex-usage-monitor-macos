import AppKit

extension Notification.Name {
    static let usageAppDidFinishLaunching = Notification.Name("usage.appDidFinishLaunching")
    static let usageAppReopenRequested = Notification.Name("usage.appReopenRequested")
    static let usageAppURLsOpened = Notification.Name("usage.appURLsOpened")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.post(name: .usageAppDidFinishLaunching, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        NotificationCenter.default.post(name: .usageAppReopenRequested, object: nil)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .usageAppURLsOpened, object: urls)
    }
}
