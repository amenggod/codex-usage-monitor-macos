import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("LaunchAtLoginControllerTests")
struct LaunchAtLoginControllerTests {
    @Test func reflectsAdapterStateAndRoutesEnableAndDisable() throws {
        let adapter = LaunchAtLoginAdapterSpy(enabled: false)
        let controller = LaunchAtLoginController(adapter: adapter)

        #expect(!controller.isEnabled)
        try controller.setEnabled(true)
        #expect(controller.isEnabled)
        try controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(adapter.operations == [.register, .unregister])
    }

    @Test func registerErrorPropagates() {
        let adapter = LaunchAtLoginAdapterSpy(enabled: false, registerFails: true)
        let controller = LaunchAtLoginController(adapter: adapter)

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try controller.setEnabled(true)
        }
        #expect(!controller.isEnabled)
    }

    @Test func unregisterErrorPropagates() {
        let adapter = LaunchAtLoginAdapterSpy(enabled: true, unregisterFails: true)
        let controller = LaunchAtLoginController(adapter: adapter)

        #expect(throws: LaunchAtLoginTestFailure.self) {
            try controller.setEnabled(false)
        }
        #expect(controller.isEnabled)
    }
}

private final class LaunchAtLoginAdapterSpy: @unchecked Sendable, LaunchAtLoginServiceAdapting {
    enum Operation: Equatable {
        case register
        case unregister
    }

    private let lock = NSLock()
    private var enabled: Bool
    private let registerFails: Bool
    private let unregisterFails: Bool
    private var recordedOperations: [Operation] = []

    init(enabled: Bool, registerFails: Bool = false, unregisterFails: Bool = false) {
        self.enabled = enabled
        self.registerFails = registerFails
        self.unregisterFails = unregisterFails
    }

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    var operations: [Operation] {
        lock.withLock { recordedOperations }
    }

    func register() throws {
        try lock.withLock {
            recordedOperations.append(.register)
            if registerFails { throw LaunchAtLoginTestFailure() }
            enabled = true
        }
    }

    func unregister() throws {
        try lock.withLock {
            recordedOperations.append(.unregister)
            if unregisterFails { throw LaunchAtLoginTestFailure() }
            enabled = false
        }
    }
}

private struct LaunchAtLoginTestFailure: Error {}
