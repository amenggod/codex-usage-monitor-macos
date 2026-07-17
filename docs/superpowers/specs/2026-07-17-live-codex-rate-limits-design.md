# Codex Usage Monitor 实时限额数据源设计

日期：2026-07-17
状态：已于 2026-07-17 获用户确认
目标平台：macOS 14 及以上
已验证 Codex CLI：`0.145.0-alpha.18`

## 1. 背景与根因

当前程序的刷新按钮只重新扫描 `~/.codex/sessions` 与 `~/.codex/archived_sessions`。Token 总量、项目排行和共享快照时间会更新，但周限额来自 SQLite 中最后一次被选中的本地日志观察值。

实机诊断确认：

- 程序数据库中的 `codex/prolite` 周限额最后观察于 2026-07-14 15:41:35，`used_percent = 27`，因此一直显示剩余 73%；
- 2026-07-17 的新日志主要包含另一个 `codex_bengalfox` 限额桶，没有更新 `codex/prolite` 的当前值；
- 点击刷新后共享快照的 `generatedAt` 和 Token 总量变新，但旧的 73% 被原样再次发布；
- 本机 Codex app-server 的 `account/rateLimits/read` 同时返回 `codex` 与 `codex_bengalfox`，其中 `codex/prolite.usedPercent = 31`，即剩余 69%，与 ChatGPT 桌面程序一致；
- app-server 协议还提供 `account/rateLimits/updated`，用于接收滚动限额更新。

因此根因不是界面缓存，而是剩余量仍以会话日志为权威数据源。“fresh”当前只代表本地扫描成功，不代表限额观察是新的。

## 2. 目标

- `codex` 账户限额以 Codex app-server 的实时响应为权威来源。
- 应用启动后自动读取一次限额，并持续接收滚动更新。
- 点击刷新时强制读取一次最新限额，同时继续刷新本地 Token 日志。
- 主窗口、菜单栏、桌面 Widget 和限额通知使用同一份实时限额状态。
- 正确区分 `codex` 与模型专属桶，例如 `codex_bengalfox`；默认界面显示账户主桶 `codex`。
- app-server 不可用、协议不兼容或响应过期时，不继续把旧日志值标记为实时。
- 5 小时窗口不存在时继续完全隐藏。
- 不读取、复制、保存或输出 ChatGPT 登录令牌、提示词、回复或其他会话正文。

## 3. 非目标

- 不抓取 ChatGPT 网页、Cookie、浏览器缓存或私有 HTTP 接口。
- 不调用 `account/rateLimitResetCredit/consume`，不自动消耗限额重置次数。
- 不展示模型专属限额桶选择器；本阶段只显示账户主桶 `codex`。
- 不改变 Token 消耗量与项目排行的本地日志统计方式。
- 不承诺 WidgetKit 秒级绘制；主程序会立即请求刷新，但最终显示调度仍由 macOS 管理。
- 不把 Codex app-server 的完整响应或 credits 信息写入 App Group 快照。

## 4. 方案比较

### 4.1 长连接 Codex app-server

主程序启动一个用户态 `codex app-server --stdio` 子进程，完成 `initialize` 后调用 `account/rateLimits/read`，并监听 `account/rateLimits/updated`。收到滚动通知时重新读取完整快照，避免错误合并稀疏字段。

优点是首次读取准确、支持实时更新、刷新按钮可以立即强制读取，并且使用 Codex 自己的认证状态。缺点是 app-server 当前标记为 experimental，需要协议兼容和进程恢复处理。

采用该方案。

### 4.2 每次刷新启动临时进程

每次点击刷新时启动 app-server、初始化、读取一次后退出。实现边界简单，但无法自动接收限额变化，频繁创建进程，主程序后台运行时也不会及时提醒。

不采用。

### 4.3 继续读取本地日志并增加过期时间

可以避免无限显示旧值，但日志可能缺少账户主桶或只出现模型专属桶，无法满足“实时准确”。

只保留为诊断信息，不再作为正常界面的权威数值来源。

## 5. 组件与职责

### 5.1 `CodexExecutableLocator`

只负责找到可运行的 Codex 二进制，顺序为：

1. 通过 bundle identifier `com.openai.codex` 定位应用，并检查其 `Contents/Resources/codex`；
2. 固定兼容路径 `/Applications/ChatGPT.app/Contents/Resources/codex`；
3. 进程环境 `PATH` 中的 `codex`。

找到的文件必须存在、可执行，并通过启动握手验证。找不到时返回可理解错误，不尝试下载、安装或修改 Codex。

