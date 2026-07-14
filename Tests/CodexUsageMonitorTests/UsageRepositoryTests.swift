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
}
