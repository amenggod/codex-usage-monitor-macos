# CPU Task 4 — 等待 app-server 子进程真正退出

## 状态

完成。`CodexAppServerTransport.stop()` 现在会等待真实子进程退出后再返回，并持续排空 stderr，避免短会话退出未回收和 pipe 背压阻塞。

## 改动范围

- `Sources/CodexUsageMonitor/RateLimits/ProcessTerminationWaiter.swift`
- `Sources/CodexUsageMonitor/RateLimits/CodexAppServerTransport.swift`
- `Tests/CodexUsageMonitorTests/CodexAppServerTransportTests.swift`
- `.superpowers/sdd/cpu-task-4-report.md`

未修改菜单栏 Helper 的未提交差异或其他文件。

## 根因

旧 transport 的 `stop()` 关闭 stdin 并调用 `Process.terminate()` 后立即清空 `Process` 引用，没有等待 termination handler，因此返回时子进程可能仍运行或尚未被回收。

stderr 虽然连接到了 `Pipe`，但没有消费者。真实 app-server 或 fixture 持续写 stderr 时，pipe buffer 填满会阻塞子进程，使 stdout response 无法产生，请求最终超时。

## RED 与调查记录

真实 stderr 压力测试在旧实现上稳定得到 `CodexAppServerTransport.TransportError.requestTimedOut`：fixture 每次请求先写约 256 KiB stderr，再发送 JSON response；未排空 stderr 时 response 无法完成。

最初的 PID 测试并不是有效 RED：raw string 把 PID 路径写成了字面量 `#(pidFile.path)`，测试实际超时在等待 PID 文件阶段，尚未调用 `stop()`。修正为 `\#(pidFile.path)` 后，测试才能读取真实 shell PID 并验证 `await stop()` 返回时 `Darwin.kill(pid, 0) == -1 && errno == ESRCH`。该误导已明确保留在报告中，没有把它计作有效的 stop RED。

第一版 `AsyncStream + TaskGroup` waiter 在 timeout 分支可能等待被取消的 stream iterator，完整套件出现挂起。最终实现改为局部 `State`：用 `NSLock` 保护 `terminated` 和 waiter continuation 注册表，termination、timeout、task cancellation 都通过原子 remove 保证 continuation 只 resume 一次。

stderr 最终使用 detached task 中的 64 KiB 块读取。逐字节 `FileHandle.AsyncBytes` 在压力场景下吞吐不足；块读取不会占用 transport actor，也不会在 stop 中被 await。stop 取消 drain task并终止子进程，pipe EOF 会释放阻塞读取。

调查期间，失败测试曾在 request 抛错后跳过末尾 `stop()`，留下 fixture 进程并污染后续 CPU/并发结果。两个新增真实进程测试现统一通过 `withStartedTransport` 在成功和抛错路径都 `await stop()`；最终验证不再使用会提前杀死测试父进程的 watchdog。

## 实现

1. `ProcessTerminationWaiter` 在 `Process.run()` 前安装 termination handler；`init` 只捕获局部 `State`，不捕获未完成初始化的 `self`。
2. waiter 注册 continuation 后附加独立 timeout task；终止、超时和取消竞争时，只有成功从锁内字典移除 waiter 的路径能 resume。
3. transport 持有 termination waiter、stdout task 和 stderr drain task。
4. 重叠 `stop()` 共享同一个 `ActiveStop` task，不会并行执行两套关闭流程。
5. stop 捕获本次 process/waiter/pipe task，关闭 stdin、取消 stdout/stderr task、发送 TERM 并异步等待最多 2 秒。
6. 若进程仍运行，发送 SIGKILL 并继续等待 termination signal；只有 `process.isRunning == false` 后才清空引用并用 `.stopped` 结束 pending requests。
7. 主动 stop 期间 stdout task 的取消不会把 pending request 误报为 `.processExited`；自然退出仍保留原有 `.processExited` 语义。

## GREEN

stderr 压力测试连续运行 5 次，5/5 通过，单次约 0.31–0.77 秒。

```bash
swift test --disable-sandbox --filter drainsStderrWhileRequestIsInFlight
```

完整定向测试：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/codex-swift-cache/clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/codex-swift-cache/clang \
swift test --disable-sandbox --filter CodexAppServerTransportTests

CLANG_MODULE_CACHE_PATH=/private/tmp/codex-swift-cache/clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/codex-swift-cache/clang \
swift test --disable-sandbox --filter CodexRateLimitServiceTests

git diff --check
```

结果：

- `CodexAppServerTransportTests`：5/5 通过。
- `CodexRateLimitServiceTests`：10/10 通过。
- 无 Swift 6 sendability 警告；输出仅有既有的 duplicate rpath 链接警告。
- `git diff --check` 无输出。

## 提交

提交信息：

```text
fix: await app server termination
```

提交仅包含上述四个 Task 4 文件。

## 关注点

- stderr drain task 使用阻塞块读取，因此必须保持在 detached task；stop 不等待该 task，进程退出关闭 pipe 后它会自然结束。
- SIGKILL 分支不会在仍运行时清空 process 引用；如果极端情况下 SIGKILL 后仍报告 running，stop 会继续等待而不是假装完成。
- 测试的 PID 启动等待和 request timeout 已放宽以适应 Swift Testing 并行执行，但 stop 返回后的 ESRCH 仍是即时断言，没有用轮询掩盖过早返回。

## Review fix：停止收尾窗口的重启竞态

Review 发现首个 stop 的 `performStop` 清空 `process` 后、外层 `stop()` 清空旧 `activeStop` 前存在 actor 重入窗口。旧实现允许 `start()` 在该窗口启动新进程；随后第二个 stop 只等待已经完成的旧 `activeStop` 并返回，新进程会逃逸。

新增确定性 gate 测试 `startDuringStopFinalizationCannotEscapeAnOverlappingStop`：测试在 `process` 已清空、旧 `activeStop` 尚存在时暂停 stop，调用 `start()` 和重叠 stop。修复前测试得到有效 RED：最后的 request 成功返回 29 bytes，而预期 transport 已是 `notRunning`。

最小修复是在 `start()` 同时检查 `activeStop == nil` 和 `process == nil`。停止仍在收尾时 start 直接返回，不能创建新 generation；旧 stop 完成并清空 `activeStop` 后，测试再确认 transport 可以正常 start、request 和 stop。

Review fix GREEN：

- 新回归测试：1/1 通过。
- `CodexAppServerTransportTests`：6/6 通过。
- `CodexRateLimitServiceTests`：10/10 通过。
- 并行 transport suite 曾使新 fixture 的 1 秒重启 request 超时；仅将测试预算放宽为 5 秒后全套稳定通过，生命周期断言未放宽。

Review fix 提交信息：

```text
fix: serialize transport restart after stop
```

非阻断 follow-up：waiter timeout/cancel 的直接单元测试，以及忽略 TERM 后进入 2 秒 SIGKILL 路径的真实进程测试尚未单独覆盖；本次按 review 范围不扩展生产设计或拉长测试套件。
