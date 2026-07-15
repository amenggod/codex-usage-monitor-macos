# Final Review Fix Report

日期：2026-07-15
修复起点：`1b5668c`
分支：`codex/usage-monitor-v2`

## 结论

`final-review-findings.md` 的五个 Important 均按 TDD 完成真实 RED、最小实现与 GREEN。测试只使用临时目录、临时 SQLite、隔离 UserDefaults、私有 NotificationCenter 与注入的可见屏幕区域；没有读取真实 `~/.codex`、真实 UserDefaults 或真实屏幕。Minor 的 AppKit 覆盖也已补为真实 `NSPanel` smoke。

## Important 1：同 inode 等长/扩长覆写

### RED

命令：

```bash
swift test --filter 'SessionScannerTests.equalLengthSameInodeRewriteRestartsAtZero'
```

实际输出：退出码 `1`；`result.processedLines` 实际为 `0`、预期 `2`，新项目 usage 未写入。

命令：

```bash
swift test --filter 'SessionScannerTests.longerSameInodeRewriteClearsTheStaleActiveSession'
```

实际输出：退出码 `1`；总 usage 错误增加，cursor 的 `activeSessionID` 实际仍为 `"old-session"`、预期 `nil`。

命令：

```bash
swift test --filter 'UsageRepositoryTests.existingVersionTwoAddsBoundaryFingerprintWithoutLosingReceipts'
```

实际输出：退出码 `1`；既有 schema-v2 的 `file_cursors` 不含 `boundary_fingerprint`。

### GREEN

命令：

```bash
swift test --filter 'SessionScannerTests.(equalLengthSameInodeRewriteRestartsAtZero|longerSameInodeRewriteClearsTheStaleActiveSession)'
swift test --filter 'UsageRepositoryTests.existingVersionTwoAddsBoundaryFingerprintWithoutLosingReceipts'
```

实际输出：退出码 `0`；scanner `2 tests` 全过，v2 兼容迁移 `1 test` 通过。

### 实现与兼容

- cursor 新增 nullable `boundary_fingerprint`，保存处理边界之前最多 4 KiB 内容的 SHA-256 Base64。
- 增量扫描前读取同一边界并比对；缺失指纹、指纹不匹配或 offset 超过文件长度时，统一将 offset 置 0，并清空 active session。
- 新建 v2 schema 直接包含该列；既有 v2 在 `migrate()` 中通过 `PRAGMA table_info` 检查后，在事务内幂等 `ALTER TABLE`。
- 兼容迁移不 drop/rebuild 任意表，因此 `notification_receipts` 原样保留；旧 cursor 的 NULL 指纹会安全触发一次全量重扫，事件 ID 去重避免重复计数。

## Important 2：亚毫秒事件身份

### RED

命令：

```bash
swift test --filter 'TokenEventIdentityTests.identityPreservesSubMillisecondTimestampDifferences'
```

实际输出：退出码 `1`；相差 100 微秒的两个事件生成同一个 SHA-256：`3297dc7f...461b1`。

### GREEN

命令：

```bash
swift test --filter 'TokenEventIdentityTests'
```

实际输出：退出码 `0`；`3 tests` 全过。

### 实现

事件身份不再将时间乘 1000 后取整，而是编码 `timeIntervalSince1970.bitPattern` 的完整 64 位稳定表示；仍不使用文件路径或 byte offset。

## Important 3：migration 失败后的 retry

### RED

命令：

```bash
swift test --filter 'UsageViewModelTests.retryAfterTransientMigrationFailureMigratesScansAndStartsWatching'
```

实际输出：退出码 `1`；释放真实临时 SQLite 写锁后调用 `UsageViewModel.retry()`，dashboard 未恢复，repository 报 `no such table: usage_events`。

### GREEN

首次实现验证发现合成事件日期不在默认“今日”范围：migration、scan、watcher 与全量 repository 查询已成功，但 dashboard 断言仍为 0。测试改为选择 `.all` 后重新运行同一命令。

实际输出：退出码 `0`；`1 test` 通过，验证首次失败、释放锁、retry、真实迁移、数据恢复以及 watcher `events()` 恰好启动一次。

