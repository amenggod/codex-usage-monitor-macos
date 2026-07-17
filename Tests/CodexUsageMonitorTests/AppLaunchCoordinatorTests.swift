import AppKit
import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("AppLaunchCoordinatorTests")
struct AppLaunchCoordinatorTests {
    @MainActor
    @Test func appDelegateRetainsLaunchCoordinatorForApplicationLifetime() {
        let delegate = AppDelegate()
        weak var retainedCoordinator: AppLaunchCoordinator?

        do {
            let coordinator = AppLaunchCoordinator(
                arguments: ["CodexUsageMonitor"],
                runtime: AppRuntimeLauncherSpy(),
                dashboard: DashboardPresenterSpy(),
                launchAtLogin: AppLaunchAtLoginSpy()
            )
            retainedCoordinator = coordinator
            delegate.retainLaunchCoordinator(coordinator)
        }

        #expect(retainedCoordinator != nil)
        withExtendedLifetime(delegate) {}
    }

    @MainActor
    @Test func appDelegateDefersNativeMenuBarUntilAfterApplicationLaunchReturns() async {
        let delegate = AppDelegate()
        let menuBar = MenuBarControllerSpy()

        delegate.retainMenuBarController(menuBar)
        delegate.startRetainedMenuBarController()

        #expect(menuBar.startCount == 0)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(menuBar.startCount == 1)
    }

    @MainActor
    @Test func normalLaunchStartsRuntimeAndShowsDashboardAfterApplicationLaunch() async {
        let runtime = AppRuntimeLauncherSpy()
        let dashboard = DashboardPresenterSpy()
        let coordinator = AppLaunchCoordinator(
            arguments: ["CodexUsageMonitor"],
            runtime: runtime,
            dashboard: dashboard,
            launchAtLogin: AppLaunchAtLoginSpy()
        )

        await coordinator.applicationDidFinishLaunching()

        #expect(runtime.startCount == 1)
        #expect(dashboard.showCount == 1)
    }

    @MainActor
    @Test func foregroundLaunchShowsDashboardBeforeRuntimeCompletesAndStartsRuntimeOnce() async {
        let runtime = GatedAppRuntimeLauncher()
        let dashboard = DashboardPresenterSpy()
        let coordinator = AppLaunchCoordinator(
            arguments: ["CodexUsageMonitor"],
            runtime: runtime,
            dashboard: dashboard,
            launchAtLogin: AppLaunchAtLoginSpy()
        )

        let launch = Task {
            await coordinator.applicationDidFinishLaunching()
        }
        for _ in 0..<100 where runtime.startCount == 0 {
            await Task.yield()
        }

        #expect(runtime.startCount == 1)
        #expect(dashboard.showCount == 1)

        runtime.succeed()
        await launch.value

        #expect(runtime.startCount == 1)
        #expect(dashboard.showCount == 1)
    }

    @MainActor
    @Test func backgroundLaunchStartsRuntimeWithoutShowingDashboard() async {
        let runtime = AppRuntimeLauncherSpy()
        let dashboard = DashboardPresenterSpy()
        let coordinator = AppLaunchCoordinator(
            arguments: ["CodexUsageMonitor", "--background"],
            runtime: runtime,
            dashboard: dashboard,
            launchAtLogin: AppLaunchAtLoginSpy()
        )

        await coordinator.applicationDidFinishLaunching()

        #expect(runtime.startCount == 1)
        #expect(dashboard.showCount == 0)
    }

    @MainActor
    @Test func widgetURLAndReopenRouteToTheRetainedDashboardPresenter() {
        let dashboard = DashboardPresenterSpy()
        let coordinator = AppLaunchCoordinator(
            arguments: [],
            runtime: AppRuntimeLauncherSpy(),
            dashboard: dashboard,
            launchAtLogin: AppLaunchAtLoginSpy()
        )

        coordinator.handle(urls: [URL(string: "codexusagemonitor://dashboard")!])
        coordinator.handleReopen()

        #expect(dashboard.showCount == 2)
    }

    @MainActor
    @Test func nonExactDashboardURLsAreIgnored() {
        let dashboard = DashboardPresenterSpy()
        let coordinator = AppLaunchCoordinator(
            arguments: [],
            runtime: AppRuntimeLauncherSpy(),
            dashboard: dashboard,
            launchAtLogin: AppLaunchAtLoginSpy()
        )
        let invalidURLs = [
            "other://dashboard",
            "codexusagemonitor://other",
            "codexusagemonitor://dashboard/",
            "codexusagemonitor://dashboard/path",
            "codexusagemonitor://dashboard?source=widget",
            "codexusagemonitor://dashboard#widget",
        ].compactMap(URL.init(string:))

        coordinator.handle(urls: invalidURLs)

        #expect(dashboard.showCount == 0)
    }

    @MainActor
    @Test func lifecycleNotificationsRouteAfterObserversAreRegistered() async {
        let center = NotificationCenter()
        let runtime = AppRuntimeLauncherSpy()
        let dashboard = DashboardPresenterSpy()
        let coordinator = AppLaunchCoordinator(
            arguments: ["CodexUsageMonitor"],
            runtime: runtime,
            dashboard: dashboard,
            launchAtLogin: AppLaunchAtLoginSpy(),
            notificationCenter: center
        )

        center.post(name: .usageAppDidFinishLaunching, object: nil)
        await Task.yield()
        center.post(name: .usageAppReopenRequested, object: nil)
        center.post(
            name: .usageAppURLsOpened,
            object: [URL(string: "codexusagemonitor://dashboard")!]
        )

        #expect(runtime.startCount == 1)
        #expect(dashboard.showCount == 3)
        _ = coordinator
    }