### 5.2 `CodexAppServerTransport`

Actor 封装 `Process`、stdin、stdout 与 stderr：

- 启动 `codex app-server --stdio`；
- 发送逐行 JSON 请求；
- 以请求 ID 配对响应；
- 把服务端通知发布为 `AsyncStream`；
- 限制 stderr 只保留脱敏状态，不输出响应正文；
- 进程退出或管道损坏时结束当前连接并允许上层重连；
- 应用退出时终止子进程并关闭管道。

初始化请求必须包含独立客户端名称、版本和 `experimentalApi: true`。传输层不理解业务限额，也不写数据库。

### 5.3 `CodexRateLimitService`

Actor 负责业务协议：

- 连接并初始化 app-server；
- 调用 `account/rateLimits/read`；
- 从 `rateLimitsByLimitId["codex"]` 读取账户主桶；若多桶字段缺失，再使用单桶 `rateLimits` 且要求 `limitId == "codex"`；
- 把 `usedPercent`、`windowDurationMins`、`resetsAt` 与 `planType` 转换成现有 `RateLimitObservation`；
- 300 分钟映射为 5 小时，10080 分钟映射为周，其余窗口不冒充已知限额；
- 收到 `account/rateLimits/updated` 后触发一次完整重新读取，而不是直接用稀疏通知覆盖本地状态；
- 发布 `AsyncStream<RateLimitServiceUpdate>`，供界面刷新、Widget 发布和通知评估；
- 连接失败后采用有限退避重连；用户点击刷新时立即取消等待并重试。

服务不读取 credits 余额，也绝不调用重置额度方法。

### 5.4 `LiveRateLimitStore`

Actor 保存最近一次成功的实时限额与 `observedAt`：

- 成功读取后原子替换当前实时限额；
- 数据超过 10 分钟未能重新验证时标记为 stale；
- stale 值可以短暂显示，但必须带“上次实时同步”状态，且不得触发新的阈值通知；
- app-server 从未成功或最后成功超过 30 分钟时，完全隐藏数值并显示“实时限额不可用”；
- 本地日志限额只用于诊断，不提升为 fresh，不覆盖曾成功读取的实时值。

该状态与 Token 扫描新鲜度分开，避免“日志 fresh”掩盖“限额 stale”。

对外状态使用一个明确的 `LiveRateLimitState`：

- `fresh(limits: [LimitStatus], observedAt: Date)`；
- `stale(limits: [LimitStatus], observedAt: Date)`；
- `unavailable(lastSuccessfulAt: Date?, message: String)`。

聚合层和通知层只消费该状态，不直接读取 app-server JSON 或日志限额表。

### 5.5 聚合、视图模型与 Widget 发布

`UsageAggregator` 继续从 SQLite 聚合 Token，但限额改由 `LiveRateLimitStore` 提供。`UsageViewModel` 同时消费文件扫描更新和限额服务更新：任一数据源变化都生成新的 Dashboard 快照。

点击刷新执行两个独立动作：

1. `coordinator.rescanAll()` 刷新 Token；
2. `rateLimitService.refresh()` 强制读取实时限额。

任何一个失败都不抹掉另一个成功结果。限额成功后立即更新主窗口、菜单栏、通知评估和 App Group 快照，并请求 WidgetKit 重载时间线。

`DashboardSnapshot` 增加 `limitFreshness`，与现有 Token `freshness` 分离。`WidgetUsageSnapshot` schema 升级为 2，并增加 `limitFreshness`；其值为 `fresh(observedAt)`、`stale(observedAt)` 或 `unavailable`。Widget 只显示 fresh 或允许短暂 stale 的实时限额；超过 30 分钟后不显示旧百分比。旧 schema 1 快照在主程序发布 schema 2 前显示等待同步，不继续显示旧限额。

## 6. 数据优先级与选择规则

显示与通知只选择 `limitId == "codex"` 的账户主桶：

1. 10 分钟内成功读取的 app-server 值：fresh，可显示、可通知；
2. 10 至 30 分钟内最后成功的 app-server 值：stale，可显示并标注时间，不发送新通知；
3. 超过 30 分钟或从未成功：unavailable，隐藏剩余百分比；
4. `codex_bengalfox` 等模型专属桶不替代 `codex`；
5. 本地日志值不再覆盖上述状态。

若 app-server 返回的 5 小时窗口为空，5 小时内容立即隐藏。周窗口为空时显示“等待实时周限额”，不沿用 73% 等旧日志值。

## 7. 进程恢复与协议兼容

