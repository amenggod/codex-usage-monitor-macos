# Independent Menu Bar Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在主应用包内新增独立 Bundle ID 的菜单栏助手，让菜单栏图标重新可见，并让助手、主程序与 Widget 始终读取同一份 App Group 快照。

**Architecture:** 主程序继续作为唯一数据生产者，在每次成功写入 `WidgetUsageSnapshot` 后发布 Darwin 通知。独立 LSUIElement 助手只读取共享快照、显示原生 `NSStatusItem` 与轻量弹窗，并通过 `codexusagemonitor://` URL 把刷新、设置和打开完整统计交还主程序。

**Tech Stack:** Swift 6、AppKit、SwiftUI、Observation、CoreFoundation Darwin Notifications、App Group、XcodeGen 2.45.4、Swift Testing、macOS 14+

## Global Constraints

- 主程序 Bundle ID 保持 `com.amenggod.CodexUsageMonitor`。
- 菜单栏助手 Bundle ID 必须是 `com.amenggod.CodexUsageMonitor.MenuBar`。
- App Group 必须保持 `ZD9PK3NY5Z.CodexUsageMonitor.shared`。
- 助手只读取脱敏后的 `WidgetUsageSnapshot`；不得读取 SQLite、Codex JSONL、凭据、提示词或完整 app-server 响应。
- 主程序是唯一数据生产者；助手不得启动 `codex app-server`。
- 菜单栏开关关闭时助手必须退出；登录后台启动时按同一偏好恢复。
- 点击图标显示轻量面板；面板提供刷新、设置、完整统计和退出入口。
- 5 小时额度缺失或过期时隐藏，不制造替代值。
- 保持 `MARKETING_VERSION = 0.2.3`，最终构建号从 `9` 升至 `10`。
- 本计划先于 `2026-07-18-idle-cpu-optimization.md` 执行。

---

### Task 1: 发布跨进程快照变化信号

**Files:**
- Create: `Sources/CodexUsageShared/UsageSnapshotChangeSignal.swift`
- Modify: `Sources/CodexUsageMonitor/Widget/WidgetSnapshotPublisher.swift:31-108`
- Modify: `Tests/CodexUsageMonitorTests/WidgetSnapshotPublisherTests.swift`

**Interfaces:**
- Produces: `UsageSnapshotChangeSignal.rawName: String`
- Produces: `UsageSnapshotChangePosting.postSnapshotChanged()`
- Produces: `DarwinUsageSnapshotChangePoster`
- Changes: `WidgetSnapshotPublisher.init(aggregator:store:reloader:changePoster:)`

- [ ] **Step 1: 写入“成功落盘后通知、失败不通知”的测试**

在 `WidgetSnapshotPublisherTests.swift` 添加：

```swift
@Test func successfulSnapshotWritePostsCrossProcessChangeSignal() async {
    let poster = SnapshotChangePosterSpy()
    let publisher = WidgetSnapshotPublisher(
        aggregator: WidgetPublisherAggregatorSpy([
            makeSnapshot(range: .today, total: 12, projects: []),
            makeSnapshot(range: .all, total: 34, projects: []),
        ]),
        store: WidgetStoreSpy(),
        reloader: WidgetReloaderSpy(),
        changePoster: poster
    )

    _ = await publisher.publish(now: testNow, calendar: testCalendar)

    #expect(poster.postCount == 1)
}

@Test func failedSnapshotWriteDoesNotPostCrossProcessChangeSignal() async {
    let poster = SnapshotChangePosterSpy()
    let publisher = WidgetSnapshotPublisher(
        aggregator: WidgetPublisherAggregatorSpy([
            makeSnapshot(range: .today, total: 12, projects: []),
            makeSnapshot(range: .all, total: 34, projects: []),
        ]),
        store: WidgetStoreSpy(writeError: WidgetPublisherTestFailure()),
        reloader: WidgetReloaderSpy(),
        changePoster: poster
    )

    _ = await publisher.publish(now: testNow, calendar: testCalendar)

    #expect(poster.postCount == 0)
}

private final class SnapshotChangePosterSpy: @unchecked Sendable,
    UsageSnapshotChangePosting {
    private let lock = NSLock()
    private var count = 0

    var postCount: Int { lock.withLock { count } }

    func postSnapshotChanged() {
        lock.withLock { count += 1 }
    }
}
```

若现有 `WidgetStoreSpy` 不接受写入错误，为它增加 `writeError: Error? = nil`，并在 `write` 中优先抛出该错误。

- [ ] **Step 2: 运行测试并确认按预期编译失败**

Run:

```bash
swift test --filter successfulSnapshotWritePostsCrossProcessChangeSignal
```

