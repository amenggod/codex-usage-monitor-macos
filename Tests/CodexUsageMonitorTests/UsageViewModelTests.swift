import Foundation
import SQLite3
import Testing
@testable import CodexUsageMonitor

@Suite("UsageViewModelTests")
struct UsageViewModelTests {
    @MainActor
    @Test func retryAfterTransientMigrationFailureMigratesScansAndStartsWatching() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "UsageViewModelMigrationRetry-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sessionsRoot = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let logURL = sessionsRoot.appending(path: "retry.jsonl")
        try Data(
            """
            {"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"retry","cwd":"/synthetic/retry"}}
            {"timestamp":"2026-07-14T01:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":1},"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":1}}}}

            """.utf8
        ).write(to: logURL)
        let databaseURL = directoryURL.appending(path: "index.sqlite")
        let repository = try UsageRepository(url: databaseURL)
        let migrationLock = try SQLiteMigrationLock(url: databaseURL)
        let watcher = RetryWatcher()
        let coordinator = IngestionCoordinator(
            roots: [sessionsRoot],
            repository: repository,
            scanner: SessionScanner(repository: repository),
            watcher: watcher
        )
        let viewModel = UsageViewModel(
            aggregator: UsageAggregator(repository: repository),
            coordinator: coordinator
        )