- 首次启动、Codex 更新或 app-server 异常退出时，服务最多立即重试一次，随后采用 5 秒、30 秒、2 分钟的有限退避；成功后重置退避。
- 初始化和每次读取请求各自使用 10 秒超时；超时只影响限额状态，不阻塞本地 Token 扫描和窗口启动。
- 未知 JSON 字段全部忽略；缺失必需字段得到解码失败，不产生 0% 或 100% 假值。
- 方法不存在或 experimental API 被移除时，界面进入 unavailable，并保留明确错误摘要。
- Codex 二进制版本变化后重新握手，不复用旧协议假设。
- app-server 子进程继承用户现有 Codex 登录状态，但应用不读取或保存认证令牌。

## 8. 提醒规则

- 仅 fresh 的 `codex` 主桶参与 20% 和 10% 阈值判断。
- stale、unavailable、模型专属桶和本地日志备用值不触发新提醒。
- 现有“限额 ID + 重置时间 + 阈值”通知去重规则继续使用。
- fresh 数据恢复后重新评估；同一重置周期已经发送的阈值不重复发送。

## 9. 隐私与安全

- 只发送 `initialize` 与只读的 `account/rateLimits/read`。
- 不发送任务、提示词、项目路径或会话正文。
- 不读取 ChatGPT Cookie、Keychain 登录令牌或网络请求头。
- 不把 app-server 的完整 JSON、credits 或重置券信息写入数据库、日志或 Widget 快照。
- 错误日志只包含协议阶段、错误类别和 Codex 版本，不包含响应正文。
- 子进程权限不高于当前用户，不请求管理员权限。

## 10. 测试设计

### 10.1 协议与解码

- `codex/prolite` 返回 `usedPercent = 31` 时生成周剩余 69%；
- 同时存在 `codex` 与 `codex_bengalfox` 时只选择 `codex`；
- `rateLimitsByLimitId` 缺失时正确使用合法的单桶兼容字段；
- 缺少 `usedPercent`、窗口或错误类型时不生成假值；
- 缺少 5 小时窗口时不生成 5 小时限额；
- 未知字段不影响解码。

### 10.2 传输与生命周期

- 初始化成功后才发送限额读取请求；
- 请求 ID 与响应正确配对；
- `account/rateLimits/updated` 触发完整重新读取；
- 进程异常退出、超时和损坏 JSON 不会卡住主线程；
- 手动刷新绕过退避并立即请求；
- 停止服务会终止子进程和所有待处理请求。

### 10.3 数据新鲜度

- 10 分钟内为 fresh；
- 10 至 30 分钟为 stale，显示更新时间但不通知；
- 超过 30 分钟为 unavailable，不显示百分比；
- 日志重新扫描不能把旧 73% 覆盖到实时 69%；
- 模型专属 0% 不能覆盖账户主桶 31%。

### 10.4 界面与 Widget

- 启动后的首次实时读取更新主窗口、菜单栏和共享快照；
- 点击刷新同时触发 Token 重扫和实时限额读取；
- 实时限额通知到达后无需点击即可刷新；
- 69% 被写入 Widget 快照，旧 73% 被替换；
- 实时接口不可用时主界面与 Widget 不继续标记旧值为 fresh；
- 限额失败不影响 Token 总量与项目排行更新。

### 10.5 实机验证

- 在已登录的 ChatGPT/Codex 环境调用 `account/rateLimits/read`，主桶结果与 ChatGPT Usage 页面一致；
- 点击刷新后 5 秒内主窗口与 App Group 快照匹配实时响应；
- 收到 `account/rateLimits/updated` 后 5 秒内主窗口状态更新；
- WidgetKit 接受新的时间线并显示相同剩余量；
- 断开或终止 app-server 后 Token 统计继续工作，限额按 10/30 分钟规则降级；
- 完整 Swift 测试、Xcode 构建、签名、App Group 和 GitHub CI 全部通过。

## 11. 验收标准

- 当前实机 `account/rateLimits/read` 返回已使用 31% 时，主窗口与 Widget 显示剩余 69%，不再显示 73%。
- 点击刷新会产生新的实时限额请求，而不只是重扫日志。
- 限额服务更新可以自动传播到主窗口、菜单栏、提醒和 Widget。
- `codex_bengalfox` 的 0% 不会覆盖 `codex` 的 31%。
- app-server 不可用或数据超过 30 分钟时不显示误导性的旧百分比。
- 5 小时窗口不存在时保持隐藏。
- 不访问或持久化认证令牌、提示词或 app-server 完整响应。