回归命令：

```bash
swift test --filter 'IngestionCoordinatorTests.watcherStartupFailurePublishesFailedThenRecovers'
```

实际输出：退出码 `0`；`1 test` 通过。

### 实现与并发边界

- coordinator 新增 `starting` 状态；只有 migration 成功且未停止后才设置 `started = true`。
- migration 失败会恢复为可重试状态并发布失败；`rescanAll()` 在尚未成功启动时改为重新执行完整 `start()`，因此现有 ViewModel `retry()` 无需绕过 migration。
- `stop()` 期间 migration 完成会被 `stopped` guard 截断；原有 scan generation、rebuild cancellation、in-flight scan 等逻辑未修改，并在聚焦套件及十轮循环中复验。

## Important 4：桌面卡片重新 clamp

### RED

命令：

```bash
swift test --filter 'DesktopCardPlacementTests.windowShowAndScreenChangesReclampWithInjectedVisibleFrame'
```

实际输出：退出码 `1`；编译明确失败为 `extra arguments at positions #4, #5`，现有 controller 没有私有 NotificationCenter 与 visible-frame 注入点，因此无法在不读取真实屏幕的前提下验证 lifecycle 行为。

### GREEN

重新运行同一命令，实际输出：退出码 `0`；真实 `NSPanel` smoke `1 test` 通过。

### 实现

- controller 注入 `NotificationCenter` 与 visible-frame provider，生产默认仍使用 `NSScreen`。
- `show()`（因此也包括 reopen 路由）先按当前 origin 与当前 size 重新 clamp。
- 监听 `NSApplication.didChangeScreenParametersNotification` 并重新 clamp；deinit 移除 observer。
- clamp 始终保留当前 size，并把最终 origin 保存到注入的隔离 preferences。
- 测试使用固定 `800x600` 可见区域、私有通知中心与唯一 UserDefaults suite，未访问真实屏幕或真实偏好。

## Important 5：limitID receipt 与 legacy 认领

### RED

命令：

```bash
swift test --filter 'NotificationCoordinatorTests.(sameLimitIDAndResetRemainIdempotent|differentLimitIDsWithSameWindowAndResetAreBothEligible|legacyReceiptIsClaimedOnlyByFirstNewLimitID)'
```

第一次实际输出：退出码 `1`；编译明确失败为 `extra argument 'limitID' in call`，证明 `LimitStatus` 尚未携带 ID。

补齐 ID plumbing 后再次运行，实际输出仍为退出码 `1`：

- 同 ID 幂等测试通过；
- 不同 ID 同 window/reset 预期 `[20, 20]`，实际仍只有一次发送；
- legacy receipt 未被认领删除，第二 ID 仍被全局抑制。

### GREEN

重新运行同一命令，实际输出：退出码 `0`；`3 tests` 全过。

命令：

```bash
swift test --filter 'LimitAvailabilityPolicyTests.activeKnownWindowsAreReturned'
```

实际输出：退出码 `0`；observation 到 `LimitStatus` 的 ID 传递测试通过。

### receipt 兼容策略

- `LimitStatus` 携带 `limitID`，`LimitAvailabilityPolicy` 从 `RateLimitObservation` 原样传递。
- 新 key 为 `v2|<Base64(limitID)>|<window>|<reset-second>|<threshold>`；Base64 分段避免 delimiter 歧义。
- 旧 key 保持 `window|reset-second|threshold`，不做批量删除。
- repository 在 `BEGIN IMMEDIATE` 单事务中检查新 key、查找旧 key、将旧 `sent_at` 升级到第一个新 ID key 并删除旧 key；之后其他 ID 不再被旧 key 全局抑制。
- 新 key 已存在且旧 key 仍存在时也删除旧 key，确保 legacy 不会永久遗留。
- coordinator 的 in-flight set 改用新 key；同 ID 并发仍幂等，不同 ID 可独立发送。

## 聚焦、稳定性与全量验证

### 聚焦套件

