import Foundation

public enum WidgetSnapshotLoadState: Equatable, Sendable {
    case available(WidgetUsageSnapshot)
    case missing
    case invalid
}

public struct SmallWidgetPresentation: Equatable, Sendable {
    public let todayTokens: Int64
    public let weekRemainingPercent: Double?
    public let statusText: String
    public let projects: [WidgetProjectUsage]
}

public struct MediumWidgetPresentation: Equatable, Sendable {
    public let todayTokens: Int64
    public let allTimeTokens: Int64
    public let fiveHourRemainingPercent: Double?
    public let weekRemainingPercent: Double?
    public let projects: [WidgetProjectUsage]
    public let statusText: String

    public var usesExpandedWeekLayout: Bool {
        fiveHourRemainingPercent == nil
    }
}

public enum WidgetDisplayFormatting {
    public static func compactTokens(
        _ tokens: Int64,
        locale: Locale = .current
    ) -> String {
        tokens.formatted(
            .number
                .notation(.compactName)
                .locale(locale)
        )
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(min(100, max(0, value)).rounded()))%"
    }
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

    public var canDisplayUsageValues: Bool {
        guard let snapshot else { return false }
        switch snapshot.state {
        case .fresh, .partial, .stale:
            return true
        case let .rebuilding(lastSuccessfulAt):
            return lastSuccessfulAt != nil
        case .noData, .failed:
            return false
        }
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
        switch snapshot.state {
        case let .fresh(lastSuccessfulAt):
            let prefix = isStale ? "上次更新" : "更新于"
            return "\(prefix) \(timeText(lastSuccessfulAt))"
        case let .partial(lastSuccessfulAt, failedFiles):
            return "部分数据 · \(timeText(lastSuccessfulAt)) · \(failedFiles) 个文件"
        case let .rebuilding(lastSuccessfulAt):
            guard let lastSuccessfulAt else {
                return "正在重建 · 尚无可用数据"
            }
            return "正在重建 · 上次 \(timeText(lastSuccessfulAt))"
        case let .stale(lastSuccessfulAt):
            return "数据可能已过期 · \(timeText(lastSuccessfulAt))"
        case .noData:
            return "尚无本地用量数据"
        case .failed:
            return "读取失败，等待主程序重新同步"
        }
    }

    public var small: SmallWidgetPresentation {
        SmallWidgetPresentation(
            todayTokens: snapshot?.todayTokens ?? 0,
            weekRemainingPercent: visibleWeekLimit?.remainingPercent,
            statusText: statusText,
            projects: []
        )
    }

    public var medium: MediumWidgetPresentation {
        MediumWidgetPresentation(
            todayTokens: snapshot?.todayTokens ?? 0,
            allTimeTokens: snapshot?.allTimeTokens ?? 0,
            fiveHourRemainingPercent: visibleFiveHourLimit?.remainingPercent,
            weekRemainingPercent: visibleWeekLimit?.remainingPercent,
            projects: snapshot.map { Array($0.projects.prefix(3)) } ?? [],
            statusText: statusText
        )
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
