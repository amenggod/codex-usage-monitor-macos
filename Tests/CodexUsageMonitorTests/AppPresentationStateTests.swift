import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("AppPresentationStateTests")
struct AppPresentationStateTests {
    @MainActor
    @Test func displayModeDefaultsToDesktopAndPersists() throws {
        let suiteName = "DisplayModeTests-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let first = DisplayModeStore(defaults: suite)

        #expect(first.mode == .desktop)
        #expect(first.showsDesktopCard)
        #expect(!first.showsMenuBar)

        first.setMode(.both)
        let reopened = DisplayModeStore(defaults: suite)
        #expect(reopened.mode == .both)
        #expect(reopened.showsDesktopCard)
        #expect(reopened.showsMenuBar)
    }

    @MainActor
    @Test func menuBarModeOnlyShowsMenuBar() throws {
        let suiteName = "DisplayModeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DisplayModeStore(defaults: defaults)
        store.setMode(.menuBar)

        #expect(!store.showsDesktopCard)
        #expect(store.showsMenuBar)
    }

    @MainActor
    @Test func settingsDisplayModeBindingUpdatesInjectedStoreAndPersists() throws {
        let suiteName = "DisplayModeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DisplayModeStore(defaults: defaults)
        let settings = SettingsView(
            model: LiveDependencies.makeFailureViewModel(
                error: PresentationTestFailure(message: "unused")
            ),
            launchAtLogin: LaunchAtLoginServiceSpy(enabled: false),
            notificationSender: PresentationNotificationSenderSpy(enabled: false),
            displayModeStore: store
        )

        let binding = settings.displayModeBinding
        #expect(binding.wrappedValue == .desktop)
        binding.wrappedValue = .both

        #expect(store.mode == .both)
        #expect(DisplayModeStore(defaults: defaults).mode == .both)
    }

    @MainActor
    @Test func appRuntimeLaunchStartsMonitoringOnceWithoutPopover() async {
        let starter = RuntimeStarterSpy()
        let runtime = AppRuntime(starter: starter)

        await runtime.launch()
        await runtime.launch()

        #expect(await starter.startCount == 1)
    }

    @MainActor
    @Test func launchAtLoginFailureRollsBackAndSurfacesError() {
        let service = LaunchAtLoginServiceSpy(enabled: false, enableFailure: "无法启用")
        let state = SettingsViewState(
            launchAtLogin: service,
            notificationSender: PresentationNotificationSenderSpy(enabled: false)
        )

        state.setLaunchAtLoginEnabled(true)

        #expect(!state.isLaunchAtLoginEnabled)
        #expect(state.launchAtLoginError == "无法启用")
        #expect(!service.isEnabled)
    }

    @MainActor
    @Test func successfulLaunchAtLoginChangeClearsPreviousError() {
        let service = LaunchAtLoginServiceSpy(enabled: false, enableFailure: "首次失败")
        let state = SettingsViewState(
            launchAtLogin: service,
            notificationSender: PresentationNotificationSenderSpy(enabled: false)
        )
        state.setLaunchAtLoginEnabled(true)
        service.enableFailure = nil

        state.setLaunchAtLoginEnabled(true)

        #expect(state.isLaunchAtLoginEnabled)
        #expect(state.launchAtLoginError == nil)
        #expect(service.isEnabled)
    }

