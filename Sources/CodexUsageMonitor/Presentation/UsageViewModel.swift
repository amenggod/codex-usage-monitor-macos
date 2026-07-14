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
        await coordinator.start()
        await refresh()
        let updates = await coordinator.updates()
        updateTask = Task { [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled else { return }
                switch update {
                case .completed:
                    await self.refresh()
                case let .failed(message):
                    self.apply(IngestionFailure(message: message))
                }
            }
        }
    }

    func selectRange(_ range: TokenRange) async {
        selectedRange = range
        await refresh()
    }

    func retry() async {
        await coordinator.rescanAll()
        await refresh()
    }

    func rebuildIndex() async {
        do {
            try await coordinator.rebuildIndex()
            await refresh()
        } catch {
            apply(error)
        }
    }

    private func refresh(now: Date = .now, calendar: Calendar = .current) async {
        do {
            snapshot = try await aggregator.snapshot(
                range: selectedRange,
                now: now,
                calendar: calendar
            )
            lastSuccessfulAt = now
            await notifier.evaluate(snapshot.limits)
        } catch {
            apply(error)
        }
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
