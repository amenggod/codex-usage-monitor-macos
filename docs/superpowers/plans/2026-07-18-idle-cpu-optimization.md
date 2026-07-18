# Idle CPU Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把空闲时约 22.5% 的主程序 CPU 和约 13% 的常驻 `codex app-server` CPU 降到稳定低占用，同时保留每分钟准确额度同步和立即手动刷新。

**Architecture:** SwiftUI 主窗口改为数据变化驱动，不再每秒重绘。`CodexRateLimitService` 保留 60 秒轮询与退避重试，但每次刷新都创建一个短生命周期 app-server 会话，并以单航班机制合并重叠请求；传输停止时必须等待子进程真正退出。

**Tech Stack:** Swift 6、Swift Concurrency、AppKit、SwiftUI、Foundation `Process`、Swift Testing、shell contract tests、macOS 14+

## Global Constraints

- 本计划在 `2026-07-18-menu-bar-helper.md` 完成后执行。
- 主程序仍每 60 秒同步一次实时额度；手动刷新必须立即执行。
- 两次同步之间不得常驻主程序启动的 `codex app-server`。
- 自动轮询、退避重试和手动刷新重叠时，至多存在一个 app-server 请求。
- 额度请求失败时保留最近可信额度，并继续使用现有 5 秒、30 秒、120 秒退避。
- 主窗口与菜单栏助手不得运行一秒周期 UI 刷新。
- Token 会话文件增量索引和 SQLite 聚合架构本次不重写。
- App Group、Bundle IDs、隐私边界和 WidgetKit 刷新预算保持不变。
- 性能验收目标：关闭窗口和弹窗、等待两分钟后，主程序与菜单栏助手 CPU 合计通常低于 2%。

---

### Task 1: 删除主界面的一秒周期重绘

**Files:**
- Create: `Scripts/test-idle-cpu-contracts.sh`
- Modify: `Sources/CodexUsageMonitor/Presentation/UsagePopoverView.swift:45-75`
- Modify: `Sources/CodexUsageMonitor/Presentation/UsagePresentationPolicy.swift:1-8`
- Modify: `Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift:20-31`
- Modify: `Scripts/test-ci-contracts.sh`

**Interfaces:**
- Removes: `UsagePresentationPolicy.refreshInterval`
- Removes: `TimelineView(.periodic(...))` from the main view
- Preserves: `UsagePresentationPolicy.activeLimits(limits:now:)`

- [ ] **Step 1: 写入空闲 CPU 源码契约测试**

创建 `Scripts/test-idle-cpu-contracts.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="$ROOT/Sources/CodexUsageMonitor/Presentation/UsagePopoverView.swift"
POLICY="$ROOT/Sources/CodexUsageMonitor/Presentation/UsagePresentationPolicy.swift"
HELPER="$ROOT/Sources/CodexUsageMenuBar"

if grep -q 'TimelineView' "$VIEW"; then
  echo 'main usage view still contains TimelineView' >&2
  exit 1
fi
if grep -q 'refreshInterval' "$POLICY"; then
  echo 'presentation policy still exposes a one-second refresh interval' >&2
  exit 1
fi
if grep -R -q 'scheduledTimer.*1\|by: 1' "$HELPER"; then
  echo 'menu helper contains a one-second timer' >&2
  exit 1
fi

echo 'Idle UI refresh contract verified.'
```

给脚本执行权限，并在 `Scripts/test-ci-contracts.sh` 末尾调用它。

- [ ] **Step 2: 运行契约并确认当前实现失败**

```bash
bash Scripts/test-idle-cpu-contracts.sh
```

Expected: FAIL，输出 `main usage view still contains TimelineView`。

- [ ] **Step 3: 改为模型变化驱动的 View body**

把 `UsagePopoverView.body` 的 `TimelineView` 外层替换为：

