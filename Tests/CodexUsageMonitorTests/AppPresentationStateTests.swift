import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("AppPresentationStateTests")
struct AppPresentationStateTests {
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
        let state = SettingsViewState(launchAtLogin: service)

        state.setLaunchAtLoginEnabled(true)

        #expect(!state.isLaunchAtLoginEnabled)
        #expect(state.launchAtLoginError == "无法启用")
        #expect(!service.isEnabled)
    }

    @MainActor
    @Test func successfulLaunchAtLoginChangeClearsPreviousError() {
        let service = LaunchAtLoginServiceSpy(enabled: false, enableFailure: "首次失败")
        let state = SettingsViewState(launchAtLogin: service)
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
