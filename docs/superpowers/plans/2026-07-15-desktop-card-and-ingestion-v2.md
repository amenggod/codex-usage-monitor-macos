# Desktop Card and Ingestion v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 Codex 分支日志造成的扫描中断与 Token 重复统计，并增加可在桌面卡片、菜单栏或两者之间切换的实时监控界面。

**Architecture:** 数据层升级为 schema v2，将会话与文件解耦，以逻辑 Token 事件键跨文件去重，并按文件原子提交；协调器隔离失败文件并发布部分失败和重建进度。展示层增加限额有效性策略、持久化显示模式和由 `NSPanel` 承载的 SwiftUI 桌面卡片，桌面与菜单栏共享同一个 `UsageViewModel`。

**Tech Stack:** Swift 6.3、SwiftUI、AppKit、Observation、SQLite3、CryptoKit、Swift Testing、macOS 14+

## Global Constraints

- 默认显示模式必须是仅桌面卡片；可切换仅菜单栏或两者同时显示。
- 桌面卡片不显示 Dock 图标、不始终置顶，普通应用可覆盖。
- 新增完整日志行从落盘到界面更新目标不超过 2 秒。
- 缺失或过期的 5 小时窗口必须隐藏、不占位、不通知。
- 过期周窗口不得展示旧剩余值或触发通知。
- 不读取、保存、记录或测试真实提示词、回复、工具输出、凭据和真实用户路径。
- 所有日志夹具必须是合成数据；不得把 `~/.codex` 内容提交到仓库。
- v1 升级到 v2 必须保留通知回执、通知偏好、显示模式、窗口位置和登录启动偏好。
- 每个生产行为先写失败测试并确认 RED，再写最小实现确认 GREEN。
- 每项任务完成后运行对应测试并创建独立提交；禁止顺手重构无关代码。

---

### Task 1: 建立 schema v2 与可恢复文件游标

**Files:**
- Create: `Sources/CodexUsageMonitor/Persistence/UsageSchema.swift`
- Modify: `Sources/CodexUsageMonitor/Persistence/UsageRepository.swift`
- Modify: `Tests/CodexUsageMonitorTests/UsageRepositoryTests.swift`

**Interfaces:**
- Produces: `FileCursor(fileKey:path:offset:modifiedAt:activeSessionID:)`
- Produces: `UsageSchema.currentVersion == 2`
- Produces: `UsageRepository.upsertSession(_:project:)`
- Removes: `UsageRepository.sessionID(forFileKey:)`
- Preserves: `notification_receipts` rows during v1-to-v2 migration

- [ ] **Step 1: 写 v1 迁移与游标 RED 测试**

在 `UsageRepositoryTests.swift` 增加：

```swift
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
```

测试帮助函数使用 SQLite 创建真实 v1 表和 `PRAGMA user_version = 1`，只写合成值。

- [ ] **Step 2: 运行测试并确认按预期失败**

Run:

```bash
swift test --filter UsageRepositoryTests
```

Expected: FAIL，原因包括 `FileCursor` 缺少 `activeSessionID`、当前版本仍为 1、`upsertSession` 仍要求 `fileKey`。

- [ ] **Step 3: 实现 schema v2 与迁移**

`UsageSchema.swift` 定义：

```swift
import Foundation

enum UsageSchema {
    static let currentVersion: Int64 = 2

    static func createVersionTwo(in database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
              id TEXT PRIMARY KEY,
              started_at REAL NOT NULL,
              project_key TEXT NOT NULL,
              project_name TEXT NOT NULL,
              full_path TEXT
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS file_cursors (
              file_key TEXT PRIMARY KEY,
              path TEXT NOT NULL,
              byte_offset INTEGER NOT NULL,
              modified_at REAL NOT NULL,
              active_session_id TEXT
            )
            """)
    }
}
```

在同一创建事务中保留现有 `rate_limits`、`notification_receipts`，并为 Task 2 创建包含原始和增量 Token 列的 v2 `usage_events`：

```sql
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
)
```

`migrate()` 对 version 1 调用 `resetIndex(preserveNotificationReceipts: true)`，再在事务中创建 v2 并设置 `PRAGMA user_version = 2`。未知未来版本继续清除不兼容回执表后安全重建。`FileCursor` 增加可选 `activeSessionID`，游标 SQL 增加 `active_session_id`。`sessions` 的 upsert 改为仅按 `id` 更新元数据。

- [ ] **Step 4: 运行仓库测试确认 GREEN**

Run:

```bash
swift test --filter UsageRepositoryTests
```

Expected: PASS；现有未来 schema、损坏数据库和通知回执测试仍通过。

- [ ] **Step 5: 提交 Task 1**

```bash
git add Sources/CodexUsageMonitor/Persistence/UsageSchema.swift \
  Sources/CodexUsageMonitor/Persistence/UsageRepository.swift \
  Tests/CodexUsageMonitorTests/UsageRepositoryTests.swift
git commit -m "feat: migrate usage index to schema v2"
```

