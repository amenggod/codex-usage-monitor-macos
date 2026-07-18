import Foundation
import SQLite3
import Testing
@testable import CodexUsageMonitor

@Suite
struct UsageRepositoryTests {
    @Test
    func newDatabaseWritesCurrentEventIdentityMarkerImmediately() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)

        try await repository.migrate()

        let hasMetadataTable = try queryRawInteger(
            "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name = 'index_metadata'",
            at: databaseURL
        ) == 1
        #expect(hasMetadataTable)
        if hasMetadataTable {
            #expect(try queryRawInteger(
                "SELECT value FROM index_metadata WHERE key = 'event_identity_version'",
                at: databaseURL
            ) == 2)
        }

        try await repository.migrate()
        if hasMetadataTable {
            #expect(try queryRawInteger(
                "SELECT value FROM index_metadata WHERE key = 'event_identity_version'",
                at: databaseURL
            ) == 2)
        }
    }

    @Test
    func duplicateLogicalEventsAcrossFileBatchesAreCountedOnce() async throws {
        let fixture = try await RepositoryBatchFixture()
        defer { fixture.remove() }
        let event = fixture.event(sessionID: "parent", second: 1, lastTotal: 25, cumulativeTotal: 25)

        let first = try await fixture.repository.apply(fixture.batch(fileKey: "file-a", events: [event]))
        let duplicate = try await fixture.repository.apply(fixture.batch(fileKey: "file-b", events: [event]))

        #expect(first == FileIngestionResult(insertedEvents: 1, duplicateEvents: 0))
        #expect(duplicate == FileIngestionResult(insertedEvents: 0, duplicateEvents: 1))
        #expect(try await fixture.total() == 25)
    }

    @Test
    func cumulativeOnlyEventsRecomputeWhenOlderEventArrivesLater() async throws {
        let fixture = try await RepositoryBatchFixture()
        defer { fixture.remove() }
        let later = fixture.cumulativeOnlyEvent(sessionID: "s", second: 2, cumulativeTotal: 30)
        let earlier = fixture.cumulativeOnlyEvent(sessionID: "s", second: 1, cumulativeTotal: 10)

        _ = try await fixture.repository.apply(fixture.batch(fileKey: "later", events: [later]))
        _ = try await fixture.repository.apply(fixture.batch(fileKey: "earlier", events: [earlier]))

        #expect(try await fixture.total() == 30)
    }

    @Test
    func mixedUsageEventRecomputesLaterCumulativeOnlyEventWhenArrivingOutOfOrder() async throws {
        let fixture = try await RepositoryBatchFixture()
        defer { fixture.remove() }
        let later = fixture.cumulativeOnlyEvent(sessionID: "s", second: 2, cumulativeTotal: 30)
        let earlier = fixture.event(sessionID: "s", second: 1, lastTotal: 10, cumulativeTotal: 10)

        _ = try await fixture.repository.apply(fixture.batch(fileKey: "later", events: [later]))
        _ = try await fixture.repository.apply(fixture.batch(fileKey: "earlier", events: [earlier]))

        #expect(try await fixture.total() == 30)
    }

    @Test
    func failedBatchRollsBackAllWrites() async throws {
        let fixture = try await RepositoryBatchFixture()
        defer { fixture.remove() }
        let event = fixture.event(sessionID: "s", second: 1, lastTotal: 25, cumulativeTotal: 25)
        let base = fixture.batch(fileKey: "failed-file", events: [event])
        let validLimit = RateLimitObservation(
            limitID: "valid",
            window: .fiveHours,
            usedPercent: 20,
            resetsAt: Date(timeIntervalSince1970: 2_000),
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let invalidLimit = RateLimitObservation(
            limitID: "invalid",
            window: .week,
            usedPercent: .nan,
            resetsAt: Date(timeIntervalSince1970: 2_000),
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let batch = FileIngestionBatch(
            sessions: base.sessions,
            events: base.events,
            limits: [validLimit, invalidLimit],
            cursor: base.cursor
        )

        do {
            _ = try await fixture.repository.apply(batch)
            Issue.record("expected the invalid limit to fail its SQLite constraint")
        } catch let error as SQLiteError {
            #expect(error.code == SQLITE_CONSTRAINT)
        }

        #expect(try queryRawInteger("SELECT COUNT(*) FROM sessions", at: fixture.databaseURL) == 0)
        #expect(try queryRawInteger("SELECT COUNT(*) FROM usage_events", at: fixture.databaseURL) == 0)
        #expect(try queryRawInteger("SELECT COUNT(*) FROM rate_limits", at: fixture.databaseURL) == 0)
        #expect(try await fixture.repository.cursor(for: "failed-file") == nil)
    }

    @Test
    func v1MigrationCreatesMultiSessionSchemaAndPreservesReceipts() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        try createVersionOneDatabase(
            at: databaseURL,
            receiptKey: "week|4000|20"
        )
        let repository = try UsageRepository(url: databaseURL)

        try await repository.migrate()

        #expect(try userVersion(at: databaseURL) == 2)
        #expect(try !columnNames(table: "sessions", at: databaseURL).contains("file_key"))
        #expect(try columnNames(table: "file_cursors", at: databaseURL).contains("active_session_id"))
        #expect(try await repository.notificationWasSent("week|4000|20"))
    }

    @Test
    func existingVersionTwoAddsBoundaryFingerprintWithoutLosingReceipts() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        try createLegacyVersionTwoCursorDatabase(
            at: databaseURL,
            receiptKey: "week|4000|20"
        )
        let repository = try UsageRepository(url: databaseURL)

        try await repository.migrate()
        try await repository.migrate()

        #expect(try columnNames(table: "file_cursors", at: databaseURL).contains("boundary_fingerprint"))
        #expect(try await repository.notificationWasSent("week|4000|20"))
    }

    @Test
    func existingVersionTwoMigratesRateLimitsAndClearsCursorsForRescan() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        try createLegacyVersionTwoRateLimitDatabase(at: databaseURL)
        let repository = try UsageRepository(url: databaseURL)

        try await repository.migrate()

        #expect(try queryRawInteger(
            "SELECT COUNT(*) FROM pragma_table_info('rate_limits') WHERE pk > 0",
            at: databaseURL
        ) == 3)
        #expect(try queryRawInteger(
            "SELECT pk FROM pragma_table_info('rate_limits') WHERE name = 'plan_type'",
            at: databaseURL
        ) == 3)
        #expect(try queryRawInteger("SELECT COUNT(*) FROM file_cursors", at: databaseURL) == 0)
        #expect(try queryRawInteger("SELECT COUNT(*) FROM rate_limits", at: databaseURL) == 1)
    }

    @Test
    func intermediateVersionTwoRateLimitKeyMigratesAndClearsCursorsForRescan() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        try createIntermediateVersionTwoRateLimitDatabase(at: databaseURL)
        let repository = try UsageRepository(url: databaseURL)

        try await repository.migrate()

        #expect(try queryRawInteger(
            "SELECT COUNT(*) FROM pragma_table_info('rate_limits') WHERE pk > 0",
            at: databaseURL
        ) == 3)
        #expect(try queryRawInteger(
            "SELECT pk FROM pragma_table_info('rate_limits') WHERE name = 'plan_type'",
            at: databaseURL
        ) == 3)
        #expect(try queryRawInteger("SELECT COUNT(*) FROM file_cursors", at: databaseURL) == 0)
        #expect(try queryRawInteger("SELECT COUNT(*) FROM rate_limits", at: databaseURL) == 1)
    }

    @Test
    func resetCycleVersionTwoKeyMigratesToPlanScopeAndKeepsLatestObservation() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        try createResetCycleVersionTwoRateLimitDatabase(at: databaseURL)
        let repository = try UsageRepository(url: databaseURL)

        try await repository.migrate()

        #expect(try queryRawInteger(
            "SELECT pk FROM pragma_table_info('rate_limits') WHERE name = 'plan_type'",
            at: databaseURL
        ) == 3)
        #expect(try queryRawInteger("SELECT COUNT(*) FROM file_cursors", at: databaseURL) == 0)
        #expect(try queryRawInteger("SELECT COUNT(*) FROM rate_limits", at: databaseURL) == 1)
        #expect(try queryRawInteger(
            "SELECT CAST(used_percent AS INTEGER) FROM rate_limits",
            at: databaseURL
        ) == 4)
    }

    @Test
    func cursorRoundTripsActiveSessionID() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let cursor = FileCursor(
            fileKey: "file-1",
            path: "/synthetic/session.jsonl",
            offset: 42,
            modifiedAt: Date(timeIntervalSince1970: 123),
            activeSessionID: "child-session"
        )

        try await repository.saveCursor(cursor)

        #expect(try await repository.cursor(for: "file-1") == cursor)
    }

    @Test
    func twoSessionsCanBeStoredWithoutAFileOwnershipConstraint() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let project = ProjectIdentity(key: "/synthetic", displayName: "synthetic", fullPath: "/synthetic")

        try await repository.upsertSession(
            SessionMetadata(sessionID: "parent", startedAt: .distantPast, workingDirectory: "/synthetic"),
            project: project
        )
        try await repository.upsertSession(
            SessionMetadata(sessionID: "child", startedAt: .distantPast, workingDirectory: "/synthetic"),
            project: project
        )

        #expect(try sessionIDs(at: databaseURL) == ["child", "parent"])
    }

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
    func distinctLimitIDsForTheSameWindowArePreserved() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let overall = RateLimitObservation(
            limitID: "codex",
            window: .week,
            usedPercent: 27,
            resetsAt: Date(timeIntervalSince1970: 3_000),
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let modelSpecific = RateLimitObservation(
            limitID: "codex_bengalfox",
            window: .week,
            usedPercent: 0,
            resetsAt: Date(timeIntervalSince1970: 4_000),
            observedAt: Date(timeIntervalSince1970: 2_000)
        )

        try await repository.replaceLatestLimits([overall])
        try await repository.replaceLatestLimits([modelSpecific])

        #expect(Set(try await repository.latestLimits().map(\.limitID)) == [
            "codex",
            "codex_bengalfox",
        ])
    }

    @Test
    func distinctPlanScopesForTheSameLimitIDArePreserved() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let firstCycle = RateLimitObservation(
            limitID: "codex",
            planType: "prolite",
            window: .week,
            usedPercent: 27,
            resetsAt: Date(timeIntervalSince1970: 3_000),
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let secondCycle = RateLimitObservation(
            limitID: "codex",
            window: .week,
            usedPercent: 4,
            resetsAt: Date(timeIntervalSince1970: 4_000),
            observedAt: Date(timeIntervalSince1970: 2_000)
        )

        try await repository.replaceLatestLimits([firstCycle])
        try await repository.replaceLatestLimits([secondCycle])

        let stored = try await repository.latestLimits()
        #expect(stored.count == 2)
        #expect(stored.contains(firstCycle))
        #expect(stored.contains(secondCycle))
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
            resetsAt: Date(timeIntervalSince1970: 2_500),
            observedAt: Date(timeIntervalSince1970: 2_000)
        )
        let earlier = RateLimitObservation(
            limitID: "flex",
            window: .other(minutes: 60, label: "Flexible"),
            usedPercent: 10,
            resetsAt: Date(timeIntervalSince1970: 3_000),
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

    private func createVersionOneDatabase(at url: URL, receiptKey: String) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not create v1 schema fixture")
        }
        defer { sqlite3_close(handle) }
        try executeRawSQL(
            """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              file_key TEXT NOT NULL UNIQUE,
              started_at REAL NOT NULL,
              project_key TEXT NOT NULL,
              project_name TEXT NOT NULL,
              full_path TEXT
            );
            CREATE TABLE usage_events (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              occurred_at REAL NOT NULL,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              reasoning_output_tokens INTEGER NOT NULL,
              total_tokens INTEGER NOT NULL
            );
            CREATE TABLE file_cursors (
              file_key TEXT PRIMARY KEY,
              path TEXT NOT NULL,
              byte_offset INTEGER NOT NULL,
              modified_at REAL NOT NULL
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
            INSERT INTO notification_receipts (receipt_key, sent_at)
            VALUES ('\(receiptKey)', 1000);
            PRAGMA user_version = 1;
            """,
            handle: handle
        )
    }

    private func createLegacyVersionTwoCursorDatabase(at url: URL, receiptKey: String) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not create legacy v2 fixture")
        }
        defer { sqlite3_close(handle) }
        try executeRawSQL(
            """
            CREATE TABLE file_cursors (
              file_key TEXT PRIMARY KEY,
              path TEXT NOT NULL,
              byte_offset INTEGER NOT NULL,
              modified_at REAL NOT NULL,
              active_session_id TEXT
            );
            CREATE TABLE notification_receipts (
              receipt_key TEXT PRIMARY KEY,
              sent_at REAL NOT NULL
            );
            INSERT INTO notification_receipts (receipt_key, sent_at)
            VALUES ('\(receiptKey)', 1000);
            PRAGMA user_version = 2;
            """,
            handle: handle
        )
    }

    private func createLegacyVersionTwoRateLimitDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not create legacy rate limit fixture")
        }
        defer { sqlite3_close(handle) }
        try executeRawSQL(
            """
            CREATE TABLE file_cursors (
              file_key TEXT PRIMARY KEY,
              path TEXT NOT NULL,
              byte_offset INTEGER NOT NULL,
              modified_at REAL NOT NULL,
              active_session_id TEXT,
              boundary_fingerprint TEXT
            );
            INSERT INTO file_cursors (
              file_key, path, byte_offset, modified_at, active_session_id, boundary_fingerprint
            ) VALUES ('session', '/tmp/session.jsonl', 42, 1000, NULL, NULL);
            CREATE TABLE rate_limits (
              window_key TEXT PRIMARY KEY,
              limit_id TEXT NOT NULL,
              window_minutes INTEGER NOT NULL,
              window_label TEXT,
              used_percent REAL NOT NULL,
              resets_at REAL NOT NULL,
              observed_at REAL NOT NULL
            );
            INSERT INTO rate_limits (
              window_key, limit_id, window_minutes, window_label,
              used_percent, resets_at, observed_at
            ) VALUES ('week', 'codex_bengalfox', 10080, NULL, 0, 4000, 2000);
            CREATE TABLE index_metadata (
              key TEXT PRIMARY KEY,
              value INTEGER NOT NULL
            );
            INSERT INTO index_metadata (key, value)
            VALUES ('event_identity_version', 2);
            PRAGMA user_version = 2;
            """,
            handle: handle
        )
    }

    private func createIntermediateVersionTwoRateLimitDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not create intermediate rate limit fixture")
        }
        defer { sqlite3_close(handle) }
        try executeRawSQL(
            """
            CREATE TABLE file_cursors (
              file_key TEXT PRIMARY KEY,
              path TEXT NOT NULL,
              byte_offset INTEGER NOT NULL,
              modified_at REAL NOT NULL,
              active_session_id TEXT,
              boundary_fingerprint TEXT
            );
            INSERT INTO file_cursors (
              file_key, path, byte_offset, modified_at, active_session_id, boundary_fingerprint
            ) VALUES ('session', '/tmp/session.jsonl', 42, 1000, NULL, NULL);
            CREATE TABLE rate_limits (
              window_key TEXT NOT NULL,
              limit_id TEXT NOT NULL,
              window_minutes INTEGER NOT NULL,
              window_label TEXT,
              used_percent REAL NOT NULL,
              resets_at REAL NOT NULL,
              observed_at REAL NOT NULL,
              PRIMARY KEY (window_key, limit_id)
            );
            INSERT INTO rate_limits (
              window_key, limit_id, window_minutes, window_label,
              used_percent, resets_at, observed_at
            ) VALUES ('week', 'codex', 10080, NULL, 4, 4000, 2000);
            CREATE TABLE index_metadata (
              key TEXT PRIMARY KEY,
              value INTEGER NOT NULL
            );
            INSERT INTO index_metadata (key, value)
            VALUES ('event_identity_version', 2);
            PRAGMA user_version = 2;
            """,
            handle: handle
        )
    }

    private func createResetCycleVersionTwoRateLimitDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not create reset cycle fixture")
        }
        defer { sqlite3_close(handle) }
        try executeRawSQL(
            """
            CREATE TABLE file_cursors (
              file_key TEXT PRIMARY KEY,
              path TEXT NOT NULL,
              byte_offset INTEGER NOT NULL,
              modified_at REAL NOT NULL,
              active_session_id TEXT,
              boundary_fingerprint TEXT
            );
            INSERT INTO file_cursors (
              file_key, path, byte_offset, modified_at, active_session_id, boundary_fingerprint
            ) VALUES ('session', '/tmp/session.jsonl', 42, 1000, NULL, NULL);
            CREATE TABLE rate_limits (
              window_key TEXT NOT NULL,
              limit_id TEXT NOT NULL,
              window_minutes INTEGER NOT NULL,
              window_label TEXT,
              used_percent REAL NOT NULL,
              resets_at REAL NOT NULL,
              observed_at REAL NOT NULL,
              PRIMARY KEY (window_key, limit_id, resets_at)
            );
            INSERT INTO rate_limits VALUES
              ('week', 'codex', 10080, NULL, 27, 3000, 1000),
              ('week', 'codex', 10080, NULL, 4, 4000, 2000);
            CREATE TABLE index_metadata (
              key TEXT PRIMARY KEY,
              value INTEGER NOT NULL
            );
            INSERT INTO index_metadata (key, value)
            VALUES ('event_identity_version', 2);
            PRAGMA user_version = 2;
            """,
            handle: handle
        )
    }

    private func userVersion(at url: URL) throws -> Int {
        try queryRawInteger("PRAGMA user_version", at: url)
    }

    private func columnNames(table: String, at url: URL) throws -> [String] {
        try queryRawStrings("PRAGMA table_info(\(table))", column: 1, at: url)
    }

    private func sessionIDs(at url: URL) throws -> [String] {
        try queryRawStrings("SELECT id FROM sessions ORDER BY id", column: 0, at: url)
    }

    private func queryRawInteger(_ sql: String, at url: URL) throws -> Int {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not inspect database")
        }
        defer { sqlite3_close(handle) }
        return try queryRawInteger(sql, handle: handle)
    }

    private func queryRawStrings(_ sql: String, column: Int32, at url: URL) throws -> [String] {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError(code: openResult, message: "could not inspect database")
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw SQLiteError(code: prepareResult, message: "database inspection prepare failed")
        }
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, column) else { continue }
            values.append(String(cString: value))
        }
        return values
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

