# CPU Task 5 — 完整回归、签名安装与现场验收

## 状态

完成。Apple Development build 10 已安装到 `/Applications/Codex Usage Monitor.app`，主应用、菜单栏 Helper 与 Widget 共享正式安装包和 App Group。空闲 CPU 与短生命周期 app-server 现场验收通过。

## 文档修正

- README 明确实时限额每 60 秒或用户手动触发。
- 每次限额读取都执行 `start → initialize → account/rateLimits/read → stop`。
- 同步瞬间允许短峰；两次同步之间不保留主应用启动的 app-server 子进程。
- WidgetKit 由 macOS 调度，不承诺严格分钟级或秒级重绘。

## 回归验证

- `Scripts/test-idle-cpu-contracts.sh`：PASS。
- `Scripts/test-ci-contracts.sh`：PASS。
- SwiftPM：311/311 PASS。
- `UsageViewModelTests` 条件式等待修复后连续 5 次 21/21 PASS。
- Xcode：重新生成项目后，以 `-skipMacroValidation` 运行，306/306 PASS，`** TEST SUCCEEDED **`。
- `git diff --check`：PASS。
- unsigned build：`** BUILD SUCCEEDED **`。
- 签名 fixture 矩阵：`Signed and unsigned bundle verification contracts passed.`。

初次验收的三个失败均已定位而未绕过：签名 fixture 缺少前置 unsigned app；Xcode 未信任锁定的 swift-testing 宏且生成项目尚未纳入 `ProcessTerminationWaiter.swift`；三个 UsageViewModel 测试依赖固定 50ms 等待，在全套并发调度下会观察到更新前初始态。正确前置、项目生成和条件式完成等待修复后全部通过。

## 签名构建与安装

- 版本：0.2.3（build 10）。
- Team：`ZD9PK3NY5Z`。
- Identity：Apple Development `mfc17@163.com (7WV83V279S)`。
- 主 App、Widget、LoginItem、MenuBar Helper 均通过 `codesign --verify --deep --strict`。
- 主 App、Widget 与 MenuBar Helper 的 App Group 均为 `ZD9PK3NY5Z.CodexUsageMonitor.shared`。
- 通过 `.new` staging、严格验证和 APFS `RENAME_SWAP` 原子替换安装；旧 bundle 已清理，dist App 与 ZIP 保留。
- 启动后主应用与 Helper 各 1 个实例。

## 功能现场证据

- `codexusagemonitor://settings` 成功打开 SwiftUI Settings 窗口。
- 设置中“显示菜单栏图标”为开启。
- Helper 拥有唯一 `NSStatusBarWindow`，frame `{{936, 923}, {42, 33}}`，`visible=true`、`occlusionVisible=true`。
- Helper 辅助功能标签在刷新后为“周 81%”，帮助文本为“更新于 20:11”。
- 同一时刻主界面为周 81%、今日 Token 205,651,457；App Group 快照为周 81%、今日 Token 205,651,457。
- 后续正式版 Widget 重新注册与刷新后，快照更新时间为 20:16，主界面今日 Token 208,418,638；Widget 进程来自 `/Applications` 正式安装路径。
- WidgetKit 注册表原有两个派生构建副本已注销；最终只保留 `/Applications/Codex Usage Monitor.app/.../CodexUsageMonitorWidget.appex` 一份注册。
- 当前桌面 Space 没有放置可见 Codex 小组件，因此没有把桌面截图冒充为 Widget 数值证据；共享快照、正式扩展注册与正式扩展进程均已验证。

## app-server 生命周期

手动刷新期间以 50ms 间隔观察主应用子进程：app-server 在 20:10:25 短暂出现，约 1.6 秒后退出。12 秒监控结束时无子进程。后续 60 秒自动轮询只在一个 5 秒采样点看到子进程，下一采样即消失。

## 两分钟空闲 CPU

关闭主窗口后，自 20:12:15 至 20:14:16 每 5 秒采样，共 25 个样本：

- 主应用：25/25 为 0.0%。
- MenuBar Helper：25/25 为 0.0%。
- app-server 子进程：24/25 为 0；唯一一次在自动分钟同步时短暂为 1，5 秒后恢复为 0。

原现场约 22.5% + 13% 的持续占用未再出现。

## 留存范围

- `ProcessTerminationWaiter` timeout/cancellation 与强制 SIGKILL 升级路径缺少直接单元测试，已记录为非阻断后续项；当前真实 TERM 退出、stderr 压力、并发 stop/start/stop 与现场子进程回收均已覆盖并通过。
