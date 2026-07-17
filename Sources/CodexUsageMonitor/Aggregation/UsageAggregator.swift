import Foundation

struct WidgetDashboardSnapshots: Sendable {
    let today: DashboardSnapshot
    let all: DashboardSnapshot
}

protocol UsageAggregating: Sendable {
    func snapshot(range: TokenRange, now: Date, calendar: Calendar) async throws -> DashboardSnapshot
}

protocol WidgetSnapshotAggregating: Sendable {
    func widgetSnapshots(now: Date, calendar: Calendar) async throws -> WidgetDashboardSnapshots
}

struct UsageAggregator: UsageAggregating, WidgetSnapshotAggregating, Sendable {
    struct Bounds: Equatable, Sendable {
        let start: Date?
        let end: Date
    }

    let repository: UsageRepository
    let limitProvider: any LiveRateLimitProviding

    init(
        repository: UsageRepository,
        limitProvider: any LiveRateLimitProviding = UnavailableLiveRateLimitProvider()
    ) {
        self.repository = repository
        self.limitProvider = limitProvider
    }

    static func bounds(for range: TokenRange, now: Date, calendar: Calendar) -> Bounds {
        switch range {
        case .today:
            Bounds(start: calendar.startOfDay(for: now), end: now)
        case .sevenDays:
            Bounds(start: now.addingTimeInterval(-7 * 24 * 60 * 60), end: now)
        case .all:
            Bounds(start: nil, end: now)
        }
    }

    func snapshot(
        range: TokenRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) async throws -> DashboardSnapshot {
        let bounds = Self.bounds(for: range, now: now, calendar: calendar)
        let rows = try await repository.queryUsage(from: bounds.start, to: bounds.end)
        let liveState = await limitProvider.state(now: now)
        return Self.makeSnapshot(
            range: range,
            rows: rows,
            limits: Self.activeLimits(from: liveState, now: now),
            limitFreshness: liveState.dashboardFreshness,
            now: now
        )
    }

    func widgetSnapshots(
        now: Date,
        calendar: Calendar
    ) async throws -> WidgetDashboardSnapshots {
        let inputs = try await repository.widgetUsageInputs(
            todayFrom: calendar.startOfDay(for: now),
            to: now
        )
        let liveState = await limitProvider.state(now: now)
        let limits = Self.activeLimits(from: liveState, now: now)
        let limitFreshness = liveState.dashboardFreshness
        return WidgetDashboardSnapshots(
            today: Self.makeSnapshot(
                range: .today,
                rows: inputs.todayRows,
                limits: limits,
                limitFreshness: limitFreshness,
                now: now
            ),
            all: Self.makeSnapshot(
                range: .all,
                rows: inputs.allRows,
                limits: limits,
                limitFreshness: limitFreshness,
                now: now
            )
        )
    }

    private static func makeSnapshot(
        range: TokenRange,
        rows: [StoredUsageRow],
        limits: [LimitStatus],
        limitFreshness: LimitDataFreshness,
        now: Date
    ) -> DashboardSnapshot {
        let duplicateNames = Dictionary(grouping: rows, by: \.projectName)
            .filter { $0.value.count > 1 }
            .keys

        let projects = rows.map { row in
            let displayName: String
            if duplicateNames.contains(row.projectName), let fullPath = row.fullPath {
                let parentDirectory = URL(fileURLWithPath: fullPath)
                    .deletingLastPathComponent()
                    .lastPathComponent
                displayName = parentDirectory.isEmpty
                    ? row.projectName
                    : "\(row.projectName) — \(parentDirectory)"
            } else {
                displayName = row.projectName
            }

            return ProjectUsage(
                id: row.projectKey,
                displayName: displayName,
                fullPath: row.fullPath,
                usage: row.usage
            )
        }.sorted {
            if $0.usage.total != $1.usage.total {
                return $0.usage.total > $1.usage.total
            }
            return $0.displayName < $1.displayName
        }

        let total = projects.reduce(TokenUsage.zero) { partial, project in
            TokenUsage(
                input: partial.input + project.usage.input,
                cachedInput: partial.cachedInput + project.usage.cachedInput,
                output: partial.output + project.usage.output,
                reasoningOutput: partial.reasoningOutput + project.usage.reasoningOutput,
                total: partial.total + project.usage.total
            )
        }

        return DashboardSnapshot(
            range: range,
            total: total,
            projects: projects,
            limits: limits,
            freshness: rows.isEmpty ? .noData : .fresh(now),
            limitFreshness: limitFreshness
        )
    }

    private static func activeLimits(
        from state: LiveRateLimitState,
        now: Date
    ) -> [LimitStatus] {
        state.limits
            .filter { $0.limitID == "codex" && $0.resetsAt > now }
            .sorted { $0.window.minutes < $1.window.minutes }
    }
}

private struct UnavailableLiveRateLimitProvider: LiveRateLimitProviding {
    func state(now: Date) async -> LiveRateLimitState {
        .unavailable(lastSuccessfulAt: nil, message: "等待实时限额")
    }
}

private extension LiveRateLimitState {
    var dashboardFreshness: LimitDataFreshness {
        switch self {
        case let .fresh(_, observedAt): .fresh(observedAt)
        case let .stale(_, observedAt): .stale(observedAt)
        case let .unavailable(lastSuccessfulAt, message):
            .unavailable(lastSuccessfulAt: lastSuccessfulAt, message: message)
        }
    }
}
