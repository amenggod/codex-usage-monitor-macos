import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("AppPresentationStateTests")
struct AppPresentationStateTests {
    @Test func missingFiveHourWindowLeavesOnlyWeekVisible() {
        let week = LimitStatus(window: .week, usedPercent: 50, resetsAt: .distantFuture)

        #expect(UsagePresentationPolicy.visibleWindows(limits: [week]) == [.week])
    }

    @Test func expiredFiveHourWindowLeavesOnlyWeekVisible() {
        let expiredFiveHours = LimitStatus(
            window: .fiveHours,
            usedPercent: 25,
            resetsAt: .distantPast
        )

        #expect(
            UsagePresentationPolicy.visibleWindows(limits: [expiredFiveHours])
                == [.week]
        )
    }

    @Test func presentationTimelineRefreshesExpiredLimitsPromptly() {
        #expect(UsagePresentationPolicy.refreshInterval <= 1)
    }

    @Test func limitsExpireExactlyAtTheirResetBoundary() {
        let reset = Date(timeIntervalSince1970: 1_000)
        let limits = [
            LimitStatus(window: .fiveHours, usedPercent: 25, resetsAt: reset),
            LimitStatus(window: .week, usedPercent: 50, resetsAt: reset),
        ]

        #expect(
            UsagePresentationPolicy.activeLimits(
                limits: limits,
                now: reset.addingTimeInterval(-0.001)
            ) == limits
        )
        #expect(UsagePresentationPolicy.activeLimits(limits: limits, now: reset).isEmpty)
        #expect(
            UsagePresentationPolicy.visibleWindows(limits: limits, now: reset)
                == [.week]
        )
    }

    @Test func bothKnownWindowsRemainVisibleInDisplayOrder() {
        let week = LimitStatus(window: .week, usedPercent: 50, resetsAt: .distantFuture)
        let fiveHours = LimitStatus(
            window: .fiveHours,
            usedPercent: 25,
            resetsAt: .distantFuture
        )

        #expect(
            UsagePresentationPolicy.visibleWindows(limits: [week, fiveHours])
                == [.fiveHours, .week]
        )
    }

    @Test func missingWeekWindowKeepsItsWaitingSlot() {
        let fiveHours = LimitStatus(
            window: .fiveHours,
            usedPercent: 25,
            resetsAt: .distantFuture
        )

        #expect(
            UsagePresentationPolicy.visibleWindows(limits: [fiveHours])
                == [.fiveHours, .week]
        )
    }

    @Test func partialFailureHasReadableStatusText() {
        let text = FreshnessFormatter.text(
            for: .partial(.distantPast, failedFiles: 2)
        )

        #expect(text == "部分数据等待恢复 · 2 个文件")
    }

    @Test func rebuildingAndFailureHaveReadableStatusText() {
        #expect(FreshnessFormatter.text(for: .rebuilding(completed: 3, total: 8)) == "正在重建 · 3/8")
        #expect(FreshnessFormatter.text(for: .failed("数据库不可用")) == "读取失败：数据库不可用")
    }

    @MainActor
    @Test func settingsMenuBarVisibilityBindingUpdatesInjectedStoreAndPersists() throws {
        let suiteName = "MenuBarVisibilityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MenuBarVisibilityStore(defaults: defaults)
        let settings = SettingsView(
            model: LiveDependencies.makeFailureViewModel(
                error: PresentationTestFailure(message: "unused")
            ),
            launchAtLogin: LaunchAtLoginServiceSpy(enabled: false),
            notificationSender: PresentationNotificationSenderSpy(enabled: false),
            menuBarVisibilityStore: store
        )

        let binding = settings.menuBarVisibilityBinding
        #expect(!binding.wrappedValue)
        binding.wrappedValue = true

        #expect(store.isVisible)
        #expect(MenuBarVisibilityStore(defaults: defaults).isVisible)
    }

    @MainActor
    @Test func displayEntryPointsShareOneLaunchAtLoginService() {
        let model = LiveDependencies.makeFailureViewModel(
            error: PresentationTestFailure(message: "unused")
        )
        let launchAtLogin = LaunchAtLoginServiceSpy(enabled: false)
        let dashboard = DashboardWindowController(
            model: model,
            launchAtLogin: launchAtLogin
        )
        let popover = UsagePopoverView(
            model: model,
            launchAtLogin: launchAtLogin,
            dashboard: dashboard
        )
        let settings = SettingsView(
            model: model,
            launchAtLogin: launchAtLogin,
            notificationSender: PresentationNotificationSenderSpy(enabled: false),
            menuBarVisibilityStore: MenuBarVisibilityStore()
        )

        #expect(dashboard.launchAtLogin === launchAtLogin)
        #expect(popover.launchAtLogin === launchAtLogin)
        #expect(settings.launchAtLogin === launchAtLogin)
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
        #expect(!state.canRetryLaunchAtLoginMigration)
        #expect(!service.isEnabled)
    }

    @MainActor
    @Test func widgetSharingFailureAppearsWithoutChangingNotificationOrLoginState() {
        let state = SettingsViewState(
            launchAtLogin: LaunchAtLoginServiceSpy(enabled: true),
            notificationSender: PresentationNotificationSenderSpy(enabled: false),
            widgetSharingStatus: .unavailable("小组件共享不可用")
        )

        #expect(state.widgetSharingMessage == "小组件共享不可用")
        #expect(state.isLaunchAtLoginEnabled)
        #expect(!state.notificationsEnabled)
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
    @Test func settingsUsesSinglePreferenceTransactionAndReturnedState() {
        let service = LaunchAtLoginServiceSpy(
            enabled: false,
            preferenceResults: [false]
        )
        let state = SettingsViewState(
            launchAtLogin: service,
            notificationSender: PresentationNotificationSenderSpy(enabled: false)
        )

        state.setLaunchAtLoginEnabled(true)

        #expect(service.preferenceRequests == [true])
        #expect(service.directSetRequests.isEmpty)
        #expect(!state.isLaunchAtLoginEnabled)
    }

    @MainActor
    @Test func settingsPreferenceRetriesStartupMigrationAndClearsItsError() {
        let service = LaunchAtLoginServiceSpy(
            enabled: false,
            migrationFailures: ["无法迁移旧登录项"]
        )
        #expect(throws: PresentationTestFailure.self) {
            try service.migrateLegacyRegistrationIfNeeded()
        }
        let state = SettingsViewState(
            launchAtLogin: service,
            notificationSender: PresentationNotificationSenderSpy(enabled: false)
        )

        state.setLaunchAtLoginEnabled(true)

        #expect(service.preferenceRequests == [true])
        #expect(service.directSetRequests.isEmpty)
        #expect(service.migrationCount == 2)
        #expect(state.isLaunchAtLoginEnabled)
        #expect(state.launchAtLoginError == nil)
        #expect(!state.canRetryLaunchAtLoginMigration)
    }

    @MainActor
    @Test func launchPromptRetriesStartupMigrationThroughPreferenceTransaction() {
        let service = LaunchAtLoginServiceSpy(
            enabled: false,
            migrationFailures: ["首次迁移失败"]
        )
        #expect(throws: PresentationTestFailure.self) {
            try service.migrateLegacyRegistrationIfNeeded()
        }
        let prompt = LaunchAtLoginPromptState(launchAtLogin: service)

        let enabled = prompt.enable()

        #expect(enabled)
        #expect(service.preferenceRequests == [true])
        #expect(service.directSetRequests.isEmpty)
        #expect(service.migrationCount == 2)
        #expect(prompt.errorDescription == nil)
    }

    @MainActor
    @Test func launchPromptPreservesMigrationErrorWhenRetryFails() {
        let service = LaunchAtLoginServiceSpy(
            enabled: false,
            migrationFailures: ["首次迁移失败", "再次迁移失败"]
        )
        #expect(throws: PresentationTestFailure.self) {
            try service.migrateLegacyRegistrationIfNeeded()
        }
        let prompt = LaunchAtLoginPromptState(launchAtLogin: service)

        let enabled = prompt.enable()

        #expect(!enabled)
        #expect(service.preferenceRequests == [true])
        #expect(service.directSetRequests.isEmpty)
        #expect(service.migrationCount == 2)
        #expect(prompt.errorDescription == "再次迁移失败")
        #expect(service.hasMigrationError)
    }

    @MainActor
    @Test func startupLoginItemMigrationErrorIsVisibleAndCanBeRetried() {
        let service = LaunchAtLoginServiceSpy(
            enabled: false,
            migrationFailures: ["无法迁移旧登录项"]
        )
        let state = SettingsViewState(
            launchAtLogin: service,
            notificationSender: PresentationNotificationSenderSpy(enabled: false)
        )
        #expect(throws: PresentationTestFailure.self) {
            try service.migrateLegacyRegistrationIfNeeded()
        }

        state.refreshLaunchAtLoginState()

        #expect(state.launchAtLoginError == "无法迁移旧登录项")
        #expect(state.canRetryLaunchAtLoginMigration)

        state.retryLaunchAtLoginMigration()

        #expect(state.launchAtLoginError == nil)
        #expect(!state.canRetryLaunchAtLoginMigration)
        #expect(service.migrationCount == 2)
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
    private var storedMigrationFailures: [String]
    private var storedLastErrorDescription: String?
    private var storedHasMigrationError = false
    private var recordedMigrationCount = 0
    private var storedPreferenceResults: [Bool]
    private var recordedPreferenceRequests: [Bool] = []
    private var recordedDirectSetRequests: [Bool] = []

    init(
        enabled: Bool,
        enableFailure: String? = nil,
        migrationFailures: [String] = [],
        preferenceResults: [Bool] = []
    ) {
        self.enabled = enabled
        storedEnableFailure = enableFailure
        storedMigrationFailures = migrationFailures
        storedPreferenceResults = preferenceResults
    }

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    var enableFailure: String? {
        get { lock.withLock { storedEnableFailure } }
        set { lock.withLock { storedEnableFailure = newValue } }
    }

    var lastErrorDescription: String? {
        lock.withLock { storedLastErrorDescription }
    }

    var hasMigrationError: Bool {
        lock.withLock { storedHasMigrationError }
    }

    var migrationCount: Int {
        lock.withLock { recordedMigrationCount }
    }

    var preferenceRequests: [Bool] {
        lock.withLock { recordedPreferenceRequests }
    }

    var directSetRequests: [Bool] {
        lock.withLock { recordedDirectSetRequests }
    }

    func applyUserPreference(enabled: Bool) throws -> Bool {
        lock.withLock { recordedPreferenceRequests.append(enabled) }
        try migrateLegacyRegistrationIfNeeded()
        return try lock.withLock {
            if enabled, let storedEnableFailure {
                storedLastErrorDescription = storedEnableFailure
                storedHasMigrationError = false
                throw PresentationTestFailure(message: storedEnableFailure)
            }
            self.enabled = storedPreferenceResults.isEmpty
                ? enabled
                : storedPreferenceResults.removeFirst()
            storedLastErrorDescription = nil
            storedHasMigrationError = false
            return self.enabled
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        try lock.withLock {
            recordedDirectSetRequests.append(enabled)
            if enabled, let storedEnableFailure {
                throw PresentationTestFailure(message: storedEnableFailure)
            }
            self.enabled = enabled
        }
    }

    func migrateLegacyRegistrationIfNeeded() throws {
        try lock.withLock {
            recordedMigrationCount += 1
            if !storedMigrationFailures.isEmpty {
                let failure = storedMigrationFailures.removeFirst()
                storedLastErrorDescription = failure
                storedHasMigrationError = true
                throw PresentationTestFailure(message: failure)
            }
            storedLastErrorDescription = nil
            storedHasMigrationError = false
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
