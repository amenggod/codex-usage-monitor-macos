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
        let limits = LimitAvailabilityPolicy.activeStatuses(
            from: try await repository.latestLimits(),
            now: now
        )
        return Self.makeSnapshot(range: range, rows: rows, limits: limits, now: now)
    }

    func widgetSnapshots(
        now: Date,
        calendar: Calendar
    ) async throws -> WidgetDashboardSnapshots {
        let inputs = try await repository.widgetUsageInputs(
            todayFrom: calendar.startOfDay(for: now),
            to: now
        )
        let limits = LimitAvailabilityPolicy.activeStatuses(from: inputs.limits, now: now)
        return WidgetDashboardSnapshots(
            today: Self.makeSnapshot(
                range: .today,
                rows: inputs.todayRows,
                limits: limits,
                now: now
            ),
            all: Self.makeSnapshot(
                range: .all,
                rows: inputs.allRows,
                limits: limits,
                now: now
            )
        )
    }

    private static func makeSnapshot(
        range: TokenRange,
        rows: [StoredUsageRow],
        limits: [LimitStatus],
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
            freshness: rows.isEmpty ? .noData : .fresh(now)
        )
    }
}
