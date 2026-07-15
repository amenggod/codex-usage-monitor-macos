import Foundation
import SQLite3
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
    func branchedHistoryIsDeduplicatedAndAppendUpdatesWithinTwoSeconds() async throws {
        let fixture = try EndToEndFixture(seedVersionOneDatabase: true)
        defer { fixture.remove() }
        let parentSession = fixture.sessionLine(
            sessionID: "parent-session",
            project: "parent-project",
            timestamp: "2026-07-15T03:00:00Z"
        )
        let parentToken = fixture.tokenLine(
            timestamp: "2026-07-15T03:00:01Z",
            last: TokenUsage(input: 10, cachedInput: 0, output: 0, reasoningOutput: 0, total: 10),
            cumulative: TokenUsage(input: 10, cachedInput: 0, output: 0, reasoningOutput: 0, total: 10)
        )
        _ = try fixture.writeLines(
            root: fixture.sessionsRoot,
            relativePath: "parent.jsonl",
            lines: [parentSession, parentToken]
        )
        let childURL = try fixture.writeLines(
            root: fixture.sessionsRoot,
            relativePath: "branches/child.jsonl",
            lines: [
                parentSession,
                parentToken,
                fixture.sessionLine(
                    sessionID: "child-session",
                    project: "child-project",
                    timestamp: "2026-07-15T03:00:02Z"
                ),
                fixture.tokenLine(
                    timestamp: "2026-07-15T03:00:03Z",
                    last: TokenUsage(input: 20, cachedInput: 0, output: 0, reasoningOutput: 0, total: 20),
                    cumulative: TokenUsage(input: 20, cachedInput: 0, output: 0, reasoningOutput: 0, total: 20),
                    limits: true,
                    includeFiveHourLimit: false
                )
            ]
        )

        let recorder = EndToEndUpdateRecorder()
        await recorder.observe(await fixture.coordinator.updates())
        defer { Task { await recorder.stop() } }
        await fixture.coordinator.start()
        #expect(await recorder.waitForCount(1))
        #expect(await recorder.value(at: 0) == .completed)
        #expect(try fixture.userVersion() == 2)
        #expect(try await fixture.repository.notificationWasSent(EndToEndFixture.migratedReceiptKey))

        try await fixture.coordinator.rebuildIndex()
        #expect(await recorder.waitForCount(5))
        #expect(await recorder.value(at: 1) == .rebuilding(completed: 0, total: 2))
        #expect(await recorder.value(at: 2) == .rebuilding(completed: 1, total: 2))
        #expect(await recorder.value(at: 3) == .rebuilding(completed: 2, total: 2))
        #expect(await recorder.value(at: 4) == .completed)

        let initial = try await fixture.snapshot()

        #expect(initial.total.total == 30)
        #expect(
            Dictionary(uniqueKeysWithValues: initial.projects.map { ($0.displayName, $0.usage.total) })
                == ["child-project": 20, "parent-project": 10]
        )
        #expect(initial.limits.map(\.window) == [.week])

        try fixture.appendToken(
            to: childURL,
            timestamp: "2026-07-15T03:00:04Z",
            last: TokenUsage(input: 5, cachedInput: 0, output: 0, reasoningOutput: 0, total: 5),
            cumulative: TokenUsage(input: 25, cachedInput: 0, output: 0, reasoningOutput: 0, total: 25)
        )

        #expect(try await fixture.waitForTotal(35, timeout: .seconds(2)))
        await fixture.coordinator.rescanAll()
        #expect(try await fixture.snapshot().total.total == 35)
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

private actor EndToEndUpdateRecorder {
    private var values: [IngestionUpdate] = []
    private var observationTask: Task<Void, Never>?

    func observe(_ stream: AsyncStream<IngestionUpdate>) {
        observationTask = Task { [weak self] in
            for await value in stream {
                await self?.record(value)
            }
        }
    }

    func waitForCount(_ expected: Int, attempts: Int = 60) async -> Bool {
        for _ in 0..<attempts {
            if values.count >= expected { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return values.count >= expected
    }

    func value(at index: Int) -> IngestionUpdate? {
        values.indices.contains(index) ? values[index] : nil
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func record(_ value: IngestionUpdate) {
        values.append(value)
    }
}

private final class EndToEndFixture: @unchecked Sendable {
    static let migratedReceiptKey = "synthetic-week|1784701200|20"

    let directoryURL: URL
    let codexHome: URL
    let sessionsRoot: URL
    let archivedRoot: URL
    let databaseURL: URL
    let repository: UsageRepository
    let coordinator: IngestionCoordinator
    let now = Date(timeIntervalSince1970: 1_784_089_200)

    init(createArchivedRoot: Bool = true, seedVersionOneDatabase: Bool = false) throws {
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
        databaseURL = directoryURL.appending(path: "index.sqlite")
        if seedVersionOneDatabase {
            try Self.createVersionOneDatabase(at: databaseURL)
        }
        repository = try UsageRepository(url: databaseURL)
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

    func userVersion() throws -> Int {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not inspect synthetic database")
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw SQLiteError(code: prepareResult, message: "could not inspect synthetic schema version")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteError(code: sqlite3_errcode(handle), message: "synthetic schema version missing")
        }
        return Int(sqlite3_column_int64(statement, 0))
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

    @discardableResult
    func writeLines(root: URL, relativePath: String, lines: [String]) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
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
        limits: Bool = false,
        includeFiveHourLimit: Bool = true
    ) -> String {
        let lastJSON = last.map { "\"last_token_usage\":\(usageJSON($0))," } ?? ""
        let fiveHourJSON = includeFiveHourLimit
            ? ",\"primary\":{\"used_percent\":28,\"window_minutes\":300,\"resets_at\":1784096400}"
            : ""
        let limitsJSON = limits
            ? ",\"rate_limits\":{\"limit_id\":\"codex\"\(fiveHourJSON),\"secondary\":{\"used_percent\":52,\"window_minutes\":10080,\"resets_at\":1784701200}}"
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

    private static func createVersionOneDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not create synthetic v1 database")
        }
        defer { sqlite3_close(handle) }

        let sql =
            """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              file_key TEXT NOT NULL UNIQUE,
              started_at REAL NOT NULL,
              project_key TEXT NOT NULL,
              project_name TEXT NOT NULL,
              full_path TEXT
            );
            CREATE TABLE notification_receipts (
              receipt_key TEXT PRIMARY KEY,
              sent_at REAL NOT NULL
            );
            INSERT INTO sessions (
              id, file_key, started_at, project_key, project_name, full_path
            ) VALUES (
              'synthetic-legacy-session', 'synthetic-legacy-file', 1000,
              '/synthetic/projects/legacy', 'legacy', '/synthetic/projects/legacy'
            );
            INSERT INTO notification_receipts (receipt_key, sent_at)
            VALUES ('\(migratedReceiptKey)', 1000);
            PRAGMA user_version = 1;
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            throw SQLiteError(
                code: result,
                message: errorMessage.map { String(cString: $0) } ?? "synthetic v1 SQL failed"
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
