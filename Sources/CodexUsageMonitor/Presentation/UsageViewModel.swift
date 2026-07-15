import Foundation
import Observation

protocol IngestionControlling: Sendable {
    func start() async
    func updates() async -> AsyncStream<IngestionUpdate>
    func rescanAll() async
    func rebuildIndex() async throws
    func stop() async
}

extension IngestionCoordinator: IngestionControlling {}

protocol LimitNotifying: Sendable {
    func evaluate(_ limits: [LimitStatus]) async
}

actor NoopLimitNotifier: LimitNotifying {
    func evaluate(_ limits: [LimitStatus]) async {}
}

@MainActor
@Observable
final class UsageViewModel {
    private(set) var snapshot: DashboardSnapshot = .loading
    private(set) var selectedRange: TokenRange = .today

    private let aggregator: any UsageAggregating
    private let coordinator: any IngestionControlling
    private let notifier: any LimitNotifying
    @ObservationIgnored
    private nonisolated(unsafe) var updateTask: Task<Void, Never>?
    private var hasStarted = false
    private var lastSuccessfulAt: Date?
    private var refreshGeneration: UInt64 = 0

    init(
        aggregator: any UsageAggregating,
        coordinator: any IngestionControlling,
        notifier: any LimitNotifying = NoopLimitNotifier()
    ) {
        self.aggregator = aggregator
        self.coordinator = coordinator
        self.notifier = notifier
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let updates = await coordinator.updates()
        updateTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                await self?.handle(update)
            }
        }
        await coordinator.start()
    }

    func selectRange(_ range: TokenRange) async {
        selectedRange = range
        await refresh()
    }

    func retry() async {
        await coordinator.rescanAll()
    }

    func rebuildIndex() async {
        do {
            try await coordinator.rebuildIndex()
        } catch {
            invalidateRefreshAndApply(error)
        }
    }

    private func handle(_ update: IngestionUpdate) async {
        switch update {
        case .completed:
            await refresh()
        case let .partial(failedFiles):
            await refresh()
            applyPartial(failedFiles: failedFiles)
        case let .rebuilding(completed, total):
            refreshGeneration &+= 1
            snapshot = DashboardSnapshot(
                range: selectedRange,
                total: snapshot.total,
                projects: snapshot.projects,
                limits: snapshot.limits,
                freshness: .rebuilding(completed: completed, total: total)
            )
        case let .failed(message):
            invalidateRefreshAndApply(IngestionFailure(message: message))
        }
    }

    private func applyPartial(failedFiles: Int) {
        guard let lastSuccessfulAt else { return }
        snapshot = DashboardSnapshot(
            range: selectedRange,
            total: snapshot.total,
            projects: snapshot.projects,
            limits: snapshot.limits,
            freshness: .partial(lastSuccessfulAt, failedFiles: failedFiles)
        )
    }

    private func refresh(now: Date = .now, calendar: Calendar = .current) async {
        let range = selectedRange
        refreshGeneration &+= 1
        let generation = refreshGeneration

        do {
            let refreshedSnapshot = try await aggregator.snapshot(
                range: range,
                now: now,
                calendar: calendar
            )
            guard generation == refreshGeneration, range == selectedRange else { return }
            snapshot = refreshedSnapshot
            lastSuccessfulAt = now
            await notifier.evaluate(refreshedSnapshot.limits)
        } catch {
            guard generation == refreshGeneration, range == selectedRange else { return }
            apply(error)
        }
    }

    private func invalidateRefreshAndApply(_ error: Error) {
        refreshGeneration &+= 1
        apply(error)
    }

    private func apply(_ error: Error) {
        if let lastSuccessfulAt {
            snapshot = DashboardSnapshot(
                range: selectedRange,
                total: snapshot.total,
                projects: snapshot.projects,
                limits: snapshot.limits,
                freshness: .stale(lastSuccessfulAt)
            )
        } else {
            snapshot = DashboardSnapshot(
                range: selectedRange,
                total: .zero,
                projects: [],
                limits: [],
                freshness: .failed(error.localizedDescription)
            )
        }
    }

    deinit {
        updateTask?.cancel()
    }
}

private struct IngestionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
