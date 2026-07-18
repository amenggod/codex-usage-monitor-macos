import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct LiveRateLimitStoreTests {
    private let base = Date(timeIntervalSince1970: 10_000)

    @Test
    func classifiesFreshStaleAndUnavailableAtExactBoundaries() async {
        let store = LiveRateLimitStore()
        let limits = [LimitStatus(
            window: .week,
            usedPercent: 31,
            resetsAt: base.addingTimeInterval(86_400)
        )]
        await store.replace(limits: limits, observedAt: base)

        #expect(await store.state(now: base.addingTimeInterval(600)) ==
            .fresh(limits: limits, observedAt: base))
        #expect(await store.state(now: base.addingTimeInterval(601)) ==
            .stale(limits: limits, observedAt: base))
        #expect(await store.state(now: base.addingTimeInterval(1_800)) ==
            .stale(limits: limits, observedAt: base))
        #expect(await store.state(now: base.addingTimeInterval(1_801)) ==
            .unavailable(lastSuccessfulAt: base, message: "实时限额已过期"))
    }

    @Test
    func failureKeepsLastSuccessfulValueOnlyAsClassifiedState() async {
        let store = LiveRateLimitStore()
        let limits = [LimitStatus(
            window: .week,
            usedPercent: 31,
            resetsAt: base.addingTimeInterval(86_400)
        )]
        await store.replace(limits: limits, observedAt: base)
        await store.markUnavailable(message: "连接失败")

        #expect(await store.state(now: base.addingTimeInterval(60)) ==
            .stale(limits: limits, observedAt: base))
        #expect(await store.state(now: base.addingTimeInterval(1_801)) ==
            .unavailable(lastSuccessfulAt: base, message: "连接失败"))
    }

    @Test
    func neverSuccessfulStoreIsUnavailableWithoutInventingLimits() async {
        let store = LiveRateLimitStore()
        #expect(await store.state(now: base) ==
            .unavailable(lastSuccessfulAt: nil, message: "等待实时限额"))
    }
}