        await viewModel.start()
        #expect(await eventually {
            if case .failed = viewModel.snapshot.freshness { return true }
            return false
        })
        #expect(watcher.eventsCallCount == 0)
        await viewModel.selectRange(.all)

        migrationLock.release()
        await viewModel.retry()

        #expect(await eventually { viewModel.snapshot.total.total == 1 })
        #expect(try await repository.queryUsage(from: nil, to: .distantFuture).map(\.usage.total) == [1])
        #expect(watcher.eventsCallCount == 1)
        await coordinator.stop()
    }

    @MainActor
    @Test func startIsIdempotentAndSuccessfulRefreshEvaluatesLimits() async {
        let expected = makeSnapshot(total: 10, limits: [makeLimit(usedPercent: 35)])
        let aggregator = AggregatorSpy([.success(expected)])
        let coordinator = CoordinatorSpy()
        let notifier = NotifierSpy()
        let viewModel = UsageViewModel(
            aggregator: aggregator,
            coordinator: coordinator,
            notifier: notifier
        )

        await viewModel.start()
        await viewModel.start()
        await settleAsyncWork()

        #expect(await coordinator.startCount == 1)
        #expect(await aggregator.requestedRanges == [.today])
        #expect(viewModel.snapshot == expected)
        #expect(await notifier.evaluations == [expected.limits])
    }

    @MainActor
    @Test func unavailableWidgetSharingDoesNotReplaceSuccessfulDashboard() async {
        let expected = makeSnapshot(total: 10, limits: [makeLimit(usedPercent: 35)])
        let viewModel = UsageViewModel(
            aggregator: AggregatorSpy([.success(expected)]),
            coordinator: CoordinatorSpy(),
            widgetPublisher: UnavailableWidgetSnapshotPublisher(
                message: "小组件共享不可用"
            )
        )

        await viewModel.start()
        await settleAsyncWork()

        #expect(viewModel.snapshot == expected)
        #expect(viewModel.widgetSharingStatus == .unavailable("小组件共享不可用"))
    }

    @MainActor
    @Test func completedUpdateRefreshesTheDashboard() async {
        let initial = makeSnapshot(total: 10)
        let refreshed = makeSnapshot(total: 25)
        let aggregator = AggregatorSpy([.success(initial), .success(refreshed)])
        let coordinator = CoordinatorSpy()
        let viewModel = UsageViewModel(aggregator: aggregator, coordinator: coordinator)
        await viewModel.start()
        await settleAsyncWork()

        #expect(await aggregator.requestedRanges == [.today])

        await coordinator.send(.completed)

        #expect(await eventually { viewModel.snapshot.total.total == 25 })
        #expect(await aggregator.requestedRanges == [.today, .today])
    }

    @MainActor
    @Test func partialUpdateRefreshesAvailableDataAndReportsFailedFileCount() async {
        let initial = makeSnapshot(total: 10)
        let refreshed = makeSnapshot(total: 25)
        let aggregator = AggregatorSpy([.success(initial), .success(refreshed)])
        let coordinator = CoordinatorSpy()
        let viewModel = UsageViewModel(aggregator: aggregator, coordinator: coordinator)
        await viewModel.start()
        await settleAsyncWork()

        await coordinator.send(.partial(failedFiles: 2))

        #expect(await eventually {
            guard viewModel.snapshot.total.total == 25,
                  case let .partial(_, failedFiles) = viewModel.snapshot.freshness else {
                return false
            }
            return failedFiles == 2
        })
        #expect(await aggregator.requestedRanges == [.today, .today])
    }

    @MainActor
    @Test func partialFreshnessIsPublishedToTheWidget() async {
        let aggregator = AggregatorSpy([
            .success(makeSnapshot(total: 10)),
            .success(makeSnapshot(total: 25)),
        ])
        let coordinator = CoordinatorSpy()
        let widgetPublisher = FreshnessRecordingWidgetPublisher()
        let viewModel = UsageViewModel(
            aggregator: aggregator,
            coordinator: coordinator,
            widgetPublisher: widgetPublisher
        )
        await viewModel.start()
        await settleAsyncWork()

        await coordinator.send(.partial(failedFiles: 2))

        #expect(await eventually {
            guard let freshness = await widgetPublisher.lastFreshness,
                  case let .partial(_, failedFiles) = freshness else {
                return false
            }
            return failedFiles == 2
        })
        #expect(viewModel.snapshot.total.total == 25)
    }

    @MainActor
    @Test func rebuildingUpdateRetainsTheLastDashboardAndOnlyChangesFreshness() async {
        let initial = makeSnapshot(total: 18, limits: [makeLimit(usedPercent: 61)])
        let aggregator = AggregatorSpy([.success(initial)])
        let coordinator = CoordinatorSpy()
        let viewModel = UsageViewModel(aggregator: aggregator, coordinator: coordinator)
        await viewModel.start()
        await settleAsyncWork()

        await coordinator.send(.rebuilding(completed: 1, total: 3))

        #expect(await eventually {
            viewModel.snapshot.freshness == .rebuilding(completed: 1, total: 3)
        })
        #expect(viewModel.snapshot.total == initial.total)
        #expect(viewModel.snapshot.projects == initial.projects)
        #expect(viewModel.snapshot.limits == initial.limits)
        #expect(await aggregator.requestedRanges == [.today])
    }

    @MainActor
    @Test func rebuildingUsesStateOnlyWidgetPublishAndCompletionRecoversFreshPublication() async {
        let initial = makeSnapshot(total: 18, limits: [makeLimit(usedPercent: 61)])
        let refreshed = makeSnapshot(total: 25, limits: [makeLimit(usedPercent: 40)])
        let aggregator = AggregatorSpy([.success(initial), .success(refreshed)])
        let coordinator = CoordinatorSpy()
        let widgetPublisher = FreshnessRecordingWidgetPublisher()
        let viewModel = UsageViewModel(
            aggregator: aggregator,
            coordinator: coordinator,
            widgetPublisher: widgetPublisher
        )
        await viewModel.start()
        #expect(await eventually { await widgetPublisher.freshnessValues.count == 1 })

        await coordinator.send(.rebuilding(completed: 1, total: 3))

        #expect(await eventually { await widgetPublisher.rebuildingRequestCount == 1 })
        #expect(viewModel.snapshot.total == initial.total)
        #expect(await aggregator.requestedRanges == [.today])

        await coordinator.send(.completed)

        #expect(await eventually {
            let publicationCount = await widgetPublisher.freshnessValues.count
            return viewModel.snapshot.total == refreshed.total && publicationCount == 2
        })
        #expect(await widgetPublisher.lastFreshness == refreshed.freshness)
        #expect(await aggregator.requestedRanges == [.today, .today])
    }

    @MainActor
    @Test func rebuildingWidgetFailureDoesNotReplaceTheTrustedDashboard() async {
        let initial = makeSnapshot(total: 18, limits: [makeLimit(usedPercent: 61)])
        let coordinator = CoordinatorSpy()
        let viewModel = UsageViewModel(
            aggregator: AggregatorSpy([.success(initial)]),
            coordinator: coordinator,
            widgetPublisher: RebuildingUnavailableWidgetPublisher()
        )
        await viewModel.start()
        await settleAsyncWork()

        await coordinator.send(.rebuilding(completed: 1, total: 3))

        #expect(await eventually {
            viewModel.widgetSharingStatus == .unavailable("rebuilding store unavailable")
        })
        #expect(viewModel.snapshot.total == initial.total)
        #expect(viewModel.snapshot.projects == initial.projects)
        #expect(viewModel.snapshot.limits == initial.limits)
        #expect(viewModel.snapshot.freshness == .rebuilding(completed: 1, total: 3))
    }

    @MainActor
    @Test func lateRebuildingWidgetFailureCannotOverwriteNewerRefreshStatus() async {
        let initial = makeSnapshot(total: 10)
        let all = makeSnapshot(range: .all, total: 100)
        let currentToday = makeSnapshot(total: 12)
        let coordinator = CoordinatorSpy()
        let widgetPublisher = GatedRebuildingWidgetPublisher()
        let viewModel = UsageViewModel(
            aggregator: AggregatorSpy([
                .success(initial),
                .success(all),
                .success(currentToday),
            ]),
            coordinator: coordinator,
            widgetPublisher: widgetPublisher
        )
        await viewModel.start()
        await settleAsyncWork()

        await coordinator.send(.rebuilding(completed: 1, total: 3))
        #expect(await eventually { await widgetPublisher.hasPendingRebuilding })

        await viewModel.selectRange(.all)
        #expect(viewModel.widgetSharingStatus == .ready(testWidgetStatusDate))

        await widgetPublisher.finishRebuilding(
            with: .unavailable("old rebuilding status")
        )
        await settleAsyncWork()

        #expect(viewModel.snapshot == all)
        #expect(viewModel.widgetSharingStatus == .ready(testWidgetStatusDate))
    }

    @MainActor
    @Test func failedUpdateRetainsTheLastSuccessfulDashboardAsStale() async {
        let initial = makeSnapshot(total: 18, limits: [makeLimit(usedPercent: 61)])
        let aggregator = AggregatorSpy([.success(initial)])
        let coordinator = CoordinatorSpy()
        let viewModel = UsageViewModel(aggregator: aggregator, coordinator: coordinator)
        await viewModel.start()

        await coordinator.send(.failed("watcher stopped"))

        #expect(await eventually {
            if case .stale = viewModel.snapshot.freshness { return true }
            return false
        })
        #expect(viewModel.snapshot.total == initial.total)
        #expect(viewModel.snapshot.projects == initial.projects)
        #expect(viewModel.snapshot.limits == initial.limits)
    }

    @MainActor
    @Test func firstRefreshFailureProducesAnEmptyFailedSnapshot() async {
        let aggregator = AggregatorSpy([.failure("database unavailable")])
        let coordinator = CoordinatorSpy()
        let viewModel = UsageViewModel(aggregator: aggregator, coordinator: coordinator)

        await viewModel.start()
        #expect(await eventually {
            viewModel.snapshot.freshness == .failed("database unavailable")
        })

        #expect(viewModel.snapshot.total == .zero)
        #expect(viewModel.snapshot.projects.isEmpty)
        #expect(viewModel.snapshot.limits.isEmpty)
        #expect(viewModel.snapshot.freshness == .failed("database unavailable"))
    }

    @MainActor
    @Test func selectingRangeRetryingAndRebuildingRefreshWithTheSelectedRange() async {
        let aggregator = AggregatorSpy([
            .success(makeSnapshot(total: 1)),
            .success(makeSnapshot(range: .sevenDays, total: 2)),
            .success(makeSnapshot(total: 10)),
            .success(makeSnapshot(range: .sevenDays, total: 3)),
            .success(makeSnapshot(total: 11)),
            .success(makeSnapshot(range: .sevenDays, total: 4)),
            .success(makeSnapshot(total: 12)),
        ])
        let coordinator = CoordinatorSpy()
        let notifier = NotifierSpy()
        let viewModel = UsageViewModel(
            aggregator: aggregator,
            coordinator: coordinator,
            notifier: notifier
        )
        await viewModel.start()
        await settleAsyncWork()
        #expect(await aggregator.requestedRanges.count == 1)
        #expect(await notifier.evaluations.count == 1)

        await viewModel.selectRange(.sevenDays)
        #expect(await aggregator.requestedRanges.count == 3)
        #expect(await notifier.evaluations.count == 2)

        await viewModel.retry()
        await settleAsyncWork()
        #expect(await aggregator.requestedRanges.count == 5)
        #expect(await notifier.evaluations.count == 3)

        await viewModel.rebuildIndex()
        await settleAsyncWork()

        #expect(viewModel.selectedRange == .sevenDays)
        #expect(viewModel.snapshot.total.total == 4)
        #expect(viewModel.todayTotal.total == 12)
        #expect(await aggregator.requestedRanges == [
            .today,
            .sevenDays, .today,
            .sevenDays, .today,
            .sevenDays, .today,
        ])
        #expect(await coordinator.rescanCount == 1)
        #expect(await coordinator.rebuildCount == 1)
    }

    @MainActor
    @Test func todayTotalRemainsIndependentAcrossLongerRanges() async {
        let aggregator = AggregatorSpy([
            .success(makeSnapshot(total: 12)),
            .success(makeSnapshot(range: .sevenDays, total: 70)),
            .success(makeSnapshot(total: 13)),
            .success(makeSnapshot(range: .all, total: 100)),
            .success(makeSnapshot(total: 14)),
        ])
        let viewModel = UsageViewModel(
            aggregator: aggregator,
            coordinator: CoordinatorSpy()
        )

        await viewModel.start()
        await settleAsyncWork()
        #expect(viewModel.todayTotal.total == 12)

        await viewModel.selectRange(.sevenDays)
        #expect(viewModel.snapshot.total.total == 70)
        #expect(viewModel.todayTotal.total == 13)

        await viewModel.selectRange(.all)
        #expect(viewModel.snapshot.total.total == 100)
        #expect(viewModel.todayTotal.total == 14)
        #expect(await aggregator.requestedRanges == [
            .today,
            .sevenDays, .today,
            .all, .today,
        ])
    }

    @MainActor
    @Test func rebuildFailureRetainsTheLastSuccessfulDashboardAsStale() async {
        let initial = makeSnapshot(total: 12)
        let aggregator = AggregatorSpy([.success(initial)])
        let coordinator = CoordinatorSpy(rebuildFailure: "rebuild failed")
        let viewModel = UsageViewModel(aggregator: aggregator, coordinator: coordinator)
        await viewModel.start()
        await settleAsyncWork()

        await viewModel.rebuildIndex()

        #expect(viewModel.snapshot.total == initial.total)
        if case .stale = viewModel.snapshot.freshness {
            // Expected.
        } else {
            Issue.record("Expected a stale snapshot after rebuild failure")
        }
    }

    @MainActor
    @Test func lateTodaySuccessCannotOverwriteNewerSevenDayResultOrNotifyItsLimits() async {
        let oldToday = makeSnapshot(total: 10, limits: [makeLimit(usedPercent: 10)])
        let currentToday = makeSnapshot(total: 12, limits: [makeLimit(usedPercent: 12)])
        let sevenDays = makeSnapshot(
            range: .sevenDays,
            total: 70,
            limits: [makeLimit(usedPercent: 70)]
        )
        let aggregator = GatedAggregator()
        let coordinator = CoordinatorSpy()
        let notifier = NotifierSpy()
        let viewModel = UsageViewModel(
            aggregator: aggregator,
            coordinator: coordinator,
            notifier: notifier
        )

        await viewModel.start()
        #expect(await eventually { await aggregator.hasRequest(for: .today) })
        let rangeSelection = Task { @MainActor in
            await viewModel.selectRange(.sevenDays)
        }
        #expect(await eventually { await aggregator.hasRequest(for: .sevenDays) })

        await aggregator.succeed(range: .sevenDays, with: sevenDays)
        #expect(await eventually { await aggregator.requestCount(for: .today) == 2 })
        await aggregator.succeedLatest(range: .today, with: currentToday)
        await rangeSelection.value
        await aggregator.succeed(range: .today, with: oldToday)
        await settleAsyncWork()

        #expect(viewModel.selectedRange == .sevenDays)
        #expect(viewModel.snapshot == sevenDays)
        #expect(viewModel.todayTotal == currentToday.total)
        #expect(await notifier.evaluations == [sevenDays.limits])
    }

    @MainActor
    @Test func lateTodayFailureCannotMakeNewerSevenDayResultStale() async {
        let currentToday = makeSnapshot(total: 15)
        let sevenDays = makeSnapshot(
            range: .sevenDays,
            total: 75,
            limits: [makeLimit(usedPercent: 75)]
        )
        let aggregator = GatedAggregator()
        let coordinator = CoordinatorSpy()
        let notifier = NotifierSpy()
        let viewModel = UsageViewModel(
            aggregator: aggregator,
            coordinator: coordinator,
            notifier: notifier
        )

        await viewModel.start()
        #expect(await eventually { await aggregator.hasRequest(for: .today) })
        let rangeSelection = Task { @MainActor in
            await viewModel.selectRange(.sevenDays)
        }
        #expect(await eventually { await aggregator.hasRequest(for: .sevenDays) })

        await aggregator.succeed(range: .sevenDays, with: sevenDays)
        #expect(await eventually { await aggregator.requestCount(for: .today) == 2 })
        await aggregator.succeedLatest(range: .today, with: currentToday)
        await rangeSelection.value
        await aggregator.fail(range: .today, message: "old request failed")
        await settleAsyncWork()

        #expect(viewModel.selectedRange == .sevenDays)
        #expect(viewModel.snapshot == sevenDays)
        #expect(viewModel.todayTotal == currentToday.total)
        #expect(await notifier.evaluations == [sevenDays.limits])
    }

    @MainActor
    @Test func latePartialRefreshCannotMarkANewerRangePartial() async {
        let initial = makeSnapshot(total: 10)
        let refreshedPartial = makeSnapshot(total: 20)
        let currentToday = makeSnapshot(total: 12)
        let sevenDays = makeSnapshot(range: .sevenDays, total: 70)
        let aggregator = GatedAggregator()
        let coordinator = CoordinatorSpy()
        let viewModel = UsageViewModel(aggregator: aggregator, coordinator: coordinator)

        await viewModel.start()
        #expect(await eventually { await aggregator.hasRequest(for: .today) })
        await aggregator.succeed(range: .today, with: initial)
        #expect(await eventually { viewModel.snapshot == initial })

        await coordinator.send(.partial(failedFiles: 2))
        #expect(await eventually { await aggregator.hasRequest(for: .today) })
        let rangeSelection = Task { @MainActor in
            await viewModel.selectRange(.sevenDays)
        }
        #expect(await eventually { await aggregator.hasRequest(for: .sevenDays) })
        await aggregator.succeed(range: .sevenDays, with: sevenDays)
        #expect(await eventually { await aggregator.requestCount(for: .today) == 2 })
        await aggregator.succeedLatest(range: .today, with: currentToday)
        await rangeSelection.value
        await aggregator.succeed(range: .today, with: refreshedPartial)
        await settleAsyncWork()

        #expect(viewModel.snapshot == sevenDays)
        #expect(viewModel.todayTotal == currentToday.total)
    }

    @MainActor
    @Test func lateWidgetStatusCannotOverwriteNewerRefreshStatus() async {
        let initial = makeSnapshot(total: 10)
        let currentToday = makeSnapshot(total: 12)
        let all = makeSnapshot(range: .all, total: 100)
        let widgetPublisher = GatedWidgetStatusPublisher()
        let viewModel = UsageViewModel(
            aggregator: AggregatorSpy([
                .success(initial),
                .success(all),
                .success(currentToday),
            ]),
            coordinator: CoordinatorSpy(),
            widgetPublisher: widgetPublisher
        )

        await viewModel.start()
        #expect(await eventually { await widgetPublisher.requestCount == 1 })
        let rangeSelection = Task { @MainActor in
            await viewModel.selectRange(.all)
        }
        #expect(await eventually { await widgetPublisher.requestCount == 2 })

        await widgetPublisher.succeedLatest(with: .ready(testWidgetStatusDate))
        await rangeSelection.value
        await widgetPublisher.succeedFirst(with: .unavailable("old widget status"))
        await settleAsyncWork()

        #expect(viewModel.snapshot == all)
        #expect(viewModel.widgetSharingStatus == .ready(testWidgetStatusDate))
    }

    @MainActor
    @Test func deinitializationCancelsUpdateConsumption() async {
        let probe = TerminationProbe()
        let aggregator = AggregatorSpy([.success(makeSnapshot(total: 1))])
        let coordinator = CoordinatorSpy(terminationProbe: probe)
        var viewModel: UsageViewModel? = UsageViewModel(
            aggregator: aggregator,
            coordinator: coordinator
        )
        await viewModel?.start()
        await settleAsyncWork()

        viewModel = nil

        #expect(await eventually { probe.isTerminated })
    }
}

