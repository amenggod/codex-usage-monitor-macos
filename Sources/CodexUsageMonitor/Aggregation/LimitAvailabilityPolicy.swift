import Foundation

enum LimitAvailabilityPolicy {
    static func activeStatuses(
        from observations: [RateLimitObservation],
        now: Date
    ) -> [LimitStatus] {
        let active = observations.filter { $0.resetsAt > now }
        let explicitPlanObservations = active.filter { $0.planType?.isEmpty == false }
        let currentPlanType = explicitPlanObservations
            .max { $0.observedAt < $1.observedAt }?
            .planType
        let currentScope = if let currentPlanType {
            active.filter { $0.planType == currentPlanType }
        } else {
            active.filter { $0.planType?.isEmpty != false }
        }
        let activeByWindow = Dictionary(
            grouping: currentScope,
            by: \.window
        )

        return activeByWindow
            .compactMap { _, candidates in
                candidates.max { lhs, rhs in
                    if lhs.usedPercent != rhs.usedPercent {
                        return lhs.usedPercent < rhs.usedPercent
                    }
                    return lhs.observedAt < rhs.observedAt
                }
            }
            .map {
                LimitStatus(
                    limitID: $0.limitID,
                    window: $0.window,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
            .sorted { $0.window.storageKey < $1.window.storageKey }
    }
}