```swift
var body: some View {
    VStack(spacing: 0) {
        header
        Divider()
        dashboard(now: .now)
        Divider()
        footer
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .confirmationDialog(
        "登录时自动启动？",
        isPresented: $showLaunchAtLoginPrompt,
        titleVisibility: .visible
    ) {
        Button("Enable") { enableLaunchAtLoginFromPrompt() }
        Button("Not Now", role: .cancel) { didAskLaunchAtLogin = true }
    } message: {
        Text("Codex Usage Monitor 可在登录后自动运行并持续更新用量。")
    }
    .task {
        guard !didAskLaunchAtLogin else { return }
        await Task.yield()
        showLaunchAtLoginPrompt = true
    }
}
```

删除 `UsagePresentationPolicy.refreshInterval`。删除仅断言 `refreshInterval <= 1` 的旧测试；`limitsExpireExactlyAtTheirResetBoundary` 继续验证时间边界。每分钟额度状态变化会让 `@Observable UsageViewModel` 重新计算 body。

- [ ] **Step 4: 运行契约和 presentation 测试**

```bash
bash Scripts/test-idle-cpu-contracts.sh
swift test --filter AppPresentationStateTests
```

Expected: PASS，且 helper 目录不存在一秒 Timer。

- [ ] **Step 5: 提交事件驱动界面**

```bash
git add Scripts/test-idle-cpu-contracts.sh Scripts/test-ci-contracts.sh \
  Sources/CodexUsageMonitor/Presentation/UsagePopoverView.swift \
  Sources/CodexUsageMonitor/Presentation/UsagePresentationPolicy.swift \
  Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift
git commit -m "perf: remove one-second UI redraws"
```

---

### Task 2: 让每次额度刷新都关闭传输

**Files:**
- Modify: `Sources/CodexUsageMonitor/RateLimits/CodexRateLimitService.swift:18-170`
- Modify: `Tests/CodexUsageMonitorTests/CodexRateLimitServiceTests.swift`

**Interfaces:**
- Preserves: `RateLimitServicing.start()` / `refresh()` / `updates()` / `stop()`
- Changes: 每次 refresh 都执行 start → initialize → read → stop
- Removes: app-server notification subscription and persistent `initialized` state

- [ ] **Step 1: 把服务测试改为短生命周期契约**

在 `FakeRateLimitTransport` 添加 `startCount`。把首个测试补充为：

```swift
#expect(await transport.startCount == 1)
#expect(await transport.stopCount == 1)
#expect(await transport.methods == [
    "initialize", "account/rateLimits/read"
])
```

用以下测试替换 `updateNotificationTriggersACompleteReadWithoutReinitializing`：

```swift
@Test func everyRefreshUsesAFreshShortLivedTransport() async {
    let transport = FakeRateLimitTransport()
    let store = LiveRateLimitStore()
    await transport.setReadResponse(readResponse(usedPercent: 31))
    let service = CodexRateLimitService(
        transport: transport,
        store: store,
        now: { Date(timeIntervalSince1970: 2_000) },
        retryDelays: []
    )

    await service.start()
    await service.refresh()

    #expect(await transport.startCount == 2)
    #expect(await transport.stopCount == 2)
    #expect(await transport.methods == [
        "initialize", "account/rateLimits/read",
        "initialize", "account/rateLimits/read",
    ])
    await service.stop()
}
```

再添加初始化失败和读取失败测试，均要求 `stopCount == startCount`。

- [ ] **Step 2: 运行测试并确认当前常驻实现失败**

```bash
swift test --filter CodexRateLimitServiceTests
```

Expected: FAIL，首次成功读取后的 `stopCount` 实际为 `0`，第二次刷新不会重新 initialize。

- [ ] **Step 3: 删除通知订阅和跨请求初始化状态**

从 `CodexRateLimitService` 删除：

```swift
private var notificationTask: Task<Void, Never>?
private var initialized = false
private func refreshFromNotification() async
```

`start()` 不再调用 `transport.notifications()`；只执行首次刷新并启动 60 秒 polling task。

- [ ] **Step 4: 用短生命周期 helper 包裹请求**

添加：

