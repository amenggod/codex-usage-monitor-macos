import AppKit
import Foundation

@MainActor
protocol MenuBarHelperCoordinating: AnyObject {
    func start()
    func stop()
}

@MainActor
protocol MenuBarHelperLaunching: AnyObject {
    func launch(at url: URL) throws
    func terminate(bundleIdentifier: String) async
}

@MainActor
final class WorkspaceMenuBarHelperLauncher: MenuBarHelperLaunching {
    func launch(at url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw MenuBarHelperLaunchError.couldNotOpenHelper
        }
    }

    func terminate(bundleIdentifier: String) async {
        let applications = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
        applications.forEach { $0.terminate() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while applications.contains(where: { !$0.isTerminated }),
              ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }
}

@MainActor
final class MenuBarHelperCoordinator: MenuBarHelperCoordinating {
    static let bundleIdentifier = "com.amenggod.CodexUsageMonitor.MenuBar"

    private let visibilityStore: MenuBarVisibilityStore
    private let launcher: any MenuBarHelperLaunching
    private let helperURL: URL
    private var started = false
    private var desiredRunning = false
    private var isRunning = false
    private var reconcileTask: Task<Void, Never>?

    init(
        visibilityStore: MenuBarVisibilityStore,
        launcher: any MenuBarHelperLaunching,
        helperURL: URL
    ) {
        self.visibilityStore = visibilityStore
        self.launcher = launcher
        self.helperURL = helperURL
    }

    func start() {
        guard !started else { return }
        started = true
        visibilityStore.setVisibilityChangeHandler { [weak self] visible in
            self?.setDesiredRunning(visible)
        }
        setDesiredRunning(visibilityStore.isVisible)
    }

    func stop() {
        visibilityStore.setVisibilityChangeHandler(nil)
        started = false
        setDesiredRunning(false)
    }

    private func setDesiredRunning(_ desiredRunning: Bool) {
        self.desiredRunning = desiredRunning
        guard reconcileTask == nil else { return }
        reconcileTask = Task { @MainActor [weak self] in
            await self?.reconcile()
        }
    }

    private func reconcile() async {
        defer { reconcileTask = nil }

        while desiredRunning != isRunning {
            if desiredRunning {
                do {
                    try launcher.launch(at: helperURL)
                    isRunning = true
                    visibilityStore.setLaunchError(nil)
                } catch {
                    visibilityStore.setLaunchError(error.localizedDescription)
                    return
                }
            } else {
                await launcher.terminate(bundleIdentifier: Self.bundleIdentifier)
                isRunning = false
            }
        }
    }
}

private enum MenuBarHelperLaunchError: LocalizedError {
    case couldNotOpenHelper

    var errorDescription: String? {
        "无法启动菜单栏助手。"
    }
}
