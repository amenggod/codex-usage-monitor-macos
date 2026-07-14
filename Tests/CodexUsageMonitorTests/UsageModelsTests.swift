import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct UsageModelsTests {
    @Test
    func tokenUsageUsesAuthoritativeTotal() {
        let usage = TokenUsage(input: 100, cachedInput: 40, output: 20, reasoningOutput: 5, total: 120)
        #expect(usage.total == 120, "Codex total_tokens is authoritative; breakdown fields must not be re-added")
    }

    @Test
    func remainingPercentIsClamped() {
        #expect(LimitStatus(window: .fiveHours, usedPercent: 105, resetsAt: .distantFuture).remainingPercent == 0)
        #expect(LimitStatus(window: .week, usedPercent: -4, resetsAt: .distantFuture).remainingPercent == 100)
    }
}