private struct RepositoryBatchFixture: Sendable {
    let databaseURL: URL
    let repository: UsageRepository
    private let project = ProjectIdentity(
        key: "/synthetic/project",
        displayName: "project",
        fullPath: "/synthetic/project"
    )

    init() async throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "RepositoryBatchFixture-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
    }

    func event(
        sessionID: String,
        second: TimeInterval,
        lastTotal: Int64,
        cumulativeTotal: Int64
    ) -> LogicalTokenEvent {
        logicalEvent(
            sessionID: sessionID,
            second: second,
            lastUsage: usage(total: lastTotal),
            cumulativeUsage: usage(total: cumulativeTotal)
        )
    }

    func cumulativeOnlyEvent(
        sessionID: String,
        second: TimeInterval,
        cumulativeTotal: Int64
    ) -> LogicalTokenEvent {
        logicalEvent(
            sessionID: sessionID,
            second: second,
            lastUsage: nil,
            cumulativeUsage: usage(total: cumulativeTotal)
        )
    }

    func batch(fileKey: String, events: [LogicalTokenEvent]) -> FileIngestionBatch {
        let sessionIDs = Set(events.map(\.sessionID))
        return FileIngestionBatch(
            sessions: sessionIDs.sorted().map { sessionID in
                SessionUpsert(
                    metadata: SessionMetadata(
                        sessionID: sessionID,
                        startedAt: Date(timeIntervalSince1970: 0),
                        workingDirectory: project.fullPath
                    ),
                    project: project
                )
            },
            events: events,
            limits: [],
            cursor: FileCursor(
                fileKey: fileKey,
                path: "/synthetic/\(fileKey).jsonl",
                offset: 100,
                modifiedAt: Date(timeIntervalSince1970: 100),
                activeSessionID: events.last?.sessionID
            )
        )
    }

    func total() async throws -> Int64 {
        try await repository.queryUsage(from: nil, to: .distantFuture)
            .map(\.usage.total)
            .reduce(0, +)
    }

    func remove() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
    }

    private func logicalEvent(
        sessionID: String,
        second: TimeInterval,
        lastUsage: TokenUsage?,
        cumulativeUsage: TokenUsage?
    ) -> LogicalTokenEvent {
        let parsed = ParsedTokenEvent(
            occurredAt: Date(timeIntervalSince1970: second),
            lastUsage: lastUsage,
            cumulativeUsage: cumulativeUsage,
            limits: []
        )
        return LogicalTokenEvent(
            id: TokenEventIdentity.make(sessionID: sessionID, event: parsed),
            sessionID: sessionID,
            occurredAt: parsed.occurredAt,
            lastUsage: parsed.lastUsage,
            cumulativeUsage: parsed.cumulativeUsage
        )
    }

    private func usage(total: Int64) -> TokenUsage {
        TokenUsage(input: total, cachedInput: 0, output: 0, reasoningOutput: 0, total: total)
    }
}
