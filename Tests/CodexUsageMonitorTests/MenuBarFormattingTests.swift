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

    @Test func missingLimitsShowsWaitingCopy() {
        #expect(MenuBarFormatter.title(limits: []) == "Codex --")
        #expect(MenuBarFormatter.title(limits: [
            LimitStatus(window: .fiveHours, usedPercent: 28, resetsAt: .distantFuture),
        ]) == "Codex --")
    }
}