Expected: FAIL，提示找不到 `UsageSnapshotChangePosting` 或 `changePoster` 参数。

- [ ] **Step 3: 添加共享 Darwin 信号契约**

创建 `Sources/CodexUsageShared/UsageSnapshotChangeSignal.swift`：

```swift
import CoreFoundation
import Foundation

public enum UsageSnapshotChangeSignal {
    public static let rawName =
        "com.amenggod.CodexUsageMonitor.snapshot-changed.v1"
}

public protocol UsageSnapshotChangePosting: Sendable {
    func postSnapshotChanged()
}

public struct DarwinUsageSnapshotChangePoster:
    UsageSnapshotChangePosting,
    Sendable {
    public init() {}

    public func postSnapshotChanged() {
        let name = CFNotificationName(
            UsageSnapshotChangeSignal.rawName as CFString
        )
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }
}
```

- [ ] **Step 4: 只在原子写入成功后发布信号**

在 `WidgetSnapshotPublisher` 添加：

```swift
private let changePoster: any UsageSnapshotChangePosting

init(
    aggregator: any WidgetSnapshotAggregating,
    store: any WidgetSnapshotStoring,
    reloader: any WidgetTimelineReloading,
    changePoster: any UsageSnapshotChangePosting =
        DarwinUsageSnapshotChangePoster()
) {
    self.aggregator = aggregator
    self.store = store
    self.reloader = reloader
    self.changePoster = changePoster
}
```

在 `publish` 和 `publishRebuilding` 的每个 `try store.write(snapshot)` 后立即添加：

```swift
changePoster.postSnapshotChanged()
```

通知必须发生在写入之后、WidgetKit 重载判断之前。

- [ ] **Step 5: 运行发布器测试**

Run:

```bash
swift test --filter WidgetSnapshotPublisherTests
```

Expected: PASS，新增两项测试和原有发布器测试全部通过。

- [ ] **Step 6: 提交快照信号契约**

```bash
git add Sources/CodexUsageShared/UsageSnapshotChangeSignal.swift \
  Sources/CodexUsageMonitor/Widget/WidgetSnapshotPublisher.swift \
  Tests/CodexUsageMonitorTests/WidgetSnapshotPublisherTests.swift
git commit -m "feat: notify menu helper after snapshot writes"
```

---

### Task 2: 建立助手的只读快照模型与刷新驱动

**Files:**
- Create: `Sources/CodexUsageMenuBarCore/MenuBarSnapshotModel.swift`
- Create: `Sources/CodexUsageMenuBarCore/MenuBarSnapshotMonitor.swift`
- Create: `Sources/CodexUsageMenuBarCore/DarwinSnapshotChangeObserver.swift`
- Create: `Tests/CodexUsageMenuBarCoreTests/MenuBarSnapshotMonitorTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `WidgetSnapshotStore.read()`、`WidgetDisplayModel`
- Produces: `MenuBarSnapshotModel.display: WidgetDisplayModel`
- Produces: `MenuBarSnapshotMonitor.start()` / `stop()` / `reload()`
- Produces: `SnapshotChangeObserving`、`MenuBarFallbackScheduling`

- [ ] **Step 1: 注册可独立测试的 Core target**

在 `Package.swift` products 添加：

```swift
.library(
    name: "CodexUsageMenuBarCore",
    targets: ["CodexUsageMenuBarCore"]
),
```

在 targets 添加：

```swift
.target(
    name: "CodexUsageMenuBarCore",
    dependencies: ["CodexUsageShared"]
),
.testTarget(
    name: "CodexUsageMenuBarCoreTests",
    dependencies: [
        "CodexUsageMenuBarCore",
        "CodexUsageShared",
        .product(name: "Testing", package: "swift-testing"),
    ],
    linkerSettings: testingLinkerSettings
),
```

- [ ] **Step 2: 写入通知刷新、兜底刷新和损坏快照测试**

创建 `MenuBarSnapshotMonitorTests.swift`。核心测试必须覆盖：`start()` 立即读取一次；Darwin observer 回调再次读取；相同快照的重复通知不改变 display；60 秒 scheduler 即使数据相同也更新时间以重新判断额度过期；读取损坏时保留最后有效快照并把 `hasReadError` 设为 `true`。

测试主体使用：

```swift
@MainActor
@Test func startsWithImmediateReadThenReloadsForSignalAndFallback() {
    let reader = SnapshotReaderStub(results: [
        .success(.placeholder),
        .success(makeSnapshot(today: 20)),
        .success(makeSnapshot(today: 30)),
    ])
    let observer = SnapshotObserverSpy()
    let scheduler = FallbackSchedulerSpy()
    let model = MenuBarSnapshotModel()
    let monitor = MenuBarSnapshotMonitor(
        model: model,
        reader: reader,
        observer: observer,
        scheduler: scheduler,
        now: { Date(timeIntervalSince1970: 2_000) }
    )

    monitor.start()
    #expect(model.display.snapshot?.todayTokens == 12_345)
    #expect(scheduler.interval == 60)
    observer.fire()
    #expect(model.display.snapshot?.todayTokens == 20)
    scheduler.fire()
    #expect(model.display.snapshot?.todayTokens == 30)
}
```

- [ ] **Step 3: 运行测试并确认缺少模型**

Run:

```bash
swift test --filter MenuBarSnapshotMonitorTests
```

Expected: FAIL，提示 `MenuBarSnapshotModel` 和 `MenuBarSnapshotMonitor` 未定义。

- [ ] **Step 4: 实现只读模型**

创建 `MenuBarSnapshotModel.swift`：

```swift
import CodexUsageShared
import Foundation
import Observation

