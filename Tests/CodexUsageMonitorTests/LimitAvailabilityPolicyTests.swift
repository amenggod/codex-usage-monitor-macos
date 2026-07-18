import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct LimitAvailabilityPolicyTests {
    @Test
    func expiredFiveHourAndWeekSnapshotsAreNotActive() {
        let now = Date(timeIntervalSince1970: 2_000)
        let expired = [
            RateLimitObservation(
                limitID: "codex",
                window: .fiveHours,
                usedPercent: 80,
                resetsAt: Date(timeIntervalSince1970: 1_999),
                observedAt: Date(timeIntervalSince1970: 1_900)
            ),
            RateLimitObservation(
                limitID: "codex",
                window: .week,
                usedPercent: 50,
                resetsAt: Date(timeIntervalSince1970: 1_999),
                observedAt: Date(timeIntervalSince1970: 1_900)
            ),
        ]

        #expect(LimitAvailabilityPolicy.activeStatuses(from: expired, now: now).isEmpty)
    }

    @Test
    func activeKnownWindowsAreReturned() {
        let now = Date(timeIntervalSince1970: 2_000)
        let active = RateLimitObservation(
            limitID: "codex",
            window: .week,
            usedPercent: 50,
            resetsAt: Date(timeIntervalSince1970: 3_000),
            observedAt: now
        )

        #expect(LimitAvailabilityPolicy.activeStatuses(from: [active], now: now) == [
            LimitStatus(
                limitID: "codex",
                window: .week,
                usedPercent: 50,
                resetsAt: active.resetsAt
            ),
        ])
    }

    @Test
    func sameWindowUsesTheMostRestrictiveActiveQuota() {
        let now = Date(timeIntervalSince1970: 2_000)
        let overall = RateLimitObservation(
            limitID: "codex",
            planType: "prolite",
            window: .week,
            usedPercent: 27,
            resetsAt: Date(timeIntervalSince1970: 3_000),
            observedAt: Date(timeIntervalSince1970: 1_900)
        )
        let modelSpecific = RateLimitObservation(
            limitID: "codex_bengalfox",
            window: .week,
            usedPercent: 0,
            resetsAt: Date(timeIntervalSince1970: 4_000),
            observedAt: Date(timeIntervalSince1970: 2_000)
        )
        let newerOverallCycle = RateLimitObservation(
            limitID: "codex",
            window: .week,
            usedPercent: 4,
            resetsAt: Date(timeIntervalSince1970: 5_000),
            observedAt: Date(timeIntervalSince1970: 2_100)
        )
        let legacyOverallCycle = RateLimitObservation(
            limitID: "codex",
            window: .week,
            usedPercent: 59,
            resetsAt: Date(timeIntervalSince1970: 6_000),
            observedAt: Date(timeIntervalSince1970: 1_800)
        )

        #expect(LimitAvailabilityPolicy.activeStatuses(
            from: [overall, modelSpecific, newerOverallCycle, legacyOverallCycle],
            now: now
        ) == [
            LimitStatus(
                limitID: "codex",
                window: .week,
                usedPercent: 27,
                resetsAt: overall.resetsAt
            ),
        ])
    }
}
