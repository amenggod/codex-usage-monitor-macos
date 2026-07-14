# Codex Usage Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu-bar app that reads local Codex session logs, shows 5-hour and weekly remaining limits, aggregates Token usage by project and time range, sends low-limit notifications, and is delivered in a public GitHub repository.

**Architecture:** A Swift 6 executable package provides a SwiftUI `MenuBarExtra` app. A local-only ingestion pipeline discovers Codex JSONL files, parses only metadata/Token/rate-limit fields, writes an idempotent SQLite index, and publishes immutable dashboard snapshots to the UI. Apple frameworks provide file watching, notifications, login launch, and app bundling; there are no third-party runtime dependencies.

**Tech Stack:** Swift 6, SwiftUI, Observation, Foundation, CoreServices/FSEvents, UserNotifications, ServiceManagement, SQLite3, Swift Package Manager, XCTest, GitHub Actions, GitHub CLI.

## Global Constraints

- Support macOS 14 and later.
- Product name is `Codex Usage Monitor`; bundle identifier is `com.amenggod.CodexUsageMonitor`.
- GitHub repository name is `codex-usage-monitor-macos`, public, licensed under MIT.
- Read `$CODEX_HOME` when set, otherwise `~/.codex`.
- Never read or persist prompt text, model responses, tool output, project file contents, credentials, Cookie values, API keys, or access tokens.
- Never commit real Codex logs, user paths, SQLite data, derived app bundles, or signing material.
- Use only synthetic JSONL fixtures in tests.
- Work offline and require no OpenAI API key.
- After initial indexing, surface newly completed JSONL lines within 2 seconds.
- Notify once when either known limit first falls below 20%, and once more when it falls below 10%, de-duplicated by reset window and threshold.
- Default the dashboard range to Today; also provide trailing 7-day and all-time ranges.
- Use test-driven development: every behavior starts with a failing focused test.

---

## Planned File Structure

```text
Package.swift                                    Swift package, executable and test targets
Config/Info.plist                                macOS app bundle metadata
Sources/CodexUsageMonitor/
  App/CodexUsageMonitorApp.swift                 App entry, dependency wiring, MenuBarExtra
  App/AppDelegate.swift                          Accessory-app activation policy
  App/LiveDependencies.swift                     Production dependency construction and fallback
  Domain/UsageModels.swift                       Shared Sendable value types
  Discovery/CodexHomeLocator.swift               CODEX_HOME and session-root discovery
  Discovery/ProjectPathNormalizer.swift          Stable project keys and display names
  Parsing/CodexEventParser.swift                 Privacy-limited JSONL parser
  Aggregation/TokenDeltaCalculator.swift         Cumulative snapshot de-duplication
  Aggregation/UsageAggregator.swift              Time-range and project summaries
  Persistence/SQLiteDatabase.swift               Serialized SQLite connection and statements
  Persistence/UsageRepository.swift              Schema, idempotent writes, dashboard queries
  Ingestion/SessionScanner.swift                  Historical and incremental file reads
  Ingestion/SessionFileWatcher.swift              Recursive FSEvents change stream
  Ingestion/IngestionCoordinator.swift            Scanner/watcher orchestration
  Services/NotificationCoordinator.swift         Threshold crossing and notification receipts
  Services/LaunchAtLoginController.swift         SMAppService wrapper
  Presentation/UsageViewModel.swift              Main-actor UI state and commands
  Presentation/MenuBarLabel.swift                Balanced menu-bar label
  Presentation/UsagePopoverView.swift            Main popover composition
  Presentation/SettingsView.swift                Preferences and diagnostics
  Presentation/Components/LimitCard.swift         Limit progress and reset text
  Presentation/Components/ProjectRow.swift        Project ranking row
Tests/CodexUsageMonitorTests/                    Unit and integration tests
Tests/CodexUsageMonitorTests/Fixtures/           Synthetic JSONL only
Scripts/build-app.sh                              Release build, bundle, ad-hoc sign, zip
.github/workflows/ci.yml                         macOS Swift test workflow
README.md                                         Chinese user/build/privacy guide
LICENSE                                           MIT License
```

## Task 1: Swift Package Foundation and Domain Contracts

**Files:**
- Create: `Package.swift`
- Create: `Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift`
- Create: `Sources/CodexUsageMonitor/App/AppDelegate.swift`
- Create: `Sources/CodexUsageMonitor/Domain/UsageModels.swift`
- Create: `Tests/CodexUsageMonitorTests/UsageModelsTests.swift`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `TokenUsage`, `SessionMetadata`, `ParsedTokenEvent`, `RateLimitObservation`, `LimitWindow`, `LimitStatus`, `TokenRange`, `ProjectUsage`, `DashboardSnapshot`, and `DataFreshness`.
- Produces: executable target `CodexUsageMonitor` and test target `CodexUsageMonitorTests`.

- [ ] **Step 1: Add the package manifest and a failing domain-model test**

```swift
// Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsageMonitor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexUsageMonitor", targets: ["CodexUsageMonitor"])],
    targets: [
        .executableTarget(
            name: "CodexUsageMonitor",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "CodexUsageMonitorTests",
            dependencies: ["CodexUsageMonitor"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
```

```swift
// Tests/CodexUsageMonitorTests/UsageModelsTests.swift
import XCTest
@testable import CodexUsageMonitor

final class UsageModelsTests: XCTestCase {
    func testTokenUsageUsesAuthoritativeTotal() {
        let usage = TokenUsage(input: 100, cachedInput: 40, output: 20, reasoningOutput: 5, total: 120)
        XCTAssertEqual(usage.total, 120, "Codex total_tokens is authoritative; breakdown fields must not be re-added")
    }

    func testRemainingPercentIsClamped() {
        XCTAssertEqual(LimitStatus(window: .fiveHours, usedPercent: 105, resetsAt: .distantFuture).remainingPercent, 0)
        XCTAssertEqual(LimitStatus(window: .week, usedPercent: -4, resetsAt: .distantFuture).remainingPercent, 100)
    }
}
```

- [ ] **Step 2: Run the test and verify that it fails**

Run: `swift test --filter UsageModelsTests`

Expected: compilation fails because `TokenUsage` and `LimitStatus` do not exist.

- [ ] **Step 3: Implement the domain contracts**

```swift
// Sources/CodexUsageMonitor/Domain/UsageModels.swift
import Foundation

struct TokenUsage: Codable, Equatable, Sendable {
    let input: Int64
    let cachedInput: Int64
    let output: Int64
    let reasoningOutput: Int64
    let total: Int64

    static let zero = TokenUsage(input: 0, cachedInput: 0, output: 0, reasoningOutput: 0, total: 0)

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(
            input: max(0, lhs.input - rhs.input),
            cachedInput: max(0, lhs.cachedInput - rhs.cachedInput),
            output: max(0, lhs.output - rhs.output),
            reasoningOutput: max(0, lhs.reasoningOutput - rhs.reasoningOutput),
            total: max(0, lhs.total - rhs.total)
        )
    }
}

struct SessionMetadata: Equatable, Sendable {
    let sessionID: String
    let startedAt: Date
    let workingDirectory: String?
}

enum LimitWindow: Equatable, Hashable, Sendable {
    case fiveHours
    case week
    case other(minutes: Int, label: String?)

    var minutes: Int {
        switch self {
        case .fiveHours: 300
        case .week: 10_080
        case let .other(minutes, _): minutes
        }
    }

    var storageKey: String {
        switch self {
        case .fiveHours: "five-hours"
        case .week: "week"
        case let .other(minutes, label): "other-\(minutes)-\(label ?? "unlabeled")"
        }
    }

    var displayName: String {
        switch self {
        case .fiveHours: "5 小时限额"
        case .week: "周限额"
        case let .other(minutes, label): label ?? "\(minutes) 分钟限额"
        }
    }
}

struct RateLimitObservation: Equatable, Sendable {
    let limitID: String
    let window: LimitWindow
    let usedPercent: Double
    let resetsAt: Date
    let observedAt: Date
}

struct ParsedTokenEvent: Equatable, Sendable {
    let occurredAt: Date
    let lastUsage: TokenUsage?
    let cumulativeUsage: TokenUsage?
    let limits: [RateLimitObservation]
}

struct LimitStatus: Equatable, Sendable {
    let window: LimitWindow
    let usedPercent: Double
    let resetsAt: Date
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
}

enum TokenRange: String, CaseIterable, Sendable {
    case today, sevenDays, all
    var displayName: String {
        switch self { case .today: "今日"; case .sevenDays: "7 天"; case .all: "全部" }
    }
}
enum DataFreshness: Equatable, Sendable { case loading, fresh(Date), stale(Date), noData, failed(String) }

struct ProjectUsage: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let fullPath: String?
    let usage: TokenUsage
}

struct DashboardSnapshot: Equatable, Sendable {
    let range: TokenRange
    let total: TokenUsage
    let projects: [ProjectUsage]
    let limits: [LimitStatus]
    let freshness: DataFreshness

    static let loading = DashboardSnapshot(range: .today, total: .zero, projects: [], limits: [], freshness: .loading)
}
```

