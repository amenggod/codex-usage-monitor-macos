import AppKit
import CodexUsageMenuBarCore

@MainActor
final class MenuBarActionRouter {
    private static let mainApplicationBundleIdentifier = "com.amenggod.CodexUsageMonitor"

    func perform(_ action: MenuBarAction) {
        NSWorkspace.shared.open(action.url)
    }

    func quitAll() {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == Self.mainApplicationBundleIdentifier }
            .forEach { $0.terminate() }
        NSApp.terminate(nil)
    }
}