private actor GatedAggregator: UsageAggregating {
    private struct PendingRequest {
        let range: TokenRange
        let continuation: CheckedContinuation<DashboardSnapshot, any Error>
    }

    private var pendingRequests: [PendingRequest] = []

    func snapshot(
        range: TokenRange,
        now: Date,
        calendar: Calendar
    ) async throws -> DashboardSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(PendingRequest(range: range, continuation: continuation))
        }
    }

    func hasRequest(for range: TokenRange) -> Bool {
        pendingRequests.contains { $0.range == range }
    }

    func requestCount(for range: TokenRange) -> Int {
        pendingRequests.count { $0.range == range }
    }

    func succeed(range: TokenRange, with snapshot: DashboardSnapshot) {
        guard let index = pendingRequests.firstIndex(where: { $0.range == range }) else {
            Issue.record("No pending request for \(range)")
            return
        }
        pendingRequests.remove(at: index).continuation.resume(returning: snapshot)
    }

    func succeedLatest(range: TokenRange, with snapshot: DashboardSnapshot) {
        guard let index = pendingRequests.lastIndex(where: { $0.range == range }) else {
            Issue.record("No pending request for \(range)")
            return
        }
        pendingRequests.remove(at: index).continuation.resume(returning: snapshot)
    }

    func fail(range: TokenRange, message: String) {
        guard let index = pendingRequests.firstIndex(where: { $0.range == range }) else {
            Issue.record("No pending request for \(range)")
            return
        }
        pendingRequests.remove(at: index).continuation.resume(
            throwing: SpyFailure(message: message)
        )
    }
}