---

### Task 2: 实现逻辑 Token 事件键与跨文件去重

**Files:**
- Create: `Sources/CodexUsageMonitor/Ingestion/TokenEventIdentity.swift`
- Create: `Sources/CodexUsageMonitor/Ingestion/FileIngestionBatch.swift`
- Modify: `Sources/CodexUsageMonitor/Persistence/UsageRepository.swift`
- Modify: `Sources/CodexUsageMonitor/Persistence/SQLiteDatabase.swift`
- Create: `Tests/CodexUsageMonitorTests/TokenEventIdentityTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/UsageRepositoryTests.swift`

**Interfaces:**
- Produces: `LogicalTokenEvent`
- Produces: `TokenEventIdentity.make(sessionID:event:) -> String`
- Produces: `FileIngestionBatch`
- Produces: `UsageRepository.apply(_:) -> FileIngestionResult`
- Consumes: schema v2 from Task 1

- [ ] **Step 1: 写事件身份和批量写入 RED 测试**

`TokenEventIdentityTests.swift`：

```swift
import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct TokenEventIdentityTests {
    @Test
    func identityIgnoresFilePathAndOffset() {
        let event = ParsedTokenEvent(
            occurredAt: Date(timeIntervalSince1970: 1_000),
            lastUsage: TokenUsage(input: 10, cachedInput: 2, output: 3, reasoningOutput: 1, total: 13),
            cumulativeUsage: TokenUsage(input: 20, cachedInput: 4, output: 6, reasoningOutput: 2, total: 26),
            limits: []
        )

        let first = TokenEventIdentity.make(sessionID: "parent", event: event)
        let second = TokenEventIdentity.make(sessionID: "parent", event: event)

        #expect(first == second)
        #expect(first.count == 64)
    }

    @Test
    func identityChangesWhenLogicalUsageChanges() {
        let first = ParsedTokenEvent(
            occurredAt: Date(timeIntervalSince1970: 1_000),
            lastUsage: .zero,
            cumulativeUsage: .zero,
            limits: []
        )
        let second = ParsedTokenEvent(
            occurredAt: Date(timeIntervalSince1970: 1_000),
            lastUsage: TokenUsage(input: 1, cachedInput: 0, output: 0, reasoningOutput: 0, total: 1),
            cumulativeUsage: .zero,
            limits: []
        )

        #expect(TokenEventIdentity.make(sessionID: "s", event: first) != TokenEventIdentity.make(sessionID: "s", event: second))
    }
}
```

在 `UsageRepositoryTests.swift` 增加两个真实数据库测试：同一逻辑事件放入两个不同批次只计一次；累计事件按时间逆序到达后仍得到正确非负差值。

```swift
@Test
func duplicateLogicalEventsAcrossFileBatchesAreCountedOnce() async throws {
    let fixture = try await RepositoryBatchFixture()
    defer { fixture.remove() }
    let event = fixture.event(sessionID: "parent", second: 1, lastTotal: 25, cumulativeTotal: 25)

    _ = try await fixture.repository.apply(fixture.batch(fileKey: "file-a", events: [event]))
    _ = try await fixture.repository.apply(fixture.batch(fileKey: "file-b", events: [event]))

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
```

- [ ] **Step 2: 运行测试确认 RED**

```bash
swift test --filter TokenEventIdentityTests
swift test --filter UsageRepositoryTests
```

Expected: FAIL，因为身份生成器、批次类型和 `apply(_:)` 尚不存在。

- [ ] **Step 3: 实现逻辑事件和原子批次**

`FileIngestionBatch.swift` 定义：

```swift
import Foundation

struct SessionUpsert: Sendable {
    let metadata: SessionMetadata
    let project: ProjectIdentity
}

struct LogicalTokenEvent: Sendable {
    let id: String
    let sessionID: String
    let occurredAt: Date
    let lastUsage: TokenUsage?
    let cumulativeUsage: TokenUsage?
}

struct FileIngestionBatch: Sendable {
    let sessions: [SessionUpsert]
    let events: [LogicalTokenEvent]
    let limits: [RateLimitObservation]
    let cursor: FileCursor
}

struct FileIngestionResult: Equatable, Sendable {
    let insertedEvents: Int
    let duplicateEvents: Int
}
```

`TokenEventIdentity` 用固定顺序编码会话 ID、毫秒时间戳和两个可选 `TokenUsage` 的五项 Int64，再计算 SHA-256；不接受路径或偏移参数。

`UsageRepository.apply(_:)` 使用一个 `BEGIN IMMEDIATE` 事务：upsert sessions、`INSERT OR IGNORE` logical events、只对新事件更新 delta、按 `observedAt` 更新限额、最后保存 cursor。若任何步骤失败则回滚，游标不前移。

有 `lastUsage` 时直接写入 delta。只有累计值时，对受影响 session 查询全部事件，按 `occurred_at, id` 排序，从零基线计算非负差值并更新 delta；重复事件不触发重算。`queryUsage` 改为汇总 `delta_*` 列。

