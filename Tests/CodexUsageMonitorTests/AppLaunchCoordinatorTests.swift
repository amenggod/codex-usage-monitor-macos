import AppKit
import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("AppLaunchCoordinatorTests")
struct AppLaunchCoordinatorTests {
    @MainActor
    @Test func normalLaunchStartsRuntimeAndShowsDashboardAfterApplicationLaunch() async {
        let runtime = AppRuntimeLauncherSpy()
        let dashboard = DashboardPresenterSpy()
        let coordinator = AppLaunchCoordinator(
            arguments: ["CodexUsageMonitor"],
            runtime: runtime,
            dashboard: dashboard
        )

        await coordinator.applicationDidFinishLaunching()

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
            dashboard: dashboard
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
            dashboard: dashboard
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
            dashboard: dashboard
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
        let controller = DashboardWindowController(model: model)
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
        let dashboard = DashboardWindowController(model: model)
        let coordinator = AppLaunchCoordinator(
            arguments: [],
            runtime: AppRuntimeLauncherSpy(),
            dashboard: dashboard
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
private final class DashboardPresenterSpy: DashboardPresenting {
    private(set) var showCount = 0

    func showDashboard() {
        showCount += 1
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