```swift
private struct LimitRead {
    let limits: [LimitStatus]
    let observedAt: Date
}

private func readLimits() async throws -> LimitRead {
    do {
        try await transport.start()
        _ = try await transport.request(
            method: "initialize",
            params: Self.initializeParameters,
            timeout: .seconds(10)
        )
        let response = try await transport.request(
            method: "account/rateLimits/read",
            params: nil,
            timeout: .seconds(10)
        )
        let observedAt = now()
        let observations = try CodexRateLimitProtocol.decodeReadResult(
            from: response,
            observedAt: observedAt
        )
        await transport.stop()
        return LimitRead(
            limits: observations.map {
                LimitStatus(
                    limitID: $0.limitID,
                    window: $0.window,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            },
            observedAt: observedAt
        )
    } catch {
        await transport.stop()
        throw error
    }
}
```

`performRefresh` 调用 `readLimits()`，使用返回的同一个 `observedAt` 执行 `store.replace(limits:observedAt:)`；失败后不再条件判断 transport error，因为 helper 已保证 stop。`stop()` 仍调用 `transport.stop()`，保证幂等清理。

- [ ] **Step 5: 运行服务测试**

```bash
swift test --filter CodexRateLimitServiceTests
```

Expected: PASS，成功、失败、轮询和手动刷新均满足 start/stop 配对。

- [ ] **Step 6: 提交短生命周期额度服务**

```bash
git add Sources/CodexUsageMonitor/RateLimits/CodexRateLimitService.swift \
  Tests/CodexUsageMonitorTests/CodexRateLimitServiceTests.swift
git commit -m "perf: stop app server after each limit refresh"
```

---

### Task 3: 合并重叠的自动与手动刷新

**Files:**
- Modify: `Sources/CodexUsageMonitor/RateLimits/CodexRateLimitService.swift`
- Modify: `Tests/CodexUsageMonitorTests/CodexRateLimitServiceTests.swift`

**Interfaces:**
- Produces: 私有 `runSingleFlightRefresh(scheduleRetryOnFailure:) async`
- Guarantees: 同一时刻只有一个 `Task<Void, Never>` 操作 transport

- [ ] **Step 1: 写入门控并发测试**

给 fake transport 增加一个可选 `AsyncGate`，在 read 请求处等待。添加：

```swift
@Test func overlappingManualRefreshesShareOneTransportSession() async {
    let gate = AsyncGate()
    let transport = FakeRateLimitTransport(readGate: gate)
    let store = LiveRateLimitStore()
    await transport.setReadResponse(readResponse(usedPercent: 31))
    let service = CodexRateLimitService(
        transport: transport,
        store: store,
        now: { Date(timeIntervalSince1970: 2_000) },
        retryDelays: []
    )

    let first = Task { await service.refresh() }
    await gate.waitUntilEntered()
    let second = Task { await service.refresh() }
    await Task.yield()

    #expect(await transport.startCount == 1)
    gate.open()
    await first.value
    await second.value

    #expect(await transport.startCount == 1)
    #expect(await transport.readCount == 1)
    #expect(await transport.stopCount == 1)
}
```

- [ ] **Step 2: 运行测试并确认出现两个会话或重入错误**

```bash
swift test --filter overlappingManualRefreshesShareOneTransportSession
```

Expected: FAIL，`startCount` 或 `readCount` 为 `2`，或 transport 被并发重入。

- [ ] **Step 3: 实现 actor 内单航班状态**

在服务中添加：

```swift
private struct ActiveRefresh {
    let id: UInt64
    let task: Task<Void, Never>
}
private var nextRefreshID: UInt64 = 0
private var activeRefresh: ActiveRefresh?

private func runSingleFlightRefresh(
    scheduleRetryOnFailure: Bool
) async {
    if let activeRefresh {
        await activeRefresh.task.value
        return
    }

    nextRefreshID &+= 1
    let id = nextRefreshID
    let task = Task { [weak self] in
        await self?.performRefresh(
            scheduleRetryOnFailure: scheduleRetryOnFailure
        )
    }
    activeRefresh = ActiveRefresh(id: id, task: task)
    await task.value
    if activeRefresh?.id == id {
        activeRefresh = nil
    }
}
```

`start()`、`refresh()`、polling 和 retry 全部改为调用该方法。`stop()` 的顺序固定为：`started = false`、取消 polling/retry、取消 active task、`await transport.stop()`、清空 active state、结束 update stream。

