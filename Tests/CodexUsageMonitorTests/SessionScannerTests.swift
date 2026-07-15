import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct SessionScannerTests {
    @Test
    func repeatedScanIsIdempotentAndAppendIsProcessedOnce() async throws {
        let fixture = try await ScannerFixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionLine(id: "s1"),
            fixture.tokenLine(
                second: 1,
                last: TokenUsage(input: 100, cachedInput: 20, output: 30, reasoningOutput: 5, total: 135)
            )
        ])

        let first = try await fixture.scanner.scan(url: fixture.logURL)
        let duplicate = try await fixture.scanner.scan(url: fixture.logURL)
        #expect(first.processedLines == 2)
        #expect(duplicate.processedLines == 0)
        #expect(try await fixture.totalUsage() == 135)

        try fixture.append(
            fixture.tokenLine(
                second: 2,
                last: TokenUsage(input: 12, cachedInput: 2, output: 3, reasoningOutput: 1, total: 16),
                cumulative: TokenUsage(input: 112, cachedInput: 22, output: 33, reasoningOutput: 6, total: 151)
            )
        )
        let appended = try await fixture.scanner.scan(url: fixture.logURL)
        let repeatedAppend = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(appended.processedLines == 1)
        #expect(repeatedAppend.processedLines == 0)
        #expect(try await fixture.totalUsage() == 151)
    }

    @Test
    func incompleteTrailingLineWaitsForNewline() async throws {
        let fixture = try await ScannerFixture()
        defer { fixture.remove() }
        let session = fixture.sessionLine(id: "s1")
        let token = fixture.tokenLine(
            second: 1,
            last: TokenUsage(input: 100, cachedInput: 20, output: 30, reasoningOutput: 5, total: 135)
        )
        try Data("\(session)\n\(token)".utf8).write(to: fixture.logURL)

        let incomplete = try await fixture.scanner.scan(url: fixture.logURL)
        #expect(incomplete.processedLines == 1)
        #expect(try await fixture.totalUsage() == 0)

        try fixture.appendRaw("\n")
        let completed = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(completed.processedLines == 1)
        #expect(try await fixture.totalUsage() == 135)
    }

    @Test
    func truncationRestartsAtZeroAndRewrittenLineHasDistinctIdentity() async throws {
        let fixture = try await ScannerFixture()
        defer { fixture.remove() }
        let session = fixture.sessionLine(id: "s1")
        try fixture.write([
            session,
            fixture.tokenLine(
                second: 1,
                last: TokenUsage(input: 100, cachedInput: 20, output: 30, reasoningOutput: 5, total: 135)
            ),
            String(repeating: "ignored-padding-", count: 80)
        ])
        let first = try await fixture.scanner.scan(url: fixture.logURL)

        try fixture.write([
            session,
            fixture.tokenLine(
                second: 1,
                last: TokenUsage(input: 101, cachedInput: 20, output: 30, reasoningOutput: 5, total: 136)
            )
        ])
        let rewritten = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(rewritten.finalOffset < first.finalOffset)
        #expect(rewritten.processedLines == 2)
        #expect(try await fixture.totalUsage() == 271)
    }

    @Test
    func oneFileCanSwitchFromParentToChildSession() async throws {
        let fixture = try await ScannerFixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionLine(id: "parent", project: "parent-project"),
            fixture.tokenLine(second: 1, last: fixture.usage(10)),
            fixture.sessionLine(id: "child", project: "child-project"),
            fixture.tokenLine(second: 2, last: fixture.usage(20)),
        ])

        _ = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(try await fixture.projectTotals() == ["child-project": 20, "parent-project": 10])
    }

    @Test
    func copiedParentHistoryAcrossBranchesIsCountedOnce() async throws {
        let fixture = try await ScannerFixture()
        defer { fixture.remove() }
        let parentSession = fixture.sessionLine(id: "parent", project: "parent-project")
        let parentToken = fixture.tokenLine(second: 1, last: fixture.usage(10))
        try fixture.write([parentSession, parentToken])
        _ = try await fixture.scanner.scan(url: fixture.logURL)

        let branchURL = fixture.directoryURL.appending(path: "branch.jsonl")
        try fixture.write([
            parentSession,
            parentToken,
            fixture.sessionLine(id: "child", project: "child-project"),
            fixture.tokenLine(second: 2, last: fixture.usage(20)),
        ], to: branchURL)
        _ = try await fixture.scanner.scan(url: branchURL)

        #expect(try await fixture.totalUsage() == 30)
    }

    @Test
    func appendedTokenUsesSessionStoredInFileCursor() async throws {
        let fixture = try await ScannerFixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionLine(id: "parent", project: "parent-project"),
            fixture.sessionLine(id: "child", project: "child-project"),
            fixture.tokenLine(second: 1, last: fixture.usage(10)),
        ])
        _ = try await fixture.scanner.scan(url: fixture.logURL)

        try fixture.append(fixture.tokenLine(second: 2, last: fixture.usage(20)))
        _ = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(try await fixture.projectTotals() == ["child-project": 30])
    }
}

private final class ScannerFixture: @unchecked Sendable {
    let directoryURL: URL
    let logURL: URL
    let repository: UsageRepository
    let scanner: SessionScanner

    init() async throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "SessionScannerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        logURL = directoryURL.appending(path: "synthetic-session.jsonl")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        scanner = SessionScanner(repository: repository)
        try await repository.migrate()
    }

    func write(_ lines: [String], to url: URL? = nil) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url ?? logURL)
    }

    func append(_ line: String) throws {
        try appendRaw("\(line)\n")
    }

    func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func totalUsage() async throws -> Int64 {
        try await repository.queryUsage(from: nil, to: .distantFuture)
            .map(\.usage.total)
            .reduce(0, +)
    }

    func projectTotals() async throws -> [String: Int64] {
        try await repository.queryUsage(from: nil, to: .distantFuture)
            .reduce(into: [:]) { totals, row in
                totals[row.projectName, default: 0] += row.usage.total
            }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func sessionLine(id: String, project: String = "alpha") -> String {
        """
        {"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"\(id)","cwd":"/synthetic/projects/\(project)"}}
        """
    }

    func usage(_ total: Int64) -> TokenUsage {
        TokenUsage(input: total, cachedInput: 0, output: 0, reasoningOutput: 0, total: total)
    }

    func tokenLine(
        second: Int,
        last: TokenUsage,
        cumulative: TokenUsage? = nil
    ) -> String {
        let cumulative = cumulative ?? last
        return """
        {"timestamp":"2026-07-14T01:00:\(String(format: "%02d", second))Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":\(usageJSON(last)),"total_token_usage":\(usageJSON(cumulative))}}}
        """
    }

    private func usageJSON(_ usage: TokenUsage) -> String {
        """
        {"input_tokens":\(usage.input),"cached_input_tokens":\(usage.cachedInput),"output_tokens":\(usage.output),"reasoning_output_tokens":\(usage.reasoningOutput),"total_tokens":\(usage.total)}
        """
    }
}
