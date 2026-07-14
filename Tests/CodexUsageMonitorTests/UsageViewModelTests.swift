import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("UsageViewModelTests")
struct UsageViewModelTests {
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

        #expect(await coordinator.startCount == 1)
        #expect(await aggregator.requestedRanges == [.today])
        #expect(viewModel.snapshot == expected)
        #expect(await notifier.evaluations == [expected.limits])
    }

    @MainActor
    @Test func completedUpdateRefreshesTheDashboard() async {
        let initial = makeSnapshot(total: 10)
        let refreshed = makeSnapshot(total: 25)
        let aggregator = AggregatorSpy([.success(initial), .success(refreshed)])
        let coordinator = CoordinatorSpy()
        let viewModel = UsageViewModel(aggregator: aggregator, coordinator: coordinator)
        await viewModel.start()

        await coordinator.send(.completed)

        #expect(await eventually { viewModel.snapshot.total.total == 25 })
        #expect(await aggregator.requestedRanges == [.today, .today])
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
            .success(makeSnapshot(range: .sevenDays, total: 3)),
            .success(makeSnapshot(range: .sevenDays, total: 4)),
        ])
        let coordinator = CoordinatorSpy()
        let viewModel = UsageViewModel(aggregator: aggregator, coordinator: coordinator)
        await viewModel.start()

        await viewModel.selectRange(.sevenDays)
        await viewModel.retry()
        await viewModel.rebuildIndex()

        #expect(viewModel.selectedRange == .sevenDays)
        #expect(viewModel.snapshot.total.total == 4)
        #expect(await aggregator.requestedRanges == [.today, .sevenDays, .sevenDays, .sevenDays])
        #expect(await coordinator.rescanCount == 1)
        #expect(await coordinator.rebuildCount == 1)
    }

    @MainActor
    @Test func rebuildFailureRetainsTheLastSuccessfulDashboardAsStale() async {
        let initial = makeSnapshot(total: 12)
        let aggregator = AggregatorSpy([.success(initial)])
        let coordinator = CoordinatorSpy(rebuildFailure: "rebuild failed")
        let viewModel = UsageViewModel(aggregator: aggregator, coordinator: coordinator)
        await viewModel.start()

        await viewModel.rebuildIndex()

        #expect(viewModel.snapshot.total == initial.total)
        if case .stale = viewModel.snapshot.freshness {
            // Expected.
        } else {
            Issue.record("Expected a stale snapshot after rebuild failure")
        }
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

        viewModel = nil

        #expect(await eventually { probe.isTerminated })
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
    }

    func updates() async -> AsyncStream<IngestionUpdate> {
        stream
    }

    func rescanAll() async {
        rescanCount += 1
    }

    func rebuildIndex() async throws {
        rebuildCount += 1
        if let rebuildFailure {
            throw SpyFailure(message: rebuildFailure)
        }
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
