import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct CodexEventParserTests {
    private let parser = CodexEventParser()

    @Test
    func parsesSessionMetadataWithoutContent() throws {
        let line = Data(#"{"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/synthetic/alpha","prompt":"secret"}}"#.utf8)
        let event = try #require(parser.parse(line: line))
        guard case let .session(metadata) = event else {
            Issue.record("expected session")
            return
        }

        #expect(metadata.sessionID == "s1")
        #expect(metadata.workingDirectory == "/synthetic/alpha")
        #expect(!String(describing: event).contains("secret"))
    }

    @Test
    func parsesTokenAndBothKnownLimitWindows() throws {
        let url = try #require(Bundle.module.url(
            forResource: "session-sample",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        ))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let event = try #require(parser.parse(line: Data(lines[1].utf8)))
        guard case let .token(token) = event else {
            Issue.record("expected token")
            return
        }

        #expect(token.lastUsage?.total == 135)
        #expect(token.limits.map(\.window) == [.fiveHours, .week])
    }

    @Test
    func ignoresMalformedAndUnknownLines() {
        #expect(parser.parse(line: Data("not-json".utf8)) == nil)
        #expect(parser.parse(line: Data(#"{"type":"response_item","payload":{"text":"ignored"}}"#.utf8)) == nil)
    }
}
