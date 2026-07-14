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
}

actor UsageRepository {
    private let database: SQLiteDatabase

    init(url: URL) throws {
        database = try SQLiteDatabase(url: url)
    }

    static func openRecovering(url: URL, now: Date = .now) throws -> UsageRepository {
        do {
            return try UsageRepository(url: url)
        } catch let error as SQLiteError
            where error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB {
            try preserveCorruptDatabase(at: url, now: now)
            return try UsageRepository(url: url)
        }
    }

    func migrate() throws {
        let version = try userVersion()
        guard version == 0 || version == 1 else {
            try resetIndex()
            try migrate()
            return
        }

        guard version == 0 else { return }

        try database.execute("BEGIN IMMEDIATE")
        do {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS sessions (
                  id TEXT PRIMARY KEY,
                  file_key TEXT NOT NULL UNIQUE,
                  started_at REAL NOT NULL,
                  project_key TEXT NOT NULL,
                  project_name TEXT NOT NULL,
                  full_path TEXT
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS usage_events (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                  occurred_at REAL NOT NULL,
                  input_tokens INTEGER NOT NULL,
                  cached_input_tokens INTEGER NOT NULL,
                  output_tokens INTEGER NOT NULL,
                  reasoning_output_tokens INTEGER NOT NULL,
                  total_tokens INTEGER NOT NULL
                )
                """
            )
            try database.execute("CREATE INDEX IF NOT EXISTS usage_events_time ON usage_events(occurred_at)")
            try database.execute("CREATE INDEX IF NOT EXISTS usage_events_session ON usage_events(session_id)")
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS file_cursors (
                  file_key TEXT PRIMARY KEY,
                  path TEXT NOT NULL,
                  byte_offset INTEGER NOT NULL,
                  modified_at REAL NOT NULL
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS cumulative_usage (
                  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                  input_tokens INTEGER NOT NULL,
                  cached_input_tokens INTEGER NOT NULL,
                  output_tokens INTEGER NOT NULL,
                  reasoning_output_tokens INTEGER NOT NULL,
                  total_tokens INTEGER NOT NULL
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS rate_limits (
                  window_key TEXT PRIMARY KEY,
                  limit_id TEXT NOT NULL,
                  window_minutes INTEGER NOT NULL,
                  window_label TEXT,
                  used_percent REAL NOT NULL,
                  resets_at REAL NOT NULL,
                  observed_at REAL NOT NULL
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS notification_receipts (
                  receipt_key TEXT PRIMARY KEY,
                  sent_at REAL NOT NULL
                )
                """
            )
            try database.execute("PRAGMA user_version = 1")
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    func upsertSession(
        _ metadata: SessionMetadata,
        fileKey: String,
        project: ProjectIdentity
    ) throws {
        try database.execute(
            """
            INSERT INTO sessions (id, file_key, started_at, project_key, project_name, full_path)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              file_key = excluded.file_key,
              started_at = excluded.started_at,
              project_key = excluded.project_key,
              project_name = excluded.project_name,
              full_path = excluded.full_path
            """,
            [
                .text(metadata.sessionID),
                .text(fileKey),
                .real(metadata.startedAt.timeIntervalSince1970),
                .text(project.key),
                .text(project.displayName),
                project.fullPath.map(SQLiteValue.text) ?? .null
            ]
        )
    }

    func sessionID(forFileKey fileKey: String) throws -> String? {
        var sessionID: String?
        try database.query(
            "SELECT id FROM sessions WHERE file_key = ? LIMIT 1",
            [.text(fileKey)]
        ) { statement in
            sessionID = Self.text(from: statement, column: 0)
        }
        return sessionID
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
              id, session_id, occurred_at, input_tokens, cached_input_tokens,
              output_tokens, reasoning_output_tokens, total_tokens
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
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
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
            SELECT file_key, path, byte_offset, modified_at
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
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            )
        }
        return cursor
    }

    func saveCursor(_ cursor: FileCursor) throws {
        try database.execute(
            """
            INSERT INTO file_cursors (file_key, path, byte_offset, modified_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(file_key) DO UPDATE SET
              path = excluded.path,
              byte_offset = excluded.byte_offset,
              modified_at = excluded.modified_at
            """,
            [
                .text(cursor.fileKey),
                .text(cursor.path),
                .integer(Int64(bitPattern: cursor.offset)),
                .real(cursor.modifiedAt.timeIntervalSince1970)
            ]
        )
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
              SUM(usage_events.input_tokens),
              SUM(usage_events.cached_input_tokens),
              SUM(usage_events.output_tokens),
              SUM(usage_events.reasoning_output_tokens),
              SUM(usage_events.total_tokens)
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

    func resetIndex() throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            try database.execute("DROP TABLE IF EXISTS notification_receipts")
            try database.execute("DROP TABLE IF EXISTS rate_limits")
            try database.execute("DROP TABLE IF EXISTS cumulative_usage")
            try database.execute("DROP TABLE IF EXISTS file_cursors")
            try database.execute("DROP TABLE IF EXISTS usage_events")
            try database.execute("DROP TABLE IF EXISTS sessions")
            try database.execute("PRAGMA user_version = 0")
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
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

    private static func text(from statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private static func optionalText(from statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(from: statement, column: column)
    }

    private static func preserveCorruptDatabase(at url: URL, now: Date) throws {
        let marker = ".corrupt-\(Int64(now.timeIntervalSince1970))"
        let fileManager = FileManager.default

        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            let destination = URL(fileURLWithPath: source.path + marker)
            try fileManager.moveItem(at: source, to: destination)
        }
    }
}