@MainActor
@Observable
public final class MenuBarSnapshotModel {
    public private(set) var display = WidgetDisplayModel(
        loadState: .missing,
        now: .now
    )
    public private(set) var lastValidSnapshot: WidgetUsageSnapshot?
    public private(set) var hasReadError = false

    public init() {}

    func apply(
        snapshot: WidgetUsageSnapshot?,
        now: Date,
        forceTimeUpdate: Bool
    ) {
        let next = WidgetDisplayModel(snapshot: snapshot, now: now)
        guard forceTimeUpdate || next.loadState != display.loadState else {
            hasReadError = false
            return
        }
        lastValidSnapshot = snapshot ?? lastValidSnapshot
        hasReadError = false
        display = next
    }

    func applyReadFailure(now: Date) {
        hasReadError = true
        display = lastValidSnapshot.map {
            WidgetDisplayModel(snapshot: $0, now: now)
        } ?? WidgetDisplayModel(loadState: .invalid, now: now)
    }
}
```

- [ ] **Step 5: 实现监视器边界**

创建 `MenuBarSnapshotMonitor.swift`：

```swift
import CodexUsageShared
import Foundation

public protocol MenuBarSnapshotReading: Sendable {
    func read() throws -> WidgetUsageSnapshot?
}
extension WidgetSnapshotStore: MenuBarSnapshotReading {}

@MainActor public protocol SnapshotChangeObserving: AnyObject {
    func start(_ handler: @escaping @MainActor () -> Void)
    func stop()
}
@MainActor public protocol MenuBarFallbackCancellation: AnyObject {
    func cancel()
}
@MainActor public protocol MenuBarFallbackScheduling: AnyObject {
    func schedule(
        every interval: TimeInterval,
        _ handler: @escaping @MainActor () -> Void
    ) -> any MenuBarFallbackCancellation
}

@MainActor
public final class MenuBarSnapshotMonitor {
    public static let fallbackInterval: TimeInterval = 60
    private let model: MenuBarSnapshotModel
    private let reader: any MenuBarSnapshotReading
    private let observer: any SnapshotChangeObserving
    private let scheduler: any MenuBarFallbackScheduling
    private let now: () -> Date
    private var cancellation: (any MenuBarFallbackCancellation)?
    private var started = false

    public init(
        model: MenuBarSnapshotModel,
        reader: any MenuBarSnapshotReading,
        observer: any SnapshotChangeObserving,
        scheduler: any MenuBarFallbackScheduling,
        now: @escaping () -> Date
    ) {
        self.model = model
        self.reader = reader
        self.observer = observer
        self.scheduler = scheduler
        self.now = now
    }

    public func start() {
        guard !started else { return }
        started = true
        observer.start { [weak self] in
            self?.reload(forceTimeUpdate: false)
        }
        cancellation = scheduler.schedule(every: Self.fallbackInterval) {
            [weak self] in self?.reload(forceTimeUpdate: true)
        }
        reload(forceTimeUpdate: true)
    }

    public func stop() {
        observer.stop()
        cancellation?.cancel()
        cancellation = nil
        started = false
    }

    public func reload(forceTimeUpdate: Bool) {
        do {
            model.apply(
                snapshot: try reader.read(),
                now: now(),
                forceTimeUpdate: forceTimeUpdate
            )
        } catch {
            model.applyReadFailure(now: now())
        }
    }
}
```

- [ ] **Step 6: 实现 Darwin observer 与 Timer scheduler**

`DarwinSnapshotChangeObserver` 用 `CFNotificationCenterAddObserver` 监听 `UsageSnapshotChangeSignal.rawName`；C 回调只做 `Task { @MainActor in handler() }`。`stop()` 用相同指针和名称移除。`TimerMenuBarFallbackScheduler` 用 `Timer.scheduledTimer` 返回具备 `cancel()` 的令牌，不得保留强引用环。

- [ ] **Step 7: 运行 Core 测试和完整 SwiftPM 测试**

```bash
swift test --filter MenuBarSnapshotMonitorTests
swift test
```

Expected: PASS，且没有 Swift 6 并发警告。

- [ ] **Step 8: 提交助手 Core**

```bash
git add Package.swift Sources/CodexUsageMenuBarCore \
  Tests/CodexUsageMenuBarCoreTests
