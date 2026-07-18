import AppKit
import CodexUsageMenuBarCore
import CodexUsageShared
import Foundation

@main
@MainActor
final class MenuBarApplicationDelegate: NSObject, NSApplicationDelegate {
    private var monitor: MenuBarSnapshotMonitor?
    private var statusController: MenuBarStatusController?

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = MenuBarApplicationDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = MenuBarSnapshotModel()
        let reader: any MenuBarSnapshotReading
        do {
            reader = try WidgetSnapshotStore.appGroup()
        } catch {
            reader = MissingSnapshotReader()
        }

        let router = MenuBarActionRouter()
        let statusController = MenuBarStatusController(model: model, router: router)
        let monitor = MenuBarSnapshotMonitor(
            model: model,
            reader: reader,
            observer: DarwinSnapshotChangeObserver(),
            scheduler: TimerMenuBarFallbackScheduler(),
            now: Date.init
        )
        self.statusController = statusController
        self.monitor = monitor
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}

private struct MissingSnapshotReader: MenuBarSnapshotReading {
    func read() throws -> WidgetUsageSnapshot? {
        nil
    }
}
