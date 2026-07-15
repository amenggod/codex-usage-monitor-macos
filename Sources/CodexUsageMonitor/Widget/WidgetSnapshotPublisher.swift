import CodexUsageShared
import Foundation

enum WidgetSharingStatus: Equatable, Sendable {
    case ready(Date)
    case unavailable(String)
}

protocol WidgetSnapshotPublishing: Sendable {
    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus
}

protocol WidgetTimelineReloading: Sendable {
    func reloadUsageWidget()
}

actor WidgetSnapshotPublisher: WidgetSnapshotPublishing {
    private let aggregator: any UsageAggregating
    private let store: any WidgetSnapshotStoring
    private let reloader: any WidgetTimelineReloading
    private var lastFingerprint: WidgetSnapshotFingerprint?

    init(
        aggregator: any UsageAggregating,
        store: any WidgetSnapshotStoring,
        reloader: any WidgetTimelineReloading
    ) {
        self.aggregator = aggregator
        self.store = store
        self.reloader = reloader
    }

    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus {
        do {
            let today = try await aggregator.snapshot(range: .today, now: now, calendar: calendar)
            let all = try await aggregator.snapshot(range: .all, now: now, calendar: calendar)
            let snapshot = WidgetUsageSnapshot.project(today: today, all: all, now: now)
            let fingerprint = WidgetSnapshotFingerprint(snapshot)
            try store.write(snapshot)
            if fingerprint != lastFingerprint {
                reloader.reloadUsageWidget()
                lastFingerprint = fingerprint
            }
            return .ready(now)
        } catch {
            return .unavailable("小组件共享不可用")
        }
    }
}

struct UnavailableWidgetSnapshotPublisher: WidgetSnapshotPublishing {
    let message: String

    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus {
        .unavailable(message)
    }
}

private struct WidgetSnapshotFingerprint: Equatable, Sendable {
    let todayTokens: Int64
    let allTimeTokens: Int64
    let fiveHourLimit: WidgetLimitStatus?
    let weekLimit: WidgetLimitStatus?
    let projects: [WidgetProjectUsage]
    let stateKind: String
    let failedFiles: Int?

    init(_ snapshot: WidgetUsageSnapshot) {
        todayTokens = snapshot.todayTokens
        allTimeTokens = snapshot.allTimeTokens
        fiveHourLimit = snapshot.fiveHourLimit
        weekLimit = snapshot.weekLimit
        projects = snapshot.projects
        switch snapshot.state {
        case .fresh:
            stateKind = "fresh"
            failedFiles = nil
        case let .partial(_, count):
            stateKind = "partial"
            failedFiles = count
        case .rebuilding:
            stateKind = "rebuilding"
            failedFiles = nil
        case .stale:
            stateKind = "stale"
            failedFiles = nil
        case .noData:
            stateKind = "noData"
            failedFiles = nil
        case .failed:
            stateKind = "failed"
            failedFiles = nil
        }
    }
}

private extension WidgetUsageSnapshot {
    static func project(
        today: DashboardSnapshot,
        all: DashboardSnapshot,
        now: Date
    ) -> Self {
        let activeLimits = today.limits.filter { $0.resetsAt > now }
        return Self(
            generatedAt: now,
            todayTokens: today.total.total,
            allTimeTokens: all.total.total,
            fiveHourLimit: activeLimits.first { $0.window == .fiveHours }.map {
                WidgetLimitStatus(
                    id: $0.limitID,
                    remainingPercent: $0.remainingPercent,
                    resetsAt: $0.resetsAt
                )
            },
            weekLimit: activeLimits.first { $0.window == .week }.map {
                WidgetLimitStatus(
                    id: $0.limitID,
                    remainingPercent: $0.remainingPercent,
                    resetsAt: $0.resetsAt
                )
            },
            projects: all.projects.prefix(3).map {
                WidgetProjectUsage(
                    id: $0.id,
                    name: $0.displayName,
                    tokens: $0.usage.total
                )
            },
            state: today.freshness.widgetState
        )
    }
}

private extension DataFreshness {
    var widgetState: WidgetDataState {
        switch self {
        case let .fresh(date): .fresh(lastSuccessfulAt: date)
        case let .stale(date): .stale(lastSuccessfulAt: date)
        case let .partial(date, failedFiles):
            .partial(lastSuccessfulAt: date, failedFiles: failedFiles)
        case .rebuilding: .rebuilding(lastSuccessfulAt: nil)
        case .noData, .loading: .noData
        case .failed: .failed
        }
    }
}