git commit -m "feat: add read-only menu bar snapshot monitor"
```

---

### Task 3: 为主程序添加助手生命周期管理

**Files:**
- Create: `Sources/CodexUsageMonitor/Services/MenuBarHelperCoordinator.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/MenuBarVisibilityStore.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/SettingsView.swift`
- Modify: `Sources/CodexUsageMonitor/App/AppDelegate.swift`
- Modify: `Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift`
- Modify: `Tests/CodexUsageMonitorTests/AppLaunchCoordinatorTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift`

**Interfaces:**
- Produces: `MenuBarHelperCoordinating.start()` / `stop()`
- Produces: `MenuBarHelperLaunching.launch(at:)` / `terminate(bundleIdentifier:)`
- Consumes: `MenuBarVisibilityStore.isVisible` 和变化回调

- [ ] **Step 1: 把 AppDelegate 测试改为助手协调器语义**

用以下测试替换旧的原生菜单栏延迟测试：

```swift
@MainActor
@Test func appDelegateDefersMenuBarHelperUntilLaunchReturns() async {
    let delegate = AppDelegate()
    let helper = MenuBarHelperCoordinatorSpy()
    delegate.retainMenuBarHelperCoordinator(helper)
    delegate.startRetainedMenuBarHelperCoordinator()

    #expect(helper.startCount == 0)
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(helper.startCount == 1)
}

@MainActor
@Test func applicationTerminationStopsMenuBarHelper() {
    let delegate = AppDelegate()
    let helper = MenuBarHelperCoordinatorSpy()
    delegate.retainMenuBarHelperCoordinator(helper)
    delegate.applicationWillTerminate(
        Notification(name: NSApplication.willTerminateNotification)
    )
    #expect(helper.stopCount == 1)
}
```

再添加协调器测试：首次开启只启动一次、关闭只终止一次、重新开启再次启动、重复 `start()` 幂等。

- [ ] **Step 2: 运行测试并确认缺少新接口**

```bash
swift test --filter AppLaunchCoordinatorTests
```

Expected: FAIL，提示 `MenuBarHelperCoordinating` 或新保留方法不存在。

- [ ] **Step 3: 实现助手启动适配器和协调器**

创建 `MenuBarHelperCoordinator.swift`，接口与核心逻辑如下：

```swift
import AppKit
import Foundation

@MainActor protocol MenuBarHelperCoordinating: AnyObject {
    func start()
    func stop()
}
@MainActor protocol MenuBarHelperLaunching: AnyObject {
    func launch(at url: URL) throws
    func terminate(bundleIdentifier: String)
}

@MainActor
final class MenuBarHelperCoordinator: MenuBarHelperCoordinating {
    static let bundleIdentifier =
        "com.amenggod.CodexUsageMonitor.MenuBar"
    private let visibilityStore: MenuBarVisibilityStore
    private let launcher: any MenuBarHelperLaunching
    private let helperURL: URL
    private var started = false
    private var requestedRunning = false

    init(
        visibilityStore: MenuBarVisibilityStore,
        launcher: any MenuBarHelperLaunching,
        helperURL: URL
    ) {
        self.visibilityStore = visibilityStore
        self.launcher = launcher
        self.helperURL = helperURL
    }

    func start() {
        guard !started else { return }
        started = true
        visibilityStore.setVisibilityChangeHandler { [weak self] visible in
            self?.synchronize(visible: visible)
        }
        synchronize(visible: visibilityStore.isVisible)
    }

    func stop() {
        visibilityStore.setVisibilityChangeHandler(nil)
        started = false
        synchronize(visible: false)
    }

