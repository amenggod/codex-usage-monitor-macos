import Foundation
import SQLite3

enum UsageSchema {
    static let currentVersion: Int64 = 2

    static func createVersionTwo(in database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS sessions (
              id TEXT PRIMARY KEY,
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
              modified_at REAL NOT NULL,
              active_session_id TEXT,
              boundary_fingerprint TEXT
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
    }

    static func ensureVersionTwoCompatibility(in database: SQLiteDatabase) throws {
        var cursorColumns: Set<String> = []
        try database.query("PRAGMA table_info(file_cursors)") { statement in
            guard let value = sqlite3_column_text(statement, 1) else { return }
            cursorColumns.insert(String(cString: value))
        }
        guard !cursorColumns.contains("boundary_fingerprint") else { return }

        try database.execute("BEGIN IMMEDIATE")
        do {
            try database.execute(
                "ALTER TABLE file_cursors ADD COLUMN boundary_fingerprint TEXT"
            )
            try database.execute("COMMIT")
        } catch {
            _ = try? database.execute("ROLLBACK")
            throw error
        }
    }
}