Add a minimal temporary app entry so `swift test` can link the executable target:

```swift
// Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift
import SwiftUI

@main
struct CodexUsageMonitorApp: App {
    var body: some Scene {
        MenuBarExtra("Codex Usage Monitor", systemImage: "gauge.with.dots.needle.33percent") {
            Text("Codex Usage Monitor")
        }
    }
}
```

```swift
// Sources/CodexUsageMonitor/App/AppDelegate.swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
```

Append `.app`, `dist`, and local output exclusions:

```gitignore
dist/
outputs/
*.app/
*.zip
```

- [ ] **Step 4: Run the focused and complete test suites**

Run: `swift test --filter UsageModelsTests && swift test`

Expected: both commands exit 0; both model tests pass.

- [ ] **Step 5: Commit the foundation**

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "feat: scaffold native Codex usage monitor"
```

## Task 2: Privacy-Limited Codex JSONL Parser

**Files:**
- Create: `Sources/CodexUsageMonitor/Parsing/CodexEventParser.swift`
- Create: `Tests/CodexUsageMonitorTests/CodexEventParserTests.swift`
- Create: `Tests/CodexUsageMonitorTests/Fixtures/session-sample.jsonl`

**Interfaces:**
- Consumes: domain values from Task 1.
- Produces: `enum ParsedCodexEvent { case session(SessionMetadata); case token(ParsedTokenEvent) }`.
- Produces: `CodexEventParser.parse(line:) -> ParsedCodexEvent?` that ignores all content fields.

- [ ] **Step 1: Add synthetic fixture lines and failing parser tests**

```jsonl
{"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"session-1","timestamp":"2026-07-14T01:00:00Z","cwd":"/synthetic/projects/alpha","prompt":"must-not-be-read"}}
{"timestamp":"2026-07-14T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":135},"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":135}},"rate_limits":{"limit_id":"codex","limit_name":"Codex","primary":{"used_percent":28,"window_minutes":300,"resets_at":1784000000},"secondary":{"used_percent":52,"window_minutes":10080,"resets_at":1784600000}}}}
```

```swift
// Tests/CodexUsageMonitorTests/CodexEventParserTests.swift
import XCTest
@testable import CodexUsageMonitor

final class CodexEventParserTests: XCTestCase {
    private let parser = CodexEventParser()

    func testParsesSessionMetadataWithoutContent() throws {
        let line = Data(#"{"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/synthetic/alpha","prompt":"secret"}}"#.utf8)
        let event = try XCTUnwrap(parser.parse(line: line))
        guard case let .session(metadata) = event else { return XCTFail("expected session") }
        XCTAssertEqual(metadata.sessionID, "s1")
        XCTAssertEqual(metadata.workingDirectory, "/synthetic/alpha")
        XCTAssertFalse(String(describing: event).contains("secret"))
    }

    func testParsesTokenAndBothKnownLimitWindows() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "session-sample", withExtension: "jsonl", subdirectory: "Fixtures"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let event = try XCTUnwrap(parser.parse(line: Data(lines[1].utf8)))
        guard case let .token(token) = event else { return XCTFail("expected token") }
        XCTAssertEqual(token.lastUsage?.total, 135)
        XCTAssertEqual(token.limits.map(\.window), [.fiveHours, .week])
    }

    func testMalformedAndUnknownLinesAreIgnored() {
        XCTAssertNil(parser.parse(line: Data("not-json".utf8)))
        XCTAssertNil(parser.parse(line: Data(#"{"type":"response_item","payload":{"text":"ignored"}}"#.utf8)))
    }
}
```

- [ ] **Step 2: Run parser tests and verify failure**

Run: `swift test --filter CodexEventParserTests`

Expected: compilation fails because `CodexEventParser` and `ParsedCodexEvent` are undefined.

- [ ] **Step 3: Implement tolerant dictionary-based parsing**

```swift
// Sources/CodexUsageMonitor/Parsing/CodexEventParser.swift
import Foundation

enum ParsedCodexEvent: Equatable, Sendable {
    case session(SessionMetadata)
    case token(ParsedTokenEvent)
}

struct CodexEventParser {
    private let formatter = ISO8601DateFormatter()

    func parse(line: Data) -> ParsedCodexEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String,
            let payload = object["payload"] as? [String: Any]
        else { return nil }

        guard let timestamp = date(object["timestamp"]) ?? date(payload["timestamp"]) else { return nil }
        if type == "session_meta", let id = payload["id"] as? String {
            return .session(SessionMetadata(
                sessionID: id,
                startedAt: timestamp,
                workingDirectory: payload["cwd"] as? String
            ))
        }

        guard type == "event_msg", payload["type"] as? String == "token_count" else { return nil }
        let info = payload["info"] as? [String: Any]
        return .token(ParsedTokenEvent(
            occurredAt: timestamp,
            lastUsage: usage(info?["last_token_usage"]),
            cumulativeUsage: usage(info?["total_token_usage"]),
            limits: limits(payload["rate_limits"], observedAt: timestamp)
        ))
    }

    private func usage(_ raw: Any?) -> TokenUsage? {
        guard let value = raw as? [String: Any] else { return nil }
        return TokenUsage(
            input: int64(value["input_tokens"]),
            cachedInput: int64(value["cached_input_tokens"]),
            output: int64(value["output_tokens"]),
            reasoningOutput: int64(value["reasoning_output_tokens"]),
            total: int64(value["total_tokens"])
        )
    }

    private func limits(_ raw: Any?, observedAt: Date) -> [RateLimitObservation] {
        guard let root = raw as? [String: Any] else { return [] }
        let id = root["limit_id"] as? String ?? "unknown"
        let label = root["limit_name"] as? String
        return ["primary", "secondary"].compactMap { key in
            guard let value = root[key] as? [String: Any],
                  let minutes = int(value["window_minutes"]),
                  let used = double(value["used_percent"]),
                  let reset = double(value["resets_at"]) else { return nil }
            let window: LimitWindow = switch minutes {
            case 300: .fiveHours
            case 10_080: .week
            default: .other(minutes: minutes, label: label)
            }
            return RateLimitObservation(limitID: id, window: window, usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset), observedAt: observedAt)
        }
    }

    private func date(_ raw: Any?) -> Date? {
        guard let string = raw as? String else { return nil }
        return formatter.date(from: string)
    }
    private func int64(_ raw: Any?) -> Int64 { (raw as? NSNumber)?.int64Value ?? 0 }
    private func int(_ raw: Any?) -> Int? { (raw as? NSNumber)?.intValue }
    private func double(_ raw: Any?) -> Double? { (raw as? NSNumber)?.doubleValue }
}
```

- [ ] **Step 4: Run parser tests**

Run: `swift test --filter CodexEventParserTests`

Expected: four parser behaviors pass; malformed and content-bearing unknown events return `nil`.

- [ ] **Step 5: Commit the parser**

```bash
git add Sources/CodexUsageMonitor/Parsing Tests/CodexUsageMonitorTests
git commit -m "feat: parse local Codex usage events"
```

## Task 3: Token De-duplication and Project Identity

**Files:**
- Create: `Sources/CodexUsageMonitor/Aggregation/TokenDeltaCalculator.swift`
- Create: `Sources/CodexUsageMonitor/Discovery/ProjectPathNormalizer.swift`
- Create: `Tests/CodexUsageMonitorTests/TokenDeltaCalculatorTests.swift`
- Create: `Tests/CodexUsageMonitorTests/ProjectPathNormalizerTests.swift`

**Interfaces:**
- Produces: `TokenDeltaCalculator.delta(lastUsage:cumulativeUsage:previousCumulative:) -> TokenUsage`.
- Produces: `ProjectIdentity(key:displayName:fullPath:)`.
- Produces: `ProjectPathNormalizer.identity(for:) -> ProjectIdentity`.

- [ ] **Step 1: Write failing delta and path tests**

```swift
// Tests/CodexUsageMonitorTests/TokenDeltaCalculatorTests.swift
import XCTest
@testable import CodexUsageMonitor

final class TokenDeltaCalculatorTests: XCTestCase {
    func testPrefersLastUsage() {
        let delta = TokenDeltaCalculator.delta(
            lastUsage: TokenUsage(input: 10, cachedInput: 2, output: 3, reasoningOutput: 1, total: 13),
            cumulativeUsage: TokenUsage(input: 100, cachedInput: 20, output: 30, reasoningOutput: 10, total: 130),
            previousCumulative: .zero
        )
        XCTAssertEqual(delta.total, 13)
    }

