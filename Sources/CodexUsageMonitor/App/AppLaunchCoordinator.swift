import Foundation

@MainActor
protocol AppRuntimeLaunching: AnyObject {
    func launch() async
}

extension AppRuntime: AppRuntimeLaunching {}

@MainActor
protocol UsageRefreshRequesting: AnyObject {
    func retry() async
}

extension UsageViewModel: UsageRefreshRequesting {}

@MainActor
protocol SettingsPresenting: AnyObject {
    func showSettings()
}

@MainActor
final class AppLaunchCoordinator {
    private let isBackgroundLaunch: Bool
    private let runtime: any AppRuntimeLaunching
    private let dashboard: any DashboardPresenting
    private let launchAtLogin: any LaunchAtLoginServicing
    private let refresher: any UsageRefreshRequesting
    private let settings: any SettingsPresenting
    private let notificationCenter: NotificationCenter
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(
        arguments: [String],
        runtime: any AppRuntimeLaunching,
        dashboard: any DashboardPresenting,
        launchAtLogin: any LaunchAtLoginServicing,
        refresher: any UsageRefreshRequesting = NoopUsageRefreshRequester(),
        settings: any SettingsPresenting = NoopSettingsPresenter(),
        notificationCenter: NotificationCenter = .default
    ) {
        isBackgroundLaunch = arguments.contains("--background")
        self.runtime = runtime
        self.dashboard = dashboard
        self.launchAtLogin = launchAtLogin
        self.refresher = refresher
        self.settings = settings
        self.notificationCenter = notificationCenter
        observers = [
            notificationCenter.addObserver(
                forName: .usageAppDidFinishLaunching,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.applicationDidFinishLaunching()
                }
            },
            notificationCenter.addObserver(
                forName: .usageAppReopenRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleReopen()
                }
            },
            notificationCenter.addObserver(
                forName: .usageAppURLsOpened,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let urls = notification.object as? [URL] ?? []
                MainActor.assumeIsolated {
                    self?.handle(urls: urls)
                }
            },
        ]
    }

    func applicationDidFinishLaunching() async {
        try? launchAtLogin.migrateLegacyRegistrationIfNeeded()
        if !isBackgroundLaunch {
            dashboard.showDashboard()
        }
        await runtime.launch()
    }

    func handleReopen() {
        dashboard.showDashboard()
    }

    func handle(urls: [URL]) {
        for url in urls {
            switch url.absoluteString {
            case "codexusagemonitor://dashboard":
                dashboard.showDashboard()
            case "codexusagemonitor://refresh":
                Task { [weak self] in
                    await self?.refresher.retry()
                }
            case "codexusagemonitor://settings":
                settings.showSettings()
            default:
                continue
            }
        }
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}

@MainActor
private final class NoopUsageRefreshRequester: UsageRefreshRequesting {
    func retry() async {}
}

@MainActor
private final class NoopSettingsPresenter: SettingsPresenting {
    func showSettings() {}
}