- [ ] **Step 4: 增加停止期间并发测试**

新增测试：read 被 gate 阻塞时调用 `service.stop()`；Expected：transport `stopCount == 1` 或幂等调用后的允许值、两个 refresh task 都结束、没有第二次 start。

- [ ] **Step 5: 运行额度服务完整测试**

```bash
swift test --filter CodexRateLimitServiceTests
```

Expected: PASS，单航班、退避、轮询、手动刷新和停止全部通过。

- [ ] **Step 6: 提交单航班刷新**

```bash
git add Sources/CodexUsageMonitor/RateLimits/CodexRateLimitService.swift \
  Tests/CodexUsageMonitorTests/CodexRateLimitServiceTests.swift
git commit -m "fix: coalesce overlapping limit refreshes"
```

---

### Task 4: 等待 app-server 子进程真正退出

**Files:**
- Create: `Sources/CodexUsageMonitor/RateLimits/ProcessTerminationWaiter.swift`
- Modify: `Sources/CodexUsageMonitor/RateLimits/CodexAppServerTransport.swift:52-165`
- Modify: `Tests/CodexUsageMonitorTests/CodexAppServerTransportTests.swift`

**Interfaces:**
- Produces: `ProcessTerminationWaiter.wait(timeout:) async`
- Changes: `CodexAppServerTransport.stop()` 返回前子进程必须已退出
- Adds: stderr drain task to prevent pipe backpressure

- [ ] **Step 1: 写入真实子进程退出测试**

创建一个 shell fixture：启动时把 `$$` 写入测试传入的 PID 文件，捕获 TERM 后退出，并保持 stdin loop。测试调用 `transport.start()`，等待 PID 文件出现，随后 `await transport.stop()`，最后用 `Darwin.kill(pid, 0)` 轮询最多一秒。

测试核心断言：

```swift
await transport.stop()
try await waitUntil {
    Darwin.kill(processID, 0) == -1 && errno == ESRCH
}
#expect(Darwin.kill(processID, 0) == -1)
```

再添加脚本持续写 stderr 的测试，确认一次 request 仍能完成，避免未读取 `errorPipe` 填满后阻塞。

- [ ] **Step 2: 运行 transport 测试并确认 stop 过早返回**

```bash
swift test --filter CodexAppServerTransportTests
```

Expected: 新退出测试 FAIL，`stop()` 返回时 PID 仍存在，或 stderr 压力测试超时。

- [ ] **Step 3: 实现可等待的 termination handler**

创建 `ProcessTerminationWaiter.swift`：

```swift
import Foundation

final class ProcessTerminationWaiter: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(process: Process) {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let terminationContinuation = pair.continuation
        stream = pair.stream
        continuation = terminationContinuation
        process.terminationHandler = { _ in
            terminationContinuation.yield(())
            terminationContinuation.finish()
        }
    }

    func wait(timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [stream] in
                for await _ in stream { return }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }
}
```

- [ ] **Step 4: 在 transport 中持有 waiter 并排空 stderr**

`start()` 在 `process.run()` 前创建 waiter，在 run 后启动 `errorReadingTask`：

```swift
errorReadingTask = Task {
    do {
        for try await _ in errorPipe.fileHandleForReading.bytes {}
    } catch {}
}
```

`stop()` 捕获局部 process/waiter，关闭 input，取消 stdout/stderr task，发送 terminate，等待最多 2 秒。若仍 `process.isRunning`，调用 `Darwin.kill(process.processIdentifier, SIGKILL)` 并再次等待。只有确认退出后才清空引用并 `failPending(with: .stopped)`。

- [ ] **Step 5: 运行 transport 与 service 测试**

```bash
swift test --filter CodexAppServerTransportTests
swift test --filter CodexRateLimitServiceTests
```

Expected: PASS；停止幂等、超时、进程自行退出、stderr 压力和服务短生命周期全部通过。

- [ ] **Step 6: 提交进程清理**