    private func synchronize(visible: Bool) {
        guard visible != requestedRunning else { return }
        if visible {
            do {
                try launcher.launch(at: helperURL)
                requestedRunning = true
            } catch {
                visibilityStore.setLaunchError(error.localizedDescription)
            }
        } else {
            launcher.terminate(bundleIdentifier: Self.bundleIdentifier)
            requestedRunning = false
        }
    }
}
```

实际 `WorkspaceMenuBarHelperLauncher.launch(at:)` 调用 `NSWorkspace.shared.open(url)`；返回 `false` 时抛出可读启动错误。助手是 LSUIElement 且没有普通窗口，因此启动不会弹出界面。终止时只查找助手 Bundle ID。`MenuBarVisibilityStore` 的 handler 改为可空，并新增 `launchErrorDescription` 与 `setLaunchError(_:)`。`SettingsView` 在菜单栏开关下方以红色 caption 显示该错误；下一次成功启动时清空错误。

- [ ] **Step 4: 用助手协调器替换 AppDelegate 的旧控制器**

`AppDelegate` 保留、延迟启动并在 `applicationWillTerminate` 停止助手协调器。`CodexUsageMonitorApp.init` 使用以下稳定路径：

```swift
let helperURL = Bundle.main.bundleURL
    .appending(path: "Contents/Library/LoginItems")
    .appending(path: "CodexUsageMenuBar.app")
```

此任务不再实例化 `AppKitMenuBarController`；文件本身在 Task 6 删除。

- [ ] **Step 5: 运行生命周期和设置测试**

```bash
swift test --filter AppLaunchCoordinatorTests
swift test --filter AppPresentationStateTests
```

Expected: PASS，菜单栏开关仍持久化并立即驱动助手启停。

- [ ] **Step 6: 提交生命周期管理**

```bash
git add Sources/CodexUsageMonitor/Services/MenuBarHelperCoordinator.swift \
  Sources/CodexUsageMonitor/Presentation/MenuBarVisibilityStore.swift \
  Sources/CodexUsageMonitor/Presentation/SettingsView.swift \
  Sources/CodexUsageMonitor/App/AppDelegate.swift \
  Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift \
  Tests/CodexUsageMonitorTests/AppLaunchCoordinatorTests.swift \
  Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift
git commit -m "feat: manage an independent menu bar helper"
```

---

### Task 4: 扩展主程序 URL 操作路由

**Files:**
- Modify: `Sources/CodexUsageMonitor/App/AppLaunchCoordinator.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/SettingsWindowPresenter.swift`
- Modify: `Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift`
- Modify: `Tests/CodexUsageMonitorTests/AppLaunchCoordinatorTests.swift`

**Interfaces:**
- Produces: `UsageRefreshRequesting.retry() async`
- Produces: `SettingsPresenting.showSettings()`
- Handles: `codexusagemonitor://dashboard`、`refresh`、`settings`

- [ ] **Step 1: 写入三条精确 URL 的路由测试**

在 `AppLaunchCoordinatorTests` 添加：

```swift
@MainActor
@Test func helperURLsRouteDashboardRefreshAndSettings() async {
    let dashboard = DashboardPresenterSpy()
    let refresher = UsageRefreshRequesterSpy()
    let settings = SettingsPresenterSpy()
    let coordinator = AppLaunchCoordinator(
        arguments: [],
        runtime: AppRuntimeLauncherSpy(),
        dashboard: dashboard,
        launchAtLogin: AppLaunchAtLoginSpy(),
        refresher: refresher,
        settings: settings
    )

    coordinator.handle(urls: [
        URL(string: "codexusagemonitor://dashboard")!,
        URL(string: "codexusagemonitor://refresh")!,
        URL(string: "codexusagemonitor://settings")!,
    ])
    await Task.yield()

    #expect(dashboard.showCount == 1)
    #expect(await refresher.refreshCount == 1)
    #expect(settings.showCount == 1)
}
```

把无效 URL 测试扩充 `codexusagemonitor://refresh/path` 与 `codexusagemonitor://settings?x=1`，继续要求全部忽略。

- [ ] **Step 2: 运行测试并确认缺少注入点**

```bash
swift test --filter helperURLsRouteDashboardRefreshAndSettings
```

Expected: FAIL，初始化器没有 `refresher` 或 `settings` 参数。

- [ ] **Step 3: 实现路由接口和设置窗口适配器**

在 `AppLaunchCoordinator.swift` 定义：

```swift
@MainActor protocol UsageRefreshRequesting: AnyObject {
    func retry() async
}
extension UsageViewModel: UsageRefreshRequesting {}

@MainActor protocol SettingsPresenting: AnyObject {
    func showSettings()
}
```

创建 `SettingsWindowPresenter.swift`：

```swift
import AppKit

@MainActor
final class SettingsWindowPresenter: SettingsPresenting {
    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: nil
        )
    }
}
```

`AppLaunchCoordinator.handle(urls:)` 只接受三个完整字符串：

```swift
func handle(urls: [URL]) {
    for url in urls {
        switch url.absoluteString {
        case "codexusagemonitor://dashboard":
            dashboard.showDashboard()
        case "codexusagemonitor://refresh":
            Task { [weak self] in await self?.refresher.retry() }
        case "codexusagemonitor://settings":
            settings.showSettings()
        default:
            continue
        }
    }
}
```

