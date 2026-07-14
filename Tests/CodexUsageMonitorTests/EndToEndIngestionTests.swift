import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite(.serialized)
struct EndToEndIngestionTests {
    @Test
    func liveAndArchivedSessionsProduceRangeProjectLimitAndRebuildSnapshots() async throws {
        let fixture = try EndToEndFixture()
        defer { fixture.remove() }
        try fixture.writeSession(
            root: fixture.sessionsRoot,
            relativePath: "2026/07/15/alpha.jsonl",
            sessionID: "alpha-today",
            project: "alpha",
            timestamp: "2026-07-15T03:00:00Z",
            usage: TokenUsage(input: 100, cachedInput: 20, output: 10, reasoningOutput: 5, total: 135)
        )
        try fixture.writeSession(
            root: fixture.sessionsRoot,
            relativePath: "2026/07/15/beta.jsonl",
            sessionID: "beta-today",
            project: "beta",
            timestamp: "2026-07-15T03:10:00Z",
            usage: TokenUsage(input: 100, cachedInput: 20, output: 10, reasoningOutput: 5, total: 135),
            limits: true
        )
        try fixture.writeSession(
            root: fixture.archivedRoot,
            relativePath: "alpha-previous-day.jsonl",
            sessionID: "alpha-archived",
            project: "alpha",
            timestamp: "2026-07-14T03:00:00Z",
            usage: TokenUsage(input: 60, cachedInput: 10, output: 5, reasoningOutput: 5, total: 80)
        )

        await fixture.coordinator.start()
        let before = try await fixture.snapshots()

        #expect(before.today.total.total == 270)
        #expect(before.sevenDays.total.total == 350)
        #expect(before.all.total.total == 350)
        #expect(before.today.projects.map(\.displayName) == ["alpha", "beta"])
        #expect(before.all.projects.map(\.displayName) == ["alpha", "beta"])
        #expect(before.all.projects.map(\.usage.total) == [215, 135])
        #expect(before.all.limits.map(\.remainingPercent) == [72, 48])

        try await fixture.coordinator.rebuildIndex()

        #expect(try await fixture.snapshots() == before)
        await fixture.coordinator.stop()
    }

    @Test
    func completeAppendIsObservedWithinTwoSecondsExactlyOnceAndArchiveMoveDoesNotDuplicate() async throws {
        let fixture = try EndToEndFixture()
        defer { fixture.remove() }
        let logURL = try fixture.writeSession(
            root: fixture.sessionsRoot,
            relativePath: "append.jsonl",
            sessionID: "append-session",
            project: "alpha",
            timestamp: "2026-07-15T03:00:00Z",
            usage: TokenUsage(input: 100, cachedInput: 20, output: 10, reasoningOutput: 5, total: 135)
        )
        await fixture.coordinator.start()

        try fixture.appendToken(
            to: logURL,
            timestamp: "2026-07-15T03:00:02Z",
            last: TokenUsage(input: 20, cachedInput: 0, output: 0, reasoningOutput: 0, total: 20),
            cumulative: TokenUsage(input: 120, cachedInput: 20, output: 10, reasoningOutput: 5, total: 155)
        )

        #expect(try await fixture.waitForTotal(155, timeout: .seconds(2)))
        await fixture.coordinator.rescanAll()
        await fixture.coordinator.rescanAll()
        #expect(try await fixture.snapshot(range: .all).total.total == 155)

        let archivedURL = fixture.archivedRoot.appending(path: "append.jsonl")
        try FileManager.default.moveItem(at: logURL, to: archivedURL)
        await fixture.coordinator.rescanAll()
        #expect(try await fixture.snapshot(range: .all).total.total == 155)
        await fixture.coordinator.stop()
    }