    @MainActor
    @Test func dashboardWindowControllerReusesOneWindow() throws {
        let model = LiveDependencies.makeFailureViewModel(
            error: DashboardTestFailure(message: "unused")
        )
        let controller = DashboardWindowController(
            model: model,
            launchAtLogin: AppLaunchAtLoginSpy()
        )
        defer { controller.close() }

        controller.showDashboard()
        let firstWindow = try #require(controller.window)
        controller.showDashboard()

        #expect(controller.window === firstWindow)
    }

    @MainActor
    @Test func reopenAfterClosingDashboardShowsTheSameWindowAgain() throws {
        let model = LiveDependencies.makeFailureViewModel(
            error: DashboardTestFailure(message: "unused")
        )
        let launchAtLogin = AppLaunchAtLoginSpy()
        let dashboard = DashboardWindowController(
            model: model,
            launchAtLogin: launchAtLogin
        )
        let coordinator = AppLaunchCoordinator(
            arguments: [],
            runtime: AppRuntimeLauncherSpy(),
            dashboard: dashboard,
            launchAtLogin: launchAtLogin
        )
        defer { dashboard.close() }

        dashboard.showDashboard()
        let firstWindow = try #require(dashboard.window)
        firstWindow.close()
        #expect(!firstWindow.isVisible)

        coordinator.handleReopen()

        #expect(dashboard.window === firstWindow)
        #expect(firstWindow.isVisible)
    }

    @MainActor
    @Test func applicationLaunchMigratesLegacyRegistration() async {
        let launchAtLogin = AppLaunchAtLoginSpy()
        let coordinator = AppLaunchCoordinator(
            arguments: ["CodexUsageMonitor"],
            runtime: AppRuntimeLauncherSpy(),
            dashboard: DashboardPresenterSpy(),
            launchAtLogin: launchAtLogin
        )

        await coordinator.applicationDidFinishLaunching()

        #expect(launchAtLogin.migrationCount == 1)
    }

    @MainActor
    @Test func migrationFailureDoesNotBlockRuntimeOrDashboard() async {
        let runtime = AppRuntimeLauncherSpy()
        let dashboard = DashboardPresenterSpy()
        let launchAtLogin = AppLaunchAtLoginSpy(
            migrationError: DashboardTestFailure(message: "无法迁移登录项")
        )
        let coordinator = AppLaunchCoordinator(
            arguments: ["CodexUsageMonitor"],
            runtime: runtime,
            dashboard: dashboard,
            launchAtLogin: launchAtLogin
        )

        await coordinator.applicationDidFinishLaunching()

        #expect(launchAtLogin.migrationCount == 1)
        #expect(runtime.startCount == 1)
        #expect(dashboard.showCount == 1)
    }

    @MainActor
    @Test func oldDisplayModesMigrateToMenuBarBoolean() throws {
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let defaults = suite.defaults

        defaults.set("both", forKey: "displayMode")
        #expect(MenuBarVisibilityStore(defaults: defaults).isVisible)

        defaults.removeObject(forKey: "menuBarVisible")
        defaults.set("desktop", forKey: "displayMode")
        #expect(!MenuBarVisibilityStore(defaults: defaults).isVisible)

        defaults.removeObject(forKey: "menuBarVisible")
        defaults.set("menuBar", forKey: "displayMode")
        #expect(MenuBarVisibilityStore(defaults: defaults).isVisible)

        defaults.removeObject(forKey: "menuBarVisible")
        defaults.removeObject(forKey: "displayMode")
        #expect(!MenuBarVisibilityStore(defaults: defaults).isVisible)
    }

    @MainActor
    @Test func explicitMenuBarVisibilityWinsAndChangesPersist() throws {
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let defaults = suite.defaults
        defaults.set(false, forKey: "menuBarVisible")
        defaults.set("both", forKey: "displayMode")

        let store = MenuBarVisibilityStore(defaults: defaults)
        #expect(!store.isVisible)

        store.setVisible(true)

        #expect(MenuBarVisibilityStore(defaults: defaults).isVisible)
    }
}

@MainActor
private final class AppRuntimeLauncherSpy: AppRuntimeLaunching {
    private(set) var startCount = 0

    func launch() async {
        startCount += 1
    }
}

@MainActor
private final class GatedAppRuntimeLauncher: AppRuntimeLaunching {
    private(set) var startCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func launch() async {
        startCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class DashboardPresenterSpy: DashboardPresenting {
    private(set) var showCount = 0

    func showDashboard() {
        showCount += 1
    }
}

@MainActor
private final class MenuBarControllerSpy: MenuBarControlling {
    private(set) var startCount = 0

    func start() {
        startCount += 1
    }
}

private final class AppLaunchAtLoginSpy: @unchecked Sendable, LaunchAtLoginServicing {
    private let lock = NSLock()
    private let migrationError: (any Error)?
    private var recordedMigrationCount = 0

    init(migrationError: (any Error)? = nil) {
        self.migrationError = migrationError
    }

    var isEnabled: Bool { false }
    var lastErrorDescription: String? { migrationError?.localizedDescription }
    var hasMigrationError: Bool { migrationError != nil }
    var migrationCount: Int { lock.withLock { recordedMigrationCount } }

    func applyUserPreference(enabled: Bool) throws -> Bool {
        try migrateLegacyRegistrationIfNeeded()
        return isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {}

    func migrateLegacyRegistrationIfNeeded() throws {
        try lock.withLock {
            recordedMigrationCount += 1
            if let migrationError { throw migrationError }
        }
    }
}

private struct DashboardTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func isolatedDefaults() throws -> (defaults: UserDefaults, name: String) {
    let name = "AppLaunchCoordinatorTests-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
}