所有生产初始化调用注入同一个 `UsageViewModel` 和 `SettingsWindowPresenter`；测试使用 spy。

- [ ] **Step 4: 运行路由和完整启动测试**

```bash
swift test --filter AppLaunchCoordinatorTests
```

Expected: PASS，原有 Widget dashboard URL 与 reopen 行为不回归。

- [ ] **Step 5: 提交 URL 路由**

```bash
git add Sources/CodexUsageMonitor/App/AppLaunchCoordinator.swift \
  Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift \
  Sources/CodexUsageMonitor/Presentation/SettingsWindowPresenter.swift \
  Tests/CodexUsageMonitorTests/AppLaunchCoordinatorTests.swift
git commit -m "feat: route menu helper actions to the main app"
```

---

### Task 5: 实现助手应用、状态项与轻量面板

**Files:**
- Create: `Sources/CodexUsageMenuBar/MenuBarApplicationDelegate.swift`
- Create: `Sources/CodexUsageMenuBar/MenuBarStatusController.swift`
- Create: `Sources/CodexUsageMenuBar/MenuBarPopoverView.swift`
- Create: `Sources/CodexUsageMenuBar/MenuBarActionRouter.swift`
- Create: `Sources/CodexUsageMenuBarCore/MenuBarAction.swift`
- Create: `Tests/CodexUsageMenuBarCoreTests/MenuBarActionTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `MenuBarSnapshotModel`、`MenuBarSnapshotMonitor`
- Produces: `MenuBarAction.dashboard` / `refresh` / `settings`
- Produces: 独立 `NSStatusItem` 与 420×430 `NSPopover`

- [ ] **Step 1: 写入动作 URL 和标题格式测试**

创建 `MenuBarActionTests.swift`：

```swift
import CodexUsageShared
import Foundation
import Testing
@testable import CodexUsageMenuBarCore

@Suite struct MenuBarActionTests {
    @Test func actionsUseExactMainApplicationURLs() {
        #expect(MenuBarAction.dashboard.url.absoluteString ==
            "codexusagemonitor://dashboard")
        #expect(MenuBarAction.refresh.url.absoluteString ==
            "codexusagemonitor://refresh")
        #expect(MenuBarAction.settings.url.absoluteString ==
            "codexusagemonitor://settings")
    }

    @Test func titleHidesMissingFiveHourLimit() {
        let model = WidgetDisplayModel(snapshot: .placeholder, now: .now)
        let title = MenuBarHelperFormatting.accessibilityTitle(model)
        #expect(title.contains("周"))
        #expect(!title.contains("5 小时"))
    }
}
```

- [ ] **Step 2: 运行测试并确认动作类型不存在**

```bash
swift test --filter MenuBarActionTests
```

Expected: FAIL，提示 `MenuBarAction` 未定义。

- [ ] **Step 3: 在 Core 中实现动作和纯格式逻辑**

创建 `MenuBarAction.swift`：

```swift
import CodexUsageShared
import Foundation

public enum MenuBarAction: Sendable {
    case dashboard
    case refresh
    case settings

    public var url: URL {
        switch self {
        case .dashboard: URL(string: "codexusagemonitor://dashboard")!
        case .refresh: URL(string: "codexusagemonitor://refresh")!
        case .settings: URL(string: "codexusagemonitor://settings")!
        }
    }
}

