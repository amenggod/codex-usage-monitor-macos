import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import CodexUsageMonitor

@Suite(.serialized)
struct EndToEndIngestionTests {
    @Test
    func oldVersionTwoMillisecondIndexRebuildsOnceAndPreservesReceipt() async throws {
        let fixture = try IdentityUpgradeFixture(kind: .oldMillisecondIndex)
        defer { fixture.remove() }

        try await fixture.repository.migrate()
        _ = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(try await fixture.totalUsage() == 10)
        #expect(try fixture.eventCount() == 1)
        #expect(try fixture.indexFormatVersion() == 2)
        #expect(try await fixture.repository.notificationWasSent(fixture.receiptKey))

        try await fixture.repository.migrate()
        _ = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(try await fixture.totalUsage() == 10)
        #expect(try fixture.eventCount() == 1)
        #expect(try fixture.indexFormatVersion() == 2)
        #expect(try await fixture.repository.notificationWasSent(fixture.receiptKey))
    }

    @Test
    func fingerprintPatchedVersionTwoWithoutMarkerDropsDuplicateIdentitiesAndRebuildsOnce() async throws {
        let fixture = try IdentityUpgradeFixture(kind: .fingerprintPatchedDuplicates)
        defer { fixture.remove() }
        #expect(try fixture.eventCount() == 2)

        try await fixture.repository.migrate()
        _ = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(try await fixture.totalUsage() == 10)
        #expect(try fixture.eventCount() == 1)
        #expect(try fixture.indexFormatVersion() == 2)
        #expect(try await fixture.repository.notificationWasSent(fixture.receiptKey))

        try await fixture.repository.migrate()
        _ = try await fixture.scanner.scan(url: fixture.logURL)

        #expect(try await fixture.totalUsage() == 10)
        #expect(try fixture.eventCount() == 1)
        #expect(try fixture.indexFormatVersion() == 2)
        #expect(try await fixture.repository.notificationWasSent(fixture.receiptKey))
    }

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
        let fixtureURL = try #require(TestResourceBundle.fixtureURL(
            forResource: "session-truncated",
            withExtension: "jsonl"
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

private final class IdentityUpgradeFixture {
    enum Kind {
        case oldMillisecondIndex
        case fingerprintPatchedDuplicates
    }

    let directoryURL: URL
    let logURL: URL
    let databaseURL: URL
    let receiptKey = "identity-upgrade-receipt"
    let repository: UsageRepository
    let scanner: SessionScanner

    init(kind: Kind) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "IdentityUpgradeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sessionsRoot = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        logURL = sessionsRoot.appending(path: "identity-upgrade.jsonl")
        databaseURL = directoryURL.appending(path: "index.sqlite")

        let usage = TokenUsage(
            input: 10,
            cachedInput: 0,
            output: 0,
            reasoningOutput: 0,
            total: 10
        )
        let timestamp = "2026-07-15T03:00:01.123456Z"
        let log =
            """
            {"timestamp":"2026-07-15T03:00:00Z","type":"session_meta","payload":{"id":"identity-upgrade","cwd":"/synthetic/projects/identity-upgrade"}}
            {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":10},"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":10}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":28,"window_minutes":300,"resets_at":1784096400}}}}
            """ + "\n"
        let logData = Data(log.utf8)
        try logData.write(to: logURL)
        let occurredAt = try Self.date(timestamp)
        let event = ParsedTokenEvent(
            occurredAt: occurredAt,
            lastUsage: usage,
            cumulativeUsage: usage,
            limits: []
        )
        let legacyID = Self.legacyIdentity(sessionID: "identity-upgrade", event: event)
        let currentID = TokenEventIdentity.make(sessionID: "identity-upgrade", event: event)
        let fileKey = try Self.fileKey(for: logURL)
        let boundaryFingerprint = Data(SHA256.hash(data: logData)).base64EncodedString()
        try Self.createVersionTwoDatabase(
            at: databaseURL,
            kind: kind,
            logURL: logURL,
            fileKey: fileKey,
            fileSize: logData.count,
            boundaryFingerprint: boundaryFingerprint,
            occurredAt: occurredAt,
            legacyID: legacyID,
            currentID: currentID,
            receiptKey: receiptKey
        )

