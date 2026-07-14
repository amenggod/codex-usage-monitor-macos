import Foundation

struct TokenUsage: Codable, Equatable, Sendable {
    let input: Int64
    let cachedInput: Int64
    let output: Int64
    let reasoningOutput: Int64
    let total: Int64

    static let zero = TokenUsage(input: 0, cachedInput: 0, output: 0, reasoningOutput: 0, total: 0)

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(
            input: max(0, lhs.input - rhs.input),
            cachedInput: max(0, lhs.cachedInput - rhs.cachedInput),
            output: max(0, lhs.output - rhs.output),
            reasoningOutput: max(0, lhs.reasoningOutput - rhs.reasoningOutput),
            total: max(0, lhs.total - rhs.total)
        )
    }
}

struct SessionMetadata: Equatable, Sendable {
    let sessionID: String
    let startedAt: Date
    let workingDirectory: String?
}

enum LimitWindow: Equatable, Hashable, Sendable {
    case fiveHours
    case week
    case other(minutes: Int, label: String?)

    var minutes: Int {
        switch self {
        case .fiveHours: 300
        case .week: 10_080
        case let .other(minutes, _): minutes
        }
    }

    var storageKey: String {
        switch self {
        case .fiveHours: "five-hours"
        case .week: "week"
        case let .other(minutes, label): "other-\(minutes)-\(label ?? "unlabeled")"
        }
    }

    var displayName: String {
        switch self {
        case .fiveHours: "5 小时限额"
        case .week: "周限额"
        case let .other(minutes, label): label ?? "\(minutes) 分钟限额"
        }
    }
}

struct RateLimitObservation: Equatable, Sendable {
    let limitID: String
    let window: LimitWindow
    let usedPercent: Double
    let resetsAt: Date
    let observedAt: Date
}

struct ParsedTokenEvent: Equatable, Sendable {
    let occurredAt: Date
    let lastUsage: TokenUsage?
    let cumulativeUsage: TokenUsage?
    let limits: [RateLimitObservation]
}

struct LimitStatus: Equatable, Sendable {
    let window: LimitWindow
    let usedPercent: Double
    let resetsAt: Date
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
}

enum TokenRange: String, CaseIterable, Sendable {
    case today, sevenDays, all

    var displayName: String {
        switch self {
        case .today: "今日"
        case .sevenDays: "7 天"
        case .all: "全部"
        }
    }
}

enum DataFreshness: Equatable, Sendable {
    case loading
    case fresh(Date)
    case stale(Date)
    case noData
    case failed(String)
}

struct ProjectUsage: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let fullPath: String?
    let usage: TokenUsage
}

struct DashboardSnapshot: Equatable, Sendable {
    let range: TokenRange
    let total: TokenUsage
    let projects: [ProjectUsage]
    let limits: [LimitStatus]
    let freshness: DataFreshness

    static let loading = DashboardSnapshot(
        range: .today,
        total: .zero,
        projects: [],
        limits: [],
        freshness: .loading
    )
}