public enum MenuBarHelperFormatting {
    public static func accessibilityTitle(
        _ model: WidgetDisplayModel
    ) -> String {
        let medium = model.medium
        var parts: [String] = []
        if let fiveHour = medium.fiveHourRemainingPercent {
            parts.append("5 小时 \(WidgetDisplayFormatting.percent(fiveHour))")
        }
        if let week = medium.weekRemainingPercent {
            parts.append("周 \(WidgetDisplayFormatting.percent(week))")
        }
        return parts.isEmpty ? "Codex 用量" : parts.joined(separator: "，")
    }
}
```

- [ ] **Step 4: 实现动作路由**

`MenuBarActionRouter.perform(_:)` 对三个动作调用 `NSWorkspace.shared.open(action.url)`。`quitAll()` 只终止 Bundle ID `com.amenggod.CodexUsageMonitor` 的主程序，然后调用 `NSApp.terminate(nil)` 退出助手。

- [ ] **Step 5: 实现轻量 SwiftUI 面板**

`MenuBarPopoverView` 使用 `@Bindable var model: MenuBarSnapshotModel` 和 `model.display.medium`。固定显示今日、总计、周额度、可用时的 5 小时额度、前三项目和 `statusText`。底部按钮调用 `refresh`、`settings`、`dashboard`、`quitAll`。不得使用 `TimelineView`、动画 Timer、SQLite 或主程序 ViewModel。

额度布局必须遵守：

```swift
if let fiveHour = presentation.fiveHourRemainingPercent {
    LimitRow(title: "5 小时剩余", remaining: fiveHour)
}
if let week = presentation.weekRemainingPercent {
    LimitRow(title: "周剩余", remaining: week)
} else {
    Text("等待周限额").foregroundStyle(.secondary)
}
```

- [ ] **Step 6: 实现状态项和应用入口**

`MenuBarStatusController` 创建固定 26pt 的 `NSStatusItem`，使用 18×18 `chart.bar.fill` 模板图标，点击切换 420×430 `NSPopover`。用 Observation 的 `withObservationTracking` 监听 `model.display`，只在模型变化时更新 tooltip 和辅助功能标签，不创建刷新 Timer。

`MenuBarApplicationDelegate.static main()` 创建 `NSApplication.shared`、设置 `.accessory`、安装 delegate 并运行事件循环。启动时构造 `WidgetSnapshotStore.appGroup()`、`DarwinSnapshotChangeObserver`、`TimerMenuBarFallbackScheduler`、monitor、status controller 和 action router。App Group 不可用时注入始终返回 `nil` 的 reader，面板显示等待同步而不是崩溃。

- [ ] **Step 7: 注册 SwiftPM 助手可执行目标并测试**

在 `Package.swift` 添加：

```swift
.executable(
    name: "CodexUsageMenuBar",
    targets: ["CodexUsageMenuBar"]
),
.executableTarget(
    name: "CodexUsageMenuBar",
    dependencies: ["CodexUsageShared", "CodexUsageMenuBarCore"]
),
```

Run:

```bash
swift test --filter MenuBarActionTests
swift build --product CodexUsageMenuBar
```

Expected: PASS，助手可执行目标构建成功。

- [ ] **Step 8: 提交助手应用**

```bash
git add Package.swift Sources/CodexUsageMenuBar \
  Sources/CodexUsageMenuBarCore/MenuBarAction.swift \
  Tests/CodexUsageMenuBarCoreTests/MenuBarActionTests.swift
git commit -m "feat: add native menu bar helper app"
```

---

### Task 6: 嵌入、签名并删除旧状态项实现

**Files:**
- Create: `Config/MenuBar-Info.plist`
- Create: `Config/CodexUsageMenuBar.entitlements`
- Modify: `project.yml`
- Modify: `Scripts/verify-bundle.sh`
- Modify: `Scripts/test-verify-bundle-signing.sh`
- Delete: `Sources/CodexUsageMonitor/Presentation/AppKitMenuBarController.swift`
- Modify: `Tests/CodexUsageMonitorTests/MenuBarFormattingTests.swift`
- Modify: `README.md`

**Interfaces:**
- Produces: `Contents/Library/LoginItems/CodexUsageMenuBar.app`
- Produces: 助手的 App Group entitlement 和统一签名校验
- Removes: 主 Bundle ID 创建的旧 `NSStatusItem`

- [ ] **Step 1: 扩充 bundle fixture 测试**

在 `Scripts/test-verify-bundle-signing.sh` 的基础 fixture 创建 `CodexUsageMenuBar.app`，Bundle ID 为 `com.amenggod.CodexUsageMonitor.MenuBar`，可执行名为 `CodexUsageMenuBar`，`LSUIElement = true`。增加矩阵：缺少助手、Bundle ID 错误、`LSUIElement` 缺失、签名 Team 不一致必须失败；完整 fixture 必须通过。

- [ ] **Step 2: 运行脚本并确认 verifier 尚未覆盖助手**

```bash
bash Scripts/test-verify-bundle-signing.sh
```

Expected: FAIL，至少“缺少助手仍被接受”矩阵失败。

- [ ] **Step 3: 添加 XcodeGen 助手目标和嵌入规则**

在 `project.yml` 添加：

```yaml
  CodexUsageMenuBar:
    type: application
    platform: macOS
    sources:
      - Sources/CodexUsageMenuBar
      - Sources/CodexUsageMenuBarCore
    dependencies:
      - target: CodexUsageShared
    info:
      path: Config/MenuBar-Info.plist
      properties:
        CFBundleDisplayName: Codex Usage Menu Bar
        CFBundleExecutable: $(EXECUTABLE_NAME)
        CFBundleIdentifier: $(PRODUCT_BUNDLE_IDENTIFIER)
        CFBundlePackageType: APPL
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSUIElement: true
    entitlements:
      path: Config/CodexUsageMenuBar.entitlements
      properties:
        com.apple.security.application-groups:
          - ZD9PK3NY5Z.CodexUsageMonitor.shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.amenggod.CodexUsageMonitor.MenuBar
        PRODUCT_NAME: CodexUsageMenuBar
        SKIP_INSTALL: YES
