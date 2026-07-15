import Foundation

enum UsagePresentationPolicy {
    static let refreshInterval: TimeInterval = 1

    static func activeLimits(
        limits: [LimitStatus],
        now: Date = .now
    ) -> [LimitStatus] {
        limits.filter { $0.resetsAt > now }
    }

    static func visibleWindows(
        limits: [LimitStatus],
        now: Date = .now
    ) -> [LimitWindow] {
        let activeLimits = activeLimits(limits: limits, now: now)
        var windows: [LimitWindow] = []
        if activeLimits.contains(where: { $0.window == .fiveHours }) {
            windows.append(.fiveHours)
        }
        windows.append(.week)
        return windows
    }
}