- [ ] **Step 4: 运行事件与仓库测试确认 GREEN**

```bash
swift test --filter TokenEventIdentityTests
swift test --filter UsageRepositoryTests
swift test --filter UsageAggregatorTests
```

Expected: PASS，聚合仍以 `total_tokens` 对应的 delta 总量为权威值。

- [ ] **Step 5: 提交 Task 2**

```bash
git add Sources/CodexUsageMonitor/Ingestion/TokenEventIdentity.swift \
  Sources/CodexUsageMonitor/Ingestion/FileIngestionBatch.swift \
  Sources/CodexUsageMonitor/Persistence/UsageRepository.swift \
  Sources/CodexUsageMonitor/Persistence/SQLiteDatabase.swift \
  Tests/CodexUsageMonitorTests/TokenEventIdentityTests.swift \
  Tests/CodexUsageMonitorTests/UsageRepositoryTests.swift
git commit -m "feat: deduplicate logical token events"
```

---

### Task 3: 支持单文件多会话和增量会话恢复

**Files:**
- Modify: `Sources/CodexUsageMonitor/Ingestion/SessionScanner.swift`
- Modify: `Tests/CodexUsageMonitorTests/SessionScannerTests.swift`

**Interfaces:**
- Consumes: `UsageRepository.apply(_:)`
- Consumes: `FileCursor.activeSessionID`
- Consumes: `TokenEventIdentity.make(sessionID:event:)`
- Preserves: `SessionScanner.scan(url:) -> ScanResult`

- [ ] **Step 1: 写多会话、分支复制和游标 RED 测试**

在 `SessionScannerTests.swift` 增加：

```swift
@Test
func oneFileCanSwitchFromParentToChildSession() async throws {
    let fixture = try await ScannerFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.sessionLine(id: "parent", project: "parent-project"),
        fixture.tokenLine(second: 1, last: fixture.usage(10)),
        fixture.sessionLine(id: "child", project: "child-project"),
        fixture.tokenLine(second: 2, last: fixture.usage(20)),
    ])

    _ = try await fixture.scanner.scan(url: fixture.logURL)

    #expect(try await fixture.projectTotals() == ["child-project": 20, "parent-project": 10])
}

@Test
func copiedParentHistoryAcrossBranchesIsCountedOnce() async throws {
    let fixture = try await ScannerFixture()
    defer { fixture.remove() }
    let parentSession = fixture.sessionLine(id: "parent", project: "parent-project")
    let parentToken = fixture.tokenLine(second: 1, last: fixture.usage(10))
    try fixture.write([parentSession, parentToken])
    _ = try await fixture.scanner.scan(url: fixture.logURL)

    let branchURL = fixture.directoryURL.appending(path: "branch.jsonl")
    try fixture.write([
        parentSession,
        parentToken,
        fixture.sessionLine(id: "child", project: "child-project"),
        fixture.tokenLine(second: 2, last: fixture.usage(20)),
    ], to: branchURL)
    _ = try await fixture.scanner.scan(url: branchURL)

    #expect(try await fixture.totalUsage() == 30)
}

@Test
func appendedTokenUsesSessionStoredInFileCursor() async throws {
    let fixture = try await ScannerFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.sessionLine(id: "parent", project: "parent-project"),
        fixture.sessionLine(id: "child", project: "child-project"),
        fixture.tokenLine(second: 1, last: fixture.usage(10)),
    ])
    _ = try await fixture.scanner.scan(url: fixture.logURL)

    try fixture.append(fixture.tokenLine(second: 2, last: fixture.usage(20)))
    _ = try await fixture.scanner.scan(url: fixture.logURL)

    #expect(try await fixture.projectTotals() == ["child-project": 30])
}
```

- [ ] **Step 2: 运行扫描器测试确认 RED**

```bash
swift test --filter SessionScannerTests
```

Expected: FAIL；当前扫描器在第二个 session 上触发约束或增量扫描无法恢复最后 session。

- [ ] **Step 3: 改为收集并原子提交文件批次**

`scan(url:)` 从保存游标的 `activeSessionID` 初始化当前 session。逐行解析时：

```swift
case let .session(metadata):
    activeSessionID = metadata.sessionID
    sessions.append(SessionUpsert(
        metadata: metadata,
        project: normalizer.identity(for: metadata.workingDirectory)
    ))

case let .token(token):
    guard let activeSessionID else { continue }
    events.append(LogicalTokenEvent(
        id: TokenEventIdentity.make(sessionID: activeSessionID, event: token),
        sessionID: activeSessionID,
        occurredAt: token.occurredAt,
        lastUsage: token.lastUsage,
        cumulativeUsage: token.cumulativeUsage
    ))
    limits.append(contentsOf: token.limits)
```