private actor AggregatorSpy: UsageAggregating {
    enum Outcome: Sendable {
        case success(DashboardSnapshot)
        case failure(String)
    }

    private var outcomes: [Outcome]
    private(set) var requestedRanges: [TokenRange] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func snapshot(
        range: TokenRange,
        now: Date,
        calendar: Calendar
    ) async throws -> DashboardSnapshot {
        requestedRanges.append(range)
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        switch outcome {
        case let .success(snapshot):
            return snapshot
        case let .failure(message):
            throw SpyFailure(message: message)
        }
    }
}

private actor CoordinatorSpy: IngestionControlling {
    private let stream: AsyncStream<IngestionUpdate>
    private let continuation: AsyncStream<IngestionUpdate>.Continuation
    private let rebuildFailure: String?
    private(set) var startCount = 0
    private(set) var rescanCount = 0
    private(set) var rebuildCount = 0
    private(set) var stopCount = 0

    init(rebuildFailure: String? = nil, terminationProbe: TerminationProbe? = nil) {
        let pair = AsyncStream<IngestionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(20))
        stream = pair.stream
        continuation = pair.continuation
        self.rebuildFailure = rebuildFailure
        if let terminationProbe {
            pair.continuation.onTermination = { _ in
                terminationProbe.markTerminated()
            }
        }
    }

    func start() async {
        startCount += 1
        continuation.yield(.completed)
    }

    func updates() async -> AsyncStream<IngestionUpdate> {
        stream
    }

    func rescanAll() async {
        rescanCount += 1
        continuation.yield(.completed)
    }

    func rebuildIndex() async throws {
        rebuildCount += 1
        if let rebuildFailure {
            throw SpyFailure(message: rebuildFailure)
        }
        continuation.yield(.completed)
    }

    func stop() async {
        stopCount += 1
        continuation.finish()
    }

    func send(_ update: IngestionUpdate) {
        continuation.yield(update)
    }
}

