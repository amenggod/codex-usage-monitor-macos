import Foundation

enum LimitAvailabilityPolicy {
    static func activeStatuses(
        from observations: [RateLimitObservation],
        now: Date
    ) -> [LimitStatus] {
        observations
            .filter { $0.resetsAt > now }
            .map {
                LimitStatus(
                    window: $0.window,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
    }
}
