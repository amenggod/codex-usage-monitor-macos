# Codex Usage Monitor

## 概览

Codex Usage Monitor 是一款 macOS 本地用量查看工具，提供小号与中号系统桌面小组件、完整仪表盘和可单独开关的菜单栏图标。主应用在本机汇总 Codex usage JSONL 中的 Token 用量与限额状态，并把专供 WidgetKit 展示的脱敏快照写入 App Group。

本项目是非官方开源项目，与 OpenAI 没有隶属关系，也未获得 OpenAI 的认可或背书。Codex 和 OpenAI 是其各自权利人的商标。

## 功能

- 小号和中号 WidgetKit 小组件显示今日、全部时间、项目与有效限额的精简信息。
- 点击任一小组件都会打开同一个完整仪表盘窗口，不会重复创建窗口。
- 菜单栏图标可在设置中单独开关；这不会添加或移除系统桌面小组件。
- 显示有效的 5 小时和每周限额；5 小时限制缺失或过期时会按设计隐藏。
- 查看今日、最近 7 天和全部时间的 Token 总量，并按项目汇总用量。
- 显示限额重置时间、数据新鲜度和读取失败状态。
- 增量监听当前与已归档的 Codex 会话日志，支持重新扫描和重建本地索引。
- 可选的限额通知与登录时启动；登录启动会静默监控，不自动打开窗口。

## 系统与开发要求

- macOS 14 Sonoma 或更高版本。
- 从源码构建需要 Xcode 26.3 或更高版本。
- 项目生成固定使用 XcodeGen 2.45.4；运行 `bash Scripts/generate-project.sh` 会拒绝其他版本。
- 当前构建脚本生成当前 Mac 主机架构的应用，不是通用二进制。

## 添加、使用与移除小组件

添加小组件：

1. 先启动一次已正确签名的 Codex Usage Monitor。
2. 右键桌面空白处，选择“编辑小组件”。
3. 搜索“Codex Usage Monitor”。
4. 选择小号或中号并添加；可以同时添加两种尺寸。

应用不能自动把系统小组件固定到桌面。若要移除，请右键对应小组件并选择“移除小组件”，也可重新进入“编辑小组件”后使用移除控件。移除系统小组件不会退出主应用或清除本地数据。

点击小组件会通过 `codexusagemonitor://dashboard` 打开单例完整仪表盘。小组件显示 App Group 中最后一次成功共享的快照；WidgetKit 决定刷新时机，因此它可能晚于完整应用更新，不承诺秒级刷新。

主应用必须在后台运行，新的 Codex 日志事件才会被监控并写入共享快照。退出主应用后，小组件仍可显示最后快照，但会逐渐标记为陈旧；在主应用再次运行并成功共享前，不会获得新的日志用量。5 小时限制缺失或超过重置时间时会从小组件和完整应用中隐藏，这是预期行为。

## 设置

- **显示菜单栏图标**：只控制菜单栏入口，不影响已添加的系统小组件。
- **登录时启动**：登录后静默启动主应用并继续监控，不自动打开仪表盘。macOS 要求批准时，请在“系统设置 > 通用 > 登录项与扩展”中确认。
- **低用量提醒**：只有用户主动启用时才请求通知权限；可分别控制 20% 和 10% 阈值。
- **重新扫描**：重新检查当前与归档日志，但不删除源 JSONL。
- **小组件共享状态**：App Group 不可用或快照写入失败时显示错误；主仪表盘成功数据不会因此被替换。

## 隐私边界

主应用只在本机扫描 `CODEX_HOME` 指向目录中的 Codex usage JSONL；未设置时使用 `~/.codex`。扫描范围仅包括：

- `sessions/**/*.jsonl`
- `archived_sessions/**/*.jsonl`

解析器只使用会话标识、工作目录、Token 计数、限额百分比和重置时间，不读取或持久化提示内容，也不索引回复正文、工具输出或凭据。SQLite 汇总索引只由主应用打开，保存在用户的 Application Support 目录中；Widget Extension 不打开 SQLite。

主应用写入 App Group 的 `widget-usage-v1.json` 只保存脱敏展示快照：生成时间、汇总 Token、有效限额、最多三个项目的展示名称与用量，以及数据状态。App Group 只保存脱敏快照，不包含 prompt、response、tool output、credentials、完整路径或原始事件。

共享项目 ID 是根据主应用项目键生成的 SHA-256 opaque 值，不是原始路径；项目名称仍是用于界面展示的末级名称。Widget Extension 不扫描 `~/.codex`，不打开 SQLite，不读取源 JSONL，也不发送通知。网络上传不属于本应用的数据路径。

主应用中的工作目录用于项目归类；完整路径只可能在完整仪表盘的鼠标悬停帮助中显示，不会进入 App Group 快照、通知正文或显式辅助功能标签。若不希望主应用继续读取日志，请退出应用或不要授予相关文件访问权限。

## 构建与验证

在仓库根目录运行 Swift Package 测试：

```bash
swift test
```

生成 Xcode 项目并确认生成结果已提交：

```bash
bash Scripts/generate-project.sh
git diff --exit-code -- CodexUsageMonitor.xcodeproj Config
```

生成 unsigned CI 验证产物：

```bash
CODE_SIGNING_ALLOWED=NO bash Scripts/build-app.sh
```

产物位于：

- `dist/Codex Usage Monitor.app`
- `dist/Codex-Usage-Monitor-macOS.zip`

unsigned CI ZIP 只是编译与包结构验证产物，没有 identity-backed 签名或 bundle resource seal，不是可安装、已公证的发布版。Mach-O 可带 linker 或 ad-hoc 签名，这不等于 Apple Development 或 Developer ID 签名。

### 签名、App Group 与发布分级