private actor NotifierSpy: LimitNotifying {
    private(set) var evaluations: [[LimitStatus]] = []

    func evaluate(_ limits: [LimitStatus]) async {
        evaluations.append(limits)
    }
}

private actor FreshnessRecordingWidgetPublisher: WidgetSnapshotPublishing {
    private(set) var freshnessValues: [DataFreshness?] = []
    private(set) var rebuildingRequestCount = 0

    var lastFreshness: DataFreshness? {
        freshnessValues.last ?? nil
    }

    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus {
        freshnessValues.append(nil)
        return .ready(now)
    }

    func publish(
        now: Date,
        calendar: Calendar,
        freshness: DataFreshness?
    ) async -> WidgetSharingStatus {
        freshnessValues.append(freshness)
        return .ready(now)
    }

    func publishRebuilding(now: Date) async -> WidgetSharingStatus {
        rebuildingRequestCount += 1
        return .ready(now)
    }
}

private actor RebuildingUnavailableWidgetPublisher: WidgetSnapshotPublishing {
    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus {
        .ready(now)
    }

    func publishRebuilding(now: Date) async -> WidgetSharingStatus {
        .unavailable("rebuilding store unavailable")
    }
}

private actor GatedRebuildingWidgetPublisher: WidgetSnapshotPublishing {
    private var rebuildingContinuation: CheckedContinuation<WidgetSharingStatus, Never>?

    var hasPendingRebuilding: Bool {
        rebuildingContinuation != nil
    }

    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus {
        .ready(testWidgetStatusDate)
    }

    func publishRebuilding(now: Date) async -> WidgetSharingStatus {
        await withCheckedContinuation { continuation in
            rebuildingContinuation = continuation
        }
    }

    func finishRebuilding(with status: WidgetSharingStatus) {
        rebuildingContinuation?.resume(returning: status)
        rebuildingContinuation = nil
    }
}