    @MainActor
    @Test func liveDependencyFailureBecomesVisibleAfterStart() async {
        let model = LiveDependencies.makeFailureViewModel(
            error: PresentationTestFailure(message: "无法打开用量数据库")
        )

        await model.start()

        #expect(await eventually {
            model.snapshot.freshness == .failed("无法打开用量数据库")
        })
    }

    @MainActor
    @Test func notificationToggleOffDoesNotPromptAndShowsMessage() async {
        let sender = PresentationNotificationSenderSpy(enabled: true)
        let state = SettingsViewState(
            launchAtLogin: LaunchAtLoginServiceSpy(enabled: false),
            notificationSender: sender
        )
        await state.loadNotificationSettings()

        await state.setNotificationsEnabled(false)

        #expect(!state.notificationsEnabled)
        #expect(state.notificationMessage == "通知已关闭")
        #expect(await sender.authorizationRequestCount == 0)
        await state.loadNotificationSettings()
        #expect(await sender.authorizationRequestCount == 0)
    }

    @MainActor
    @Test func deniedNotificationToggleRollsBackAndShowsMessage() async {
        let sender = PresentationNotificationSenderSpy(
            enabled: false,
            authorizationResults: [false]
        )
        let state = SettingsViewState(
            launchAtLogin: LaunchAtLoginServiceSpy(enabled: false),
            notificationSender: sender
        )
        await state.loadNotificationSettings()

        await state.setNotificationsEnabled(true)

        #expect(!state.notificationsEnabled)
        #expect(state.notificationMessage == "未授予通知权限")
        #expect(await sender.authorizationRequestCount == 1)
    }

    @MainActor
    @Test func notificationThresholdTogglesPersistThroughInjectedSender() async {
        let sender = PresentationNotificationSenderSpy(enabled: true)
        let state = SettingsViewState(
            launchAtLogin: LaunchAtLoginServiceSpy(enabled: false),
            notificationSender: sender
        )
        await state.loadNotificationSettings()

        await state.setThresholdEnabled(false, threshold: 20)

        #expect(!state.twentyPercentNotificationsEnabled)
        #expect(state.tenPercentNotificationsEnabled)
        #expect(await !sender.isThresholdEnabled(20))
        #expect(await sender.isThresholdEnabled(10))
    }
}

private final class LaunchAtLoginServiceSpy: @unchecked Sendable, LaunchAtLoginServicing {
    private let lock = NSLock()
    private var enabled: Bool
    private var storedEnableFailure: String?

    init(enabled: Bool, enableFailure: String? = nil) {
        self.enabled = enabled
        storedEnableFailure = enableFailure
    }

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    var enableFailure: String? {
        get { lock.withLock { storedEnableFailure } }
        set { lock.withLock { storedEnableFailure = newValue } }
    }

    func setEnabled(_ enabled: Bool) throws {
        try lock.withLock {
            if enabled, let storedEnableFailure {
                throw PresentationTestFailure(message: storedEnableFailure)
            }
            self.enabled = enabled
        }
    }
}

private struct PresentationTestFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private actor RuntimeStarterSpy: AppRuntimeStarting {
    private(set) var startCount = 0

    func start() async {
        startCount += 1
    }
}

private actor PresentationNotificationSenderSpy: NotificationSending {
    private var enabled: Bool
    private var enabledThresholds: Set<Int>
    private var authorizationResults: [Bool]
    private(set) var authorizationRequestCount = 0

    init(
        enabled: Bool,
        enabledThresholds: Set<Int> = [20, 10],
        authorizationResults: [Bool] = []
    ) {
        self.enabled = enabled
        self.enabledThresholds = enabledThresholds
        self.authorizationResults = authorizationResults
    }

    func isEnabled() async -> Bool { enabled }

    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
    }

    func isThresholdEnabled(_ threshold: Int) async -> Bool {
        enabledThresholds.contains(threshold)
    }

    func setThresholdEnabled(_ enabled: Bool, threshold: Int) async {
        if enabled {
            enabledThresholds.insert(threshold)
        } else {
            enabledThresholds.remove(threshold)
        }
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        guard !authorizationResults.isEmpty else {
            throw PresentationTestFailure(message: "未配置授权结果")
        }
        let granted = authorizationResults.removeFirst()
        enabled = granted
        return granted
    }

    func send(title: String, body: String, threshold: Int) async throws {}
}

@MainActor
private func eventually(
    attempts: Int = 100,
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
