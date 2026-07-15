import Foundation
import SQLite3

struct StoredUsageRow: Equatable, Sendable {
    let projectKey: String
    let projectName: String
    let fullPath: String?
    let usage: TokenUsage
}

struct FileCursor: Equatable, Sendable {
    let fileKey: String
    let path: String
    let offset: UInt64
    let modifiedAt: Date
    let activeSessionID: String?
    let boundaryFingerprint: String?

    init(
        fileKey: String,
        path: String,
        offset: UInt64,
        modifiedAt: Date,
        activeSessionID: String? = nil,
        boundaryFingerprint: String? = nil
    ) {
        self.fileKey = fileKey
        self.path = path
        self.offset = offset
        self.modifiedAt = modifiedAt
        self.activeSessionID = activeSessionID
        self.boundaryFingerprint = boundaryFingerprint
    }
}

actor UsageRepository {
    private struct SidecarSnapshot {
        let suffix: String
        let url: URL
    }

    private let database: SQLiteDatabase

    init(url: URL) throws {
        database = try SQLiteDatabase(url: url)
    }

    private init(database: SQLiteDatabase) {
        self.database = database
    }

    static func openRecovering(url: URL, now: Date = .now) throws -> UsageRepository {
        let sidecarSnapshots = try snapshotSidecars(at: url)
        defer {
            for snapshot in sidecarSnapshots {
                try? FileManager.default.removeItem(at: snapshot.url)
            }
        }

        do {
            return try openValidated(url: url)
        } catch let error as SQLiteError
            where error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB {
            try preserveCorruptDatabase(
                at: url,
                now: now,
                sidecarSnapshots: sidecarSnapshots
            )
            return try openValidated(url: url)
        }
    }

    func migrate() throws {
        let version = try userVersion()
        if version == UsageSchema.currentVersion {
            try UsageSchema.ensureVersionTwoCompatibility(in: database)
            return
        }

        if version == 1 {
            try resetIndex(preserveNotificationReceipts: true)
        } else if version != 0 {
            try resetIndex(preserveNotificationReceipts: false)
        }

        try database.execute("BEGIN IMMEDIATE")
        do {
            try UsageSchema.createVersionTwo(in: database)
            try database.execute("PRAGMA user_version = \(UsageSchema.currentVersion)")
            try database.execute("COMMIT")
        } catch {
            _ = try? database.execute("ROLLBACK")
            throw error
        }
    }

    func upsertSession(
        _ metadata: SessionMetadata,
        project: ProjectIdentity
    ) throws {
        try database.execute(
            """
            INSERT INTO sessions (id, started_at, project_key, project_name, full_path)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              started_at = excluded.started_at,
              project_key = excluded.project_key,
              project_name = excluded.project_name,
              full_path = excluded.full_path
            """,
            [
                .text(metadata.sessionID),
                .real(metadata.startedAt.timeIntervalSince1970),
                .text(project.key),
                .text(project.displayName),
                project.fullPath.map(SQLiteValue.text) ?? .null
            ]
        )
    }

    func insertUsageEvent(
        id: String,
        sessionID: String,
        occurredAt: Date,
        usage: TokenUsage
    ) throws {
        try database.execute(
            """
            INSERT OR IGNORE INTO usage_events (
              id, session_id, occurred_at, delta_input_tokens, delta_cached_input_tokens,
              delta_output_tokens, delta_reasoning_output_tokens, delta_total_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id),
                .text(sessionID),
                .real(occurredAt.timeIntervalSince1970),
                .integer(usage.input),
                .integer(usage.cachedInput),
                .integer(usage.output),
                .integer(usage.reasoningOutput),
                .integer(usage.total)
            ]
        )
    }

    func apply(_ batch: FileIngestionBatch) throws -> FileIngestionResult {
        try database.execute("BEGIN IMMEDIATE")
        do {
            for session in batch.sessions {
                try upsertSession(session.metadata, project: session.project)
            }

            var insertedEvents = 0
            var cumulativeSessions: Set<String> = []
            for event in batch.events {
                let delta = event.lastUsage ?? .zero
                let inserted = try database.execute(
                    """
                    INSERT OR IGNORE INTO usage_events (
                      id, session_id, occurred_at,
                      last_input_tokens, last_cached_input_tokens, last_output_tokens,
                      last_reasoning_output_tokens, last_total_tokens,
                      cumulative_input_tokens, cumulative_cached_input_tokens,
                      cumulative_output_tokens, cumulative_reasoning_output_tokens,
                      cumulative_total_tokens,
                      delta_input_tokens, delta_cached_input_tokens, delta_output_tokens,
                      delta_reasoning_output_tokens, delta_total_tokens
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(event.id),
                        .text(event.sessionID),
                        .real(event.occurredAt.timeIntervalSince1970),
                        event.lastUsage.map { .integer($0.input) } ?? .null,
                        event.lastUsage.map { .integer($0.cachedInput) } ?? .null,
                        event.lastUsage.map { .integer($0.output) } ?? .null,
                        event.lastUsage.map { .integer($0.reasoningOutput) } ?? .null,
                        event.lastUsage.map { .integer($0.total) } ?? .null,
                        event.cumulativeUsage.map { .integer($0.input) } ?? .null,
                        event.cumulativeUsage.map { .integer($0.cachedInput) } ?? .null,
                        event.cumulativeUsage.map { .integer($0.output) } ?? .null,
                        event.cumulativeUsage.map { .integer($0.reasoningOutput) } ?? .null,
                        event.cumulativeUsage.map { .integer($0.total) } ?? .null,
                        .integer(delta.input),
                        .integer(delta.cachedInput),
                        .integer(delta.output),
                        .integer(delta.reasoningOutput),
                        .integer(delta.total)
                    ]
                ) == 1

                guard inserted else { continue }
                insertedEvents += 1
                if event.cumulativeUsage != nil {
                    cumulativeSessions.insert(event.sessionID)
                }
            }

            for sessionID in cumulativeSessions {
                try recomputeCumulativeDeltas(sessionID: sessionID)
            }
            try upsertLatestLimits(batch.limits)
            try persistCursor(batch.cursor)
            try database.execute("COMMIT")

            return FileIngestionResult(
                insertedEvents: insertedEvents,
                duplicateEvents: batch.events.count - insertedEvents
            )
        } catch {
            _ = try? database.execute("ROLLBACK")
            throw error
        }
    }

    func previousCumulativeUsage(sessionID: String) throws -> TokenUsage? {
        var usage: TokenUsage?
        try database.query(
            """
            SELECT input_tokens, cached_input_tokens, output_tokens,
                   reasoning_output_tokens, total_tokens
            FROM cumulative_usage
            WHERE session_id = ?
            LIMIT 1
            """,
            [.text(sessionID)]
        ) { statement in
            usage = Self.tokenUsage(from: statement, startingAt: 0)
        }
        return usage
    }

    func saveCumulativeUsage(_ usage: TokenUsage, sessionID: String) throws {
        try database.execute(
            """
            INSERT INTO cumulative_usage (
              session_id, input_tokens, cached_input_tokens, output_tokens,
              reasoning_output_tokens, total_tokens
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
              input_tokens = excluded.input_tokens,
              cached_input_tokens = excluded.cached_input_tokens,
              output_tokens = excluded.output_tokens,
              reasoning_output_tokens = excluded.reasoning_output_tokens,
              total_tokens = excluded.total_tokens
            """,
            [
                .text(sessionID),
                .integer(usage.input),
                .integer(usage.cachedInput),
                .integer(usage.output),
                .integer(usage.reasoningOutput),
                .integer(usage.total)
            ]
        )
    }

    func replaceLatestLimits(_ observations: [RateLimitObservation]) throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            try upsertLatestLimits(observations)
            try database.execute("COMMIT")
        } catch {
            _ = try? database.execute("ROLLBACK")
            throw error
        }
    }

    func latestLimits() throws -> [RateLimitObservation] {
        var observations: [RateLimitObservation] = []
        try database.query(
            """
            SELECT window_key, limit_id, window_minutes, window_label,
                   used_percent, resets_at, observed_at
            FROM rate_limits
            ORDER BY window_key
            """
        ) { statement in
            let windowKey = Self.text(from: statement, column: 0)
            let minutes = Int(sqlite3_column_int64(statement, 2))
            let label = Self.optionalText(from: statement, column: 3)
            let window: LimitWindow = switch windowKey {
            case LimitWindow.fiveHours.storageKey:
                .fiveHours
            case LimitWindow.week.storageKey:
                .week
            default:
                .other(minutes: minutes, label: label)
            }
            observations.append(RateLimitObservation(
                limitID: Self.text(from: statement, column: 1),
                window: window,
                usedPercent: sqlite3_column_double(statement, 4),
                resetsAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            ))
        }
        return observations
    }

    func cursor(for fileKey: String) throws -> FileCursor? {
        var cursor: FileCursor?
        try database.query(
            """
            SELECT file_key, path, byte_offset, modified_at, active_session_id,
                   boundary_fingerprint
            FROM file_cursors
            WHERE file_key = ?
            LIMIT 1
            """,
            [.text(fileKey)]
        ) { statement in
            cursor = FileCursor(
                fileKey: Self.text(from: statement, column: 0),
                path: Self.text(from: statement, column: 1),
                offset: UInt64(bitPattern: sqlite3_column_int64(statement, 2)),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                activeSessionID: Self.optionalText(from: statement, column: 4),
                boundaryFingerprint: Self.optionalText(from: statement, column: 5)
            )
        }
        return cursor
    }

    func saveCursor(_ cursor: FileCursor) throws {
        try persistCursor(cursor)
    }

    private func persistCursor(_ cursor: FileCursor) throws {
        try database.execute(
            """
            INSERT INTO file_cursors (
              file_key, path, byte_offset, modified_at, active_session_id,
              boundary_fingerprint
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_key) DO UPDATE SET
              path = excluded.path,
              byte_offset = excluded.byte_offset,
              modified_at = excluded.modified_at,
              active_session_id = excluded.active_session_id,
              boundary_fingerprint = excluded.boundary_fingerprint
            """,
            [
                .text(cursor.fileKey),
                .text(cursor.path),
                .integer(Int64(bitPattern: cursor.offset)),
                .real(cursor.modifiedAt.timeIntervalSince1970),
                cursor.activeSessionID.map(SQLiteValue.text) ?? .null,
                cursor.boundaryFingerprint.map(SQLiteValue.text) ?? .null
            ]
        )
    }

    private func upsertLatestLimits(_ observations: [RateLimitObservation]) throws {
        for observation in observations {
            let label: String? = switch observation.window {
            case let .other(_, label): label
            case .fiveHours, .week: nil
            }
            try database.execute(
                """
                INSERT INTO rate_limits (
                  window_key, limit_id, window_minutes, window_label,
                  used_percent, resets_at, observed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(window_key) DO UPDATE SET
                  limit_id = excluded.limit_id,
                  window_minutes = excluded.window_minutes,
                  window_label = excluded.window_label,
                  used_percent = excluded.used_percent,
                  resets_at = excluded.resets_at,
                  observed_at = excluded.observed_at
                WHERE excluded.observed_at >= rate_limits.observed_at
                """,
                [
                    .text(observation.window.storageKey),
                    .text(observation.limitID),
                    .integer(Int64(observation.window.minutes)),
                    label.map(SQLiteValue.text) ?? .null,
                    .real(observation.usedPercent),
                    .real(observation.resetsAt.timeIntervalSince1970),
                    .real(observation.observedAt.timeIntervalSince1970)
                ]
            )
        }
    }

    private func recomputeCumulativeDeltas(sessionID: String) throws {
        struct EventUsage {
            let id: String
            let last: TokenUsage?
            let cumulative: TokenUsage?
        }

        var events: [EventUsage] = []
        try database.query(
            """
            SELECT id,
                   last_input_tokens, last_cached_input_tokens, last_output_tokens,
                   last_reasoning_output_tokens, last_total_tokens,
                   cumulative_input_tokens, cumulative_cached_input_tokens,
                   cumulative_output_tokens, cumulative_reasoning_output_tokens,
                   cumulative_total_tokens
            FROM usage_events
            WHERE session_id = ?
            ORDER BY occurred_at, id
            """,
            [.text(sessionID)]
        ) { statement in
            events.append(EventUsage(
                id: Self.text(from: statement, column: 0),
                last: Self.optionalTokenUsage(from: statement, startingAt: 1),
                cumulative: Self.optionalTokenUsage(from: statement, startingAt: 6)
            ))
        }

        var previousCumulative = TokenUsage.zero
        for event in events {
            let delta: TokenUsage?
            if let last = event.last {
                delta = last
            } else if let cumulative = event.cumulative {
                delta = cumulative - previousCumulative
            } else {
                delta = nil
            }

            if let cumulative = event.cumulative {
                previousCumulative = cumulative
            }
            guard let delta else { continue }
            try database.execute(
                """
                UPDATE usage_events SET
                  delta_input_tokens = ?,
                  delta_cached_input_tokens = ?,
                  delta_output_tokens = ?,
                  delta_reasoning_output_tokens = ?,
                  delta_total_tokens = ?
                WHERE id = ?
                """,
                [
                    .integer(delta.input),
                    .integer(delta.cachedInput),
                    .integer(delta.output),
                    .integer(delta.reasoningOutput),
                    .integer(delta.total),
                    .text(event.id)
                ]
            )
        }
    }

    func notificationWasSent(_ key: String) throws -> Bool {
        var wasSent = false
        try database.query(
            "SELECT 1 FROM notification_receipts WHERE receipt_key = ? LIMIT 1",
            [.text(key)]
        ) { _ in
            wasSent = true
        }
        return wasSent
    }

    func notificationWasSent(
        _ key: String,
        claimingLegacyKey legacyKey: String
    ) throws -> Bool {
        try database.execute("BEGIN IMMEDIATE")
        do {
            let currentWasSent = try notificationWasSent(key)
            var legacySentAt: Double?
            try database.query(
                "SELECT sent_at FROM notification_receipts WHERE receipt_key = ? LIMIT 1",
                [.text(legacyKey)]
            ) { statement in
                legacySentAt = sqlite3_column_double(statement, 0)
            }

            if let legacySentAt {
                if !currentWasSent {
                    try database.execute(
                        "INSERT OR IGNORE INTO notification_receipts (receipt_key, sent_at) VALUES (?, ?)",
                        [.text(key), .real(legacySentAt)]
                    )
                }
                try database.execute(
                    "DELETE FROM notification_receipts WHERE receipt_key = ?",
                    [.text(legacyKey)]
                )
            }
            try database.execute("COMMIT")
            return currentWasSent || legacySentAt != nil
        } catch {
            _ = try? database.execute("ROLLBACK")
            throw error
        }
    }

    func markNotificationSent(_ key: String, sentAt: Date) throws {
        try database.execute(
            "INSERT OR IGNORE INTO notification_receipts (receipt_key, sent_at) VALUES (?, ?)",
            [.text(key), .real(sentAt.timeIntervalSince1970)]
        )
    }

    func queryUsage(from: Date?, to: Date) throws -> [StoredUsageRow] {
        var rows: [StoredUsageRow] = []
        let select =
            """
            SELECT
              sessions.project_key,
              sessions.project_name,
              sessions.full_path,
              SUM(usage_events.delta_input_tokens),
              SUM(usage_events.delta_cached_input_tokens),
              SUM(usage_events.delta_output_tokens),
              SUM(usage_events.delta_reasoning_output_tokens),
              SUM(usage_events.delta_total_tokens)
            FROM usage_events
            JOIN sessions ON sessions.id = usage_events.session_id
            """
        let group =
            """
            GROUP BY sessions.project_key, sessions.project_name, sessions.full_path
            ORDER BY sessions.project_key
            """

        if let from {
            try database.query(
                select + " WHERE usage_events.occurred_at >= ? AND usage_events.occurred_at <= ? " + group,
                [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]
            ) { statement in
                rows.append(Self.storedUsageRow(from: statement))
            }
        } else {
            try database.query(
                select + " WHERE usage_events.occurred_at <= ? " + group,
                [.real(to.timeIntervalSince1970)]
            ) { statement in
                rows.append(Self.storedUsageRow(from: statement))
            }
        }

        return rows
    }

    func resetIndex(preserveNotificationReceipts: Bool = true) throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            if !preserveNotificationReceipts {
                try database.execute("DROP TABLE IF EXISTS notification_receipts")
            }
            try database.execute("DROP TABLE IF EXISTS rate_limits")
            try database.execute("DROP TABLE IF EXISTS cumulative_usage")
            try database.execute("DROP TABLE IF EXISTS file_cursors")
            try database.execute("DROP TABLE IF EXISTS usage_events")
            try database.execute("DROP TABLE IF EXISTS sessions")
            try database.execute("PRAGMA user_version = 0")
            try database.execute("COMMIT")
        } catch {
            _ = try? database.execute("ROLLBACK")
            throw error
        }
    }

    private func userVersion() throws -> Int64 {
        var version: Int64 = 0
        try database.query("PRAGMA user_version") { statement in
            version = sqlite3_column_int64(statement, 0)
        }
        return version
    }

    private static func storedUsageRow(from statement: OpaquePointer) -> StoredUsageRow {
        StoredUsageRow(
            projectKey: text(from: statement, column: 0),
            projectName: text(from: statement, column: 1),
            fullPath: optionalText(from: statement, column: 2),
            usage: TokenUsage(
                input: sqlite3_column_int64(statement, 3),
                cachedInput: sqlite3_column_int64(statement, 4),
                output: sqlite3_column_int64(statement, 5),
                reasoningOutput: sqlite3_column_int64(statement, 6),
                total: sqlite3_column_int64(statement, 7)
            )
        )
    }

    private static func tokenUsage(
        from statement: OpaquePointer,
        startingAt column: Int32
    ) -> TokenUsage {
        TokenUsage(
            input: sqlite3_column_int64(statement, column),
            cachedInput: sqlite3_column_int64(statement, column + 1),
            output: sqlite3_column_int64(statement, column + 2),
            reasoningOutput: sqlite3_column_int64(statement, column + 3),
            total: sqlite3_column_int64(statement, column + 4)
        )
    }

    private static func optionalTokenUsage(
        from statement: OpaquePointer,
        startingAt column: Int32
    ) -> TokenUsage? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return tokenUsage(from: statement, startingAt: column)
    }

    private static func text(from statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private static func optionalText(from statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(from: statement, column: column)
    }

    private static func preserveCorruptDatabase(
        at url: URL,
        now: Date,
        sidecarSnapshots: [SidecarSnapshot]
    ) throws {
        let marker = ".corrupt-\(Int64(now.timeIntervalSince1970))"
        let fileManager = FileManager.default
        let backupBase = availableBackupBase(
            for: url,
            marker: marker,
            fileManager: fileManager
        )
        let quarantineMarker = ".recovery-discard-\(UUID().uuidString)"
        var moves: [(source: URL, destination: URL)] = []

        do {
            let sourceDatabase = url
            if fileManager.fileExists(atPath: sourceDatabase.path) {
                try fileManager.moveItem(at: sourceDatabase, to: backupBase)
                moves.append((sourceDatabase, backupBase))
            }

            for suffix in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let quarantine = URL(fileURLWithPath: source.path + quarantineMarker)
                try fileManager.moveItem(at: source, to: quarantine)
                moves.append((source, quarantine))
            }

            for snapshot in sidecarSnapshots {
                let destination = URL(fileURLWithPath: backupBase.path + snapshot.suffix)
                try fileManager.moveItem(at: snapshot.url, to: destination)
                moves.append((snapshot.url, destination))
            }

            for move in moves where move.destination.path.contains(quarantineMarker) {
                try? fileManager.removeItem(at: move.destination)
            }
        } catch {
            for move in moves.reversed()
                where fileManager.fileExists(atPath: move.destination.path)
                    && !fileManager.fileExists(atPath: move.source.path) {
                try? fileManager.moveItem(at: move.destination, to: move.source)
            }
            throw error
        }
    }

    private static func availableBackupBase(
        for url: URL,
        marker: String,
        fileManager: FileManager
    ) -> URL {
        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let candidate = URL(fileURLWithPath: url.path + marker + suffix)
            let candidatePaths = [candidate.path, candidate.path + "-wal", candidate.path + "-shm"]
            if candidatePaths.allSatisfy({ !pathExists($0, fileManager: fileManager) }) {
                return candidate
            }
            attempt += 1
        }
    }

    private static func pathExists(_ path: String, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: path) {
            return true
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private static func snapshotSidecars(at url: URL) throws -> [SidecarSnapshot] {
        let fileManager = FileManager.default
        var snapshots: [SidecarSnapshot] = []

        do {
            for suffix in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let snapshotURL = URL(
                    fileURLWithPath: source.path + ".recovery-snapshot-\(UUID().uuidString)"
                )
                try fileManager.copyItem(at: source, to: snapshotURL)
                snapshots.append(SidecarSnapshot(suffix: suffix, url: snapshotURL))
            }
            return snapshots
        } catch {
            for snapshot in snapshots {
                try? fileManager.removeItem(at: snapshot.url)
            }
            throw error
        }
    }

    private static func openValidated(url: URL) throws -> UsageRepository {
        let database = try SQLiteDatabase(url: url, configure: false)
        try database.quickCheck()
        try database.configureForRepository()
        return UsageRepository(database: database)
    }
}