private actor GatedWidgetStatusPublisher: WidgetSnapshotPublishing {
    private var continuations: [CheckedContinuation<WidgetSharingStatus, Never>] = []

    var requestCount: Int { continuations.count }

    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func publishRebuilding(now: Date) async -> WidgetSharingStatus {
        .ready(now)
    }

    func succeedFirst(with status: WidgetSharingStatus) {
        guard !continuations.isEmpty else {
            Issue.record("No pending widget status request")
            return
        }
        continuations.removeFirst().resume(returning: status)
    }

    func succeedLatest(with status: WidgetSharingStatus) {
        guard !continuations.isEmpty else {
            Issue.record("No pending widget status request")
            return
        }
        continuations.removeLast().resume(returning: status)
    }
}

private struct SpyFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private final class TerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false

    var isTerminated: Bool {
        lock.withLock { terminated }
    }

    func markTerminated() {
        lock.withLock { terminated = true }
    }
}

private final class RetryWatcher: SessionFileWatching, @unchecked Sendable {
    private let lock = NSLock()
    private let pair = AsyncStream<Void>.makeStream()
    private var eventCalls = 0

    var startupFailure: String? { nil }
    var eventsCallCount: Int { lock.withLock { eventCalls } }

    func events() -> AsyncStream<Void> {
        lock.withLock { eventCalls += 1 }
        return pair.stream
    }

