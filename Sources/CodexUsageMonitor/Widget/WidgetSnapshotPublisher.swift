import CodexUsageShared
import CryptoKit
import Foundation

enum WidgetSharingStatus: Equatable, Sendable {
    case ready(Date)
    case unavailable(String)
}

protocol WidgetSnapshotPublishing: Sendable {
    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus
    func publish(
        now: Date,
        calendar: Calendar,
        freshness: DataFreshness?
    ) async -> WidgetSharingStatus
    func publishRebuilding(now: Date) async -> WidgetSharingStatus
}

extension WidgetSnapshotPublishing {
    func publish(
        now: Date,
        calendar: Calendar,
        freshness: DataFreshness?
    ) async -> WidgetSharingStatus {
        await publish(now: now, calendar: calendar)
    }
}

protocol WidgetTimelineReloading: Sendable {
    func reloadUsageWidget()
}

actor WidgetSnapshotPublisher: WidgetSnapshotPublishing {
    private let aggregator: any WidgetSnapshotAggregating
    private let store: any WidgetSnapshotStoring
    private let reloader: any WidgetTimelineReloading
    private let changePoster: any UsageSnapshotChangePosting
    private var lastFingerprint: WidgetSnapshotFingerprint?
    private var requestSequence: UInt64 = 0
    private var newestRequest: WidgetPublicationRequest?

    init(
        aggregator: any WidgetSnapshotAggregating,
        store: any WidgetSnapshotStoring,
        reloader: any WidgetTimelineReloading,
        changePoster: any UsageSnapshotChangePosting =
            DarwinUsageSnapshotChangePoster()
    ) {
        self.aggregator = aggregator
        self.store = store
        self.reloader = reloader
        self.changePoster = changePoster
    }

    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus {
        await publish(now: now, calendar: calendar, freshness: nil)
    }

    func publish(
        now: Date,
        calendar: Calendar,
        freshness: DataFreshness?
    ) async -> WidgetSharingStatus {
        let request = registerRequest(now: now)

        do {
            let dashboards = try await aggregator.widgetSnapshots(now: now, calendar: calendar)
            guard newestRequest == request else { return .ready(now) }
            let snapshot = WidgetUsageSnapshot.project(
                today: dashboards.today,
                all: dashboards.all,
                now: now,
                freshness: freshness
            )
            let fingerprint = WidgetSnapshotFingerprint(snapshot)
            try store.write(snapshot)
            changePoster.postSnapshotChanged()
            if fingerprint != lastFingerprint {
                reloader.reloadUsageWidget()
                lastFingerprint = fingerprint
            }
            return .ready(now)
        } catch {
            guard newestRequest == request else { return .ready(now) }
            return .unavailable("小组件共享不可用")
        }
    }

    func publishRebuilding(now: Date) async -> WidgetSharingStatus {
        let request = registerRequest(now: now)

        do {
            let existing = try store.read()
            guard newestRequest == request else { return .ready(now) }
            let snapshot = existing?.replacingState(
                .rebuilding(lastSuccessfulAt: existing?.reliableLastSuccessfulAt)
            ) ?? WidgetUsageSnapshot(
                generatedAt: now,
                todayTokens: 0,
                allTimeTokens: 0,
                fiveHourLimit: nil,
                weekLimit: nil,
                limitFreshness: .unavailable,
                projects: [],
                state: .rebuilding(lastSuccessfulAt: nil)
            )
            let fingerprint = WidgetSnapshotFingerprint(snapshot)
            try store.write(snapshot)
            changePoster.postSnapshotChanged()
            if fingerprint != lastFingerprint {
                reloader.reloadUsageWidget()
                lastFingerprint = fingerprint
            }
            return .ready(now)
        } catch {
            guard newestRequest == request else { return .ready(now) }
            return .unavailable("小组件共享不可用")
        }
    }

    private func registerRequest(now: Date) -> WidgetPublicationRequest {
        requestSequence &+= 1
        let request = WidgetPublicationRequest(now: now, sequence: requestSequence)
        if let newestRequest {
            if request.isNewer(than: newestRequest) {
                self.newestRequest = request
            }
        } else {
            newestRequest = request
        }
        return request
    }
}

struct UnavailableWidgetSnapshotPublisher: WidgetSnapshotPublishing {
    let message: String

    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus {
        .unavailable(message)
    }

    func publishRebuilding(now: Date) async -> WidgetSharingStatus {
        .unavailable(message)
    }
}

private struct WidgetSnapshotFingerprint: Equatable, Sendable {
    let todayTokens: Int64
    let allTimeTokens: Int64
    let fiveHourLimit: WidgetLimitStatus?
    let weekLimit: WidgetLimitStatus?
    let limitFreshnessKind: WidgetLimitFreshnessKind
    let projects: [WidgetProjectUsage]
    let stateKind: String
    let failedFiles: Int?

    init(_ snapshot: WidgetUsageSnapshot) {
        todayTokens = snapshot.todayTokens
        allTimeTokens = snapshot.allTimeTokens
        fiveHourLimit = snapshot.fiveHourLimit
        weekLimit = snapshot.weekLimit
        limitFreshnessKind = WidgetLimitFreshnessKind(snapshot.limitFreshness)
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

private enum WidgetLimitFreshnessKind: Equatable, Sendable {
    case fresh
    case stale
    case unavailable

    init(_ freshness: WidgetLimitFreshness) {
        switch freshness {
        case .fresh:
            self = .fresh
        case .stale:
            self = .stale
        case .unavailable:
            self = .unavailable
        }
    }
}

private struct WidgetPublicationRequest: Equatable, Sendable {
    let now: Date
    let sequence: UInt64

    func isNewer(than other: Self) -> Bool {
        now > other.now || (now == other.now && sequence > other.sequence)
    }
}

private extension WidgetUsageSnapshot {
    var reliableLastSuccessfulAt: Date? {
        switch state {
        case let .fresh(lastSuccessfulAt),
             let .partial(lastSuccessfulAt, _),
             let .stale(lastSuccessfulAt):
            lastSuccessfulAt
        case let .rebuilding(lastSuccessfulAt):
            lastSuccessfulAt
        case .noData, .failed:
            nil
        }
    }

    func replacingState(_ state: WidgetDataState) -> Self {
        Self(
            generatedAt: generatedAt,
            todayTokens: todayTokens,
            allTimeTokens: allTimeTokens,
            fiveHourLimit: fiveHourLimit,
            weekLimit: weekLimit,
            limitFreshness: limitFreshness,
            projects: projects,
            state: state
        )
    }

    static func project(
        today: DashboardSnapshot,
        all: DashboardSnapshot,
        now: Date,
        freshness: DataFreshness?
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
            limitFreshness: today.limitFreshness.widgetFreshness,
            projects: all.projects.prefix(3).map {
                WidgetProjectUsage(
                    id: opaqueProjectID($0.id),
                    name: $0.displayName,
                    tokens: $0.usage.total
                )
            },
            state: (freshness ?? today.freshness).widgetState
        )
    }

    static func opaqueProjectID(_ projectKey: String) -> String {
        SHA256.hash(data: Data(projectKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension LimitDataFreshness {
    var widgetFreshness: WidgetLimitFreshness {
        switch self {
        case let .fresh(observedAt): .fresh(observedAt: observedAt)
        case let .stale(observedAt): .stale(observedAt: observedAt)
        case .unavailable: .unavailable
        }
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