        repository = try UsageRepository(url: databaseURL)
        scanner = SessionScanner(repository: repository)
    }

    func totalUsage() async throws -> Int64 {
        try await repository.queryUsage(from: nil, to: .distantFuture)
            .map(\.usage.total)
            .reduce(0, +)
    }

    func eventCount() throws -> Int {
        try queryInteger("SELECT COUNT(*) FROM usage_events") ?? 0
    }

    func indexFormatVersion() throws -> Int? {
        guard try queryInteger(
            "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name = 'index_metadata'"
        ) == 1 else {
            return nil
        }
        return try queryInteger(
            "SELECT value FROM index_metadata WHERE key = 'event_identity_version' LIMIT 1"
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func queryInteger(_ sql: String) throws -> Int? {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not inspect identity fixture")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw SQLiteError(
                code: prepareResult,
                message: String(cString: sqlite3_errmsg(handle))
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func createVersionTwoDatabase(
        at url: URL,
        kind: Kind,
        logURL: URL,
        fileKey: String,
        fileSize: Int,
        boundaryFingerprint: String,
        occurredAt: Date,
        legacyID: String,
        currentID: String,
        receiptKey: String
    ) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not create identity fixture")
        }
        defer { sqlite3_close(handle) }

        let hasFingerprint = kind == .fingerprintPatchedDuplicates
        let fingerprintColumn = hasFingerprint ? ", boundary_fingerprint TEXT" : ""
        let fingerprintName = hasFingerprint ? ", boundary_fingerprint" : ""
        let fingerprintValue = hasFingerprint ? ", '\(sql(boundaryFingerprint))'" : ""
        let duplicateEvent = kind == .fingerprintPatchedDuplicates
            ? usageEventInsert(id: currentID, occurredAt: occurredAt)
            : ""
        let fixtureSQL =
            """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              started_at REAL NOT NULL,
              project_key TEXT NOT NULL,
              project_name TEXT NOT NULL,
              full_path TEXT
            );
            CREATE TABLE usage_events (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              occurred_at REAL NOT NULL,
              last_input_tokens INTEGER,
              last_cached_input_tokens INTEGER,
              last_output_tokens INTEGER,
              last_reasoning_output_tokens INTEGER,
              last_total_tokens INTEGER,
              cumulative_input_tokens INTEGER,
              cumulative_cached_input_tokens INTEGER,
              cumulative_output_tokens INTEGER,
              cumulative_reasoning_output_tokens INTEGER,
              cumulative_total_tokens INTEGER,
              delta_input_tokens INTEGER NOT NULL,
              delta_cached_input_tokens INTEGER NOT NULL,
              delta_output_tokens INTEGER NOT NULL,
              delta_reasoning_output_tokens INTEGER NOT NULL,
              delta_total_tokens INTEGER NOT NULL
            );
            CREATE INDEX usage_events_time ON usage_events(occurred_at);
            CREATE INDEX usage_events_session ON usage_events(session_id);
            CREATE TABLE file_cursors (
              file_key TEXT PRIMARY KEY,
              path TEXT NOT NULL,
              byte_offset INTEGER NOT NULL,
              modified_at REAL NOT NULL,
              active_session_id TEXT\(fingerprintColumn)
            );
            CREATE TABLE cumulative_usage (
              session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              reasoning_output_tokens INTEGER NOT NULL,
              total_tokens INTEGER NOT NULL
            );
            CREATE TABLE rate_limits (
              window_key TEXT PRIMARY KEY,
              limit_id TEXT NOT NULL,
              window_minutes INTEGER NOT NULL,
              window_label TEXT,
              used_percent REAL NOT NULL,
              resets_at REAL NOT NULL,
              observed_at REAL NOT NULL
            );
            CREATE TABLE notification_receipts (
              receipt_key TEXT PRIMARY KEY,
              sent_at REAL NOT NULL
            );
            INSERT INTO sessions (id, started_at, project_key, project_name, full_path)
            VALUES (
              'identity-upgrade', 1784084400,
              '/synthetic/projects/identity-upgrade', 'identity-upgrade',
              '/synthetic/projects/identity-upgrade'
            );
            \(usageEventInsert(id: legacyID, occurredAt: occurredAt))
            \(duplicateEvent)
            INSERT INTO file_cursors (
              file_key, path, byte_offset, modified_at, active_session_id\(fingerprintName)
            ) VALUES (
              '\(sql(fileKey))', '\(sql(logURL.path))', \(fileSize), 1784084401,
              'identity-upgrade'\(fingerprintValue)
            );
            INSERT INTO cumulative_usage (
              session_id, input_tokens, cached_input_tokens, output_tokens,
              reasoning_output_tokens, total_tokens
            ) VALUES ('identity-upgrade', 10, 0, 0, 0, 10);
            INSERT INTO rate_limits (
              window_key, limit_id, window_minutes, window_label,
              used_percent, resets_at, observed_at
            ) VALUES ('five-hours', 'codex', 300, NULL, 28, 1784096400, 1784084401);
            INSERT INTO notification_receipts (receipt_key, sent_at)
            VALUES ('\(sql(receiptKey))', 1784084401);
            PRAGMA user_version = 2;
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, fixtureSQL, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            throw SQLiteError(
                code: result,
                message: errorMessage.map { String(cString: $0) } ?? "identity fixture SQL failed"
            )
        }
    }

    private static func usageEventInsert(id: String, occurredAt: Date) -> String {
        """
        INSERT INTO usage_events (
          id, session_id, occurred_at,
          last_input_tokens, last_cached_input_tokens, last_output_tokens,
          last_reasoning_output_tokens, last_total_tokens,
          cumulative_input_tokens, cumulative_cached_input_tokens,
          cumulative_output_tokens, cumulative_reasoning_output_tokens,
          cumulative_total_tokens, delta_input_tokens, delta_cached_input_tokens,
          delta_output_tokens, delta_reasoning_output_tokens, delta_total_tokens
        ) VALUES (
          '\(sql(id))', 'identity-upgrade', \(occurredAt.timeIntervalSince1970),
          10, 0, 0, 0, 10,
          10, 0, 0, 0, 10,
          10, 0, 0, 0, 10
        );
        """
    }

    private static func legacyIdentity(
        sessionID: String,
        event: ParsedTokenEvent
    ) -> String {
        var payload = Data()
        let sessionData = Data(sessionID.utf8)
        append(Int64(sessionData.count), to: &payload)
        payload.append(sessionData)
        append(
            Int64((event.occurredAt.timeIntervalSince1970 * 1_000).rounded()),
            to: &payload
        )
        append(event.lastUsage, to: &payload)
        append(event.cumulativeUsage, to: &payload)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func append(_ usage: TokenUsage?, to data: inout Data) {
        guard let usage else {
            data.append(0)
            return
        }
        data.append(1)
        append(usage.input, to: &data)
        append(usage.cachedInput, to: &data)
        append(usage.output, to: &data)
        append(usage.reasoningOutput, to: &data)
        append(usage.total, to: &data)
    }

    private static func append(_ integer: Int64, to data: inout Data) {
        var bigEndian = integer.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else {
            throw SQLiteError(code: SQLITE_MISMATCH, message: "invalid identity fixture date")
        }
        return date
    }

    private static func fileKey(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        return values.fileResourceIdentifier
            .map { String(describing: $0) }
            ?? url.standardizedFileURL.path
    }

    private static func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
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