读取完整行后构造包含最终偏移和 `activeSessionID` 的 cursor，并调用一次 `repository.apply(batch)`。文件被截断时 offset 和 active session 一起重置；未形成完整行时不提交。

- [ ] **Step 4: 运行扫描、仓库和端到端测试确认 GREEN**

```bash
swift test --filter SessionScannerTests
swift test --filter UsageRepositoryTests
swift test --filter EndToEndIngestionTests
```

Expected: PASS；分支父历史总量只出现一次。

- [ ] **Step 5: 提交 Task 3**

```bash
git add Sources/CodexUsageMonitor/Ingestion/SessionScanner.swift \
  Tests/CodexUsageMonitorTests/SessionScannerTests.swift
git commit -m "fix: ingest multi-session branch logs"
```

---

### Task 4: 隔离失败文件并发布重建进度

**Files:**
- Modify: `Sources/CodexUsageMonitor/Domain/UsageModels.swift`
- Modify: `Sources/CodexUsageMonitor/Ingestion/IngestionCoordinator.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/UsageViewModel.swift`
- Modify: `Tests/CodexUsageMonitorTests/IngestionCoordinatorTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/UsageViewModelTests.swift`

**Interfaces:**
- Produces: `IngestionUpdate.partial(failedFiles:)`
- Produces: `IngestionUpdate.rebuilding(completed:total:)`
- Produces: `DataFreshness.partial(Date, failedFiles: Int)`
- Produces: `DataFreshness.rebuilding(completed: Int, total: Int)`

- [ ] **Step 1: 写失败隔离和进度 RED 测试**

在 `IngestionCoordinatorTests.swift` 增加一个注入的 `scanFileOperation`：对 `broken.jsonl` 抛错，对 `healthy.jsonl` 成功并记录调用。断言两个文件都被尝试、update 是 `.partial(failedFiles: 1)`，下一次重试成功后发布 `.completed`。

```swift
@Test
func oneBrokenFileDoesNotBlockHealthyFilesAndCanRecover() async throws {
    let fixture = try FailureIsolationFixture()
    defer { fixture.remove() }
    await fixture.start()

    #expect(await fixture.scannedNames == ["broken.jsonl", "healthy.jsonl"])
    #expect(await fixture.recorder.value(at: 0) == .partial(failedFiles: 1))

    await fixture.allowBrokenFile()
    await fixture.coordinator.rescanAll()

    #expect(await fixture.recorder.waitForValue(.completed))
}
```

在 `UsageViewModelTests.swift` 增加 `.partial` 保留数据并显示失败数量、`.rebuilding` 保留总量但改变状态的测试。

- [ ] **Step 2: 运行测试确认 RED**

```bash
swift test --filter IngestionCoordinatorTests
swift test --filter UsageViewModelTests
```

Expected: FAIL，因为 update 和 freshness 尚无 partial/rebuilding 状态，扫描循环仍在首个错误处抛出。

- [ ] **Step 3: 实现失败隔离、重试和进度**

把 `scanChangedFiles` 的单文件调用包在独立 `do/catch` 中：成功文件更新 `fileMetadata`，失败文件保留旧 metadata 并加入失败集合。扫描结束后：失败集合为空发布 `.completed`，否则发布 `.partial(failedFiles: count)` 并安排 30 秒恢复任务。

`rebuildIndex()` 在发现文件后先发布 `.rebuilding(completed: 0, total: files.count)`，每个文件完成后更新进度，结束后发布 completed 或 partial。`UsageViewModel` 对 partial 先刷新可用数据，再把 freshness 标记为 partial；对 rebuilding 保留最后快照并只更新状态。

- [ ] **Step 4: 运行并发测试十次和完整相关测试**

```bash
for run in {1..10}; do swift test --filter IngestionCoordinatorTests >/dev/null || exit 1; done
swift test --filter UsageViewModelTests
swift test --filter EndToEndIngestionTests
```

Expected: 全部 PASS，无固定短延迟竞态。

- [ ] **Step 5: 提交 Task 4**

```bash
git add Sources/CodexUsageMonitor/Domain/UsageModels.swift \
  Sources/CodexUsageMonitor/Ingestion/IngestionCoordinator.swift \
  Sources/CodexUsageMonitor/Presentation/UsageViewModel.swift \
  Tests/CodexUsageMonitorTests/IngestionCoordinatorTests.swift \
  Tests/CodexUsageMonitorTests/UsageViewModelTests.swift
git commit -m "fix: isolate ingestion failures and report progress"
```

---

### Task 5: 过滤过期限额并阻止无效提醒

**Files:**
- Create: `Sources/CodexUsageMonitor/Aggregation/LimitAvailabilityPolicy.swift`
- Modify: `Sources/CodexUsageMonitor/Aggregation/UsageAggregator.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/MenuBarLabel.swift`
- Create: `Tests/CodexUsageMonitorTests/LimitAvailabilityPolicyTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/UsageAggregatorTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/MenuBarFormattingTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/NotificationCoordinatorTests.swift`

