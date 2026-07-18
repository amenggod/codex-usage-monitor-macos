# Native Widget Refresh Budget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让原生 macOS 小组件只在可见数据真正变化时请求 WidgetKit 重载，同时继续每分钟写入最新共享快照并明确显示更新时间。

**Architecture:** 保留现有 `UsageViewModel → WidgetSnapshotPublisher → App Group → UsageTimelineProvider` 数据流。发布器把完整快照与“是否值得请求重载”的可见内容指纹分离：时间戳仍写入快照，但 `observedAt` 不再直接参与指纹比较；WidgetKit 时间线继续以五分钟或更早的额度重置时刻为兜底。

**Tech Stack:** Swift 6、SwiftUI、WidgetKit、AppKit、Swift Testing、XcodeGen 2.45.4、macOS 14+

## Global Constraints

- 保留原生 WidgetKit 小组件，不恢复浮动桌面窗口。
- 主程序继续每 60 秒读取实时额度并写入 App Group 快照。
- WidgetKit 重绘时间由 macOS 决定，不承诺秒级或严格分钟级更新。
- 共享快照不得包含凭据、提示词内容、完整路径或完整 app-server 响应。
- 5 小时窗口缺失或过期时继续隐藏，不制造替代值。
- Token 旧值可以带更新时间继续显示；实时额度超过 30 分钟未观测时必须隐藏。
- 不主动对抗 Only Switch 等第三方菜单栏折叠工具。
- 当前发布版本保持 `MARKETING_VERSION = 0.2.3`，构建号从 `6` 升至 `7`。

---

### Task 1: 让刷新指纹忽略同类别的新观测时间

**Files:**
- Modify: `Tests/CodexUsageMonitorTests/WidgetSnapshotPublisherTests.swift:80-121`
- Modify: `Sources/CodexUsageMonitor/Widget/WidgetSnapshotPublisher.swift:142-180`

**Interfaces:**
- Consumes: `WidgetUsageSnapshot.limitFreshness: WidgetLimitFreshness`
- Produces: 私有 `WidgetLimitFreshnessKind`，包含 `.fresh`、`.stale`、`.unavailable`；`WidgetSnapshotFingerprint.limitFreshnessKind` 只比较类别。

- [ ] **Step 1: 写入只改变 `observedAt` 的失败测试**

在 `identicalVisibleValuesWriteFreshTimeButReloadOnlyOnce` 之后添加：

```swift
@Test func newerFreshObservationWritesSnapshotWithoutSpendingAnotherReload() async throws {
    let firstObservedAt = testNow.addingTimeInterval(-60)
    let secondObservedAt = testNow
    let week = LimitStatus(
        window: .week,
        usedPercent: 40,
        resetsAt: testNow.addingTimeInterval(86_400)
    )
    let all = makeSnapshot(range: .all, total: 100, projects: [])
    let store = WidgetStoreSpy()
    let reloader = WidgetReloaderSpy()
    let publisher = WidgetSnapshotPublisher(
        aggregator: WidgetPublisherAggregatorSpy([
            makeSnapshot(
                range: .today,
                total: 12,
                projects: [],
                limits: [week],
                limitFreshness: .fresh(firstObservedAt)
            ),
            all,
            makeSnapshot(
                range: .today,
                total: 12,
                projects: [],
                limits: [week],
                limitFreshness: .fresh(secondObservedAt)
            ),
            all,
        ]),
        store: store,
        reloader: reloader
    )

    _ = await publisher.publish(now: testNow, calendar: testCalendar)
    _ = await publisher.publish(
        now: testNow.addingTimeInterval(60),
        calendar: testCalendar
    )

    #expect(store.snapshots.count == 2)
    #expect(try #require(store.lastSnapshot).limitFreshness == .fresh(
        observedAt: secondObservedAt
    ))
    #expect(reloader.reloadCount == 1)
}
```

- [ ] **Step 2: 运行测试并确认当前实现失败**

Run:

```bash
swift test --filter newerFreshObservationWritesSnapshotWithoutSpendingAnotherReload
```

Expected: FAIL，`reloader.reloadCount` 实际为 `2`。