```bash
swift test --filter '(UsageRepositoryTests|SessionScannerTests|TokenEventIdentityTests|IngestionCoordinatorTests|UsageViewModelTests|NotificationCoordinatorTests|DesktopCardPlacementTests|LimitAvailabilityPolicyTests)'
```

实际输出：退出码 `0`；`91 tests in 8 suites passed`。

### coordinator 十轮

```bash
for round in {1..10}; do swift test --filter 'IngestionCoordinatorTests'; done
```

实际输出：10/10 轮通过，每轮 `20 tests in 1 suite passed`；耗时依次为 `3.567, 3.630, 3.511, 3.620, 3.525, 3.581, 3.557, 3.547, 3.534, 3.505` 秒，共 `200/200`。

### 全量

```bash
swift test
```

实际输出：退出码 `0`；`167 tests in 18 suites passed after 3.576 seconds`。

### Release / plist / codesign / ZIP

```bash
bash Scripts/build-app.sh
plutil -lint 'dist/Codex Usage Monitor.app/Contents/Info.plist'
codesign --verify --deep --strict --verbose=2 'dist/Codex Usage Monitor.app'
unzip -t 'dist/Codex-Usage-Monitor-macOS.zip'
```

实际输出：退出码 `0`；Release build 完成；plist `OK`；app `valid on disk` 且 `satisfies its Designated Requirement`；ZIP 为 `No errors detected in compressed data`。

### diff/status

```bash
git diff --check
git status --short
```

实际输出：`git diff --check` 无输出、退出码 `0`；status 仅包含下列实现、测试与本报告，没有 dist 产物或 findings/计划账本改动。

## 修改文件

生产代码：

- `Sources/CodexUsageMonitor/Aggregation/LimitAvailabilityPolicy.swift`
- `Sources/CodexUsageMonitor/Domain/UsageModels.swift`
- `Sources/CodexUsageMonitor/Ingestion/IngestionCoordinator.swift`
- `Sources/CodexUsageMonitor/Ingestion/SessionScanner.swift`
- `Sources/CodexUsageMonitor/Ingestion/TokenEventIdentity.swift`
- `Sources/CodexUsageMonitor/Persistence/UsageRepository.swift`
- `Sources/CodexUsageMonitor/Persistence/UsageSchema.swift`
- `Sources/CodexUsageMonitor/Presentation/DesktopCardWindowController.swift`
- `Sources/CodexUsageMonitor/Services/NotificationCoordinator.swift`

测试：

- `Tests/CodexUsageMonitorTests/DesktopCardPlacementTests.swift`
- `Tests/CodexUsageMonitorTests/LimitAvailabilityPolicyTests.swift`
- `Tests/CodexUsageMonitorTests/NotificationCoordinatorTests.swift`
- `Tests/CodexUsageMonitorTests/SessionScannerTests.swift`
- `Tests/CodexUsageMonitorTests/TokenEventIdentityTests.swift`
- `Tests/CodexUsageMonitorTests/UsageRepositoryTests.swift`
- `Tests/CodexUsageMonitorTests/UsageViewModelTests.swift`

报告：

- `.superpowers/sdd/final-review-fix-report.md`

## 自审

- 五项 findings 均有独立 RED/GREEN 证据，且没有靠修改期望掩盖产品行为。
- schema 仍保持 `user_version = 2`，用兼容补列而不是破坏性升级；receipts 不丢失。
- cursor 指纹只读取被测临时 session 文件，不引入路径或 offset 到事件身份。
- startup retry 没有改动 rebuild generation；原有 cancellation、stale generation、watcher recovery 与 notification concurrency 测试均通过。
- AppKit smoke 走真实 window，但所有屏幕输入、通知与 preferences 都是注入/隔离的。
- legacy receipt 只抑制并升级第一个新 ID，随后删除旧 key；不同 ID 的新 receipt 独立。
- 未修改 `final-review-findings.md`、计划或进度账本。

## 疑虑与人工边界

- 无已知功能疑虑。
- 本地签名为仓库既有 ad-hoc 签名，只验证包完整性，不代表 Developer ID 签名或 Apple 公证。
- 外接显示器真实拔插仍属于人工体验 QA；自动化已覆盖相同 notification 路径与确定性 frame 结果。