    func testUsesNonNegativeCumulativeDifferenceWhenLastUsageMissing() {
        let delta = TokenDeltaCalculator.delta(
            lastUsage: nil,
            cumulativeUsage: TokenUsage(input: 120, cachedInput: 20, output: 30, reasoningOutput: 10, total: 150),
            previousCumulative: TokenUsage(input: 100, cachedInput: 20, output: 25, reasoningOutput: 10, total: 130)
        )
        XCTAssertEqual(delta.total, 20)
    }
}
```

```swift
// Tests/CodexUsageMonitorTests/ProjectPathNormalizerTests.swift
import XCTest
@testable import CodexUsageMonitor

final class ProjectPathNormalizerTests: XCTestCase {
    func testUsesLastPathComponentAsDisplayName() {
        let identity = ProjectPathNormalizer().identity(for: "/synthetic/work/alpha")
        XCTAssertEqual(identity.displayName, "alpha")
        XCTAssertEqual(identity.key, "/synthetic/work/alpha")
    }

    func testMissingPathBecomesUnknownProject() {
        XCTAssertEqual(ProjectPathNormalizer().identity(for: nil).displayName, "未知项目")
    }
}
```

- [ ] **Step 2: Verify tests fail**

Run: `swift test --filter 'TokenDeltaCalculatorTests|ProjectPathNormalizerTests'`

Expected: compilation fails because both production types are missing.

- [ ] **Step 3: Implement deterministic delta and project identity**

```swift
// Sources/CodexUsageMonitor/Aggregation/TokenDeltaCalculator.swift
enum TokenDeltaCalculator {
    static func delta(lastUsage: TokenUsage?, cumulativeUsage: TokenUsage?, previousCumulative: TokenUsage?) -> TokenUsage {
        if let lastUsage { return lastUsage }
        guard let cumulativeUsage else { return .zero }
        guard let previousCumulative else { return cumulativeUsage }
        return cumulativeUsage - previousCumulative
    }
}
```

```swift
// Sources/CodexUsageMonitor/Discovery/ProjectPathNormalizer.swift
import Foundation

struct ProjectIdentity: Equatable, Sendable {
    let key: String
    let displayName: String
    let fullPath: String?
}

struct ProjectPathNormalizer: Sendable {
    func identity(for rawPath: String?) -> ProjectIdentity {
        guard let rawPath, !rawPath.isEmpty else {
            return ProjectIdentity(key: "unknown", displayName: "未知项目", fullPath: nil)
        }
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        let name = URL(fileURLWithPath: resolved).lastPathComponent
        return ProjectIdentity(key: resolved, displayName: name.isEmpty ? resolved : name, fullPath: resolved)
    }
}
```

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter 'TokenDeltaCalculatorTests|ProjectPathNormalizerTests'`

Expected: all four tests pass.

- [ ] **Step 5: Commit aggregation primitives**

```bash
git add Sources/CodexUsageMonitor/Aggregation Sources/CodexUsageMonitor/Discovery Tests
git commit -m "feat: normalize projects and deduplicate tokens"
```

## Task 4: SQLite Index and Idempotent Repository

**Files:**
- Create: `Sources/CodexUsageMonitor/Persistence/SQLiteDatabase.swift`
- Create: `Sources/CodexUsageMonitor/Persistence/UsageRepository.swift`
- Create: `Tests/CodexUsageMonitorTests/UsageRepositoryTests.swift`

**Interfaces:**
- Produces: `FileCursor(fileKey:path:offset:modifiedAt:)`.
- Produces actor `UsageRepository` with `openRecovering(url:now:)`, `migrate()`, `upsertSession`, `sessionID(forFileKey:)`, `insertUsageEvent`, `previousCumulativeUsage`, `saveCumulativeUsage`, `replaceLatestLimits`, `cursor`, `saveCursor`, `queryUsage`, `latestLimits`, `notificationWasSent`, `markNotificationSent`, and `resetIndex`.
- Consumes: `ProjectIdentity`, `TokenUsage`, `RateLimitObservation`.

- [ ] **Step 1: Write failing repository idempotency and query tests**

```swift
// Tests/CodexUsageMonitorTests/UsageRepositoryTests.swift
import XCTest
@testable import CodexUsageMonitor

final class UsageRepositoryTests: XCTestCase {
    func testDuplicateEventIDIsCountedOnce() async throws {
        let repository = try UsageRepository(url: temporaryDatabaseURL())
        try await repository.migrate()
        let project = ProjectIdentity(key: "/synthetic/alpha", displayName: "alpha", fullPath: "/synthetic/alpha")
        try await repository.upsertSession(SessionMetadata(sessionID: "s1", startedAt: Date(timeIntervalSince1970: 100), workingDirectory: project.fullPath), fileKey: "file-1", project: project)
        let usage = TokenUsage(input: 10, cachedInput: 2, output: 3, reasoningOutput: 1, total: 13)
        try await repository.insertUsageEvent(id: "file:100", sessionID: "s1", occurredAt: Date(timeIntervalSince1970: 200), usage: usage)
        try await repository.insertUsageEvent(id: "file:100", sessionID: "s1", occurredAt: Date(timeIntervalSince1970: 200), usage: usage)
        let rows = try await repository.queryUsage(from: nil, to: nil)
        XCTAssertEqual(rows.map(\.usage.total).reduce(0, +), 13)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
    }
}
```

- [ ] **Step 2: Verify repository tests fail**

Run: `swift test --filter UsageRepositoryTests`

Expected: compilation fails because `UsageRepository` is undefined.

- [ ] **Step 3: Implement the serialized SQLite wrapper and schema**

`SQLiteDatabase` must open with `SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX`, enable foreign keys and WAL, expose parameterized `execute`/`query`, and convert every non-`SQLITE_OK` result into `SQLiteError`. Do not construct SQL with user path interpolation.

Use this exact schema in `UsageRepository.migrate()`:

```sql
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  file_key TEXT NOT NULL UNIQUE,
  started_at REAL NOT NULL,
  project_key TEXT NOT NULL,
  project_name TEXT NOT NULL,
  full_path TEXT
);
CREATE TABLE IF NOT EXISTS usage_events (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  occurred_at REAL NOT NULL,
  input_tokens INTEGER NOT NULL,
  cached_input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  reasoning_output_tokens INTEGER NOT NULL,
  total_tokens INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS usage_events_time ON usage_events(occurred_at);
CREATE INDEX IF NOT EXISTS usage_events_session ON usage_events(session_id);
CREATE TABLE IF NOT EXISTS file_cursors (
  file_key TEXT PRIMARY KEY,
  path TEXT NOT NULL,
  byte_offset INTEGER NOT NULL,
  modified_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS cumulative_usage (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  input_tokens INTEGER NOT NULL,
  cached_input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  reasoning_output_tokens INTEGER NOT NULL,
  total_tokens INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS rate_limits (
  window_key TEXT PRIMARY KEY,
  limit_id TEXT NOT NULL,
  window_minutes INTEGER NOT NULL,
  window_label TEXT,
  used_percent REAL NOT NULL,
  resets_at REAL NOT NULL,
  observed_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS notification_receipts (
  receipt_key TEXT PRIMARY KEY,
  sent_at REAL NOT NULL
);
PRAGMA user_version = 1;
```

Run schema creation in one transaction. Accept `user_version` 0 for a fresh database, set it to 1 after creating tables, and call `resetIndex()` before rebuilding if a future binary encounters a version it cannot migrate explicitly.

Use a small bound-value wrapper; all calls are serialized by `UsageRepository` actor isolation:

```swift
// Sources/CodexUsageMonitor/Persistence/SQLiteDatabase.swift
import Foundation
import SQLite3

enum SQLiteValue: Sendable {
    case integer(Int64), real(Double), text(String), null
}

struct SQLiteError: Error, LocalizedError {
    let code: Int32
    let message: String
    var errorDescription: String? { "SQLite \(code): \(message)" }
}

final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else { throw currentError() }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    func query(_ sql: String, _ values: [SQLiteValue] = [], row: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw currentError()
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw currentError() }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (zeroIndex, value) in values.enumerated() {
            let index = Int32(zeroIndex + 1)
            let result: Int32 = switch value {
            case let .integer(value): sqlite3_bind_int64(statement, index, value)
            case let .real(value): sqlite3_bind_double(statement, index, value)
            case let .text(value): sqlite3_bind_text(statement, index, value, -1, transient)
            case .null: sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw currentError() }
        }
    }

    private func currentError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }
}
```

Define the repository query row and cursor exactly:

```swift
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
```

Implement idempotency with `INSERT OR IGNORE INTO usage_events`. Implement `queryUsage(from:to:)` with bound date parameters and `GROUP BY project_key, project_name, full_path`. Implement `replaceLatestLimits` as an upsert only when `excluded.observed_at >= rate_limits.observed_at`.

Use these exact repository signatures so ingestion and presentation tasks do not invent a second persistence API:

```swift
actor UsageRepository {
    init(url: URL) throws
    static func openRecovering(url: URL, now: Date = .now) throws -> UsageRepository
    func migrate() throws
    func upsertSession(_ metadata: SessionMetadata, fileKey: String, project: ProjectIdentity) throws
    func sessionID(forFileKey fileKey: String) throws -> String?
    func insertUsageEvent(id: String, sessionID: String, occurredAt: Date, usage: TokenUsage) throws
    func previousCumulativeUsage(sessionID: String) throws -> TokenUsage?
    func saveCumulativeUsage(_ usage: TokenUsage, sessionID: String) throws
    func replaceLatestLimits(_ observations: [RateLimitObservation]) throws
    func cursor(for fileKey: String) throws -> FileCursor?
    func saveCursor(_ cursor: FileCursor) throws
    func queryUsage(from: Date?, to: Date) throws -> [StoredUsageRow]
    func latestLimits() throws -> [RateLimitObservation]
    func notificationWasSent(_ key: String) throws -> Bool
    func markNotificationSent(_ key: String, sentAt: Date) throws
    func resetIndex() throws
}
```

`openRecovering` catches only `SQLITE_CORRUPT` and `SQLITE_NOTADB`, moves the database plus any `-wal`/`-shm` sidecars to names containing `.corrupt-<unix-seconds>`, and retries with an empty database. Permission, disk-full, and other errors propagate unchanged. Add a test that writes non-SQLite bytes, opens through `openRecovering`, migrates, and proves both the fresh database and preserved corrupt copy exist.

- [ ] **Step 4: Run repository tests, then add cursor/limit/receipt cases**

Add focused cases proving: cursor round-trip, later limit observation wins, earlier observation cannot overwrite, and a notification receipt is idempotent.

Run: `swift test --filter UsageRepositoryTests`

Expected: all repository tests pass and duplicate event total remains 16.

- [ ] **Step 5: Commit persistence**

```bash
git add Sources/CodexUsageMonitor/Persistence Tests/CodexUsageMonitorTests/UsageRepositoryTests.swift
git commit -m "feat: add local idempotent usage index"
```

## Task 5: Codex Home Discovery, Historical Scan, and Recursive Watching

**Files:**
- Create: `Sources/CodexUsageMonitor/Discovery/CodexHomeLocator.swift`
- Create: `Sources/CodexUsageMonitor/Ingestion/SessionScanner.swift`
- Create: `Sources/CodexUsageMonitor/Ingestion/SessionFileWatcher.swift`
- Create: `Sources/CodexUsageMonitor/Ingestion/IngestionCoordinator.swift`
- Create: `Tests/CodexUsageMonitorTests/CodexHomeLocatorTests.swift`
- Create: `Tests/CodexUsageMonitorTests/SessionScannerTests.swift`
- Create: `Tests/CodexUsageMonitorTests/IngestionCoordinatorTests.swift`

**Interfaces:**
- Produces: `CodexHomeLocator.home(environment:homeDirectory:)` and `sessionRoots(home:)`.
- Produces: actor `SessionScanner.scan(url:) -> ScanResult`.
- Produces: `SessionFileWatcher.events() -> AsyncStream<Void>` watching both session roots recursively with FSEvents.
- Produces: `enum IngestionUpdate { case completed; case failed(String) }` and actor `IngestionCoordinator.start()`, `updates()`, `rescanAll()`, `rebuildIndex()`, and `stop()`.
- Consumes: parser and repository from Tasks 2 and 4.

- [ ] **Step 1: Write failing discovery and incremental-scan tests**

```swift
// Tests/CodexUsageMonitorTests/CodexHomeLocatorTests.swift
import XCTest
@testable import CodexUsageMonitor

final class CodexHomeLocatorTests: XCTestCase {
    func testEnvironmentOverrideWins() {
        let result = CodexHomeLocator.home(environment: ["CODEX_HOME": "/synthetic/codex"], homeDirectory: URL(fileURLWithPath: "/synthetic/home"))
        XCTAssertEqual(result.path, "/synthetic/codex")
    }

    func testDefaultUsesDotCodex() {
        let result = CodexHomeLocator.home(environment: [:], homeDirectory: URL(fileURLWithPath: "/synthetic/home"))
        XCTAssertEqual(result.path, "/synthetic/home/.codex")
    }
}
```

The scanner test creates a temporary JSONL file with one session line and one Token line, scans it twice, appends another complete Token line, scans again, and asserts repository totals are first 135, still 135, then increased exactly once. Add a final line without `\n` and assert it is not processed until the newline is appended.

- [ ] **Step 2: Run ingestion tests and verify failure**

Run: `swift test --filter 'CodexHomeLocatorTests|SessionScannerTests|IngestionCoordinatorTests'`

Expected: compilation fails because discovery and ingestion types are missing.

- [ ] **Step 3: Implement discovery and newline-safe incremental reads**

```swift
// Sources/CodexUsageMonitor/Discovery/CodexHomeLocator.swift
import Foundation

enum CodexHomeLocator {
    static func home(environment: [String: String] = ProcessInfo.processInfo.environment,
                     homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    static func sessionRoots(home: URL) -> [URL] {
        [home.appendingPathComponent("sessions", isDirectory: true),
         home.appendingPathComponent("archived_sessions", isDirectory: true)]
    }
}
```

`SessionScanner.scan(url:)` must:

1. derive `fileKey` from resource identifier when available and fall back to standardized path;
2. fetch the saved cursor;
3. reset offset to 0 when file size is smaller than the cursor;
4. seek to the offset and read available data;
5. process only bytes through the final newline;
6. identify every event as `"\(fileKey):\(lineStartOffset):\(SHA256(line))"` so a rewritten line at the same byte offset is distinct while an identical re-read remains idempotent;
7. remember current session metadata while walking the file;
8. compute usage with `TokenDeltaCalculator` and repository cumulative state;
9. insert events idempotently and save the cursor only after every complete line succeeds, so a crash causes a safe re-read;
10. leave incomplete trailing bytes for the next scan.

Implement the scanner with this production shape:

```swift
// Sources/CodexUsageMonitor/Ingestion/SessionScanner.swift
import CryptoKit
import Foundation

struct ScanResult: Equatable, Sendable {
    let processedLines: Int
    let finalOffset: UInt64
}

actor SessionScanner {
    private let repository: UsageRepository
    private let parser = CodexEventParser()
    private let normalizer = ProjectPathNormalizer()

    init(repository: UsageRepository) { self.repository = repository }

    func scan(url: URL) async throws -> ScanResult {
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey])
        let fileKey = String(describing: values.fileResourceIdentifier ?? url.standardizedFileURL.path as NSString)
        let fileSize = UInt64(values.fileSize ?? 0)
        let modifiedAt = values.contentModificationDate ?? .distantPast
        let saved = try await repository.cursor(for: fileKey)
        let startOffset = min(saved?.offset ?? 0, fileSize)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)
        guard let available = try handle.readToEnd(),
              let finalNewline = available.lastIndex(of: 0x0A) else {
            return ScanResult(processedLines: 0, finalOffset: startOffset)
        }

        let complete = available[available.startIndex...finalNewline]
        var lineStart = startOffset
        var sessionID = try await repository.sessionID(forFileKey: fileKey)
        var processed = 0

        for rawLine in complete.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = Data(rawLine)
            defer { lineStart += UInt64(rawLine.count + 1) }
            guard !line.isEmpty else { continue }
            guard let event = parser.parse(line: line) else { continue }
            processed += 1

            switch event {
            case let .session(metadata):
                sessionID = metadata.sessionID
                let project = normalizer.identity(for: metadata.workingDirectory)
                try await repository.upsertSession(metadata, fileKey: fileKey, project: project)

            case let .token(token):
                guard let sessionID else { continue }
                let previous = try await repository.previousCumulativeUsage(sessionID: sessionID)
                let usage = TokenDeltaCalculator.delta(
                    lastUsage: token.lastUsage,
                    cumulativeUsage: token.cumulativeUsage,
                    previousCumulative: previous
                )
                let digest = SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined()
                try await repository.insertUsageEvent(
                    id: "\(fileKey):\(lineStart):\(digest)",
                    sessionID: sessionID,
                    occurredAt: token.occurredAt,
                    usage: usage
                )
                if let cumulative = token.cumulativeUsage {
                    try await repository.saveCumulativeUsage(cumulative, sessionID: sessionID)
                }
                try await repository.replaceLatestLimits(token.limits)
            }
        }

        let finalOffset = startOffset + UInt64(complete.count)
        try await repository.saveCursor(FileCursor(fileKey: fileKey, path: url.path, offset: finalOffset, modifiedAt: modifiedAt))
        return ScanResult(processedLines: processed, finalOffset: finalOffset)
    }
}
```

- [ ] **Step 4: Implement recursive FSEvents and coordinator debounce**

Create an `AsyncStream<Void>` backed by `FSEventStreamCreate` with:

```swift
let flags = FSEventStreamCreateFlags(
    kFSEventStreamCreateFlagFileEvents |
    kFSEventStreamCreateFlagUseCFTypes |
    kFSEventStreamCreateFlagWatchRoot
)
let latency: CFTimeInterval = 0.5
```

Keep the callback bridge minimal and lifetime-owned by the watcher:

```swift
import CoreServices

private final class WatcherContext: @unchecked Sendable {
    let continuation: AsyncStream<Void>.Continuation
    init(continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
}

private let fseventsCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
    guard let info else { return }
    Unmanaged<WatcherContext>.fromOpaque(info).takeUnretainedValue().continuation.yield(())
}
```

Expose the watcher and coordinator with these exact signatures:

```swift
final class SessionFileWatcher: @unchecked Sendable {
    init(roots: [URL])
    func events() -> AsyncStream<Void>
    func stop()
}

enum IngestionUpdate: Equatable, Sendable {
    case completed
    case failed(String)
}

actor IngestionCoordinator {
    init(roots: [URL], repository: UsageRepository, scanner: SessionScanner, watcher: SessionFileWatcher)
    func start() async
    func updates() async -> AsyncStream<IngestionUpdate>
    func rescanAll() async
    func rebuildIndex() async throws
    func stop() async
}
```

The FSEvents callback receives an unmanaged `WatcherContext`, calls `continuation.yield(())`, and never touches SQLite or SwiftUI directly. `stop()` calls `FSEventStreamStop`, `FSEventStreamInvalidate`, and `FSEventStreamRelease` exactly once. `IngestionCoordinator.start()` runs `UsageRepository.migrate()` before scanning. The coordinator owns the debounce task, cancels it before scheduling a new 300 ms task, and yields `.completed` only after affected scans finish or `.failed(error.localizedDescription)` when a scan/watch operation fails. `rebuildIndex()` calls `UsageRepository.resetIndex()`, clears in-memory file metadata, performs a full rescan, and yields one update.

The coordinator performs one initial recursive enumeration of `.jsonl` files, starts the watcher, debounces bursts for 300 ms, and rescans only JSONL files whose modification date or size changed. If either root does not exist, keep running and rescan roots after the next event or a 30-second recovery timer.

Run: `swift test --filter 'CodexHomeLocatorTests|SessionScannerTests|IngestionCoordinatorTests'`

Expected: all discovery, incomplete-line, idempotency, append, truncation, and archived-session tests pass.

- [ ] **Step 5: Commit ingestion**

```bash
git add Sources/CodexUsageMonitor/Discovery Sources/CodexUsageMonitor/Ingestion Tests
git commit -m "feat: ingest Codex logs incrementally"
```

## Task 6: Time-Range Aggregation and Dashboard View Model

**Files:**
- Create: `Sources/CodexUsageMonitor/Aggregation/UsageAggregator.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/UsageViewModel.swift`
- Create: `Tests/CodexUsageMonitorTests/UsageAggregatorTests.swift`
- Create: `Tests/CodexUsageMonitorTests/UsageViewModelTests.swift`

**Interfaces:**
- Produces: `UsageAggregator.bounds(for:now:calendar:)` and `snapshot(range:now:calendar:)`.
- Produces: `protocol LimitNotifying` and `@MainActor @Observable final class UsageViewModel` with `snapshot`, `selectedRange`, `start()`, `selectRange(_:)`, `retry()`, and `rebuildIndex()`.
- Consumes: `UsageRepository` and `IngestionCoordinator`.

- [ ] **Step 1: Write failing range and sorting tests**

```swift
// Tests/CodexUsageMonitorTests/UsageAggregatorTests.swift
import XCTest
@testable import CodexUsageMonitor

final class UsageAggregatorTests: XCTestCase {
    func testTodayStartsAtLocalMidnightAndProjectsSortDescending() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = Date(timeIntervalSince1970: 1_783_975_200)
        let bounds = UsageAggregator.bounds(for: .today, now: now, calendar: calendar)
        XCTAssertEqual(bounds.start, calendar.startOfDay(for: now))
        XCTAssertEqual(bounds.end, now)
    }

    func testSevenDaysIsExactlySevenTimesTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_783_975_200)
        let bounds = UsageAggregator.bounds(for: .sevenDays, now: now, calendar: .current)
        XCTAssertEqual(bounds.start, now.addingTimeInterval(-7 * 24 * 60 * 60))
    }
}
```

- [ ] **Step 2: Verify aggregation tests fail**

Run: `swift test --filter 'UsageAggregatorTests|UsageViewModelTests'`

Expected: compilation fails because aggregator and view model are undefined.

- [ ] **Step 3: Implement range bounds and dashboard construction**

```swift
// Sources/CodexUsageMonitor/Aggregation/UsageAggregator.swift
import Foundation

protocol UsageAggregating: Sendable {
    func snapshot(range: TokenRange, now: Date, calendar: Calendar) async throws -> DashboardSnapshot
}

struct UsageAggregator: UsageAggregating, Sendable {
    struct Bounds: Equatable, Sendable { let start: Date?; let end: Date }
    let repository: UsageRepository

    static func bounds(for range: TokenRange, now: Date, calendar: Calendar) -> Bounds {
        switch range {
        case .today: Bounds(start: calendar.startOfDay(for: now), end: now)
        case .sevenDays: Bounds(start: now.addingTimeInterval(-7 * 24 * 60 * 60), end: now)
        case .all: Bounds(start: nil, end: now)
        }
    }

    func snapshot(range: TokenRange, now: Date = .now, calendar: Calendar = .current) async throws -> DashboardSnapshot {
        let bounds = Self.bounds(for: range, now: now, calendar: calendar)
        let rows = try await repository.queryUsage(from: bounds.start, to: bounds.end)
        let groups = Dictionary(grouping: rows, by: \.projectName)
        let projects = rows.map { row in
            let duplicate = (groups[row.projectName]?.count ?? 0) > 1
            let parent = row.fullPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }
            let suffix = duplicate ? parent.flatMap { $0.isEmpty ? nil : $0 } : nil
            let name = suffix.map { "\(row.projectName) — \($0)" } ?? row.projectName
            return ProjectUsage(id: row.projectKey, displayName: name, fullPath: row.fullPath, usage: row.usage)
        }
            .sorted { $0.usage.total == $1.usage.total ? $0.displayName < $1.displayName : $0.usage.total > $1.usage.total }
        let total = projects.reduce(TokenUsage.zero) { current, project in
            TokenUsage(input: current.input + project.usage.input,
                       cachedInput: current.cachedInput + project.usage.cachedInput,
                       output: current.output + project.usage.output,
                       reasoningOutput: current.reasoningOutput + project.usage.reasoningOutput,
                       total: current.total + project.usage.total)
        }
        let limits = try await repository.latestLimits().map { LimitStatus(window: $0.window, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
        return DashboardSnapshot(range: range, total: total, projects: projects, limits: limits, freshness: rows.isEmpty ? .noData : .fresh(now))
    }
}
```

- [ ] **Step 4: Implement the main-actor view model and test stale/error retention**

Use these protocols to keep view-model tests independent from the filesystem and SQLite:

```swift
protocol IngestionControlling: Sendable {
    func start() async
    func updates() async -> AsyncStream<IngestionUpdate>
    func rescanAll() async
    func rebuildIndex() async throws
    func stop() async
}
```

Make `UsageAggregator` and `IngestionCoordinator` conform, then implement this state machine:

```swift
// Sources/CodexUsageMonitor/Presentation/UsageViewModel.swift
import Foundation
import Observation

protocol LimitNotifying: Sendable {
    func evaluate(_ limits: [LimitStatus]) async
}

actor NoopLimitNotifier: LimitNotifying {
    func evaluate(_ limits: [LimitStatus]) async {}
}

@MainActor
@Observable
final class UsageViewModel {
    private(set) var snapshot: DashboardSnapshot = .loading
    private(set) var selectedRange: TokenRange = .today
    private let aggregator: any UsageAggregating
    private let coordinator: any IngestionControlling
    private let notifier: any LimitNotifying
    private var updateTask: Task<Void, Never>?
    private var lastSuccessfulAt: Date?

    init(aggregator: any UsageAggregating, coordinator: any IngestionControlling, notifier: any LimitNotifying = NoopLimitNotifier()) {
        self.aggregator = aggregator
        self.coordinator = coordinator
        self.notifier = notifier
    }

    func start() async {
        guard updateTask == nil else { return }
        await coordinator.start()
        await refresh()
        let updates = await coordinator.updates()
        updateTask = Task { [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled else { return }
                switch update {
                case .completed: await self.refresh()
                case let .failed(message): self.apply(IngestionFailure(message: message))
                }
            }
        }
    }

    func selectRange(_ range: TokenRange) async {
        selectedRange = range
        await refresh()
    }

    func retry() async {
        await coordinator.rescanAll()
        await refresh()
    }

    func rebuildIndex() async {
        do {
            try await coordinator.rebuildIndex()
            await refresh()
        } catch {
            apply(error)
        }
    }

    private func refresh(now: Date = .now, calendar: Calendar = .current) async {
        do {
            snapshot = try await aggregator.snapshot(range: selectedRange, now: now, calendar: calendar)
            lastSuccessfulAt = now
            await notifier.evaluate(snapshot.limits)
        } catch {
            apply(error)
        }
    }

    private func apply(_ error: Error) {
        if let lastSuccessfulAt {
            snapshot = DashboardSnapshot(range: selectedRange, total: snapshot.total, projects: snapshot.projects, limits: snapshot.limits, freshness: .stale(lastSuccessfulAt))
        } else {
            snapshot = DashboardSnapshot(range: selectedRange, total: .zero, projects: [], limits: [], freshness: .failed(error.localizedDescription))
        }
    }

    deinit { updateTask?.cancel() }
}

private struct IngestionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
```

The view model retains the previous `total`, `projects`, and `limits` when refresh fails, changing only `freshness` to `.stale(lastSuccessfulDate)` or `.failed(message)` when there has never been a successful snapshot. Its tests use actor-backed spies, prove `start()` is idempotent, and prove deinitialization cancels update consumption.

Run: `swift test --filter 'UsageAggregatorTests|UsageViewModelTests'`

Expected: range, ordering, empty, stale-retention, retry, and range-selection tests pass.

- [ ] **Step 5: Commit aggregation and presentation state**

```bash
git add Sources/CodexUsageMonitor/Aggregation Sources/CodexUsageMonitor/Presentation Tests
git commit -m "feat: aggregate usage into dashboard snapshots"
```

## Task 7: Low-Limit Notifications and Login Launch

**Files:**
- Create: `Sources/CodexUsageMonitor/Services/NotificationCoordinator.swift`
- Create: `Sources/CodexUsageMonitor/Services/LaunchAtLoginController.swift`
- Create: `Tests/CodexUsageMonitorTests/NotificationCoordinatorTests.swift`
- Create: `Tests/CodexUsageMonitorTests/LaunchAtLoginControllerTests.swift`

**Interfaces:**
- Produces protocol `NotificationSending` and actor `NotificationCoordinator.evaluate(_:)`.
- Produces protocol `LaunchAtLoginServicing` and `LaunchAtLoginController`.
- Consumes repository notification receipts and `LimitStatus`.

- [ ] **Step 1: Write failing threshold and de-duplication tests**

```swift
// Tests/CodexUsageMonitorTests/NotificationCoordinatorTests.swift
import XCTest
@testable import CodexUsageMonitor

final class NotificationCoordinatorTests: XCTestCase {
    func testTwentyAndTenPercentEachNotifyOncePerResetWindow() async throws {
        let sender = NotificationSenderSpy()
        let repository = try UsageRepository(url: temporaryDatabaseURL())
        try await repository.migrate()
        let coordinator = NotificationCoordinator(repository: repository, sender: sender)
        let reset = Date(timeIntervalSince1970: 2_000)
        await coordinator.evaluate([LimitStatus(window: .fiveHours, usedPercent: 81, resetsAt: reset)])
        await coordinator.evaluate([LimitStatus(window: .fiveHours, usedPercent: 82, resetsAt: reset)])
        await coordinator.evaluate([LimitStatus(window: .fiveHours, usedPercent: 91, resetsAt: reset)])
        XCTAssertEqual(await sender.sentThresholds, [20, 10])
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
    }
}

private actor NotificationSenderSpy: NotificationSending {
    private(set) var sentThresholds: [Int] = []
    func isEnabled() async -> Bool { true }
    func requestAuthorization() async throws -> Bool { true }
    func send(title: String, body: String, threshold: Int) async throws {
        sentThresholds.append(threshold)
    }
}
```

- [ ] **Step 2: Verify service tests fail**

Run: `swift test --filter 'NotificationCoordinatorTests|LaunchAtLoginControllerTests'`

Expected: compilation fails because service protocols and controllers are missing.

- [ ] **Step 3: Implement notification keys and UserNotifications adapter**

```swift
import UserNotifications

protocol NotificationSending: Sendable {
    func isEnabled() async -> Bool
    func requestAuthorization() async throws -> Bool
    func send(title: String, body: String, threshold: Int) async throws
}

actor NotificationCoordinator: LimitNotifying {
    let repository: UsageRepository
    let sender: any NotificationSending

    func evaluate(_ limits: [LimitStatus]) async {
        guard await sender.isEnabled() else { return }
        for limit in limits {
            for threshold in [20, 10] where limit.remainingPercent < Double(threshold) {
                let key = "\(limit.window.storageKey)|\(Int(limit.resetsAt.timeIntervalSince1970))|\(threshold)"
                guard (try? await repository.notificationWasSent(key)) == false else { continue }
                do {
                    try await sender.send(
                        title: "Codex 用量提醒",
                        body: "\(limit.window.displayName)剩余 \(Int(limit.remainingPercent.rounded()))%",
                        threshold: threshold
                    )
                    try await repository.markNotificationSent(key, sentAt: .now)
                } catch { continue }
            }
        }
    }
}

final class UserNotificationSender: @unchecked Sendable, NotificationSending {
    private let center = UNUserNotificationCenter.current()
    func isEnabled() async -> Bool { UserDefaults.standard.bool(forKey: "notificationsEnabled") }
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func send(title: String, body: String, threshold: Int) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await center.add(request)
    }
}
```

Import `UserNotifications`. Settings set `notificationsEnabled=true` only after `requestAuthorization()` returns `true`; a denied permission leaves it false and is never prompted again automatically.

- [ ] **Step 4: Implement `SMAppService.mainApp` adapter**

```swift
// Sources/CodexUsageMonitor/Services/LaunchAtLoginController.swift
import ServiceManagement

protocol LaunchAtLoginServicing: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

struct LaunchAtLoginController: LaunchAtLoginServicing {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}
```

Run: `swift test --filter 'NotificationCoordinatorTests|LaunchAtLoginControllerTests'`

Expected: threshold order is `[20, 10]`, duplicate snapshots do not resend, a new reset timestamp permits new alerts, and login-service state errors are surfaced.

- [ ] **Step 5: Commit system services**

```bash
git add Sources/CodexUsageMonitor/Services Tests
git commit -m "feat: add usage alerts and login launch"
```

## Task 8: SwiftUI Menu Bar, Popover, and Settings

**Files:**
- Modify: `Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift`
- Modify: `Sources/CodexUsageMonitor/App/AppDelegate.swift`
- Create: `Sources/CodexUsageMonitor/App/LiveDependencies.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/MenuBarLabel.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/UsagePopoverView.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/SettingsView.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/Components/LimitCard.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/Components/ProjectRow.swift`
- Create: `Tests/CodexUsageMonitorTests/MenuBarFormattingTests.swift`

**Interfaces:**
- Consumes: `UsageViewModel`, `DashboardSnapshot`, `LimitStatus`, `ProjectUsage`.
- Produces: balanced label `5h 72% · 周 48%`, minimal popover, settings window, accessibility labels, and dark/light mode behavior.

- [ ] **Step 1: Write failing menu-label formatter tests**

```swift
// Tests/CodexUsageMonitorTests/MenuBarFormattingTests.swift
import XCTest
@testable import CodexUsageMonitor

final class MenuBarFormattingTests: XCTestCase {
    func testBalancedLabelShowsBothKnownWindows() {
        let limits = [
            LimitStatus(window: .fiveHours, usedPercent: 28, resetsAt: .distantFuture),
            LimitStatus(window: .week, usedPercent: 52, resetsAt: .distantFuture)
        ]
        XCTAssertEqual(MenuBarFormatter.title(limits: limits), "5h 72% · 周 48%")
    }

    func testMissingLimitsShowsWaitingCopy() {
        XCTAssertEqual(MenuBarFormatter.title(limits: []), "Codex --")
    }
}
```

- [ ] **Step 2: Verify formatter test fails**

Run: `swift test --filter MenuBarFormattingTests`

Expected: compilation fails because `MenuBarFormatter` is missing.

- [ ] **Step 3: Implement formatter and reusable visual components**

```swift
enum MenuBarFormatter {
    static func title(limits: [LimitStatus]) -> String {
        let five = limits.first { $0.window == .fiveHours }
        let week = limits.first { $0.window == .week }
        guard let five, let week else { return "Codex --" }
        return "5h \(Int(five.remainingPercent.rounded()))% · 周 \(Int(week.remainingPercent.rounded()))%"
    }
}
```

`LimitCard` uses `ProgressView(value: remainingPercent, total: 100)`, shows an absolute reset date plus relative countdown, and uses orange below 20 and red below 10. `ProjectRow` shows display name, monospaced abbreviated Token count, and the full path as `.help(fullPath)` without exposing it anywhere else.

Use these component bodies as the baseline rather than duplicating limit color logic across views:

```swift
func limitColor(remaining: Double) -> Color {
    if remaining < 10 { return .red }
    if remaining < 20 { return .orange }
    return .accentColor
}

struct MenuBarLabel: View {
    let snapshot: DashboardSnapshot
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(MenuBarFormatter.title(limits: snapshot.limits))
        }
        .foregroundStyle(isStale ? .secondary : mostSevereColor)
        .accessibilityLabel("Codex 用量，\(MenuBarFormatter.title(limits: snapshot.limits))")
    }

    private var isStale: Bool {
        if case .stale = snapshot.freshness { return true }
        if case .failed = snapshot.freshness { return true }
        return false
    }

    private var mostSevereColor: Color {
        limitColor(remaining: snapshot.limits.map(\.remainingPercent).min() ?? 100)
    }
}

struct LimitCard: View {
    let status: LimitStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.window.displayName).font(.caption).foregroundStyle(.secondary)
            Text("\(Int(status.remainingPercent.rounded()))%")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            ProgressView(value: status.remainingPercent, total: 100)
                .tint(limitColor(remaining: status.remainingPercent))
            Text(status.resetsAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProjectRow: View {
    let project: ProjectUsage
    var body: some View {
        HStack {
            Text(project.displayName).lineLimit(1)
            Spacer()
            Text(project.usage.total.formatted(.number.notation(.compactName)))
                .fontDesign(.monospaced)
        }
        .help(project.fullPath ?? project.displayName)
        .accessibilityLabel("\(project.displayName)，\(project.usage.total) Token")
    }
}
```

- [ ] **Step 4: Wire the final app scene and settings**

Construct production dependencies without `try!` and preserve a visible startup failure state:

```swift
// Sources/CodexUsageMonitor/App/LiveDependencies.swift
import Foundation

enum LiveDependencies {
    @MainActor
    static func makeViewModel() -> UsageViewModel {
        do {
            let supportRoot = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("CodexUsageMonitor", isDirectory: true)
            try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
            let repository = try UsageRepository.openRecovering(url: supportRoot.appendingPathComponent("usage.sqlite"))
            let roots = CodexHomeLocator.sessionRoots(home: CodexHomeLocator.home())
            let scanner = SessionScanner(repository: repository)
            let watcher = SessionFileWatcher(roots: roots)
            let coordinator = IngestionCoordinator(roots: roots, repository: repository, scanner: scanner, watcher: watcher)
            let notifier = NotificationCoordinator(repository: repository, sender: UserNotificationSender())
            return UsageViewModel(aggregator: UsageAggregator(repository: repository), coordinator: coordinator, notifier: notifier)
        } catch {
            return UsageViewModel(
                aggregator: StartupFailureAggregator(error: error),
                coordinator: NoopIngestionController()
            )
        }
    }
}

private struct StartupFailureAggregator: UsageAggregating {
    let error: Error
    func snapshot(range: TokenRange, now: Date, calendar: Calendar) async throws -> DashboardSnapshot { throw error }
}

private actor NoopIngestionController: IngestionControlling {
    func start() async {}
    func updates() async -> AsyncStream<IngestionUpdate> { AsyncStream { $0.finish() } }
    func rescanAll() async {}
    func rebuildIndex() async throws {}
    func stop() async {}
}
```

```swift
// Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift
import SwiftUI

@main
@MainActor
struct CodexUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = LiveDependencies.makeViewModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(model: model)
                .frame(width: 520, height: 480)
                .task { await model.start() }
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 460, height: 360)
        }
    }
}
```

The popover uses a segmented `Picker` for `TokenRange`, two `LimitCard`s, one total Token row, a sorted project list, freshness footer, retry/rebuild buttons, Settings link, and Quit action. Add accessibility labels for every percentage, Token total, project row, and freshness state. On first launch, present a non-blocking choice to enable login launch; declining must remain respected.

The popover range binding must call the asynchronous view-model command instead of mutating `selectedRange` directly:

```swift
private var rangeBinding: Binding<TokenRange> {
    Binding(
        get: { model.selectedRange },
        set: { range in Task { await model.selectRange(range) } }
    )
}
```

Persist the first-launch decision with `@AppStorage("didAskLaunchAtLogin")`; set it to `true` for both Enable and Not Now actions. `SettingsView` calls `LaunchAtLoginServicing.setEnabled`, displays any thrown error inline, and never silently reports a state change that failed.

Run: `swift test --filter MenuBarFormattingTests && swift test`

Expected: formatter and all prior tests pass; `swift build` succeeds.

- [ ] **Step 5: Commit the complete menu-bar UI**

```bash
git add Sources/CodexUsageMonitor/App Sources/CodexUsageMonitor/Presentation Tests
git commit -m "feat: build native menu bar usage dashboard"
```

## Task 9: End-to-End Ingestion and Recovery Verification

**Files:**
- Create: `Tests/CodexUsageMonitorTests/EndToEndIngestionTests.swift`
- Create: `Tests/CodexUsageMonitorTests/Fixtures/session-truncated.jsonl`
- Modify: ingestion and persistence files only when a failing integration test demonstrates a defect.

**Interfaces:**
- Verifies the complete local pipeline without production user data.
- Consumes all domain, parsing, persistence, ingestion, aggregation, and service interfaces.

- [ ] **Step 1: Write an end-to-end synthetic-home test**

The test creates a temporary `$CODEX_HOME/sessions/2026/07/14` tree, writes two synthetic projects and one archived session, starts the coordinator, and asserts:

```swift
XCTAssertEqual(today.total.total, 270)
XCTAssertEqual(today.projects.map(\.displayName), ["alpha", "beta"])
XCTAssertEqual(today.limits.first { $0.window == .fiveHours }?.remainingPercent, 72)
XCTAssertEqual(today.limits.first { $0.window == .week }?.remainingPercent, 48)
```

Then append a complete Token line, wait with an XCTest expectation capped at 2 seconds, and assert the increase appears exactly once. Repeat after deleting the SQLite index and verify the rebuilt snapshot equals the original snapshot.

Build fixtures through this helper so the test never touches real Codex files:

```swift
private func writeSyntheticSession(
    at url: URL,
    id: String,
    cwd: String,
    timestamp: String,
    total: Int,
    usedFiveHour: Double = 28,
    usedWeek: Double = 52
) throws {
    let session: [String: Any] = [
        "timestamp": timestamp,
        "type": "session_meta",
        "payload": ["id": id, "timestamp": timestamp, "cwd": cwd]
    ]
    let token: [String: Any] = [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": [
                "last_token_usage": ["input_tokens": total - 10, "cached_input_tokens": 5, "output_tokens": 10, "reasoning_output_tokens": 0, "total_tokens": total],
                "total_token_usage": ["input_tokens": total - 10, "cached_input_tokens": 5, "output_tokens": 10, "reasoning_output_tokens": 0, "total_tokens": total]
            ],
            "rate_limits": [
                "limit_id": "synthetic",
                "limit_name": "Synthetic Codex",
                "primary": ["used_percent": usedFiveHour, "window_minutes": 300, "resets_at": 1_784_000_000],
                "secondary": ["used_percent": usedWeek, "window_minutes": 10_080, "resets_at": 1_784_600_000]
            ]
        ]
    ]
    let data = try [session, token]
        .map { try JSONSerialization.data(withJSONObject: $0) }
        .reduce(into: Data()) { result, line in result.append(line); result.append(0x0A) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}
```

Call it with two current-day sessions of 135 total Tokens each and one previous-day archived session of 80 total Tokens. Assert Today is 270, 7 Days and All are 350, and project ordering is stable.

- [ ] **Step 2: Run the end-to-end test and verify failure**

Run: `swift test --filter EndToEndIngestionTests`

Expected: the new test fails on the first uncovered integration seam rather than being skipped.

- [ ] **Step 3: Fix only the demonstrated pipeline defects**

For each failure, add the smallest production change and a focused assertion covering it. Required recovery cases are: incomplete trailing line, malformed middle line, file truncation, file replacement, move to archive, missing roots at startup, and SQLite index rebuild.

- [ ] **Step 4: Run all tests repeatedly**

Run: `for i in 1 2 3; do swift test || exit 1; done`

Expected: three consecutive green runs with no timing flake and no test reading `~/.codex`.

- [ ] **Step 5: Commit verified ingestion behavior**

```bash
git add Sources Tests
git commit -m "test: verify usage pipeline end to end"
```

## Task 10: App Bundle, Documentation, License, and CI

**Files:**
- Create: `Config/Info.plist`
- Create: `Scripts/build-app.sh`
- Create: `README.md`
- Create: `LICENSE`
- Create: `.github/workflows/ci.yml`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `dist/Codex Usage Monitor.app` and `dist/Codex-Usage-Monitor-macOS.zip`.
- Produces: reproducible local build and public-repository documentation.

- [ ] **Step 1: Add Info.plist and a bundle smoke-test command that initially fails**

Use `LSUIElement=true`, bundle identifier `com.amenggod.CodexUsageMonitor`, deployment target `14.0`, executable `CodexUsageMonitor`, and user-facing name `Codex Usage Monitor`.

```xml
<!-- Config/Info.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>Codex Usage Monitor</string>
  <key>CFBundleExecutable</key><string>CodexUsageMonitor</string>
  <key>CFBundleIdentifier</key><string>com.amenggod.CodexUsageMonitor</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Codex Usage Monitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

Run before the script exists: `bash Scripts/build-app.sh`

Expected: exit non-zero because the build script is missing.

- [ ] **Step 2: Implement deterministic host-architecture bundling**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Codex Usage Monitor.app"
rm -rf "$APP" "$ROOT/dist/Codex-Usage-Monitor-macOS.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexUsageMonitor" "$APP/Contents/MacOS/CodexUsageMonitor"
cp "$ROOT/Config/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/Codex-Usage-Monitor-macOS.zip"
echo "$APP"
```

Make it executable with `chmod +x Scripts/build-app.sh`.

- [ ] **Step 3: Write the public documentation and MIT License**

README sections must be: overview, features, macOS 14 requirement, privacy boundary, build with `swift test` and `bash Scripts/build-app.sh`, installation, first-launch notification/login choices, data-source health, rebuild index, troubleshooting, known schema-compatibility risk, contributing, and MIT license. Omit screenshots until a real app screenshot has been produced; never add a fake image. State that the app is unofficial and not affiliated with or endorsed by OpenAI.

The MIT copyright line is:

```text
Copyright (c) 2026 amenggod
```

- [ ] **Step 4: Add CI and run bundle verification**

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
  pull_request:
jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Test
        run: swift test
      - name: Build app bundle
        run: bash Scripts/build-app.sh
```

Run: `swift test && bash Scripts/build-app.sh && test -f 'dist/Codex Usage Monitor.app/Contents/MacOS/CodexUsageMonitor' && unzip -t dist/Codex-Usage-Monitor-macOS.zip`

Expected: tests pass, plist and signature verify, executable exists, and ZIP integrity reports no errors.

- [ ] **Step 5: Commit release tooling and docs**

```bash
git add Config Scripts README.md LICENSE .github .gitignore
git commit -m "docs: add build and release documentation"
```

## Task 11: Final Verification, Public GitHub Repository, and Deliverable

**Files:**
- Modify only files required by failing verification.
- Produce ignored artifact: `dist/Codex-Usage-Monitor-macOS.zip`.
- Copy user-facing artifact to ignored workspace path: `outputs/Codex-Usage-Monitor-macOS.zip`.

**Interfaces:**
- Publishes the verified `main` branch to public GitHub repository `codex-usage-monitor-macos`.
- Produces the final local `.app` ZIP without committing it.

- [ ] **Step 1: Run the complete local verification gate**

```bash
swift test
bash Scripts/build-app.sh
git diff --check
git status --short
codesign --verify --deep --strict 'dist/Codex Usage Monitor.app'
spctl --assess --type execute 'dist/Codex Usage Monitor.app' || true
```

Expected: tests, build, diff check, and ad-hoc signature verification pass. `spctl` may reject the app because notarization is explicitly out of scope; record that result in delivery notes rather than weakening Gatekeeper.

- [ ] **Step 2: Audit the exact public repository contents**

```bash
test -z "$(git status --porcelain)"
! git ls-files | rg '(^|/)(\.codex|sessions|archived_sessions|dist|outputs)(/|$)'
HOME_PREFIX="/$(printf '%s' 'Users')/"
TOKEN_PREFIX="$(printf '%s%s' 'gh' 'o_')"
API_PREFIX="$(printf '%s%s' 's' 'k-')"
! git grep -nF "$HOME_PREFIX"
! git grep -nE "${TOKEN_PREFIX}[A-Za-z0-9]+|${API_PREFIX}[A-Za-z0-9]+"
git log --oneline --decorate -12
```

Expected: clean tree, no real session or artifact paths tracked, no credential patterns, and intentional incremental commits.

- [ ] **Step 3: Create the public GitHub repository safely**

First check ownership and nonexistence:

```bash
gh auth status
if gh repo view amenggod/codex-usage-monitor-macos >/dev/null 2>&1; then
  echo 'Repository already exists; stop and inspect before pushing.' >&2
  exit 1
fi
```

Expected: authenticated as `amenggod`; repository lookup fails because the name is unused. If it exists, do not overwrite or force-push it—ask the user for direction.

Create and push only after the audit passes:

```bash
gh repo create codex-usage-monitor-macos \
  --public \
  --source=. \
  --remote=origin \
  --push \
  --description 'Native macOS menu bar monitor for local Codex usage and rate limits'
```

Expected: public repository URL `https://github.com/amenggod/codex-usage-monitor-macos` and `main` pushed to `origin`.

- [ ] **Step 4: Verify GitHub state and CI**

```bash
gh repo view amenggod/codex-usage-monitor-macos --json nameWithOwner,isPrivate,url,defaultBranchRef
gh run list --repo amenggod/codex-usage-monitor-macos --limit 5
```

Expected: `isPrivate` is `false`, default branch is `main`, and the latest CI run completes successfully. If CI fails, inspect with `gh run view <run-id> --log-failed`, fix through a tested commit, and push normally.

- [ ] **Step 5: Copy the verified artifact and report delivery**

```bash
mkdir -p outputs
cp dist/Codex-Usage-Monitor-macOS.zip outputs/Codex-Usage-Monitor-macOS.zip
shasum -a 256 outputs/Codex-Usage-Monitor-macOS.zip
```

Expected: final response includes the clickable local ZIP path, GitHub public URL, test/build results, CI result, commit SHA, and SHA-256. Explicitly note that the app is ad-hoc signed and not notarized.
