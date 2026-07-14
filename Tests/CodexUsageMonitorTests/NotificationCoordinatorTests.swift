import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("NotificationCoordinatorTests")
struct NotificationCoordinatorTests {
    @Test func thresholdsAreStrictAndTwentyPrecedesTen() async throws {
        let database = try TemporaryNotificationDatabase()
        try await database.repository.migrate()
        let sender = NotificationSenderSpy()
        let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)
        let reset = Date(timeIntervalSince1970: 2_000)

        await coordinator.evaluate([
            LimitStatus(window: .fiveHours, usedPercent: 80, resetsAt: reset),
        ])
        #expect(await sender.sentThresholds.isEmpty)

        await coordinator.evaluate([
            LimitStatus(window: .fiveHours, usedPercent: 91, resetsAt: reset),
        ])

        #expect(await sender.sentThresholds == [20, 10])
    }

    @Test func eachThresholdIsSentOncePerWindowAndReset() async throws {
        let database = try TemporaryNotificationDatabase()
        try await database.repository.migrate()
        let sender = NotificationSenderSpy()
        let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)
        let firstReset = Date(timeIntervalSince1970: 2_000)
        let nextReset = Date(timeIntervalSince1970: 4_000)

        await coordinator.evaluate([
            LimitStatus(window: .fiveHours, usedPercent: 81, resetsAt: firstReset),
        ])
        await coordinator.evaluate([
            LimitStatus(window: .fiveHours, usedPercent: 82, resetsAt: firstReset),
        ])
        await coordinator.evaluate([
            LimitStatus(window: .fiveHours, usedPercent: 91, resetsAt: firstReset),
        ])
        await coordinator.evaluate([
            LimitStatus(window: .fiveHours, usedPercent: 91, resetsAt: firstReset),
        ])
        await coordinator.evaluate([
            LimitStatus(window: .fiveHours, usedPercent: 91, resetsAt: nextReset),
        ])

        #expect(await sender.sentThresholds == [20, 10, 20, 10])
    }

    @Test func disabledSenderDoesNoWork() async throws {
        let database = try TemporaryNotificationDatabase()
        try await database.repository.migrate()
        let sender = NotificationSenderSpy(enabled: false)
        let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)

        await coordinator.evaluate([
            LimitStatus(
                window: .week,
                usedPercent: 95,
                resetsAt: Date(timeIntervalSince1970: 5_000)
            ),
        ])

        #expect(await sender.attemptedThresholds.isEmpty)
    }

    @Test func sendFailureDoesNotWriteReceiptAndCanRetry() async throws {
        let database = try TemporaryNotificationDatabase()
        try await database.repository.migrate()
        let sender = NotificationSenderSpy(sendFailures: 1)
        let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)
        let limit = LimitStatus(
            window: .fiveHours,
            usedPercent: 81,
            resetsAt: Date(timeIntervalSince1970: 6_000)
        )

        await coordinator.evaluate([limit])
        await coordinator.evaluate([limit])

        #expect(await sender.attemptedThresholds == [20, 20])
        #expect(await sender.sentThresholds == [20])
    }

    @Test func repositoryReadFailureDoesNotSendOrInventReceipt() async throws {
        let database = try TemporaryNotificationDatabase()
        let sender = NotificationSenderSpy()
        let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)
        let limit = LimitStatus(
            window: .week,
            usedPercent: 81,
            resetsAt: Date(timeIntervalSince1970: 7_000)
        )

        await coordinator.evaluate([limit])
        #expect(await sender.sentThresholds.isEmpty)

        try await database.repository.migrate()
        await coordinator.evaluate([limit])
        #expect(await sender.sentThresholds == [20])
    }

    @Test func repositoryWriteFailureDoesNotPreventLaterRetry() async throws {
        let database = try TemporaryNotificationDatabase()
        try await database.repository.migrate()
        let sender = GatedNotificationSender()
        let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)
        let limit = LimitStatus(
            window: .fiveHours,
            usedPercent: 81,
            resetsAt: Date(timeIntervalSince1970: 8_000)
        )

        let firstEvaluation = Task {
            await coordinator.evaluate([limit])
        }
        #expect(await eventually { await sender.isWaitingToSend })
        try await database.repository.resetIndex()
        await sender.resumeSend()
        await firstEvaluation.value

        try await database.repository.migrate()
        await coordinator.evaluate([limit])

        #expect(await sender.sentThresholds == [20, 20])
    }

    @Test func concurrentEvaluationsForTheSameReceiptSendOnlyOnce() async throws {
        let database = try TemporaryNotificationDatabase()
        try await database.repository.migrate()
        let sender = GatedNotificationSender()
        let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)
        let reset = Date(timeIntervalSince1970: 9_000)
        let limit = LimitStatus(window: .fiveHours, usedPercent: 81, resetsAt: reset)

        let firstEvaluation = Task {
            await coordinator.evaluate([limit])
        }
        #expect(await eventually { await sender.isWaitingToSend })
        let secondEvaluation = Task {
            await coordinator.evaluate([limit])
        }
        await secondEvaluation.value

        await sender.resumeSend()
        await firstEvaluation.value

        #expect(await sender.attemptedThresholds == [20])
        #expect(await sender.sentThresholds == [20])
        #expect(try await database.repository.notificationWasSent("five-hours|9000|20"))
    }

    @Test func failedInFlightSendReleasesReceiptForLaterRetry() async throws {
        let database = try TemporaryNotificationDatabase()
        try await database.repository.migrate()
        let sender = GatedNotificationSender(firstSendFails: true)
        let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)
        let reset = Date(timeIntervalSince1970: 10_000)
        let limit = LimitStatus(window: .fiveHours, usedPercent: 81, resetsAt: reset)

        let firstEvaluation = Task {
            await coordinator.evaluate([limit])
        }
        #expect(await eventually { await sender.isWaitingToSend })
        let concurrentEvaluation = Task {
            await coordinator.evaluate([limit])
        }
        await concurrentEvaluation.value

        await sender.resumeSend()
        await firstEvaluation.value
        #expect(try await !database.repository.notificationWasSent("five-hours|10000|20"))

        await coordinator.evaluate([limit])

        #expect(await sender.attemptedThresholds == [20, 20])
        #expect(await sender.sentThresholds == [20])
        #expect(try await database.repository.notificationWasSent("five-hours|10000|20"))
    }

    @Test func concurrentDifferentWindowKeysBothSend() async throws {
        let database = try TemporaryNotificationDatabase()
        try await database.repository.migrate()
        let sender = GatedNotificationSender()
        let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)
        let reset = Date(timeIntervalSince1970: 11_000)
        let fiveHourLimit = LimitStatus(window: .fiveHours, usedPercent: 81, resetsAt: reset)
        let weekLimit = LimitStatus(window: .week, usedPercent: 81, resetsAt: reset)

        let firstEvaluation = Task {
            await coordinator.evaluate([fiveHourLimit])
        }
        #expect(await eventually { await sender.isWaitingToSend })
        let secondEvaluation = Task {
            await coordinator.evaluate([weekLimit])
        }
        await secondEvaluation.value

        await sender.resumeSend()
        await firstEvaluation.value

        #expect(await sender.attemptedThresholds == [20, 20])
        #expect(await sender.sentThresholds == [20, 20])
        #expect(try await database.repository.notificationWasSent("five-hours|11000|20"))
        #expect(try await database.repository.notificationWasSent("week|11000|20"))
    }

    @Test func explicitDeniedAuthorizationKeepsSettingFalseWithoutAutomaticReprompt() async throws {
        let preferences = NotificationPreferencesSpy(enabled: false)
        let center = UserNotificationCenterSpy(authorizationResults: [false])
        let sender = UserNotificationSender(center: center, preferences: preferences)

        #expect(await !sender.isEnabled())
        #expect(await center.authorizationRequestCount == 0)

        #expect(try await !sender.requestAuthorization())
        #expect(await !sender.isEnabled())
        #expect(await center.authorizationRequestCount == 1)

        #expect(await !sender.isEnabled())
        #expect(await center.authorizationRequestCount == 1)
    }

    @Test func explicitGrantedAuthorizationEnablesNotifications() async throws {
        let preferences = NotificationPreferencesSpy(enabled: false)
        let center = UserNotificationCenterSpy(authorizationResults: [true])
        let sender = UserNotificationSender(center: center, preferences: preferences)

        #expect(try await sender.requestAuthorization())

        #expect(await sender.isEnabled())
        #expect(await center.authorizationRequestCount == 1)
    }
}

