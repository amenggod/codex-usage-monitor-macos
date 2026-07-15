import Foundation
import SQLite3
import Testing
@testable import CodexUsageMonitor

@Suite("NotificationCoordinatorTests")
struct NotificationCoordinatorTests {
    @Test func filteredExpiredLimitsDoNotSendNotifications() async throws {
        let database = try TemporaryNotificationDatabase()
        try await database.repository.migrate()
        let sender = NotificationSenderSpy()
        let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)
        let now = Date(timeIntervalSince1970: 2_000)
        let expired = RateLimitObservation(
            limitID: "codex",
            window: .fiveHours,
            usedPercent: 95,
            resetsAt: now,
            observedAt: now.addingTimeInterval(-100)
        )

        await coordinator.evaluate(LimitAvailabilityPolicy.activeStatuses(from: [expired], now: now))

        #expect(await sender.attemptedThresholds.isEmpty)
    }

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

    @Test func coordinatorRebuildPreservesReceiptAndNewResetStillSends() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "NotificationRebuildTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sessionsRoot = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let logURL = sessionsRoot.appending(path: "limits.jsonl")
        try Data(notificationLimitLog(reset: 2_000).utf8).write(to: logURL)
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let watcher = SessionFileWatcher(roots: [sessionsRoot])
        let ingestion = IngestionCoordinator(
            roots: [sessionsRoot],
            repository: repository,
            scanner: scanner,
            watcher: watcher
        )
        let sender = NotificationSenderSpy()
        let notifier = NotificationCoordinator(repository: repository, sender: sender)

        await ingestion.start()
        await notifier.evaluate(try await notificationLimitStatuses(repository: repository))
        #expect(await sender.sentThresholds == [20])

        try await ingestion.rebuildIndex()
        await notifier.evaluate(try await notificationLimitStatuses(repository: repository))
        #expect(await sender.sentThresholds == [20])

        try appendNotificationLimit(reset: 4_000, to: logURL)
        await ingestion.rescanAll()
        await notifier.evaluate(try await notificationLimitStatuses(repository: repository))
        #expect(await sender.sentThresholds == [20, 20])

        await ingestion.stop()
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

    @Test func notificationPolicySupportsOffOnlyTwentyOnlyTenAndBoth() async throws {
        let policies: [(enabled: Bool, thresholds: Set<Int>, expected: [Int])] = [
            (false, [20, 10], []),
            (true, [20], [20]),
            (true, [10], [10]),
            (true, [20, 10], [20, 10]),
        ]

        for (index, policy) in policies.enumerated() {
            let database = try TemporaryNotificationDatabase()
            try await database.repository.migrate()
            let sender = NotificationSenderSpy(
                enabled: policy.enabled,
                enabledThresholds: policy.thresholds
            )
            let coordinator = NotificationCoordinator(repository: database.repository, sender: sender)

            await coordinator.evaluate([
                LimitStatus(
                    window: .fiveHours,
                    usedPercent: 91,
                    resetsAt: Date(timeIntervalSince1970: Double(20_000 + index))
                ),
            ])

            #expect(await sender.sentThresholds == policy.expected)
        }
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
        try removeNotificationReceiptSchema(at: database.url)
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

    @Test func preferencesPersistTotalAndThresholdChoicesAcrossReopen() async throws {
        let suiteName = "NotificationPreferencesTests-\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let first = UserDefaultsNotificationPreferences(
            defaults: try #require(UserDefaults(suiteName: suiteName))
        )

        #expect(await !first.isEnabled())
        #expect(await first.isThresholdEnabled(20))
        #expect(await first.isThresholdEnabled(10))
        await first.setEnabled(true)
        await first.setThresholdEnabled(false, threshold: 20)

        let reopened = UserDefaultsNotificationPreferences(
            defaults: try #require(UserDefaults(suiteName: suiteName))
        )
        #expect(await reopened.isEnabled())
        #expect(await !reopened.isThresholdEnabled(20))
        #expect(await reopened.isThresholdEnabled(10))
    }

    @Test func turningOffDoesNotPromptAndDeniedExplicitReenableStaysOff() async throws {
        let preferences = NotificationPreferencesSpy(enabled: true)
        let center = UserNotificationCenterSpy(authorizationResults: [false])
        let sender = UserNotificationSender(center: center, preferences: preferences)

        await sender.setEnabled(false)
        #expect(await !sender.isEnabled())
        #expect(await center.authorizationRequestCount == 0)

        #expect(try await !sender.requestAuthorization())
        #expect(await !sender.isEnabled())
        #expect(await center.authorizationRequestCount == 1)
    }
}

private actor NotificationSenderSpy: NotificationSending {
    private var enabled: Bool
    private var enabledThresholds: Set<Int>
    private var sendFailures: Int
    private(set) var attemptedThresholds: [Int] = []
    private(set) var sentThresholds: [Int] = []

    init(
        enabled: Bool = true,
        enabledThresholds: Set<Int> = [20, 10],
        sendFailures: Int = 0
    ) {
        self.enabled = enabled
        self.enabledThresholds = enabledThresholds
        self.sendFailures = sendFailures
    }

    func isEnabled() async -> Bool { enabled }

    func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
    }

    func requestAuthorization() async throws -> Bool { true }

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

    func setEnabled(_ enabled: Bool) async {}

    func setThresholdEnabled(_ enabled: Bool, threshold: Int) async {}

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
    private var enabledThresholds: Set<Int>

    init(enabled: Bool, enabledThresholds: Set<Int> = [20, 10]) {
        self.enabled = enabled
        self.enabledThresholds = enabledThresholds
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

private struct NotificationSQLiteFixtureFailure: Error {
    let code: Int32
}

private func removeNotificationReceiptSchema(at url: URL) throws {
    var handle: OpaquePointer?
    let openResult = sqlite3_open_v2(
        url.path,
        &handle,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openResult == SQLITE_OK, let handle else {
        throw NotificationSQLiteFixtureFailure(code: openResult)
    }
    defer { sqlite3_close(handle) }
    let result = sqlite3_exec(
        handle,
        "DROP TABLE notification_receipts; PRAGMA user_version = 0;",
        nil,
        nil,
        nil
    )
    guard result == SQLITE_OK else {
        throw NotificationSQLiteFixtureFailure(code: result)
    }
}

private func notificationLimitLog(reset: Int) -> String {
    """
    {"timestamp":"2026-07-15T03:00:00Z","type":"session_meta","payload":{"id":"notification-rebuild","cwd":"/synthetic/notification-rebuild"}}
    {"timestamp":"2026-07-15T03:00:01Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":81,"window_minutes":300,"resets_at":\(reset)}}}}
    """ + "\n"
}

private func appendNotificationLimit(reset: Int, to url: URL) throws {
    let line = """
    {"timestamp":"2026-07-15T03:00:02Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":81,"window_minutes":300,"resets_at":\(reset)}}}}
    """ + "\n"
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(line.utf8))
}

private func notificationLimitStatuses(repository: UsageRepository) async throws -> [LimitStatus] {
    try await repository.latestLimits().map {
        LimitStatus(window: $0.window, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
    }
}

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
