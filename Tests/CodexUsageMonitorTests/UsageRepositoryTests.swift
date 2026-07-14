import Foundation
import SQLite3
import Testing
@testable import CodexUsageMonitor

@Suite
struct UsageRepositoryTests {
    @Test
    func duplicateEventIDIsCountedOnce() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }

        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let project = ProjectIdentity(
            key: "/synthetic/alpha",
            displayName: "alpha",
            fullPath: "/synthetic/alpha"
        )
        try await repository.upsertSession(
            SessionMetadata(
                sessionID: "s1",
                startedAt: Date(timeIntervalSince1970: 100),
                workingDirectory: project.fullPath
            ),
            fileKey: "file-1",
            project: project
        )
        let usage = TokenUsage(
            input: 10,
            cachedInput: 2,
            output: 3,
            reasoningOutput: 1,
            total: 13
        )
        try await repository.insertUsageEvent(
            id: "file:100",
            sessionID: "s1",
            occurredAt: Date(timeIntervalSince1970: 200),
            usage: usage
        )
        try await repository.insertUsageEvent(
            id: "file:100",
            sessionID: "s1",
            occurredAt: Date(timeIntervalSince1970: 200),
            usage: usage
        )

        let rows = try await repository.queryUsage(from: nil, to: .distantFuture)

        #expect(rows.map(\.usage.total).reduce(0, +) == 13)
    }

    @Test
    func sessionCanBeFoundByFileKey() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let project = ProjectIdentity(key: "unknown", displayName: "未知项目", fullPath: nil)
        try await repository.upsertSession(
            SessionMetadata(
                sessionID: "session-with-bound-strings",
                startedAt: Date(timeIntervalSince1970: 100),
                workingDirectory: nil
            ),
            fileKey: "file-'?; DROP TABLE sessions; --",
            project: project
        )

        let sessionID = try await repository.sessionID(forFileKey: "file-'?; DROP TABLE sessions; --")

        #expect(sessionID == "session-with-bound-strings")
    }

    @Test
    func cumulativeUsageRoundTripsAndKeepsAuthoritativeTotal() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let project = ProjectIdentity(key: "/synthetic/alpha", displayName: "alpha", fullPath: nil)
        try await repository.upsertSession(
            SessionMetadata(
                sessionID: "s1",
                startedAt: Date(timeIntervalSince1970: 100),
                workingDirectory: nil
            ),
            fileKey: "file-1",
            project: project
        )
        let first = TokenUsage(input: 100, cachedInput: 20, output: 30, reasoningOutput: 4, total: 777)
        let latest = TokenUsage(input: 120, cachedInput: 25, output: 35, reasoningOutput: 6, total: 888)

        try await repository.saveCumulativeUsage(first, sessionID: "s1")
        try await repository.saveCumulativeUsage(latest, sessionID: "s1")

        #expect(try await repository.previousCumulativeUsage(sessionID: "s1") == latest)
    }

    @Test
    func cursorRoundTripsBoundPathAndFullUInt64Offset() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let cursor = FileCursor(
            fileKey: "file-'?; --",
            path: "/synthetic/alpha/'?; DROP TABLE file_cursors; --",
            offset: UInt64.max,
            modifiedAt: Date(timeIntervalSince1970: 123.456)
        )

        try await repository.saveCursor(cursor)

        #expect(try await repository.cursor(for: cursor.fileKey) == cursor)
    }

    @Test
    func notificationReceiptIsIdempotent() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()

        #expect(try await !repository.notificationWasSent("five-hours-80%"))
        try await repository.markNotificationSent(
            "five-hours-80%",
            sentAt: Date(timeIntervalSince1970: 500)
        )
        try await repository.markNotificationSent(
            "five-hours-80%",
            sentAt: Date(timeIntervalSince1970: 600)
        )
        #expect(try await repository.notificationWasSent("five-hours-80%"))
    }

    @Test
    func futureSchemaRecoveryRecreatesNotificationReceipts() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        try await repository.markNotificationSent(
            "five-hours|2000|20",
            sentAt: Date(timeIntervalSince1970: 1_000)
        )
        try setUserVersion(99, at: databaseURL)

        try await repository.migrate()

        #expect(try await !repository.notificationWasSent("five-hours|2000|20"))
        try await repository.markNotificationSent(
            "week|4000|10",
            sentAt: Date(timeIntervalSince1970: 3_000)
        )
        #expect(try await repository.notificationWasSent("week|4000|10"))
        #expect(try await repository.queryUsage(from: nil, to: .distantFuture).isEmpty)
    }

    @Test
    func futureIncompatibleReceiptSchemaIsRecreatedBeforeMigrationCompletes() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        try createFutureReceiptDatabase(at: databaseURL)
        let repository = try UsageRepository(url: databaseURL)

        try await repository.migrate()

        #expect(try receiptColumnNames(at: databaseURL) == ["receipt_key", "sent_at"])
        do {
            try await repository.markNotificationSent(
                "five-hours|6000|20",
                sentAt: Date(timeIntervalSince1970: 5_000)
            )
            #expect(try await repository.notificationWasSent("five-hours|6000|20"))
        } catch {
            Issue.record("current notification receipt schema should be writable: \(error)")
        }
    }

    @Test
    func laterLimitObservationWins() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let earlier = RateLimitObservation(
            limitID: "codex",
            window: .fiveHours,
            usedPercent: 20,
            resetsAt: Date(timeIntervalSince1970: 2_000),
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let later = RateLimitObservation(
            limitID: "codex",
            window: .fiveHours,
            usedPercent: 40,
            resetsAt: Date(timeIntervalSince1970: 2_500),
            observedAt: Date(timeIntervalSince1970: 1_500)
        )

        try await repository.replaceLatestLimits([earlier])
        try await repository.replaceLatestLimits([later])

        #expect(try await repository.latestLimits() == [later])
    }

    @Test
    func earlierLimitObservationCannotOverwriteLatestUnknownWindow() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let later = RateLimitObservation(
            limitID: "flex",
            window: .other(minutes: 60, label: "Flexible"),
            usedPercent: 75,
            resetsAt: Date(timeIntervalSince1970: 3_000),
            observedAt: Date(timeIntervalSince1970: 2_000)
        )
        let earlier = RateLimitObservation(
            limitID: "stale",
            window: .other(minutes: 60, label: "Flexible"),
            usedPercent: 10,
            resetsAt: Date(timeIntervalSince1970: 2_500),
            observedAt: Date(timeIntervalSince1970: 1_000)
        )

        try await repository.replaceLatestLimits([later])
        try await repository.replaceLatestLimits([earlier])

        #expect(try await repository.latestLimits() == [later])
    }

    @Test
    func corruptDatabaseIsPreservedAndRebuilt() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer {
            removeDatabase(at: databaseURL)
            removeDatabase(at: URL(fileURLWithPath: databaseURL.path + ".corrupt-1"))
        }
        let invalidBytes = Data("not a sqlite database".utf8)
        try invalidBytes.write(to: databaseURL)

        let repository = try UsageRepository.openRecovering(
            url: databaseURL,
            now: Date(timeIntervalSince1970: 1)
        )
        try await repository.migrate()

        let corruptCopyURL = URL(fileURLWithPath: databaseURL.path + ".corrupt-1")
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(try Data(contentsOf: corruptCopyURL) == invalidBytes)
    }

    @Test
    func pageLevelCorruptionIsDetectedBeforeRepositoryIsReturned() async throws {
        let databaseURL = temporaryDatabaseURL()
        let corruptCopyURL = URL(fileURLWithPath: databaseURL.path + ".corrupt-10")
        defer {
            removeDatabase(at: databaseURL)
            removeDatabase(at: corruptCopyURL)
        }
        try createDatabaseWithCorruptTableRootPage(at: databaseURL)

        do {
            let probe = try SQLiteDatabase(url: databaseURL)
            var version: Int64 = 0
            try probe.query("PRAGMA user_version") { statement in
                version = sqlite3_column_int64(statement, 0)
            }
            #expect(version == 1)
        }

        let repository = try UsageRepository.openRecovering(
            url: databaseURL,
            now: Date(timeIntervalSince1970: 10)
        )
        try await repository.migrate()

        #expect(FileManager.default.fileExists(atPath: corruptCopyURL.path))
        #expect(try await !repository.notificationWasSent("fresh-index"))
    }

    @Test
    func corruptSidecarsArePreservedBesideBackupDatabase() async throws {
        let databaseURL = temporaryDatabaseURL()
        let backupURL = URL(fileURLWithPath: databaseURL.path + ".corrupt-20")
        let sourceWAL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let sourceSHM = URL(fileURLWithPath: databaseURL.path + "-shm")
        let backupWAL = URL(fileURLWithPath: backupURL.path + "-wal")
        let backupSHM = URL(fileURLWithPath: backupURL.path + "-shm")
        defer {
            removeDatabase(at: databaseURL)
            removeDatabase(at: backupURL)
            try? FileManager.default.removeItem(atPath: sourceWAL.path + ".corrupt-20")
            try? FileManager.default.removeItem(atPath: sourceSHM.path + ".corrupt-20")
        }
        let walBytes = Data("synthetic-wal-sidecar".utf8)
        let shmBytes = Data("synthetic-shm-sidecar".utf8)
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        try walBytes.write(to: sourceWAL)
        try shmBytes.write(to: sourceSHM)

        do {
            let repository = try UsageRepository.openRecovering(
                url: databaseURL,
                now: Date(timeIntervalSince1970: 20)
            )
            try await repository.migrate()
        }

        #expect(try Data(contentsOf: backupWAL) == walBytes)
        #expect(try Data(contentsOf: backupSHM) == shmBytes)
        #expect((try? Data(contentsOf: sourceWAL)) != walBytes)
        #expect((try? Data(contentsOf: sourceSHM)) != shmBytes)
    }

    @Test
    func sameSecondBackupCollisionUsesNextCompleteFileSet() async throws {
        let databaseURL = temporaryDatabaseURL()
        let existingBackupURL = URL(fileURLWithPath: databaseURL.path + ".corrupt-30")
        let nextBackupURL = URL(fileURLWithPath: databaseURL.path + ".corrupt-30-1")
        let existingBytes = Data("existing-backup".utf8)
        let corruptBytes = Data("new-corrupt-database".utf8)
        let walBytes = Data("new-corrupt-wal".utf8)
        let shmBytes = Data("new-corrupt-shm".utf8)
        defer {
            removeDatabase(at: databaseURL)
            removeDatabase(at: existingBackupURL)
            removeDatabase(at: nextBackupURL)
        }
        try existingBytes.write(to: existingBackupURL)
        try corruptBytes.write(to: databaseURL)
        try walBytes.write(to: URL(fileURLWithPath: databaseURL.path + "-wal"))
        try shmBytes.write(to: URL(fileURLWithPath: databaseURL.path + "-shm"))

        do {
            let repository = try UsageRepository.openRecovering(
                url: databaseURL,
                now: Date(timeIntervalSince1970: 30)
            )
            try await repository.migrate()
        }

        #expect(try Data(contentsOf: existingBackupURL) == existingBytes)
        #expect(try Data(contentsOf: nextBackupURL) == corruptBytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: nextBackupURL.path + "-wal")) == walBytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: nextBackupURL.path + "-shm")) == shmBytes)
    }

    @Test
    func nonCorruptionOpenErrorsPropagateWithoutBackup() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "UsageRepositoryTests-directory-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        do {
            _ = try UsageRepository.openRecovering(
                url: directoryURL,
                now: Date(timeIntervalSince1970: 2)
            )
            Issue.record("expected SQLite open error")
        } catch let error as SQLiteError {
            #expect(error.code != SQLITE_CORRUPT)
            #expect(error.code != SQLITE_NOTADB)
        }

        #expect(!FileManager.default.fileExists(atPath: directoryURL.path + ".corrupt-2"))
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "UsageRepositoryTests-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func createDatabaseWithCorruptTableRootPage(at url: URL) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not create corruption fixture")
        }

        let pageSize: Int
        let rootPage: Int
        do {
            try executeRawSQL(
                "CREATE TABLE damaged_payload (id INTEGER PRIMARY KEY, value TEXT); " +
                "INSERT INTO damaged_payload (value) VALUES ('synthetic'); " +
                "PRAGMA user_version = 1;",
                handle: handle
            )
            pageSize = try queryRawInteger("PRAGMA page_size", handle: handle)
            rootPage = try queryRawInteger(
                "SELECT rootpage FROM sqlite_schema WHERE name = 'damaged_payload'",
                handle: handle
            )
        } catch {
            sqlite3_close(handle)
            throw error
        }
        guard sqlite3_close(handle) == SQLITE_OK else {
            throw SQLiteError(code: SQLITE_BUSY, message: "could not close corruption fixture")
        }

        var bytes = try Data(contentsOf: url)
        let pageStart = (rootPage - 1) * pageSize
        let pageEnd = pageStart + pageSize
        guard pageStart >= 100, pageEnd <= bytes.count else {
            throw SQLiteError(code: SQLITE_CORRUPT, message: "invalid synthetic root page range")
        }
        bytes.replaceSubrange(pageStart..<pageEnd, with: repeatElement(UInt8(0), count: pageSize))
        try bytes.write(to: url, options: .atomic)
    }

    private func createFutureReceiptDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not create future schema fixture")
        }
        defer { sqlite3_close(handle) }
        try executeRawSQL(
            """
            CREATE TABLE notification_receipts (
              future_key INTEGER PRIMARY KEY,
              future_payload BLOB NOT NULL
            );
            INSERT INTO notification_receipts (future_key, future_payload)
            VALUES (1, X'0102');
            PRAGMA user_version = 99;
            """,
            handle: handle
        )
    }

    private func receiptColumnNames(at url: URL) throws -> [String] {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not inspect receipt schema")
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            handle,
            "PRAGMA table_info(notification_receipts)",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw SQLiteError(code: prepareResult, message: "could not inspect receipt columns")
        }
        defer { sqlite3_finalize(statement) }

        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 1) else { continue }
            columns.append(String(cString: value))
        }
        return columns
    }

    private func setUserVersion(_ version: Int, at url: URL) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not open version fixture")
        }
        defer { sqlite3_close(handle) }
        try executeRawSQL("PRAGMA user_version = \(version)", handle: handle)
    }

    private func executeRawSQL(_ sql: String, handle: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            throw SQLiteError(
                code: result,
                message: errorMessage.map { String(cString: $0) } ?? "raw SQL failed"
            )
        }
    }

    private func queryRawInteger(_ sql: String, handle: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw SQLiteError(code: prepareResult, message: "raw query prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteError(code: sqlite3_errcode(handle), message: "raw query returned no row")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
