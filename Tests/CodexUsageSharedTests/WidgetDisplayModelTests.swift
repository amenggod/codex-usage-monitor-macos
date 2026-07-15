import Foundation
import Testing
@testable import CodexUsageShared

@Suite("WidgetDisplayModelTests")
struct WidgetDisplayModelTests {
    private let testNow = Date(timeIntervalSince1970: 10_000)

    @Test func expiredFiveHourLimitIsRemovedWithoutRemovingWeek() {
        let model = WidgetDisplayModel(
            snapshot: .fixture(
                fiveHourLimit: .fixture(resetsAt: testNow),
                weekLimit: .fixture(resetsAt: testNow.addingTimeInterval(3_600))
            ),
            now: testNow
        )

        #expect(model.visibleFiveHourLimit == nil)
        #expect(model.visibleWeekLimit != nil)
    }

    @Test func missingFiveHourLimitIsRemovedWithoutRemovingWeek() {
        let model = WidgetDisplayModel(
            snapshot: .fixture(
                fiveHourLimit: nil,
                weekLimit: .fixture(resetsAt: testNow.addingTimeInterval(3_600))
            ),
            now: testNow
        )

        #expect(model.visibleFiveHourLimit == nil)
        #expect(model.visibleWeekLimit != nil)
    }

    @Test func snapshotOlderThanFifteenMinutesKeepsValuesAndShowsLastUpdate() {
        let snapshot = WidgetUsageSnapshot.fixture(
            generatedAt: testNow.addingTimeInterval(-901),
            todayTokens: 42
        )
        let model = WidgetDisplayModel(snapshot: snapshot, now: testNow)

        #expect(model.todayTokens == 42)
        #expect(model.isStale)
        #expect(model.statusText.hasPrefix("上次更新"))
    }

    @Test func snapshotAtFifteenMinuteBoundaryIsStillFresh() {
        let snapshot = WidgetUsageSnapshot.fixture(
            generatedAt: testNow.addingTimeInterval(-900)
        )
        let model = WidgetDisplayModel(snapshot: snapshot, now: testNow)

        #expect(!model.isStale)
        #expect(model.statusText.hasPrefix("更新于"))
    }

    @Test func nextRefreshUsesEarliestResetOrFiveMinuteFreshnessTick() {
        let reset = testNow.addingTimeInterval(120)
        let model = WidgetDisplayModel(
            snapshot: .fixture(fiveHourLimit: .fixture(resetsAt: reset)),
            now: testNow
        )

        #expect(model.nextRefreshAt == reset)
    }

    @Test func nextRefreshUsesFiveMinuteTickWhenResetsAreLater() {
        let model = WidgetDisplayModel(
            snapshot: .fixture(
                fiveHourLimit: .fixture(resetsAt: testNow.addingTimeInterval(600)),
                weekLimit: .fixture(resetsAt: testNow.addingTimeInterval(3_600))
            ),
            now: testNow
        )

        #expect(model.nextRefreshAt == testNow.addingTimeInterval(300))
    }

    @Test func missingAndInvalidSnapshotsUseDifferentRecoveryCopy() {
        #expect(
            WidgetDisplayModel(loadState: .missing, now: testNow).statusText
                == "打开 Codex Usage Monitor 完成首次同步"
        )
        #expect(
            WidgetDisplayModel(loadState: .invalid, now: testNow).statusText
                == "等待 Codex Usage Monitor 重新同步"
        )
    }
}