原生小组件只有在主应用和 Widget Extension 使用匹配签名并同时具备匹配 App Group entitlement 时，才具备可分发构建所需的共享容器条件。所有嵌入代码还必须由同一 Team 正确签名。

- **unsigned CI 构建**：仅证明编译和包结构通过，不用于安装、Widget Gallery 发现或公证声明。
- **Apple Development 构建**：仅供开发者在当前 Mac 上验证主应用、小组件发现和 App Group 共享；它不是面向其他用户分发的 Developer ID 公证版。
- **Developer ID 发布**：只有同时通过四道门槛才可作为发布版：① 主应用、Widget、登录项和嵌入 framework 均使用同一 Team 的 Developer ID Application identity-backed 签名，并保留匹配的 App Group entitlement；② 签名后 bundle 通过严格签名验证；③ Apple 公证返回 accepted；④ 公证票据完成 stapling 并再次验证。仓库脚本和当前 unsigned ZIP 不代表这些步骤已经完成。

贡献者必须在自己的构建环境中设置 Team、主应用/Widget/登录项 bundle IDs 和唯一 App Group，并让主应用与 Widget entitlement 保持一致。不要提交证书、私钥、Apple ID、app-specific password、API key、provisioning profile 或其他签名秘密。修改 `project.yml` 后使用 XcodeGen 2.45.4 重新生成项目。

可使用调用方提供的开发签名参数构建：

```bash
CODE_SIGNING_ALLOWED=YES \
DEVELOPMENT_TEAM=YOUR_TEAM_ID \
CODE_SIGN_STYLE=Automatic \
bash Scripts/build-app.sh
```

此命令是否产生可运行的 Apple Development 构建取决于当前 Mac 的证书、provisioning、bundle IDs 与 App Group 配置；它只用于本机验证，不会自动完成 Developer ID 公证发布。正式分发前应通过上述四道门槛，并在目标 macOS 上另行完成安装测试。

## 索引迁移与重建

在完整仪表盘中点击“重建”（提示为“清空本地索引并重新构建”），应用会清空本地 SQLite 汇总索引并重新扫描所有当前及已归档会话。只有这项由用户触发的显式重建会显示逐文件进度，例如“正在重建 · 3/8”。此操作不会修改或删除源 JSONL。

从 v1 首次升级到 v2 时，主应用会迁移数据库并强制完整扫描本地日志，以建立支持多会话文件与分支历史去重的 v2 索引。首次扫描完成前界面保持“正在读取本地用量…”；通知回执、通知阈值、菜单栏显示和登录启动等偏好会保留。原先由应用自身提供的浮动桌面界面不会迁移为系统小组件，用户需按上文步骤在 macOS 中手动添加小组件。

## 故障排查

- **小组件库中找不到应用**：确认使用的是正确签名的开发或发布构建，主应用与 Widget 的 Team、bundle IDs、App Group 和 entitlements 匹配；将应用放在稳定位置并至少启动一次，再重新打开“编辑小组件”。unsigned CI ZIP 不可用来确认 Gallery 发现能力。
- **小组件没有新数据或显示陈旧**：确认主应用仍在后台运行，打开完整仪表盘检查读取状态或执行“重新扫描”，并查看设置中的小组件共享错误。主应用成功写入后仍需等待 WidgetKit 安排刷新。
- **退出后仍显示旧数据**：这是最后共享快照；退出主应用不会清除它，也不会继续扫描。重新启动主应用并完成一次成功刷新后才会更新。
- **没有菜单栏图标**：在设置中打开“显示菜单栏图标”。该开关只影响菜单栏，不影响系统小组件。
- **登录后未静默启动**：在设置中重新打开“登录时启动”，并前往“系统设置 > 通用 > 登录项与扩展”检查是否需要用户批准。启用后登录启动不会自动打开窗口。
- **没有用量数据**：运行 Codex 产生至少一条会话记录，确认 `CODEX_HOME` 或默认 `~/.codex` 目录存在。
- **限额一直缺失**：限额只在 Codex 日志包含 rate-limit 观测时出现；缺失或过期的 5 小时限制会按设计隐藏。
- **Gatekeeper 阻止启动**：先确认产物类型与来源。unsigned CI 产物不是安装包；Apple Development 构建只用于当前 Mac 的本机验证。对可信但未公证的自建版本，按 Finder 和“系统设置 > 隐私与安全性”给出的系统提示处理。面向用户的正式版本应使用 Developer ID 签名并完成 Apple 公证。
- **构建失败**：确认 Xcode 26.3+ 与 XcodeGen 2.45.4 可用，先运行 `bash Scripts/generate-project.sh`、`swift test`，再运行构建脚本定位阶段。

## 已知的格式兼容风险

本项目依赖 Codex 本地 JSONL 日志的现有字段结构。该结构不是本项目控制的稳定公共接口；Codex 更新可能新增、重命名或移除字段，导致部分事件被安全忽略、限额暂时缺失或统计停止更新。遇到兼容问题时请保留隐私脱敏后的最小结构样例并提交 issue，不要上传真实提示词、回复、凭据或完整会话日志。

## 贡献

欢迎提交 issue 和 pull request。贡献前请：

1. 不提交真实 Codex 会话、用户路径、签名证书、凭据或构建产物。
2. 为行为变更添加 Swift Testing 测试，并使用临时 `CODEX_HOME` 和合成 JSONL。
3. 运行 SwiftPM 与 Xcode 测试、生成项目检查、unsigned package/bundle 验证和 `actionlint`。
4. 保持隐私边界：主应用只处理汇总所需字段，Widget 只消费 App Group 中的脱敏快照。

## 许可证

本项目使用 MIT License，详见 [LICENSE](LICENSE)。
