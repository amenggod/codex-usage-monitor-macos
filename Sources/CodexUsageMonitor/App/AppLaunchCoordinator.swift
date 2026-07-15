import Foundation

@MainActor
protocol AppRuntimeLaunching: AnyObject {
    func launch() async
}

extension AppRuntime: AppRuntimeLaunching {}

@MainActor
final class AppLaunchCoordinator {
    private let isBackgroundLaunch: Bool
    private let runtime: any AppRuntimeLaunching
    private let dashboard: any DashboardPresenting
    private let notificationCenter: NotificationCenter
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(
        arguments: [String],
        runtime: any AppRuntimeLaunching,
        dashboard: any DashboardPresenting,
        notificationCenter: NotificationCenter = .default
    ) {
        isBackgroundLaunch = arguments.contains("--background")
        self.runtime = runtime
        self.dashboard = dashboard
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
        await runtime.launch()
        if !isBackgroundLaunch {
            dashboard.showDashboard()
        }
    }

    func handleReopen() {
        dashboard.showDashboard()
    }

    func handle(urls: [URL]) {
        guard urls.contains(where: {
            $0.absoluteString == "codexusagemonitor://dashboard"
        }) else { return }

        dashboard.showDashboard()
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}