- [ ] **Step 3: 写入新鲜度类别变化测试**

继续添加：

```swift
@Test func freshnessCategoryChangeStillTriggersReload() async {
    let observedAt = testNow.addingTimeInterval(-60)
    let week = LimitStatus(
        window: .week,
        usedPercent: 40,
        resetsAt: testNow.addingTimeInterval(86_400)
    )
    let all = makeSnapshot(range: .all, total: 100, projects: [])
    let reloader = WidgetReloaderSpy()
    let publisher = WidgetSnapshotPublisher(
        aggregator: WidgetPublisherAggregatorSpy([
            makeSnapshot(
                range: .today,
                total: 12,
                projects: [],
                limits: [week],
                limitFreshness: .fresh(observedAt)
            ),
            all,
            makeSnapshot(
                range: .today,
                total: 12,
                projects: [],
                limits: [week],
                limitFreshness: .stale(observedAt)
            ),
            all,
        ]),
        store: WidgetStoreSpy(),
        reloader: reloader
    )

    _ = await publisher.publish(now: testNow, calendar: testCalendar)
    _ = await publisher.publish(
        now: testNow.addingTimeInterval(60),
        calendar: testCalendar
    )

    #expect(reloader.reloadCount == 2)
}
```

再添加额度数值变化测试：

```swift
@Test func weekRemainingChangeTriggersReload() async {
    let observedAt = testNow
    let firstWeek = LimitStatus(
        window: .week,
        usedPercent: 40,
        resetsAt: testNow.addingTimeInterval(86_400)
    )
    let secondWeek = LimitStatus(
        window: .week,
        usedPercent: 41,
        resetsAt: firstWeek.resetsAt
    )
    let all = makeSnapshot(range: .all, total: 100, projects: [])
    let reloader = WidgetReloaderSpy()
    let publisher = WidgetSnapshotPublisher(
        aggregator: WidgetPublisherAggregatorSpy([
            makeSnapshot(
                range: .today,
                total: 12,
                projects: [],
                limits: [firstWeek],
                limitFreshness: .fresh(observedAt)
            ),
            all,
            makeSnapshot(
                range: .today,
                total: 12,
                projects: [],
                limits: [secondWeek],
                limitFreshness: .fresh(observedAt)
            ),
            all,
        ]),
        store: WidgetStoreSpy(),
        reloader: reloader
    )

    _ = await publisher.publish(now: testNow, calendar: testCalendar)
    _ = await publisher.publish(
        now: testNow.addingTimeInterval(60),
        calendar: testCalendar
    )

    #expect(reloader.reloadCount == 2)
}
```

- [ ] **Step 4: 最小化修改刷新指纹**

把 `WidgetSnapshotFingerprint.limitFreshness` 替换为类别，并在结构体后添加私有枚举：

```swift
private struct WidgetSnapshotFingerprint: Equatable, Sendable {
    let todayTokens: Int64
    let allTimeTokens: Int64
    let fiveHourLimit: WidgetLimitStatus?
    let weekLimit: WidgetLimitStatus?
    let limitFreshnessKind: WidgetLimitFreshnessKind
    let projects: [WidgetProjectUsage]
    let stateKind: String
    let failedFiles: Int?

    init(_ snapshot: WidgetUsageSnapshot) {
        todayTokens = snapshot.todayTokens
        allTimeTokens = snapshot.allTimeTokens
        fiveHourLimit = snapshot.fiveHourLimit
        weekLimit = snapshot.weekLimit
        limitFreshnessKind = WidgetLimitFreshnessKind(snapshot.limitFreshness)
        projects = snapshot.projects
        switch snapshot.state {
        case .fresh:
            stateKind = "fresh"
            failedFiles = nil
        case let .partial(_, count):
            stateKind = "partial"
            failedFiles = count
        case .rebuilding:
            stateKind = "rebuilding"
            failedFiles = nil
        case .stale:
            stateKind = "stale"
            failedFiles = nil
        case .noData:
            stateKind = "noData"
            failedFiles = nil
        case .failed:
            stateKind = "failed"
            failedFiles = nil
        }
    }
}

private enum WidgetLimitFreshnessKind: Equatable, Sendable {
    case fresh
    case stale
    case unavailable

    init(_ freshness: WidgetLimitFreshness) {
        switch freshness {
        case .fresh:
            self = .fresh
        case .stale:
            self = .stale
        case .unavailable:
            self = .unavailable
        }
    }
}
```