```

主应用 dependencies 增加不链接的助手目标，`Embed Login Item` 脚本同时 `ditto` `CodexUsageMenuBar.app`。把所有显式 `CURRENT_PROJECT_VERSION` 更新为 `10`，然后运行 `bash Scripts/generate-project.sh`。

- [ ] **Step 4: 扩充 bundle verifier**

`verify-bundle.sh` 必须要求两个且仅两个 LoginItems app，验证助手 Bundle ID、可执行名、`LSUIElement`、版本、Team、`CodexUsageShared.framework` 和 App Group。unsigned fixture 也把助手可执行文件纳入“不得伪装成 Apple identity-backed”检查。

- [ ] **Step 5: 删除旧控制器并更新文档**

删除 `AppKitMenuBarController.swift`，清理旧 controller/formatter 测试和所有实例化引用。README 说明独立助手与共享快照，并保留“第三方工具仍可主动隐藏任何状态项”的限制。

Run:

```bash
rg -n 'AppKitMenuBarController|MenuBarControlling|scheduledTimer' \
  Sources/CodexUsageMonitor Tests/CodexUsageMonitorTests
```

Expected: no matches。

- [ ] **Step 6: 运行生成、测试和 unsigned Release 构建**

```bash
bash Scripts/generate-project.sh
git diff --check
bash Scripts/test-verify-bundle-signing.sh
swift test
xcodebuild \
  -project CodexUsageMonitor.xcodeproj \
  -scheme CodexUsageMonitorTests \
  -configuration Debug \
  test
CODE_SIGNING_ALLOWED=NO bash Scripts/build-app.sh
```

Expected: 全部 exit 0；bundle verifier 报告主应用、Widget、登录项、助手和 framework 结构通过。

- [ ] **Step 7: 提交工程和文档**

```bash
git add project.yml Package.swift CodexUsageMonitor.xcodeproj Config \
  Scripts README.md Sources Tests \
  docs/superpowers/specs/2026-07-18-menu-bar-helper-and-idle-cpu-design.md \
  docs/superpowers/plans/2026-07-18-menu-bar-helper.md
git commit -m "feat: embed independent menu bar helper"
```

---

### Task 7: 安装并验证菜单栏现场故障

**Files:**
- Verify: `dist/Codex Usage Monitor.app`
- Install: `/Applications/Codex Usage Monitor.app`

**Interfaces:**
- Verifies: 新助手身份的状态项实际位于当前屏幕
- Verifies: 主程序、助手和 Widget 读取相同快照

- [ ] **Step 1: 构建 Apple Development 安装包**

```bash
CODE_SIGNING_ALLOWED=YES \
DEVELOPMENT_TEAM=ZD9PK3NY5Z \
CODE_SIGN_STYLE=Automatic \
bash Scripts/build-app.sh
```

Expected: exit 0，bundle verifier 确认所有嵌入代码 Team 和 App Group 一致。

- [ ] **Step 2: 原子替换已安装版本**

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

- [ ] **Step 3: 验证状态项实际可见**

用 LLDB 附加 `CodexUsageMenuBar`，打印 `NSApp.windows` 中 `NSStatusBarWindow` 的 frame、screen 和 `occlusionState`。Expected：frame 位于某个 `NSScreen.visibleFrame` 内，`occlusionState` 包含 visible，且不是 `{{0,-17},...}` 一类屏幕外位置。

- [ ] **Step 4: 验证交互和数据一致性**

依次检查图标弹窗、周额度、5 小时隐藏、刷新同步、设置入口、开关启停和 Widget dashboard 深链。主程序、助手和 App Group 快照的周额度必须一致。

- [ ] **Step 5: 运行最终回归**

```bash
swift test
xcodebuild \
  -project CodexUsageMonitor.xcodeproj \
  -scheme CodexUsageMonitorTests \
  -configuration Debug \
  test
bash Scripts/verify-bundle.sh \
  '/Applications/Codex Usage Monitor.app'
git status --short
```

Expected: 测试 0 failures；bundle 验证 exit 0；工作区仅包含用户原有无关改动或为空。

- [ ] **Step 6: 仅在现场发现问题时补回归修正**

先写能复现现场问题的失败测试，再修改并提交：

```bash
git add Sources Tests project.yml Scripts README.md
git commit -m "fix: complete menu bar helper integration"
```
