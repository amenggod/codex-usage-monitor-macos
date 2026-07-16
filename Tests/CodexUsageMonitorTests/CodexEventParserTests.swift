import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct CodexEventParserTests {
    private let parser = CodexEventParser()

    @Test
    func parsesSessionMetadataWithoutPrivateContent() throws {
        let line = Data(#"{"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/synthetic/alpha","prompt":"privacy-canary-prompt","response":{"text":"privacy-canary-response"},"tool":{"output":"privacy-canary-tool"},"credential":"privacy-canary-credential"}}"#.utf8)
        let event = try #require(parser.parse(line: line))
        guard case let .session(metadata) = event else {
            Issue.record("expected session")
            return
        }

        #expect(metadata.sessionID == "s1")
        #expect(metadata.workingDirectory == "/synthetic/alpha")
        #expect(!String(describing: event).contains("privacy-canary"))
    }

    @Test
    func parsesWholeAndFractionalSecondTimestamps() throws {
        let wholeLine = Data(#"{"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"whole"}}"#.utf8)
        let fractionalLine = Data(#"{"type":"session_meta","payload":{"id":"fractional","timestamp":"2026-07-14T01:00:00.123Z"}}"#.utf8)

        let wholeEvent = try #require(parser.parse(line: wholeLine))
        let fractionalEvent = try #require(parser.parse(line: fractionalLine))
        guard case let .session(whole) = wholeEvent,
              case let .session(fractional) = fractionalEvent else {
            Issue.record("expected sessions")
            return
        }

        #expect(abs(fractional.startedAt.timeIntervalSince(whole.startedAt) - 0.123) < 0.000_001)
    }

    @Test
    func fallsBackToPayloadWhenTopLevelTimestampIsInvalid() throws {
        let line = Data(#"{"timestamp":"not-a-date","type":"session_meta","payload":{"id":"fallback","timestamp":"2026-07-14T01:00:00Z"}}"#.utf8)
        let event = try #require(parser.parse(line: line))
        guard case let .session(metadata) = event else {
            Issue.record("expected session")
            return
        }

        #expect(metadata.sessionID == "fallback")
    }

    @Test
    func fallsBackAcrossWrongTimestampTypes() throws {
        let wrongTopLevel = Data(#"{"timestamp":42,"type":"session_meta","payload":{"id":"payload-fallback","timestamp":"2026-07-14T01:00:00Z"}}"#.utf8)
        let wrongPayload = Data(#"{"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"top-level-fallback","timestamp":{"invalid":true}}}"#.utf8)

        let payloadFallback = try #require(parser.parse(line: wrongTopLevel))
        let topLevelFallback = try #require(parser.parse(line: wrongPayload))
        guard case let .session(payloadMetadata) = payloadFallback,
              case let .session(topLevelMetadata) = topLevelFallback else {
            Issue.record("expected sessions")
            return
        }

        #expect(payloadMetadata.sessionID == "payload-fallback")
        #expect(topLevelMetadata.sessionID == "top-level-fallback")
    }

    @Test
    func ignoresMissingAndInvalidTimestamps() {
        #expect(parser.parse(line: Data(#"{"type":"session_meta","payload":{"id":"missing"}}"#.utf8)) == nil)
        #expect(parser.parse(line: Data(#"{"timestamp":"not-a-date","type":"session_meta","payload":{"id":"invalid"}}"#.utf8)) == nil)
    }

    @Test
    func parsesTokenAndBothKnownLimitWindows() throws {
        let url = try #require(TestResourceBundle.fixtureURL(
            forResource: "session-sample",
            withExtension: "jsonl"
        ))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let event = try #require(parser.parse(line: Data(lines[1].utf8)))
        guard case let .token(token) = event else {
            Issue.record("expected token")
            return
        }

        #expect(token.lastUsage == TokenUsage(
            input: 100,
            cachedInput: 20,
            output: 10,
            reasoningOutput: 5,
            total: 777
        ))
        #expect(token.cumulativeUsage?.total == 777)
        #expect(token.limits.map(\.window) == [.fiveHours, .week])
    }

    @Test
    func ignoresWrongWorkingDirectoryType() throws {
        let line = Data(#"{"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"wrong-cwd","cwd":{"unexpected":true}}}"#.utf8)
        let event = try #require(parser.parse(line: line))
        guard case let .session(metadata) = event else {
            Issue.record("expected session")
            return
        }

        #expect(metadata.sessionID == "wrong-cwd")
        #expect(metadata.workingDirectory == nil)
    }

    @Test
    func preservesTokenLimitsWhenInfoHasWrongType() throws {
        let line = Data(#"{"timestamp":"2026-07-14T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":"unexpected","rate_limits":{"limit_id":"codex","primary":{"used_percent":28,"window_minutes":300,"resets_at":1784000000}}}}"#.utf8)
        let event = try #require(parser.parse(line: line))
        guard case let .token(token) = event else {
            Issue.record("expected token")
            return
        }

        #expect(token.lastUsage == nil)
        #expect(token.cumulativeUsage == nil)
        #expect(token.limits.map(\.window) == [.fiveHours])
    }

    @Test
    func preservesTokenUsageWhenRateLimitsHaveWrongType() throws {
        let line = Data(#"{"timestamp":"2026-07-14T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":777}},"rate_limits":"unexpected"}}"#.utf8)
        let event = try #require(parser.parse(line: line))
        guard case let .token(token) = event else {
            Issue.record("expected token")
            return
        }

        #expect(token.lastUsage?.total == 777)
        #expect(token.limits == [])
    }

    @Test
    func mapsUnknownLimitWindowToOther() throws {
        let line = Data(#"{"timestamp":"2026-07-14T01:05:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"flex","limit_name":"Flexible","primary":{"used_percent":12.5,"window_minutes":60,"resets_at":1784000000}}}}"#.utf8)
        let event = try #require(parser.parse(line: line))
        guard case let .token(token) = event else {
            Issue.record("expected token")
            return
        }

        #expect(token.limits.map(\.window) == [.other(minutes: 60, label: "Flexible")])
    }

    @Test
    func rejectsNonIntegralOrIncompleteUsageObjects() throws {
        let invalidUsages = [
            #""input_tokens":true,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":135"#,
            #""input_tokens":100,"cached_input_tokens":20,"output_tokens":10.5,"reasoning_output_tokens":5,"total_tokens":135"#,
            #""cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":135"#,
            #""input_tokens":100,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":135"#,
            #""input_tokens":100,"cached_input_tokens":20,"reasoning_output_tokens":5,"total_tokens":135"#,
            #""input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":135"#,
            #""input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":5"#
        ]

        for invalidUsage in invalidUsages {
            let line = Data(#"{"timestamp":"2026-07-14T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{\#(invalidUsage)}}}}"#.utf8)
            let event = try #require(parser.parse(line: line))
            guard case let .token(token) = event else {
                Issue.record("expected token")
                return
            }

            #expect(token.lastUsage == nil)
        }
    }

    @Test
    func ignoresMalformedAndUnknownLines() {
        #expect(parser.parse(line: Data("not-json".utf8)) == nil)
        #expect(parser.parse(line: Data(#"{"timestamp":"2026-07-14T01:05:00Z","type":"response_item","payload":{"text":"ignored"}}"#.utf8)) == nil)
    }
}
