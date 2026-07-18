import Foundation
import Testing
import CodexUsageShared

#if SWIFT_PACKAGE
@testable import CodexUsageMonitorWidget
#endif

@Suite("UsageTimelineProviderTests")
struct UsageTimelineProviderTests {
    private let testNow = Date(timeIntervalSince1970: 10_000)

    @Test func entryMapsAvailableSnapshotWithoutTransformingIt() {
        let snapshot = makeSnapshot()
        let provider = UsageTimelineProvider(
            now: { testNow },
            readSnapshot: { snapshot }
        )

        let entry = provider.makeEntry(at: testNow)

        #expect(entry.date == testNow)
        #expect(entry.loadState == .available(snapshot))
    }

    @Test func entryMapsAbsentSnapshotToMissing() {
        let provider = UsageTimelineProvider(
            now: { testNow },
            readSnapshot: { nil }
        )

        #expect(provider.makeEntry(at: testNow).loadState == .missing)
    }

    @Test func entryMapsReadFailureToInvalid() {
        let provider = UsageTimelineProvider(
            now: { testNow },
            readSnapshot: { throw StubError.unreadable }
        )

        #expect(provider.makeEntry(at: testNow).loadState == .invalid)
    }

    @Test func timelinePlanUsesDisplayModelsNextRefreshBoundary() {
        let reset = testNow.addingTimeInterval(120)
        let snapshot = makeSnapshot(
            fiveHourLimit: WidgetLimitStatus(
                id: "five-hour",
                remainingPercent: 64,
                resetsAt: reset
            )
        )
        let provider = UsageTimelineProvider(
            now: { testNow },
            readSnapshot: { snapshot }
        )

        let plan = provider.makeTimelinePlan(at: testNow)

        #expect(plan.entry.date == testNow)
        #expect(plan.entry.loadState == .available(snapshot))
        #expect(plan.refreshAt == reset)
    }

    @Test func placeholderUsesExplicitSampleRatherThanZeroValues() {
        let provider = UsageTimelineProvider(
            now: { testNow },
            readSnapshot: { nil }
        )

        let entry = provider.makePlaceholderEntry(at: testNow)

        guard case let .available(snapshot) = entry.loadState else {
            Issue.record("Placeholder must be an available display-safe sample")
            return
        }
        #expect(entry.date == testNow)
        #expect(snapshot.todayTokens > 0)
        #expect(snapshot.allTimeTokens > 0)
    }

    @MainActor
    @Test func widgetIdentityAndDashboardDeepLinkAreExact() {
        #expect(
            CodexUsageWidget.kind
                == "com.amenggod.CodexUsageMonitor.usage"
        )
        #expect(
            CodexUsageWidget.dashboardURL.absoluteString
                == "codexusagemonitor://dashboard"
        )
    }

    @Test func accessibilityLayoutReducesProjectDensity() {
        #expect(
            UsageWidgetLayoutPolicy.projectLimit(
                isAccessibilitySize: false
            ) == 3
        )
        #expect(
            UsageWidgetLayoutPolicy.projectLimit(
                isAccessibilitySize: true
            ) == 1
        )
    }

    private func makeSnapshot(
        fiveHourLimit: WidgetLimitStatus? = nil
    ) -> WidgetUsageSnapshot {
        WidgetUsageSnapshot(
            generatedAt: testNow,
            todayTokens: 12_345,
            allTimeTokens: 98_765,
            fiveHourLimit: fiveHourLimit,
            weekLimit: WidgetLimitStatus(
                id: "week",
                remainingPercent: 72,
                resetsAt: testNow.addingTimeInterval(86_400)
            ),
            limitFreshness: .fresh(observedAt: testNow),
            projects: [
                WidgetProjectUsage(id: "one", name: "restaurant", tokens: 42_100),
                WidgetProjectUsage(id: "two", name: "monitor", tokens: 31_400),
                WidgetProjectUsage(id: "three", name: "notes", tokens: 25_265),
            ],
            state: .fresh(lastSuccessfulAt: testNow)
        )
    }
}

private enum StubError: Error {
    case unreadable
}
