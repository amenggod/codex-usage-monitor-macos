import Foundation
@testable import CodexUsageShared

extension WidgetUsageSnapshot {
    static var fixture: Self { fixture() }

    static func fixture(
        generatedAt: Date = Date(timeIntervalSince1970: 1_000),
        todayTokens: Int64 = 12_345,
        fiveHourLimit: WidgetLimitStatus? = nil,
        weekLimit: WidgetLimitStatus? = .fixture(),
        state: WidgetDataState? = nil
    ) -> Self {
        Self(
            generatedAt: generatedAt,
            todayTokens: todayTokens,
            allTimeTokens: 98_765,
            fiveHourLimit: fiveHourLimit,
            weekLimit: weekLimit,
            projects: [
                WidgetProjectUsage(id: "one", name: "restaurant", tokens: 42_100),
                WidgetProjectUsage(id: "two", name: "monitor", tokens: 31_400),
                WidgetProjectUsage(id: "three", name: "notes", tokens: 25_265),
            ],
            state: state ?? .fresh(lastSuccessfulAt: generatedAt)
        )
    }

    static var privacyFixtures: [Self] {
        let generatedAt = Date(timeIntervalSince1970: 1_000)
        return [
            fixture(
                generatedAt: generatedAt,
                fiveHourLimit: .fixture(),
                weekLimit: .fixture(),
                state: .fresh(lastSuccessfulAt: generatedAt)
            ),
            fixture(
                generatedAt: generatedAt,
                fiveHourLimit: nil,
                weekLimit: .fixture(),
                state: .partial(lastSuccessfulAt: generatedAt, failedFiles: 2)
            ),
            fixture(
                generatedAt: generatedAt,
                fiveHourLimit: .fixture(),
                weekLimit: nil,
                state: .rebuilding(lastSuccessfulAt: nil)
            ),
            fixture(
                generatedAt: generatedAt,
                fiveHourLimit: nil,
                weekLimit: nil,
                state: .stale(lastSuccessfulAt: generatedAt)
            ),
            fixture(
                generatedAt: generatedAt,
                fiveHourLimit: .fixture(),
                weekLimit: .fixture(),
                state: .noData
            ),
            fixture(
                generatedAt: generatedAt,
                fiveHourLimit: nil,
                weekLimit: nil,
                state: .failed
            ),
        ]
    }
}

extension WidgetLimitStatus {
    static func fixture(
        resetsAt: Date = Date(timeIntervalSince1970: 9_000)
    ) -> Self {
        Self(id: "codex", remainingPercent: 72, resetsAt: resetsAt)
    }
}
