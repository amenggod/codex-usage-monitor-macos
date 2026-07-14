import Testing
@testable import CodexUsageMonitor

@Suite
struct TokenDeltaCalculatorTests {
    @Test
    func prefersLastUsageIncludingItsAuthoritativeTotal() {
        let lastUsage = TokenUsage(
            input: 10,
            cachedInput: 2,
            output: 3,
            reasoningOutput: 1,
            total: 99
        )

        let delta = TokenDeltaCalculator.delta(
            lastUsage: lastUsage,
            cumulativeUsage: TokenUsage(
                input: 100,
                cachedInput: 20,
                output: 30,
                reasoningOutput: 10,
                total: 130
            ),
            previousCumulative: .zero
        )

        #expect(delta == lastUsage)
    }

    @Test
    func usesNonNegativeCumulativeDifferenceWhenLastUsageIsMissing() {
        let delta = TokenDeltaCalculator.delta(
            lastUsage: nil,
            cumulativeUsage: TokenUsage(
                input: 120,
                cachedInput: 15,
                output: 30,
                reasoningOutput: 5,
                total: 150
            ),
            previousCumulative: TokenUsage(
                input: 100,
                cachedInput: 20,
                output: 25,
                reasoningOutput: 10,
                total: 130
            )
        )

        #expect(delta == TokenUsage(
            input: 20,
            cachedInput: 0,
            output: 5,
            reasoningOutput: 0,
            total: 20
        ))
    }

    @Test
    func returnsZeroWhenAuthoritativeCumulativeTotalMovesBackward() {
        let delta = TokenDeltaCalculator.delta(
            lastUsage: nil,
            cumulativeUsage: TokenUsage(
                input: 70,
                cachedInput: 5,
                output: 10,
                reasoningOutput: 2,
                total: 20
            ),
            previousCumulative: TokenUsage(
                input: 60,
                cachedInput: 8,
                output: 20,
                reasoningOutput: 4,
                total: 100
            )
        )

        #expect(delta == .zero)
    }

    @Test
    func returnsZeroWhenAuthoritativeCumulativeTotalDoesNotAdvance() {
        let delta = TokenDeltaCalculator.delta(
            lastUsage: nil,
            cumulativeUsage: TokenUsage(
                input: 70,
                cachedInput: 5,
                output: 10,
                reasoningOutput: 2,
                total: 100
            ),
            previousCumulative: TokenUsage(
                input: 60,
                cachedInput: 8,
                output: 20,
                reasoningOutput: 4,
                total: 100
            )
        )

        #expect(delta == .zero)
    }

    @Test
    func usesCumulativeUsageWhenThereIsNoPreviousSnapshot() {
        let cumulative = TokenUsage(
            input: 40,
            cachedInput: 8,
            output: 12,
            reasoningOutput: 4,
            total: 52
        )

        let delta = TokenDeltaCalculator.delta(
            lastUsage: nil,
            cumulativeUsage: cumulative,
            previousCumulative: nil
        )

        #expect(delta == cumulative)
    }

    @Test
    func returnsZeroWhenNoUsageSnapshotExists() {
        let delta = TokenDeltaCalculator.delta(
            lastUsage: nil,
            cumulativeUsage: nil,
            previousCumulative: TokenUsage(
                input: 10,
                cachedInput: 2,
                output: 3,
                reasoningOutput: 1,
                total: 13
            )
        )

        #expect(delta == .zero)
    }
}
