import AppKit
import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite("MenuBarFormattingTests")
struct MenuBarFormattingTests {
    @MainActor
    @Test func menuBarLabelUsesACompactTemplateImageForCrowdedMenuBars() {
        let image = MenuBarFormatter.templateImage(title: "周 62%")

        #expect(image.isTemplate)
        #expect(image.size.height == 18)
        #expect(image.size.width <= 18)
    }

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

    @Test func expiredKnownWindowsAreNotFormatted() {
        let limits = [
            LimitStatus(window: .fiveHours, usedPercent: 28, resetsAt: .distantPast),
            LimitStatus(window: .week, usedPercent: 52, resetsAt: .distantPast),
        ]

        #expect(MenuBarFormatter.title(limits: limits) == "Codex --")
    }

    @Test func labelDropsLimitsAtTheirExactResetBoundary() {
        let reset = Date(timeIntervalSince1970: 1_000)
        let limits = [
            LimitStatus(window: .fiveHours, usedPercent: 28, resetsAt: reset),
            LimitStatus(window: .week, usedPercent: 52, resetsAt: reset),
        ]

        #expect(
            MenuBarFormatter.title(
                limits: limits,
                now: reset.addingTimeInterval(-0.001)
            ) == "5h 72% · 周 48%"
        )
        #expect(MenuBarFormatter.title(limits: limits, now: reset) == "Codex --")
    }

    @Test func expiredFiveHourDoesNotHideActiveWeek() {
        let limits = [
            LimitStatus(window: .fiveHours, usedPercent: 28, resetsAt: .distantPast),
            LimitStatus(window: .week, usedPercent: 52, resetsAt: .distantFuture),
        ]

        #expect(MenuBarFormatter.title(limits: limits) == "周 48%")
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