**Interfaces:**
- Produces: `LimitAvailabilityPolicy.activeStatuses(from:now:) -> [LimitStatus]`
- Consumes: `RateLimitObservation.resetsAt`
- Preserves: `NotificationCoordinator.evaluate(_:)` but only receives active statuses

- [ ] **Step 1: 写限额有效性 RED 测试**

```swift
@Suite
struct LimitAvailabilityPolicyTests {
    @Test
    func expiredFiveHourAndWeekSnapshotsAreNotActive() {
        let now = Date(timeIntervalSince1970: 2_000)
        let expired = [
            RateLimitObservation(limitID: "codex", window: .fiveHours, usedPercent: 80, resetsAt: Date(timeIntervalSince1970: 1_999), observedAt: Date(timeIntervalSince1970: 1_900)),
            RateLimitObservation(limitID: "codex", window: .week, usedPercent: 50, resetsAt: Date(timeIntervalSince1970: 1_999), observedAt: Date(timeIntervalSince1970: 1_900)),
        ]

        #expect(LimitAvailabilityPolicy.activeStatuses(from: expired, now: now).isEmpty)
    }

    @Test
    func activeKnownWindowsAreReturned() {
        let now = Date(timeIntervalSince1970: 2_000)
        let active = RateLimitObservation(limitID: "codex", window: .week, usedPercent: 50, resetsAt: Date(timeIntervalSince1970: 3_000), observedAt: now)

        #expect(LimitAvailabilityPolicy.activeStatuses(from: [active], now: now) == [
            LimitStatus(window: .week, usedPercent: 50, resetsAt: active.resetsAt),
        ])
    }
}
```

更新菜单测试：只有周窗口时标题为 `周 48%`；只有 5 小时时为 `5h 72%`；都没有时为 `Codex --`。新增通知测试，传入过滤后的空数组不会发送。

- [ ] **Step 2: 运行测试确认 RED**

```bash
swift test --filter LimitAvailabilityPolicyTests
swift test --filter MenuBarFormattingTests
```

Expected: FAIL，因为 policy 不存在且 formatter 仍要求两个窗口同时存在。

- [ ] **Step 3: 实现有效性策略和动态标题**

```swift
enum LimitAvailabilityPolicy {
    static func activeStatuses(
        from observations: [RateLimitObservation],
        now: Date
    ) -> [LimitStatus] {
        observations
            .filter { $0.resetsAt > now }
            .map { LimitStatus(window: $0.window, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
    }
}
```

`UsageAggregator.snapshot` 调用该策略。`MenuBarFormatter` 分别格式化两个可选窗口。通知继续只接收 snapshot 中的 active limits，因此过期或缺失窗口不会生成回执或提醒。

- [ ] **Step 4: 运行限额、聚合和通知测试确认 GREEN**

```bash
swift test --filter LimitAvailabilityPolicyTests
swift test --filter UsageAggregatorTests
swift test --filter MenuBarFormattingTests
swift test --filter NotificationCoordinatorTests
```

Expected: PASS。

- [ ] **Step 5: 提交 Task 5**

```bash
git add Sources/CodexUsageMonitor/Aggregation/LimitAvailabilityPolicy.swift \
  Sources/CodexUsageMonitor/Aggregation/UsageAggregator.swift \
  Sources/CodexUsageMonitor/Presentation/MenuBarLabel.swift \
  Tests/CodexUsageMonitorTests/LimitAvailabilityPolicyTests.swift \
  Tests/CodexUsageMonitorTests/UsageAggregatorTests.swift \
  Tests/CodexUsageMonitorTests/MenuBarFormattingTests.swift \
  Tests/CodexUsageMonitorTests/NotificationCoordinatorTests.swift
git commit -m "feat: hide unavailable usage limits"
```

---

### Task 6: 持久化三种显示模式

**Files:**
- Create: `Sources/CodexUsageMonitor/Presentation/DisplayModeStore.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/SettingsView.swift`
- Modify: `Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift`

**Interfaces:**
- Produces: `DisplayMode.desktop`, `.menuBar`, `.both`
- Produces: `DisplayModeStore.mode`
- Produces: `DisplayModeStore.showsDesktopCard` and `.showsMenuBar`
- Consumes: injected `UserDefaults`

- [ ] **Step 1: 写默认值、持久化和三模式 RED 测试**

```swift
@MainActor
@Test func displayModeDefaultsToDesktopAndPersists() throws {
    let suiteName = "DisplayModeTests-\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let first = DisplayModeStore(defaults: suite)

    #expect(first.mode == .desktop)
    #expect(first.showsDesktopCard)
    #expect(!first.showsMenuBar)

    first.setMode(.both)
    let reopened = DisplayModeStore(defaults: suite)
    #expect(reopened.mode == .both)
    #expect(reopened.showsDesktopCard)
    #expect(reopened.showsMenuBar)
}

@MainActor
@Test func menuBarModeOnlyShowsMenuBar() throws {
    let suiteName = "DisplayModeTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = DisplayModeStore(defaults: defaults)
    store.setMode(.menuBar)

    #expect(!store.showsDesktopCard)
    #expect(store.showsMenuBar)
}
```

