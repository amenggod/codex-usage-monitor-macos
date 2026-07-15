import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("MenuBarFormattingTests")
struct MenuBarFormattingTests {
    @Test func freshnessSymbolsRemainAvailableForEveryState() {
        let states: [DataFreshness] = [
            .loading,
            .fresh(.distantPast),
            .stale(.distantPast),
            .partial(.distantPast, failedFiles: 1),
            .rebuilding(completed: 1, total: 2),
            .noData,
            .failed("错误"),
        ]

        #expect(states.allSatisfy { !FreshnessFormatter.symbol(for: $0).isEmpty })
    }

    @Test func balancedLabelShowsBothKnownWindows() {
        let limits = [
            LimitStatus(window: .fiveHours, usedPercent: 28, resetsAt: .distantFuture),
            LimitStatus(window: .week, usedPercent: 52, resetsAt: .distantFuture),
        ]

        #expect(MenuBarFormatter.title(limits: limits) == "5h 72% · 周 48%")
    }

    @Test func singleWeekWindowShowsItsRemainingPercent() {
        #expect(MenuBarFormatter.title(limits: [
            LimitStatus(window: .week, usedPercent: 52, resetsAt: .distantFuture),
        ]) == "周 48%")
    }

    @Test func singleFiveHourWindowShowsItsRemainingPercent() {
        #expect(MenuBarFormatter.title(limits: [
            LimitStatus(window: .fiveHours, usedPercent: 28, resetsAt: .distantFuture),
        ]) == "5h 72%")
    }

    @Test func missingLimitsShowsWaitingCopy() {
        #expect(MenuBarFormatter.title(limits: []) == "Codex --")
    }

    @Test func projectAccessibilityTextNeverContainsFullPath() {
        let project = ProjectUsage(
            id: "secret-project",
            displayName: "project",
            fullPath: "/synthetic/ClientSecret/project",
            usage: TokenUsage(input: 42, cachedInput: 0, output: 0, reasoningOutput: 0, total: 42)
        )

        let label = ProjectRowAccessibilityFormatter.label(for: project)

        #expect(label == "project，42 Token")
        #expect(!label.contains("/synthetic/ClientSecret/project"))
        #expect(!label.contains("ClientSecret"))
    }
}
