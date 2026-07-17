import Foundation

enum LiveRateLimitState: Equatable, Sendable {
    case fresh(limits: [LimitStatus], observedAt: Date)
    case stale(limits: [LimitStatus], observedAt: Date)
    case unavailable(lastSuccessfulAt: Date?, message: String)

    var limits: [LimitStatus] {
        switch self {
        case let .fresh(limits, _), let .stale(limits, _): limits
        case .unavailable: []
        }
    }

    var observedAt: Date? {
        switch self {
        case let .fresh(_, observedAt), let .stale(_, observedAt): observedAt
        case let .unavailable(lastSuccessfulAt, _): lastSuccessfulAt
        }
    }

    var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }
}

protocol LiveRateLimitProviding: Sendable {
    func state(now: Date) async -> LiveRateLimitState
}

actor LiveRateLimitStore: LiveRateLimitProviding {
    static let freshInterval: TimeInterval = 10 * 60
    static let unavailableInterval: TimeInterval = 30 * 60

    private var limits: [LimitStatus] = []
    private var lastSuccessfulAt: Date?
    private var failureMessage: String?

    func replace(limits: [LimitStatus], observedAt: Date) {
        self.limits = limits
        lastSuccessfulAt = observedAt
        failureMessage = nil
    }

    func markUnavailable(message: String) {
        failureMessage = message
    }

    func state(now: Date) -> LiveRateLimitState {
        guard let lastSuccessfulAt else {
            return .unavailable(
                lastSuccessfulAt: nil,
                message: failureMessage ?? "等待实时限额"
            )
        }

        let age = max(0, now.timeIntervalSince(lastSuccessfulAt))
        if age > Self.unavailableInterval {
            return .unavailable(
                lastSuccessfulAt: lastSuccessfulAt,
                message: failureMessage ?? "实时限额已过期"
            )
        }
        if failureMessage != nil || age > Self.freshInterval {
            return .stale(limits: limits, observedAt: lastSuccessfulAt)
        }
        return .fresh(limits: limits, observedAt: lastSuccessfulAt)
    }
}
