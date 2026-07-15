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
    func equalLengthSameInodeRewriteRestartsAtZero() async throws {
        let fixture = try await ScannerFixture()
        defer { fixture.remove() }
        let original = fixture.encodedLines([
            fixture.sessionLine(id: "old-session", project: "old-one"),
            fixture.tokenLine(second: 1, last: fixture.usage(10)),
        ])
        let rewritten = fixture.encodedLines([
            fixture.sessionLine(id: "new-session", project: "new-two"),
            fixture.tokenLine(second: 1, last: fixture.usage(20)),
        ])
        #expect(original.count == rewritten.count)
        try original.write(to: fixture.logURL)
        let originalFileKey = try fixture.fileKey()
        _ = try await fixture.scanner.scan(url: fixture.logURL)

        try fixture.overwriteInPlace(with: rewritten)
        #expect(try fixture.fileKey() == originalFileKey)
        let result = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(result.processedLines == 2)
        #expect(try await fixture.projectTotals() == ["new-two": 20, "old-one": 10])
    }

    @Test
    func longerSameInodeRewriteClearsTheStaleActiveSession() async throws {
        let fixture = try await ScannerFixture()
        defer { fixture.remove() }
        let original = fixture.encodedLines([
            fixture.sessionLine(id: "old-session", project: "old-one"),
            fixture.tokenLine(second: 1, last: fixture.usage(10)),
        ])
        try original.write(to: fixture.logURL)
        let originalFileKey = try fixture.fileKey()
        _ = try await fixture.scanner.scan(url: fixture.logURL)

        let sameLengthInvalidPrefix = Data(
            (String(repeating: "x", count: original.count - 1) + "\n").utf8
        )
        let orphanToken = Data(
            (fixture.tokenLine(second: 2, last: fixture.usage(90)) + "\n").utf8
        )
        try fixture.overwriteInPlace(with: sameLengthInvalidPrefix + orphanToken)
        #expect(try fixture.fileKey() == originalFileKey)
        let result = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(result.finalOffset > UInt64(original.count))
        #expect(try await fixture.totalUsage() == 10)
        let cursor = try await fixture.repository.cursor(for: originalFileKey)
        #expect(cursor?.activeSessionID == nil)
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
        try encodedLines(lines).write(to: url ?? logURL)
    }

    func encodedLines(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    func overwriteInPlace(with data: Data) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
    }

    func fileKey() throws -> String {
        let values = try logURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        return values.fileResourceIdentifier
            .map { String(describing: $0) }
            ?? logURL.standardizedFileURL.path
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
