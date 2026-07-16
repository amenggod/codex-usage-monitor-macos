import Foundation
import Testing
@testable import CodexUsageShared

@Suite("WidgetDisplayModelTests")
struct WidgetDisplayModelTests {
    private let testNow = Date(timeIntervalSince1970: 10_000)

    @Test func smallPresentationContainsTodayWeekAndFreshnessOnly() {
        let model = WidgetDisplayModel(
            snapshot: .fixture(
                generatedAt: testNow,
                fiveHourLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(3_600)
                ),
                weekLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(86_400)
                )
            ),
            now: testNow
        )

        #expect(model.small.todayTokens == 12_345)
        #expect(model.small.weekRemainingPercent == 72)
        #expect(model.small.statusText.hasPrefix("更新于"))
        #expect(model.small.projects.isEmpty)
    }

    @Test func mediumPresentationContainsTotalsLimitsAndThreeProjects() {
        let model = WidgetDisplayModel(
            snapshot: .fixture(
                generatedAt: testNow,
                fiveHourLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(3_600)
                ),
                weekLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(86_400)
                )
            ),
            now: testNow
        )

        #expect(model.medium.todayTokens == 12_345)
        #expect(model.medium.allTimeTokens == 98_765)
        #expect(model.medium.fiveHourRemainingPercent == 72)
        #expect(model.medium.weekRemainingPercent == 72)
        #expect(model.medium.projects.count == 3)
        #expect(!model.medium.usesExpandedWeekLayout)
    }

    @Test func mediumPresentationReflowsWhenFiveHourLimitIsMissing() {
        let model = WidgetDisplayModel(
            snapshot: .fixture(
                generatedAt: testNow,
                fiveHourLimit: nil,
                weekLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(86_400)
                )
            ),
            now: testNow
        )

        #expect(model.medium.fiveHourRemainingPercent == nil)
        #expect(model.medium.projects.count == 3)
        #expect(model.medium.usesExpandedWeekLayout)
    }

    @Test func mediumPresentationReflowsWhenFiveHourLimitIsExpired() {
        let model = WidgetDisplayModel(
            snapshot: .fixture(
                generatedAt: testNow,
                fiveHourLimit: .fixture(resetsAt: testNow),
                weekLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(86_400)
                )
            ),
            now: testNow
        )

        #expect(model.medium.fiveHourRemainingPercent == nil)
        #expect(model.medium.usesExpandedWeekLayout)
    }

    @Test func widgetFormattingIsDeterministicForTokensAndPercents() {
        let locale = Locale(identifier: "en_US_POSIX")

        #expect(
            WidgetDisplayFormatting.compactTokens(12_345, locale: locale) == "12K"
        )
        #expect(WidgetDisplayFormatting.percent(71.6) == "72%")
    }

    @Test func stateStatusUsesLastSuccessfulTimeInsteadOfPublicationTime() {
        let lastSuccessfulAt = testNow.addingTimeInterval(-3_600)
        let generatedAt = testNow.addingTimeInterval(-60)
        let timeText = lastSuccessfulAt.formatted(
            date: .omitted,
            time: .shortened
        )

        let stale = WidgetDisplayModel(
            snapshot: .fixture(
                generatedAt: generatedAt,
                state: .stale(lastSuccessfulAt: lastSuccessfulAt)
            ),
            now: testNow
        )
        let partial = WidgetDisplayModel(
            snapshot: .fixture(
                generatedAt: generatedAt,
                state: .partial(
                    lastSuccessfulAt: lastSuccessfulAt,
                    failedFiles: 2
                )
            ),
            now: testNow
        )

        #expect(stale.statusText == "数据可能已过期 · \(timeText)")
        #expect(partial.statusText == "部分数据 · \(timeText) · 2 个文件")
    }

    @Test func unavailableDataStatesNeverExposeNumericUsageValues() {
        let noData = WidgetDisplayModel(
            snapshot: .fixture(
                generatedAt: testNow,
                todayTokens: 0,
                state: .noData
            ),
            now: testNow
        )
        let failed = WidgetDisplayModel(
            snapshot: .fixture(
                generatedAt: testNow,
                todayTokens: 0,
                state: .failed
            ),
            now: testNow
        )
        let rebuildingWithoutData = WidgetDisplayModel(
            snapshot: .fixture(
                generatedAt: testNow,
                todayTokens: 0,
                state: .rebuilding(lastSuccessfulAt: nil)
            ),
            now: testNow
        )
        let rebuildingWithData = WidgetDisplayModel(
            snapshot: .fixture(
                generatedAt: testNow,
                state: .rebuilding(
                    lastSuccessfulAt: testNow.addingTimeInterval(-60)
                )
            ),
            now: testNow
        )

        #expect(!noData.canDisplayUsageValues)
        #expect(!failed.canDisplayUsageValues)
        #expect(!rebuildingWithoutData.canDisplayUsageValues)
        #expect(rebuildingWithData.canDisplayUsageValues)
        #expect(noData.statusText == "尚无本地用量数据")
        #expect(failed.statusText == "读取失败，等待主程序重新同步")
        #expect(rebuildingWithoutData.statusText == "正在重建 · 尚无可用数据")
    }

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

    @Test func nextRefreshUsesFiveMinuteTickWhenNoLimitsAreVisible() {
        let model = WidgetDisplayModel(
            snapshot: .fixture(fiveHourLimit: nil, weekLimit: nil),
            now: testNow
        )

        #expect(model.nextRefreshAt == testNow.addingTimeInterval(300))
    }

    @Test(arguments: [
        (60.0, 120.0, 60.0),
        (120.0, 60.0, 60.0),
    ])
    func nextRefreshUsesEarlierOfTwoActiveResets(
        fiveHourOffset: TimeInterval,
        weekOffset: TimeInterval,
        expectedOffset: TimeInterval
    ) {
        let model = WidgetDisplayModel(
            snapshot: .fixture(
                fiveHourLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(fiveHourOffset)
                ),
                weekLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(weekOffset)
                )
            ),
            now: testNow
        )

        #expect(model.nextRefreshAt == testNow.addingTimeInterval(expectedOffset))
    }

    @Test(arguments: [
        (0.0, 120.0),
        (120.0, -1.0),
    ])
    func expiredResetDoesNotOverrideAnotherActiveReset(
        fiveHourOffset: TimeInterval,
        weekOffset: TimeInterval
    ) {
        let model = WidgetDisplayModel(
            snapshot: .fixture(
                fiveHourLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(fiveHourOffset)
                ),
                weekLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(weekOffset)
                )
            ),
            now: testNow
        )

        #expect(model.nextRefreshAt == testNow.addingTimeInterval(120))
        #expect(model.nextRefreshAt > testNow)
    }

    @Test(arguments: [0.0, -1.0])
    func weekLimitAtOrBeforeResetIsRemovedWithoutRemovingFiveHour(
        weekOffset: TimeInterval
    ) {
        let fiveHourReset = testNow.addingTimeInterval(120)
        let model = WidgetDisplayModel(
            snapshot: .fixture(
                fiveHourLimit: .fixture(resetsAt: fiveHourReset),
                weekLimit: .fixture(
                    resetsAt: testNow.addingTimeInterval(weekOffset)
                )
            ),
            now: testNow
        )

        #expect(model.visibleWeekLimit == nil)
        #expect(model.visibleFiveHourLimit != nil)
        #expect(model.nextRefreshAt == fiveHourReset)
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