    @Test
    func malformedMiddleIncompleteTailAndTruncationRecoverWithoutLosingUsage() async throws {
        let fixture = try EndToEndFixture()
        defer { fixture.remove() }
        let logURL = fixture.sessionsRoot.appending(path: "session-truncated.jsonl")
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "session-truncated",
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        ))
        let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        try Data(contents.utf8).write(to: logURL)

        await fixture.coordinator.start()
        #expect(try await fixture.snapshot(range: .all).total.total == 90)

        try fixture.appendRaw(
            ",\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":105}}}}\n",
            to: logURL
        )
        #expect(try await fixture.waitForTotal(105, timeout: .seconds(2)))

        let truncated = [
            fixture.sessionLine(
                sessionID: "fixture-truncated",
                project: "gamma",
                timestamp: "2026-07-15T03:00:00Z"
            ),
            fixture.tokenLine(
                timestamp: "2026-07-15T03:00:04Z",
                last: nil,
                cumulative: TokenUsage(input: 115, cachedInput: 0, output: 0, reasoningOutput: 0, total: 115)
            )
        ].joined(separator: "\n") + "\n"
        try Data(truncated.utf8).write(to: logURL)
        await fixture.coordinator.rescanAll()

        #expect(try await fixture.snapshot(range: .all).total.total == 115)
        await fixture.coordinator.stop()
    }

    @Test
    func missingArchivedRootAtStartupRecoversWhenItAppears() async throws {
        let fixture = try EndToEndFixture(createArchivedRoot: false)
        defer { fixture.remove() }
        try fixture.writeSession(
            root: fixture.sessionsRoot,
            relativePath: "live.jsonl",
            sessionID: "live-session",
            project: "alpha",
            timestamp: "2026-07-15T03:00:00Z",
            usage: TokenUsage(input: 10, cachedInput: 0, output: 0, reasoningOutput: 0, total: 10)
        )
        await fixture.coordinator.start()
        #expect(try await fixture.snapshot(range: .all).total.total == 10)

        try FileManager.default.createDirectory(at: fixture.archivedRoot, withIntermediateDirectories: true)
        try fixture.writeSession(
            root: fixture.archivedRoot,
            relativePath: "recovered.jsonl",
            sessionID: "recovered-session",
            project: "beta",
            timestamp: "2026-07-14T03:00:00Z",
            usage: TokenUsage(input: 20, cachedInput: 0, output: 0, reasoningOutput: 0, total: 20)
        )

        #expect(try await fixture.waitForTotal(30, timeout: .seconds(2)))
        await fixture.coordinator.stop()
    }

    @Test
    func samePathReplacementIsIngestedWhenSizeAndModificationDateAreUnchanged() async throws {
        let fixture = try EndToEndFixture()
        defer { fixture.remove() }
        let logURL = fixture.sessionsRoot.appending(path: "replacement.jsonl")
        let original = fixture.sessionLog(sessionID: "replace-a", project: "alpha", total: 10)
        let replacement = fixture.sessionLog(sessionID: "replace-b", project: "bravo", total: 20)
        #expect(original.utf8.count == replacement.utf8.count)
        try Data(original.utf8).write(to: logURL)
        let fixedModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModifiedAt],
            ofItemAtPath: logURL.path
        )
        let originalValues = try logURL.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .contentModificationDateKey
        ])

        await fixture.coordinator.start()
        #expect(try await fixture.snapshot().total.total == 10)

        try FileManager.default.removeItem(at: logURL)
        try Data(replacement.utf8).write(to: logURL)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModifiedAt],
            ofItemAtPath: logURL.path
        )
        let replacementURL = URL(fileURLWithPath: logURL.path)
        let replacementValues = try replacementURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        #expect(
            String(describing: originalValues.fileResourceIdentifier)
                != String(describing: replacementValues.fileResourceIdentifier)
        )

        await fixture.coordinator.rescanAll()

        #expect(try await fixture.snapshot().total.total == 30)
        await fixture.coordinator.stop()
    }
}