private actor NotificationSenderSpy: NotificationSending {
    private let enabled: Bool
    private var sendFailures: Int
    private(set) var attemptedThresholds: [Int] = []
    private(set) var sentThresholds: [Int] = []

    init(enabled: Bool = true, sendFailures: Int = 0) {
        self.enabled = enabled
        self.sendFailures = sendFailures
    }

    func isEnabled() async -> Bool { enabled }

    func requestAuthorization() async throws -> Bool { true }

    func send(title: String, body: String, threshold: Int) async throws {
        attemptedThresholds.append(threshold)
        if sendFailures > 0 {
            sendFailures -= 1
            throw NotificationTestFailure()
        }
        sentThresholds.append(threshold)
    }
}

private actor GatedNotificationSender: NotificationSending {
    private var sendContinuation: CheckedContinuation<Void, Never>?
    private var hasGatedSend = false
    private let firstSendFails: Bool
    private(set) var attemptedThresholds: [Int] = []
    private(set) var sentThresholds: [Int] = []

    var isWaitingToSend: Bool { sendContinuation != nil }

    init(firstSendFails: Bool = false) {
        self.firstSendFails = firstSendFails
    }

    func isEnabled() async -> Bool { true }

    func requestAuthorization() async throws -> Bool { true }

    func send(title: String, body: String, threshold: Int) async throws {
        attemptedThresholds.append(threshold)
        let isFirstSend = !hasGatedSend
        if !hasGatedSend {
            hasGatedSend = true
            await withCheckedContinuation { continuation in
                sendContinuation = continuation
            }
        }
        if isFirstSend, firstSendFails {
            throw NotificationTestFailure()
        }
        sentThresholds.append(threshold)
    }

    func resumeSend() {
        sendContinuation?.resume()
        sendContinuation = nil
    }
}

private actor NotificationPreferencesSpy: NotificationPreferenceStoring {
    private var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func isEnabled() async -> Bool { enabled }

    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
    }
}

private actor UserNotificationCenterSpy: UserNotificationCenterServing {
    private var authorizationResults: [Bool]
    private(set) var authorizationRequestCount = 0

    init(authorizationResults: [Bool]) {
        self.authorizationResults = authorizationResults
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        return authorizationResults.removeFirst()
    }

    func send(title: String, body: String) async throws {}
}

private final class TemporaryNotificationDatabase {
    let url: URL
    let repository: UsageRepository

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        repository = try UsageRepository(url: url)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

private struct NotificationTestFailure: Error {}

private func eventually(
    attempts: Int = 100,
    _ condition: @escaping () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
