import Foundation
@testable import CodexUsageShared

extension WidgetUsageSnapshot {
    static var fixture: Self { fixture() }

    static func fixture(
        generatedAt: Date = Date(timeIntervalSince1970: 1_000),
        todayTokens: Int64 = 12_345,
        fiveHourLimit: WidgetLimitStatus? = nil,
        weekLimit: WidgetLimitStatus? = .fixture()
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
            state: .fresh(lastSuccessfulAt: generatedAt)
        )
    }
}

extension WidgetLimitStatus {
    static func fixture(
        resetsAt: Date = Date(timeIntervalSince1970: 9_000)
    ) -> Self {
        Self(id: "codex", remainingPercent: 72, resetsAt: resetsAt)
    }
}