private final class EndToEndFixture: @unchecked Sendable {
    let directoryURL: URL
    let codexHome: URL
    let sessionsRoot: URL
    let archivedRoot: URL
    let repository: UsageRepository
    let coordinator: IngestionCoordinator
    let now = Date(timeIntervalSince1970: 1_784_089_200)

    init(createArchivedRoot: Bool = true) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "EndToEndIngestionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        codexHome = directoryURL.appending(path: "CODEX_HOME", directoryHint: .isDirectory)
        let roots = CodexHomeLocator.sessionRoots(home: codexHome)
        sessionsRoot = roots[0]
        archivedRoot = roots[1]
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        if createArchivedRoot {
            try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        }
        repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let watcher = SessionFileWatcher(roots: roots)
        coordinator = IngestionCoordinator(
            roots: roots,
            repository: repository,
            scanner: scanner,
            watcher: watcher,
            recoveryDelay: .milliseconds(50),
            debounceDelay: .milliseconds(50)
        )
    }

    func snapshot(range: TokenRange = .all) async throws -> DashboardSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return try await UsageAggregator(repository: repository).snapshot(
            range: range,
            now: now,
            calendar: calendar
        )
    }

    func snapshots() async throws -> (today: DashboardSnapshot, sevenDays: DashboardSnapshot, all: DashboardSnapshot) {
        (
            try await snapshot(range: .today),
            try await snapshot(range: .sevenDays),
            try await snapshot(range: .all)
        )
    }

    func waitForTotal(_ expected: Int64, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if try await snapshot(range: .all).total.total == expected { return true }
            try await Task.sleep(for: .milliseconds(20))
        } while clock.now < deadline
        return try await snapshot(range: .all).total.total == expected
    }

    @discardableResult
    func writeSession(
        root: URL,
        relativePath: String,
        sessionID: String,
        project: String,
        timestamp: String,
        usage: TokenUsage,
        limits: Bool = false
    ) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = [
            sessionLine(sessionID: sessionID, project: project, timestamp: timestamp),
            tokenLine(timestamp: timestamp, last: usage, cumulative: usage, limits: limits)
        ].joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: url)
        return url
    }

    func appendToken(to url: URL, timestamp: String, last: TokenUsage, cumulative: TokenUsage) throws {
        try appendRaw(
            tokenLine(timestamp: timestamp, last: last, cumulative: cumulative) + "\n",
            to: url
        )
    }

    func appendRaw(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func sessionLog(sessionID: String, project: String, total: Int64) -> String {
        let usage = TokenUsage(input: total, cachedInput: 0, output: 0, reasoningOutput: 0, total: total)
        return [
            sessionLine(sessionID: sessionID, project: project, timestamp: "2026-07-15T03:00:00Z"),
            tokenLine(timestamp: "2026-07-15T03:00:01Z", last: usage, cumulative: usage)
        ].joined(separator: "\n") + "\n"
    }

    func sessionLine(sessionID: String, project: String, timestamp: String) -> String {
        """
        {"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/synthetic/projects/\(project)"}}
        """
    }

    func tokenLine(
        timestamp: String,
        last: TokenUsage?,
        cumulative: TokenUsage,
        limits: Bool = false
    ) -> String {
        let lastJSON = last.map { "\"last_token_usage\":\(usageJSON($0))," } ?? ""
        let limitsJSON = limits
            ? ",\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":28,\"window_minutes\":300,\"resets_at\":1784096400},\"secondary\":{\"used_percent\":52,\"window_minutes\":10080,\"resets_at\":1784701200}}"
            : ""
        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{\(lastJSON)"total_token_usage":\(usageJSON(cumulative))}\(limitsJSON)}}
        """
    }

    private func usageJSON(_ usage: TokenUsage) -> String {
        """
        {"input_tokens":\(usage.input),"cached_input_tokens":\(usage.cachedInput),"output_tokens":\(usage.output),"reasoning_output_tokens":\(usage.reasoningOutput),"total_tokens":\(usage.total)}
        """
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
