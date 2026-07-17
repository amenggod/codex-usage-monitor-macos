import AppKit

@MainActor
protocol MenuBarControlling: AnyObject {
    func start()
}

extension Notification.Name {
    static let usageAppDidFinishLaunching = Notification.Name("usage.appDidFinishLaunching")
    static let usageAppReopenRequested = Notification.Name("usage.appReopenRequested")
    static let usageAppURLsOpened = Notification.Name("usage.appURLsOpened")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchCoordinator: AppLaunchCoordinator?
    private var menuBarController: (any MenuBarControlling)?

    func retainLaunchCoordinator(_ coordinator: AppLaunchCoordinator) {
        launchCoordinator = coordinator
    }

    func retainMenuBarController(_ controller: any MenuBarControlling) {
        menuBarController = controller
    }

    func startRetainedMenuBarController() {
        menuBarController?.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        startRetainedMenuBarController()
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