    func stop() {
        pair.continuation.finish()
    }
}

private final class SQLiteMigrationLock {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            throw SpyFailure(message: "could not open migration lock: \(result)")
        }
        let lockResult = sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil)
        guard lockResult == SQLITE_OK else {
            sqlite3_close(handle)
            self.handle = nil
            throw SpyFailure(message: "could not acquire migration lock: \(lockResult)")
        }
    }

    func release() {
        guard let handle else { return }
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close(handle)
        self.handle = nil
    }

    deinit {
        release()
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

private func settleAsyncWork() async {
    try? await Task.sleep(for: .milliseconds(50))
}

private let testWidgetStatusDate = Date(timeIntervalSince1970: 1_784_164_800)

private func makeSnapshot(
    range: TokenRange = .today,
    total: Int64,
    limits: [LimitStatus] = []
) -> DashboardSnapshot {
    let usage = TokenUsage(
        input: total,
        cachedInput: 0,
        output: 0,
        reasoningOutput: 0,
        total: total
    )
    return DashboardSnapshot(
        range: range,
        total: usage,
        projects: [ProjectUsage(id: "project", displayName: "Project", fullPath: nil, usage: usage)],
        limits: limits,
        freshness: .fresh(Date(timeIntervalSince1970: 1_783_975_200))
    )
}

private func makeLimit(usedPercent: Double) -> LimitStatus {
    LimitStatus(
        window: .fiveHours,
        usedPercent: usedPercent,
        resetsAt: Date(timeIntervalSince1970: 1_783_978_800)
    )
}