```bash
git add Sources/CodexUsageMonitor/RateLimits/ProcessTerminationWaiter.swift \
  Sources/CodexUsageMonitor/RateLimits/CodexAppServerTransport.swift \
  Tests/CodexUsageMonitorTests/CodexAppServerTransportTests.swift
git commit -m "fix: reap transient app server processes"
```

---

### Task 5: 完整回归、安装与 CPU 现场验收

**Files:**
- Modify: `README.md`
- Verify: `dist/Codex Usage Monitor.app`
- Install: `/Applications/Codex Usage Monitor.app`

**Interfaces:**
- Verifies: 空闲 UI 无一秒周期任务
- Verifies: 两次同步之间无主程序子 `codex app-server`
- Verifies: CPU 稳定目标与数据一致性

- [ ] **Step 1: 更新 README 性能与刷新说明**

明确说明：实时额度每 60 秒或手动触发；每次请求使用短生命周期 app-server；同步瞬间可能短暂升高；空闲时不应持续出现额外 codex 子进程。不要承诺 WidgetKit 严格分钟级重绘。

- [ ] **Step 2: 运行全部静态、单元和 Xcode 测试**

```bash
bash Scripts/test-idle-cpu-contracts.sh
bash Scripts/test-ci-contracts.sh
bash Scripts/test-verify-bundle-signing.sh
swift test
xcodebuild \
  -project CodexUsageMonitor.xcodeproj \
  -scheme CodexUsageMonitorTests \
  -configuration Debug \
  test
git diff --check
```

Expected: 全部 exit 0，测试 0 failures。

- [ ] **Step 3: 构建并验证签名 Release**

```bash
CODE_SIGNING_ALLOWED=YES \
DEVELOPMENT_TEAM=ZD9PK3NY5Z \
CODE_SIGN_STYLE=Automatic \
bash Scripts/build-app.sh
bash Scripts/verify-bundle.sh 'dist/Codex Usage Monitor.app'
```

Expected: exit 0，主程序、Widget、登录项、菜单栏助手和所有 framework 签名与 App Group 一致。

- [ ] **Step 4: 安装 build 10**

```bash
pkill -x CodexUsageMonitor || true
pkill -x CodexUsageMenuBar || true
rm -rf '/Applications/Codex Usage Monitor.app.new'
ditto 'dist/Codex Usage Monitor.app' \
  '/Applications/Codex Usage Monitor.app.new'
rm -rf '/Applications/Codex Usage Monitor.app'
mv '/Applications/Codex Usage Monitor.app.new' \
  '/Applications/Codex Usage Monitor.app'
open -a '/Applications/Codex Usage Monitor.app'
```

- [ ] **Step 5: 验证同步瞬间和空闲进程状态**

打开主程序点击刷新，确认额度变化传播到主程序、助手与 App Group。刷新结束 10 秒后，在活动监视器按“Codex”筛选：Expected 主程序和 `CodexUsageMenuBar` 存在，但主程序启动的 `codex app-server` 不存在。到下一个分钟边界允许它短暂出现，随后必须退出。

- [ ] **Step 6: 验证两分钟空闲 CPU**

关闭主窗口和助手弹窗，等待两分钟。连续观察活动监视器至少 30 秒：Expected 主程序与助手合计通常低于 2%，不再稳定停留在原来的约 22.5% + 13%。记录稳定区间和任何分钟同步短峰值，不用单个瞬时读数代替结论。

- [ ] **Step 7: 验证 Token 实时更新未回归**

完成一次短 Codex 会话，确认今日 Token、总 Token、项目排行、助手面板和 Widget 共享快照更新。停止输出后 CPU 应回到空闲基线，不出现持续扫描。

- [ ] **Step 8: 提交文档和最终修正**

```bash
git add README.md Scripts Sources Tests \
  docs/superpowers/plans/2026-07-18-idle-cpu-optimization.md
git commit -m "perf: complete idle CPU optimization"
```

- [ ] **Step 9: 最终证据检查**

```bash
swift test
bash Scripts/verify-bundle.sh \
  '/Applications/Codex Usage Monitor.app'
git log -8 --oneline
git status --short
```

Expected: 测试 0 failures；安装包验证通过；最近提交对应计划任务；工作区仅包含用户已有无关改动或为空。
