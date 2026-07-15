import Foundation

public enum WidgetSnapshotLoadState: Equatable, Sendable {
    case available(WidgetUsageSnapshot)
    case missing
    case invalid
}

public struct WidgetDisplayModel: Equatable, Sendable {
    public static let staleInterval: TimeInterval = 15 * 60
    public static let fallbackRefreshInterval: TimeInterval = 5 * 60

    public let loadState: WidgetSnapshotLoadState
    public let now: Date

    public init(snapshot: WidgetUsageSnapshot?, now: Date) {
        loadState = snapshot.map(WidgetSnapshotLoadState.available) ?? .missing
        self.now = now
    }

    public init(loadState: WidgetSnapshotLoadState, now: Date) {
        self.loadState = loadState
        self.now = now
    }

    public var snapshot: WidgetUsageSnapshot? {
        guard case let .available(snapshot) = loadState else { return nil }
        return snapshot
    }

    public var todayTokens: Int64 { snapshot?.todayTokens ?? 0 }

    public var visibleFiveHourLimit: WidgetLimitStatus? {
        snapshot?.fiveHourLimit.flatMap { $0.resetsAt > now ? $0 : nil }
    }

    public var visibleWeekLimit: WidgetLimitStatus? {
        snapshot?.weekLimit.flatMap { $0.resetsAt > now ? $0 : nil }
    }

    public var isStale: Bool {
        guard let generatedAt = snapshot?.generatedAt else { return true }
        return now.timeIntervalSince(generatedAt) > Self.staleInterval
    }

    public var nextRefreshAt: Date {
        let fallback = now.addingTimeInterval(Self.fallbackRefreshInterval)
        let resets = [visibleFiveHourLimit?.resetsAt, visibleWeekLimit?.resetsAt]
            .compactMap { $0 }
        return resets.min().map { min($0, fallback) } ?? fallback
    }

    public var statusText: String {
        switch loadState {
        case .missing:
            return "打开 Codex Usage Monitor 完成首次同步"
        case .invalid:
            return "等待 Codex Usage Monitor 重新同步"
        case .available:
            break
        }
        guard let snapshot else { return "等待 Codex Usage Monitor 重新同步" }
        if isStale {
            return "上次更新 \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened))"
        }
        return "更新于 \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened))"
    }
}