- [ ] **Step 2: 运行测试确认 RED**

```bash
swift test --filter AppPresentationStateTests
```

Expected: FAIL，因为 `DisplayModeStore` 不存在。

- [ ] **Step 3: 实现 store 并接入设置状态**

```swift
enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    case desktop, menuBar, both
    var id: String { rawValue }
}

@MainActor
@Observable
final class DisplayModeStore {
    private static let key = "displayMode"
    private let defaults: UserDefaults
    private(set) var mode: DisplayMode

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.key).flatMap(DisplayMode.init(rawValue:)) ?? .desktop
    }

    var showsDesktopCard: Bool { mode == .desktop || mode == .both }
    var showsMenuBar: Bool { mode == .menuBar || mode == .both }

    func setMode(_ mode: DisplayMode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}
```

给 `SettingsView` 注入同一个 store，并增加“显示位置” Picker；不要在此任务创建窗口。

- [ ] **Step 4: 运行展示状态测试确认 GREEN**

```bash
swift test --filter AppPresentationStateTests
```

Expected: PASS。

- [ ] **Step 5: 提交 Task 6**

```bash
git add Sources/CodexUsageMonitor/Presentation/DisplayModeStore.swift \
  Sources/CodexUsageMonitor/Presentation/SettingsView.swift \
  Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift
git commit -m "feat: persist desktop and menu bar modes"
```

---

### Task 7: 创建桌面卡片窗口控制器

**Files:**
- Create: `Sources/CodexUsageMonitor/Presentation/DesktopCardPlacement.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/DesktopCardPresentationController.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/DesktopCardWindowController.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/DesktopCardView.swift`
- Modify: `Sources/CodexUsageMonitor/App/AppDelegate.swift`
- Create: `Tests/CodexUsageMonitorTests/DesktopCardPlacementTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift`

**Interfaces:**
- Produces: `DesktopCardSize.compact`, `.expanded`
- Produces: `DesktopCardPlacement.visibleOrigin(savedOrigin:windowSize:visibleFrame:)`
- Produces: `DesktopCardPresenting.show()`, `.hide()`, `.setExpanded(_:)`
- Produces: `DesktopCardPresentationController.apply(mode:)`, `.handleReopen()`
- Produces: `DesktopCardWindowController.show()`, `.hide()`, `.setExpanded(_:)`
- Produces: `Notification.Name.codexUsageMonitorReopenRequested`
- Consumes: `UsageViewModel`, `AppRuntime`, `DisplayModeStore`

- [ ] **Step 1: 写位置修正、展开状态和重开 RED 测试**

```swift
@Suite
struct DesktopCardPlacementTests {
    @Test
    func savedOriginIsClampedIntoVisibleFrame() {
        let origin = DesktopCardPlacement.visibleOrigin(
            savedOrigin: CGPoint(x: 2_000, y: -500),
            windowSize: CGSize(width: 340, height: 220),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        #expect(origin.x == 1_100)
        #expect(origin.y == 0)
    }
}
```

在 `AppPresentationStateTests` 使用遵循 `DesktopCardPresenting` 的 `DesktopCardSurfaceSpy` 测试：`apply(mode: .desktop/.both)` 调用 `show()`，`.menuBar` 调用 `hide()`；`handleReopen()` 仅在 desktop/both 模式调用 `show()`。

- [ ] **Step 2: 运行测试确认 RED**

```bash
swift test --filter DesktopCardPlacementTests
swift test --filter AppPresentationStateTests
```

Expected: FAIL，因为 placement、surface 和 controller 尚不存在。

- [ ] **Step 3: 实现窗口控制器和最小卡片**

`DesktopCardPresentationController` 只负责模式路由和重开行为，依赖注入 `DesktopCardPresenting`，不直接创建 AppKit 窗口。`DesktopCardWindowController` 遵循该协议并创建一个 `.borderless` `NSPanel`，配置：

```swift
panel.level = .normal
panel.hidesOnDeactivate = false
panel.isMovableByWindowBackground = true
panel.hasShadow = true
panel.backgroundColor = .clear
panel.isOpaque = false
panel.collectionBehavior = [.moveToActiveSpace]
```

用 `NSHostingView` 承载 `DesktopCardView`。compact 为 `340 × 220`，expanded 为 `520 × 480`。窗口移动时把 origin 写入 UserDefaults，加载时用 `DesktopCardPlacement` 修正到可见屏幕。`DesktopCardPresentationController.apply(mode:)` 决定 show/hide；`handleReopen()` 在当前 desktop/both 模式调用 surface 的 `show()`。窗口 surface 的 `show()` 使用 `orderFrontRegardless()`。