- [ ] **Step 5: 运行发布器测试**

Run:

```bash
swift test --filter WidgetSnapshotPublisherTests
```

Expected: `WidgetSnapshotPublisherTests` 全部 PASS；新测试证明同类别时间变化只重载一次，类别变化仍重载两次。

- [ ] **Step 6: 提交核心修复**

```bash
git add Sources/CodexUsageMonitor/Widget/WidgetSnapshotPublisher.swift \
  Tests/CodexUsageMonitorTests/WidgetSnapshotPublisherTests.swift
git commit -m "fix: preserve native widget reload budget"
```

---

### Task 2: 明确小组件时间语义和 Only Switch 边界

**Files:**
- Modify: `Sources/CodexUsageMonitor/Presentation/SettingsView.swift:132-142`
- Modify: `README.md:188-195`

**Interfaces:**
- Consumes: 现有 `WidgetDisplayModel.statusText`，已实现“更新于”“上次更新”和实时额度不可用文案。
- Produces: 设置页和故障排查说明；不新增运行时接口。

- [ ] **Step 1: 更新设置页菜单栏说明**

把显示区说明改为：

```swift
Text("菜单栏图标可单独开关；若使用 Only Switch，请不要折叠该状态项。关闭图标不会移除系统桌面小组件。")
    .font(.caption)
    .foregroundStyle(.secondary)
```

- [ ] **Step 2: 更新设置页小组件刷新说明**

把桌面小组件的第二段改为：

```swift
Text("小组件显示最近一次有效值和更新时间；点击会打开完整面板。刷新时机由 WidgetKit 决定，不保证秒级更新。")
```

- [ ] **Step 3: 更新 README 故障排查**

把“小组件没有新数据或显示陈旧”条目改为：

```markdown
- **小组件没有新数据或显示陈旧**：先看小组件底部的“更新于/上次更新”时间，再确认主应用仍在后台运行；打开完整仪表盘点击刷新，并查看页脚的 Token/实时限额状态和设置中的小组件共享错误。主应用会持续写入共享快照，并只在可见数据变化时请求 WidgetKit 重载；最终重绘时间仍由 macOS 决定。
```

保留紧随其后的 Only Switch 条目，不删除模板图像说明。

- [ ] **Step 4: 运行展示模型和设置状态测试**

Run:

```bash
swift test --filter WidgetDisplayModelTests
swift test --filter AppPresentationStateTests
```

Expected: 两组测试全部 PASS，既有 15 分钟与 30 分钟陈旧规则不变。

- [ ] **Step 5: 提交文案与说明**

```bash
git add Sources/CodexUsageMonitor/Presentation/SettingsView.swift README.md
git commit -m "docs: explain native widget refresh timing"
```

---

### Task 3: 生成 build 7 工程配置

**Files:**
- Modify: `project.yml:10,25`
- Modify: `CodexUsageMonitor.xcodeproj/project.pbxproj`（由 XcodeGen 生成）

**Interfaces:**
- Consumes: `MARKETING_VERSION = 0.2.3`、固定 Team 前缀 App Group。
- Produces: 主应用、Widget、登录项统一的 `CFBundleVersion = 7`。

- [ ] **Step 1: 修改规范配置中的构建号**

在 `project.yml` 把两个 `CURRENT_PROJECT_VERSION: "6"` 改成：

```yaml
CURRENT_PROJECT_VERSION: "7"
```

- [ ] **Step 2: 重新生成 Xcode 工程**

Run:

```bash
bash Scripts/generate-project.sh
```

Expected: XcodeGen 2.45.4 成功生成 `CodexUsageMonitor.xcodeproj`。

- [ ] **Step 3: 校验所有生成构建号**

Run:

```bash
rg -n 'CURRENT_PROJECT_VERSION = ' CodexUsageMonitor.xcodeproj/project.pbxproj
rg -n 'CURRENT_PROJECT_VERSION:' project.yml
git diff --check
```

Expected: `.pbxproj` 的四处值均为 `7`，`project.yml` 两处值均为 `"7"`，无空白错误。

- [ ] **Step 4: 提交构建号**

```bash
git add project.yml CodexUsageMonitor.xcodeproj/project.pbxproj
git commit -m "build: bump usage monitor to build 7"
```

---

### Task 4: 完整验证、签名安装和现场检查

**Files:**
- Verify: `dist/Codex Usage Monitor.app`
- Install: `/Applications/Codex Usage Monitor.app`
- Inspect: `~/Library/Group Containers/ZD9PK3NY5Z.CodexUsageMonitor.shared/widget-usage-v1.json`

**Interfaces:**
- Consumes: build 7 源码、Team `ZD9PK3NY5Z` 的 Apple Development 签名、本机固定 App Group。
- Produces: 已签名并安装的 `0.2.3 (7)`，以及与主程序一致的共享快照。

- [ ] **Step 1: 运行完整 Swift 测试**

Run:

```bash
swift test
```

Expected: 所有测试 PASS，失败数为 `0`。

- [ ] **Step 2: 运行签名 Release 构建和 bundle 验证**

Run:

```bash
CODE_SIGNING_ALLOWED=YES \
DEVELOPMENT_TEAM=ZD9PK3NY5Z \
CODE_SIGN_STYLE=Automatic \
bash Scripts/build-app.sh
```

Expected: Release 构建成功；`Scripts/verify-bundle.sh` 验证主应用、Widget、登录项、framework、bundle IDs、签名与 App Group 全部通过。

- [ ] **Step 3: 严格验证产物签名和版本**

Run:

```bash
APP="$PWD/dist/Codex Usage Monitor.app"
codesign --verify --deep --strict --verbose=2 "$APP"
defaults read "$APP/Contents/Info" CFBundleShortVersionString
defaults read "$APP/Contents/Info" CFBundleVersion
```

Expected: 签名有效；版本输出依次为 `0.2.3` 和 `7`。

- [ ] **Step 4: 不备份旧版本，直接安装 build 7**

Run:

```bash
pkill -x CodexUsageMonitor 2>/dev/null || true
rm -rf "/Applications/Codex Usage Monitor.app"
ditto "$PWD/dist/Codex Usage Monitor.app" "/Applications/Codex Usage Monitor.app"
open -a "/Applications/Codex Usage Monitor.app"
```

Expected: 应用从 `/Applications` 启动；不创建旧版本备份。

- [ ] **Step 5: 验证已安装版本、签名和快照同步**

Run:

```bash
INSTALLED="/Applications/Codex Usage Monitor.app"
SNAPSHOT="$HOME/Library/Group Containers/ZD9PK3NY5Z.CodexUsageMonitor.shared/widget-usage-v1.json"
codesign --verify --deep --strict --verbose=2 "$INSTALLED"
defaults read "$INSTALLED/Contents/Info" CFBundleShortVersionString
defaults read "$INSTALLED/Contents/Info" CFBundleVersion
stat -f 'updated=%Sm' -t '%Y-%m-%d %H:%M:%S %z' "$SNAPSHOT"
plutil -extract weekLimit.remainingPercent raw "$SNAPSHOT"
```

Expected: 已安装版本为 `0.2.3 (7)`；签名有效；快照时间推进并包含当前周剩余百分比。

- [ ] **Step 6: 现场验证主程序、菜单栏与 WidgetKit 请求**

使用 Computer Use 打开主程序，确认主程序周剩余值与快照一致；确认菜单栏开关为开，且 Only Switch 未运行或未折叠状态项。让额度产生一次可见变化或使用测试替身验证：只有可见数据改变才调用 `reloadTimelines`，单纯 `observedAt` 推进不重复请求。

- [ ] **Step 7: 检查工作树和提交序列**

Run:

```bash
git status -sb
git log -4 --oneline
git diff --check
```

Expected: 工作树干净；最新提交依次包含核心修复、文案说明和 build 7；无未提交差异。
