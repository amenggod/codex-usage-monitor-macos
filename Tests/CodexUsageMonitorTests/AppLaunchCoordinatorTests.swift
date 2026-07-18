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
    @Test func appDelegateDefersMenuBarHelperUntilLaunchReturns() async {
        let delegate = AppDelegate()
        let helper = MenuBarHelperCoordinatorSpy()

        delegate.retainMenuBarHelperCoordinator(helper)
        delegate.startRetainedMenuBarHelperCoordinator()

        #expect(helper.startCount == 0)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(helper.startCount == 1)
    }

    @MainActor
    @Test func applicationTerminationStopsMenuBarHelper() {
        let delegate = AppDelegate()
        let helper = MenuBarHelperCoordinatorSpy()
        delegate.retainMenuBarHelperCoordinator(helper)

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        #expect(helper.stopCount == 1)
    }

    @MainActor
    @Test func menuBarHelperCoordinatorStartsVisibleHelperOnce() async throws {
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = MenuBarVisibilityStore(defaults: suite.defaults)
        store.setVisible(true)
        let launcher = MenuBarHelperLauncherSpy()
        let coordinator = MenuBarHelperCoordinator(
            visibilityStore: store,
            launcher: launcher,
            helperURL: URL(fileURLWithPath: "/tmp/CodexUsageMenuBar.app")
        )

        coordinator.start()
        await waitUntil { launcher.launchURLs.count == 1 }

        #expect(launcher.launchURLs.count == 1)
        #expect(launcher.terminatedBundleIdentifiers.isEmpty)
    }

    @MainActor
    @Test func menuBarHelperCoordinatorStopsVisibleHelperOnce() async throws {
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = MenuBarVisibilityStore(defaults: suite.defaults)
        store.setVisible(true)
        let launcher = MenuBarHelperLauncherSpy()
        let coordinator = MenuBarHelperCoordinator(
            visibilityStore: store,
            launcher: launcher,
            helperURL: URL(fileURLWithPath: "/tmp/CodexUsageMenuBar.app")
        )
        coordinator.start()
        await waitUntil { launcher.launchURLs.count == 1 }

        store.setVisible(false)
        store.setVisible(false)
        await waitUntil { launcher.terminatedBundleIdentifiers.count == 1 }

        #expect(launcher.terminatedBundleIdentifiers == [
            MenuBarHelperCoordinator.bundleIdentifier,
        ])
    }

    @MainActor
    @Test func menuBarHelperCoordinatorRestartsAfterVisibilityIsReenabled() async throws {
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = MenuBarVisibilityStore(defaults: suite.defaults)
        store.setVisible(true)
        let launcher = MenuBarHelperLauncherSpy()
        let coordinator = MenuBarHelperCoordinator(
            visibilityStore: store,
            launcher: launcher,
            helperURL: URL(fileURLWithPath: "/tmp/CodexUsageMenuBar.app")
        )
        coordinator.start()
        await waitUntil { launcher.launchURLs.count == 1 }

        store.setVisible(false)
        await waitUntil { launcher.terminatedBundleIdentifiers.count == 1 }
        store.setVisible(true)
        await waitUntil { launcher.launchURLs.count == 2 }

        #expect(launcher.launchURLs.count == 2)
        #expect(launcher.terminatedBundleIdentifiers == [
            MenuBarHelperCoordinator.bundleIdentifier,
        ])
    }

    @MainActor
    @Test func menuBarHelperCoordinatorWaitsForTerminationBeforeRelaunching() async throws {
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = MenuBarVisibilityStore(defaults: suite.defaults)
        store.setVisible(true)
        let launcher = DelayedTerminationMenuBarHelperLauncherSpy()
        let coordinator = MenuBarHelperCoordinator(
            visibilityStore: store,
            launcher: launcher,
            helperURL: URL(fileURLWithPath: "/tmp/CodexUsageMenuBar.app")
        )
        coordinator.start()
        await waitUntil { launcher.launchURLs.count == 1 }

        store.setVisible(false)
        await waitUntil { launcher.terminatedBundleIdentifiers.count == 1 }
        store.setVisible(true)

        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(launcher.launchURLs.count == 1)

        launcher.completeTermination()
        await waitUntil { launcher.launchURLs.count == 2 }

        #expect(launcher.launchURLs.count == 2)
        #expect(launcher.terminatedBundleIdentifiers == [
            MenuBarHelperCoordinator.bundleIdentifier,
        ])
    }

    @MainActor
    @Test func menuBarHelperCoordinatorStartIsIdempotent() async throws {
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = MenuBarVisibilityStore(defaults: suite.defaults)
        store.setVisible(true)
        let launcher = MenuBarHelperLauncherSpy()
        let coordinator = MenuBarHelperCoordinator(
            visibilityStore: store,
            launcher: launcher,
            helperURL: URL(fileURLWithPath: "/tmp/CodexUsageMenuBar.app")
        )

        coordinator.start()
        coordinator.start()
        await waitUntil { launcher.launchURLs.count == 1 }

        #expect(launcher.launchURLs.count == 1)
    }

    @MainActor
    @Test func successfulHelperLaunchClearsPreviousError() async throws {
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = MenuBarVisibilityStore(defaults: suite.defaults)
        store.setVisible(true)
        let launcher = MenuBarHelperLauncherSpy(
            launchErrors: [DashboardTestFailure(message: "无法启动菜单栏助手")]
        )
        let coordinator = MenuBarHelperCoordinator(
            visibilityStore: store,
            launcher: launcher,
            helperURL: URL(fileURLWithPath: "/tmp/CodexUsageMenuBar.app")
        )

        coordinator.start()
        await waitUntil { launcher.launchURLs.count == 1 }
        #expect(store.launchErrorDescription == "无法启动菜单栏助手")

        store.setVisible(true)
        await waitUntil { launcher.launchURLs.count == 2 }

        #expect(store.launchErrorDescription == nil)
        #expect(launcher.launchURLs.count == 2)
    }

    @MainActor
    @Test func failedHelperLaunchShowsError() async throws {
        let suite = try isolatedDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = MenuBarVisibilityStore(defaults: suite.defaults)
        store.setVisible(true)
        let coordinator = MenuBarHelperCoordinator(
            visibilityStore: store,
            launcher: MenuBarHelperLauncherSpy(
                launchErrors: [DashboardTestFailure(message: "无法启动菜单栏助手")]
            ),
            helperURL: URL(fileURLWithPath: "/tmp/CodexUsageMenuBar.app")
        )

        coordinator.start()
        await waitUntil { store.launchErrorDescription != nil }

        #expect(store.launchErrorDescription == "无法启动菜单栏助手")
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
    @Test func helperURLsRouteDashboardRefreshAndSettings() async {
        let dashboard = DashboardPresenterSpy()
        let refresher = UsageRefreshRequesterSpy()
        let settings = SettingsPresenterSpy()
        let coordinator = AppLaunchCoordinator(
            arguments: [],
            runtime: AppRuntimeLauncherSpy(),
            dashboard: dashboard,
            launchAtLogin: AppLaunchAtLoginSpy(),
            refresher: refresher,
            settings: settings
        )

        coordinator.handle(urls: [
            URL(string: "codexusagemonitor://dashboard")!,
            URL(string: "codexusagemonitor://refresh")!,
            URL(string: "codexusagemonitor://settings")!,
        ])
        await Task.yield()

        #expect(dashboard.showCount == 1)
        #expect(refresher.refreshCount == 1)
        #expect(settings.showCount == 1)
    }

    @MainActor
    @Test func settingsPresenterActivatesBeforePerformingInjectedMenuCommand() {
        var events: [String] = []
        let command = SettingsMenuCommandPerformerSpy {
            events.append("settings-command")
        }
        let presenter = SettingsWindowPresenter(
            settingsMenuCommand: command,
            activateApplication: {
                events.append("activate")
            }
        )

        presenter.showSettings()

        #expect(events == ["activate", "settings-command"])
    }

    @MainActor
    @Test func appKitSettingsCommandClicksOnlyEnabledCommaItemInFirstSubmenu() {
        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        defer { application.mainMenu = previousMainMenu }

        let disabledCommaTarget = MenuItemActionTarget()
        let nonSettingsTarget = MenuItemActionTarget()
        let settingsTarget = MenuItemActionTarget()
        let secondSubmenuTarget = MenuItemActionTarget()

        let firstSubmenu = NSMenu()
        firstSubmenu.autoenablesItems = false
        firstSubmenu.addItem(menuItem(
            keyEquivalent: ",",
            isEnabled: false,
            target: disabledCommaTarget
        ))
        firstSubmenu.addItem(menuItem(
            keyEquivalent: "s",
            isEnabled: true,
            target: nonSettingsTarget
        ))
        firstSubmenu.addItem(menuItem(
            keyEquivalent: ",",
            isEnabled: true,
            target: settingsTarget
        ))

        let secondSubmenu = NSMenu()
        secondSubmenu.autoenablesItems = false
        secondSubmenu.addItem(menuItem(
            keyEquivalent: ",",
            isEnabled: true,
            target: secondSubmenuTarget
        ))

        let mainMenu = NSMenu()
        let firstRootItem = NSMenuItem()
        firstRootItem.submenu = firstSubmenu
        mainMenu.addItem(firstRootItem)
        let secondRootItem = NSMenuItem()
        secondRootItem.submenu = secondSubmenu
        mainMenu.addItem(secondRootItem)
        application.mainMenu = mainMenu

        AppKitSettingsMenuCommandPerformer().performSettingsMenuCommand()

        #expect(disabledCommaTarget.performCount == 0)
        #expect(nonSettingsTarget.performCount == 0)
        #expect(settingsTarget.performCount == 1)
        #expect(secondSubmenuTarget.performCount == 0)
    }

    @MainActor
    @Test func nonExactHelperURLsAreIgnored() async {
        let dashboard = DashboardPresenterSpy()
        let refresher = UsageRefreshRequesterSpy()
        let settings = SettingsPresenterSpy()
        let coordinator = AppLaunchCoordinator(
            arguments: [],
            runtime: AppRuntimeLauncherSpy(),
            dashboard: dashboard,
            launchAtLogin: AppLaunchAtLoginSpy(),
            refresher: refresher,
            settings: settings
        )
        let invalidURLs = [
            "other://dashboard",
            "codexusagemonitor://other",
            "codexusagemonitor://dashboard/",
            "codexusagemonitor://dashboard/path",
            "codexusagemonitor://dashboard?source=widget",
            "codexusagemonitor://dashboard#widget",
            "codexusagemonitor://refresh/path",
            "codexusagemonitor://settings?x=1",
        ].compactMap(URL.init(string:))

        coordinator.handle(urls: invalidURLs)
        await Task.yield()

        #expect(dashboard.showCount == 0)
        #expect(refresher.refreshCount == 0)
        #expect(settings.showCount == 0)
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
private final class UsageRefreshRequesterSpy: UsageRefreshRequesting {
    private(set) var refreshCount = 0

    func retry() async {
        refreshCount += 1
    }
}

@MainActor
private final class SettingsPresenterSpy: SettingsPresenting {
    private(set) var showCount = 0

    func showSettings() {
        showCount += 1
    }
}

@MainActor
private final class SettingsMenuCommandPerformerSpy: SettingsMenuCommandPerforming {
    private let perform: () -> Void

    init(perform: @escaping () -> Void) {
        self.perform = perform
    }

    func performSettingsMenuCommand() {
        perform()
    }
}

@MainActor
private final class MenuItemActionTarget: NSObject {
    private(set) var performCount = 0

    @objc func performMenuItemAction(_ sender: Any?) {
        performCount += 1
    }
}

@MainActor
private func menuItem(
    keyEquivalent: String,
    isEnabled: Bool,
    target: MenuItemActionTarget
) -> NSMenuItem {
    let item = NSMenuItem(
        title: "not-a-localized-settings-title",
        action: #selector(MenuItemActionTarget.performMenuItemAction(_:)),
        keyEquivalent: keyEquivalent
    )
    item.target = target
    item.isEnabled = isEnabled
    return item
}

@MainActor
private final class MenuBarHelperCoordinatorSpy: MenuBarHelperCoordinating {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class MenuBarHelperLauncherSpy: MenuBarHelperLaunching {
    private var launchErrors: [any Error]
    private(set) var launchURLs: [URL] = []
    private(set) var terminatedBundleIdentifiers: [String] = []

    init(launchErrors: [any Error] = []) {
        self.launchErrors = launchErrors
    }

    func launch(at url: URL) throws {
        launchURLs.append(url)
        if !launchErrors.isEmpty {
            throw launchErrors.removeFirst()
        }
    }

    func terminate(bundleIdentifier: String) async {
        terminatedBundleIdentifiers.append(bundleIdentifier)
    }
}

@MainActor
private final class DelayedTerminationMenuBarHelperLauncherSpy: MenuBarHelperLaunching {
    private(set) var launchURLs: [URL] = []
    private(set) var terminatedBundleIdentifiers: [String] = []
    private var terminationContinuation: CheckedContinuation<Void, Never>?

    func launch(at url: URL) throws {
        launchURLs.append(url)
    }

    func terminate(bundleIdentifier: String) async {
        terminatedBundleIdentifiers.append(bundleIdentifier)
        await withCheckedContinuation { continuation in
            terminationContinuation = continuation
        }
    }

    func completeTermination() {
        terminationContinuation?.resume()
        terminationContinuation = nil
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<100 where !condition() {
        await Task.yield()
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