`AppDelegate.applicationShouldHandleReopen` 发布 `codexUsageMonitorReopenRequested`，继续使用 `.accessory` activation policy。

- [ ] **Step 4: 运行窗口状态测试确认 GREEN**

```bash
swift test --filter DesktopCardPlacementTests
swift test --filter AppPresentationStateTests
```

Expected: PASS；测试不依赖真实用户屏幕坐标。

- [ ] **Step 5: 提交 Task 7**

```bash
git add Sources/CodexUsageMonitor/Presentation/DesktopCardPlacement.swift \
  Sources/CodexUsageMonitor/Presentation/DesktopCardPresentationController.swift \
  Sources/CodexUsageMonitor/Presentation/DesktopCardWindowController.swift \
  Sources/CodexUsageMonitor/Presentation/DesktopCardView.swift \
  Sources/CodexUsageMonitor/App/AppDelegate.swift \
  Tests/CodexUsageMonitorTests/DesktopCardPlacementTests.swift \
  Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift
git commit -m "feat: add movable desktop usage card"
```

---

### Task 8: 整合桌面卡片、菜单栏与动态限额布局

**Files:**
- Create: `Sources/CodexUsageMonitor/App/AppPresentationCoordinator.swift`
- Modify: `Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/UsagePresentationPolicy.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/FreshnessFormatter.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/DesktopCardView.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/UsagePopoverView.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/SettingsView.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/MenuBarLabel.swift`
- Modify: `Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/MenuBarFormattingTests.swift`

**Interfaces:**
- Consumes: one shared `UsageViewModel`
- Consumes: one shared `DisplayModeStore`
- Consumes: one `DesktopCardWindowController`
- Produces: `AppPresentationCoordinator.setMode(_:)`
- Produces: `AppPresentationCoordinator.isMenuBarInserted`
- Produces: desktop/menu/both immediate switching

- [ ] **Step 1: 写动态布局和模式路由 RED 测试**

增加纯展示状态 `UsagePresentationPolicy.visibleWindows(limits:)` 并测试：缺少 five-hours 时只返回 week；有效 two windows 时返回两者。测试三种 mode 对应 `showsDesktopCard`/`showsMenuBar`，以及 partial/rebuilding 的中文状态文本不为空。

```swift
@Test
func missingFiveHourWindowLeavesOnlyWeekVisible() {
    let week = LimitStatus(window: .week, usedPercent: 50, resetsAt: .distantFuture)
    #expect(UsagePresentationPolicy.visibleWindows(limits: [week]) == [.week])
}

@Test
func partialFailureHasReadableStatusText() {
    let text = FreshnessFormatter.text(for: .partial(.now, failedFiles: 2))
    #expect(text == "部分数据等待恢复 · 2 个文件")
}
```

- [ ] **Step 2: 运行测试确认 RED**

```bash
swift test --filter AppPresentationStateTests
swift test --filter MenuBarFormattingTests
```

Expected: FAIL，因为 presentation policy 和新 freshness copy 尚不存在。

- [ ] **Step 3: 完成 App 组合与界面**

`CodexUsageMonitorApp` 在 init 中创建并共享 model、runtime、displayModeStore、desktop window controller、desktop presentation controller 和 `AppPresentationCoordinator`。`AppPresentationCoordinator.setMode(_:)` 是唯一模式切换入口：先持久化 mode，再调用 desktop presentation controller，最后同步可观察的 `isMenuBarInserted`。`MenuBarExtra` 的 `isInserted` binding 绑定该属性。desktop card 和 menu label 都可以触发幂等的 `runtime.launch()`，确保任何默认模式都启动监控。

`DesktopCardView` compact 显示有效限额、今日 Token、状态、展开/设置/退出按钮；expanded 复用 `UsagePopoverView`。`UsagePopoverView` 只在 five-hours 存在时创建其卡片，week 缺失时继续显示等待卡片。错误 footer 显示文字摘要而非只有图标。

设置页 Picker 调用 `displayModeStore.setMode`，切换立即应用。桌面模式没有 MenuBarExtra；menuBar 模式隐藏 panel；both 同时显示。

- [ ] **Step 4: 运行展示和完整单元测试确认 GREEN**

```bash
swift test --filter AppPresentationStateTests
swift test --filter MenuBarFormattingTests
swift test --filter UsageViewModelTests
swift test
```

Expected: 所有测试 PASS，无编译警告。

- [ ] **Step 5: 提交 Task 8**

```bash
git add Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift \
  Sources/CodexUsageMonitor/App/AppPresentationCoordinator.swift \
  Sources/CodexUsageMonitor/Presentation/DesktopCardView.swift \
  Sources/CodexUsageMonitor/Presentation/UsagePresentationPolicy.swift \
  Sources/CodexUsageMonitor/Presentation/FreshnessFormatter.swift \
  Sources/CodexUsageMonitor/Presentation/UsagePopoverView.swift \
  Sources/CodexUsageMonitor/Presentation/SettingsView.swift \
  Sources/CodexUsageMonitor/Presentation/MenuBarLabel.swift \
  Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift \
  Tests/CodexUsageMonitorTests/MenuBarFormattingTests.swift
git commit -m "feat: switch between desktop and menu bar presentation"
```

