import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct TokenEventIdentityTests {
    @Test
    func identityIgnoresFilePathAndOffset() {
        let event = ParsedTokenEvent(
            occurredAt: Date(timeIntervalSince1970: 1_000),
            lastUsage: TokenUsage(input: 10, cachedInput: 2, output: 3, reasoningOutput: 1, total: 13),
            cumulativeUsage: TokenUsage(input: 20, cachedInput: 4, output: 6, reasoningOutput: 2, total: 26),
            limits: []
        )

        let first = TokenEventIdentity.make(sessionID: "parent", event: event)
        let second = TokenEventIdentity.make(sessionID: "parent", event: event)

        #expect(first == second)
        #expect(first.count == 64)
    }

    @Test
    func identityChangesWhenLogicalUsageChanges() {
        let first = ParsedTokenEvent(
            occurredAt: Date(timeIntervalSince1970: 1_000),
            lastUsage: .zero,
            cumulativeUsage: .zero,
            limits: []
        )
        let second = ParsedTokenEvent(
            occurredAt: Date(timeIntervalSince1970: 1_000),
            lastUsage: TokenUsage(input: 1, cachedInput: 0, output: 0, reasoningOutput: 0, total: 1),
            cumulativeUsage: .zero,
            limits: []
        )

        #expect(TokenEventIdentity.make(sessionID: "s", event: first) != TokenEventIdentity.make(sessionID: "s", event: second))
    }

    @Test
    func identityPreservesSubMillisecondTimestampDifferences() {
        let usage = TokenUsage(
            input: 10,
            cachedInput: 2,
            output: 3,
            reasoningOutput: 1,
            total: 13
        )
        let first = ParsedTokenEvent(
            occurredAt: Date(timeIntervalSince1970: 1_000.000_1),
            lastUsage: usage,
            cumulativeUsage: usage,
            limits: []
        )
        let second = ParsedTokenEvent(
            occurredAt: Date(timeIntervalSince1970: 1_000.000_2),
            lastUsage: usage,
            cumulativeUsage: usage,
            limits: []
        )

        #expect(
            TokenEventIdentity.make(sessionID: "s", event: first)
                != TokenEventIdentity.make(sessionID: "s", event: second)
        )
    }
}
