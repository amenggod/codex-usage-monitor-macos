import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("MenuBarFormattingTests")
struct MenuBarFormattingTests {
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