---

### Task 9: 端到端分支日志回归验收与交付更新

**Files:**
- Modify: `Tests/CodexUsageMonitorTests/EndToEndIngestionTests.swift`
- Modify: `README.md`
- Modify: `Scripts/build-app.sh` only if packaging paths need no-code adjustment
- Modify: `.github/workflows/ci.yml` only if the existing Xcode 26.3 job does not discover new tests

**Interfaces:**
- Validates: v1 migration → full rebuild → branch dedup → incremental update
- Validates: desktop default and missing five-hour behavior
- Produces: refreshed `.app` and ZIP artifacts

- [ ] **Step 1: 写最终端到端回归测试**

在临时 `$CODEX_HOME` 创建父日志与子分支日志。两者包含相同父 Token，子文件再追加 child Token 和仅周限额。启动 coordinator 后断言：总量不重复、项目归属正确、five-hours 缺失、week 存在；再追加 child Token 并在 2 秒内观察唯一一次增量。

```swift
@Test
func branchedHistoryIsDeduplicatedAndAppendUpdatesWithinTwoSeconds() async throws {
    let fixture = try BranchingEndToEndFixture()
    defer { fixture.remove() }
    try fixture.writeParent(total: 10)
    try fixture.writeChildCopy(parentTotal: 10, childTotal: 20, includeFiveHourLimit: false)

    let recorder = await fixture.start()
    #expect(await recorder.waitForCompleted())
    #expect(try await fixture.totalUsage() == 30)
    #expect(try await fixture.activeLimitWindows() == [.week])

    try fixture.appendChild(total: 5)
    #expect(await fixture.waitForTotal(35, timeout: .seconds(2)))
}
```

- [ ] **Step 2: 运行端到端测试确认集成结果**

```bash
swift test --filter EndToEndIngestionTests
```

Expected: PASS，因为 Tasks 1–8 已分别通过 RED-GREEN 覆盖生产行为。若失败，将失败场景缩成最小回归测试并确认 RED，再做最小生产修复并确认 GREEN。

- [ ] **Step 3: 完成最小集成调整和文档**

只修正端到端测试揭示的集成缺口。更新 README：默认桌面卡片、三种显示模式、缺失 5 小时自动隐藏、v2 首次重建说明、未公证版本首次打开步骤。不得提交真实 `.app`、ZIP、数据库或日志。

- [ ] **Step 4: 执行最终验证**

```bash
swift test
for run in {1..10}; do swift test --filter IngestionCoordinatorTests >/dev/null || exit 1; done
bash Scripts/build-app.sh
plutil -lint "dist/Codex Usage Monitor.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "dist/Codex Usage Monitor.app"
unzip -t "dist/Codex-Usage-Monitor-macOS.zip"
git diff --check
git status --short
```

Expected:

- 所有测试通过；
- 并发测试连续十次通过；
- Release 构建、plist、签名和 ZIP 完整性通过；
- 工作区只包含本任务预期文件。

- [ ] **Step 5: 提交 Task 9**

```bash
git add Tests/CodexUsageMonitorTests/EndToEndIngestionTests.swift README.md
git diff --quiet -- Scripts/build-app.sh || git add Scripts/build-app.sh
git diff --quiet -- .github/workflows/ci.yml || git add .github/workflows/ci.yml
git commit -m "test: verify branch ingestion and desktop delivery"
```

- [ ] **Step 6: 推送并等待 GitHub CI**

```bash
git push origin HEAD
run_id="$(gh run list --repo amenggod/codex-usage-monitor-macos --workflow ci.yml --branch "$(git branch --show-current)" --limit 1 --json databaseId --jq '.[0].databaseId')"
test -n "$run_id"
gh run watch "$run_id" --repo amenggod/codex-usage-monitor-macos --exit-status
```

Expected: CI 的 Test 和 Build app bundle 两步均为 success。

---

## Final Review Checklist

- [ ] 对照设计文档逐项核对数据、限额、桌面卡片、设置和通知要求。
- [ ] 搜索常见未完成占位标记、真实 home 路径、真实 session ID 和凭据模式，确认未进入 tracked files。
- [ ] 用合成分支日志人工计算期望 Token，并与数据库及界面结果一致。
- [ ] 在“仅桌面”“仅菜单栏”“两者”之间切换，确认入口不会全部消失。
- [ ] 关闭并重新启动应用，确认桌面位置、展开状态和显示模式恢复。
- [ ] 让 5 小时快照缺失或过期，确认卡片、菜单文字和提醒全部消失。
- [ ] 保留有效周快照，确认周剩余量和 20%/10% 提醒仍工作。
- [ ] 确认 GitHub 仓库公开、main/交付分支同步且 CI 通过。
