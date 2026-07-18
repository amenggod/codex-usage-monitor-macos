# Codex Usage Monitor

## 概览

Codex Usage Monitor 是一款 macOS 本地用量查看工具，提供小号与中号系统桌面小组件、完整仪表盘和可单独开关的菜单栏图标。主应用在本机汇总 Codex usage JSONL 中的 Token 用量，并通过已登录 Codex 自带的 app-server 读取账户实时限额，再把供 WidgetKit 与独立菜单栏 Helper 展示的脱敏快照写入 App Group；只有主应用生产数据，Helper 只读共享快照。

本项目是非官方开源项目，与 OpenAI 没有隶属关系，也未获得 OpenAI 的认可或背书。Codex 和 OpenAI 是其各自权利人的商标。

## 功能

- 小号和中号 WidgetKit 小组件显示今日、全部时间、项目与有效限额的精简信息。
- 点击任一小组件都会打开同一个完整仪表盘窗口，不会重复创建窗口。
- 菜单栏图标可在设置中单独开关；这不会添加或移除系统桌面小组件。
- 菜单栏入口由独立的 `CodexUsageMenuBar` Helper 提供；它不扫描日志、不打开索引，也不启动 Codex app-server，只读取主应用写入的共享快照。
- 以账户主限额桶 `codex` 的实时响应为准，每 60 秒主动同步或在用户点击刷新时手动触发，不会让 `codex_bengalfox` 等模型专属桶覆盖周限额。
- 显示有效的 5 小时和每周限额；Codex 不再返回 5 小时窗口时会自动隐藏。
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

点击小组件会通过 `codexusagemonitor://dashboard` 打开单例完整仪表盘。主应用获得新限额后会立即写入 App Group 并请求 WidgetKit 重载；WidgetKit 仍由 macOS 决定最终绘制时机，因此桌面卡片可能晚于完整应用，不承诺严格按分钟绘制，更不承诺秒级刷新。

主应用必须在后台运行，新的 Codex 日志事件和实时限额才会继续共享。限额成功同步后 10 分钟内标记为实时，10–30 分钟显示“上次实时同步”且不发新提醒，超过 30 分钟会隐藏百分比。退出主应用后 Token 快照仍可显示，但限额不会永久冒充实时值。

## 设置

- **显示菜单栏图标**：启动或停止独立菜单栏 Helper，只控制菜单栏入口，不影响已添加的系统小组件。
- **登录时启动**：登录后静默启动主应用并继续监控，不自动打开仪表盘。macOS 要求批准时，请在“系统设置 > 通用 > 登录项与扩展”中确认。
- **低用量提醒**：只有用户主动启用时才请求通知权限；可分别控制 20% 和 10% 阈值。
- **刷新**：同时重新检查当前/归档日志并强制读取一次 Codex 实时限额，两者互不阻塞。
- **小组件共享状态**：App Group 不可用或快照写入失败时显示错误；主仪表盘成功数据不会因此被替换。

## 隐私边界

主应用只在本机扫描 `CODEX_HOME` 指向目录中的 Codex usage JSONL；未设置时使用 `~/.codex`。扫描范围仅包括：

- `sessions/**/*.jsonl`
- `archived_sessions/**/*.jsonl`

主应用在本机扫描 JSONL 源字节，并逐行解码会话标识、工作目录和 Token 计数等汇总所需结构化字段。源 JSONL 行本身可能包含 prompt、response、tool output 或 credentials；解码器会忽略这些未声明字段。SQLite 中的日志限额只保留为诊断信息，不再作为界面的权威值。

每次读取实时限额都使用短生命周期的本机 Codex app-server：启动（start）→ 初始化（`initialize`）→ 只读查询（`account/rateLimits/read`）→ 停止（stop）。它不读取 ChatGPT Cookie、Keychain 登录令牌或提示词内容，不调用限额重置功能，也不保存 app-server 完整响应或 credits 信息。同步瞬间 CPU 可能短暂升高；两次同步之间，空闲的主应用不应保有或持续运行由它启动的 `codex app-server` 子进程。

主应用写入 App Group 的 `widget-usage-v1.json`（保留历史文件名）使用 schema 2，只保存生成时间、汇总 Token、有效限额、限额新鲜度、最多三个项目的展示名称与用量，以及数据状态。App Group 不包含 prompt、response、tool output、credentials、完整路径、credits 或原始 app-server 响应。

共享项目 ID 是根据主应用项目键生成的 SHA-256 opaque 值，不是原始路径；项目名称仍是用于界面展示的末级名称。Widget Extension 与菜单栏 Helper 都不扫描 `~/.codex`、不打开 SQLite、不读取源 JSONL，也不启动 Codex app-server；它们只消费 App Group 快照。上述处理全部在本机完成，本应用不把 Codex JSONL、解析结果、SQLite 索引或共享快照上传到网络。

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

原生小组件和菜单栏 Helper 只有在主应用、Widget Extension 与 Helper 使用匹配签名并同时具备匹配 App Group entitlement 时，才具备可分发构建所需的共享容器条件。所有嵌入代码还必须由同一 Team 正确签名。

- **unsigned CI 构建**：仅证明编译和包结构通过，不用于安装、Widget Gallery 发现或公证声明。
- **Apple Development 构建**：仅供开发者在当前 Mac 上验证主应用、小组件发现和 App Group 共享；它不是面向其他用户分发的 Developer ID 公证版。
- **Developer ID 发布**：只有同时通过四道门槛才可作为发布版：① 主应用、Widget、登录项、菜单栏 Helper 和嵌入 framework 均使用同一 Team 的 Developer ID Application identity-backed 签名，主应用、Widget 与 Helper 保留匹配的 App Group entitlement，签名后 bundle 通过严格验证；② Apple 公证返回 `Accepted`；③ 公证票据完成 stapling 并验证；④ Gatekeeper assessment 通过。

以下是发布者需要对真实 Developer ID 产物执行的命令，占位符必须替换为实际路径和已配置的 Keychain profile。它们没有在本轮 unsigned CI 验证中执行，当前仓库产物不得据此声称已签名、公证或通过 Gatekeeper：

```bash
# Gate 1：签名后严格验证，并比较主应用/Widget 的唯一 App Group
APP='<app>'
WIDGET="$APP/Contents/PlugIns/CodexUsageMonitorWidget.appex"
EXPECTED_APP_GROUP='ZD9PK3NY5Z.CodexUsageMonitor.shared'
ENTITLEMENTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-entitlements.XXXXXX")"
trap 'rm -rf -- "$ENTITLEMENTS_DIR"' EXIT

codesign --verify --deep --strict --verbose=4 "$APP"
codesign -d --entitlements :- "$APP" \
  >"$ENTITLEMENTS_DIR/app.plist" 2>/dev/null
codesign -d --entitlements :- "$WIDGET" \
  >"$ENTITLEMENTS_DIR/widget.plist" 2>/dev/null
plutil -lint "$ENTITLEMENTS_DIR/app.plist"
plutil -lint "$ENTITLEMENTS_DIR/widget.plist"
app_groups="$(
  plutil -extract 'com\.apple\.security\.application-groups' json -o - \
    "$ENTITLEMENTS_DIR/app.plist"
)"
widget_groups="$(
  plutil -extract 'com\.apple\.security\.application-groups' json -o - \
    "$ENTITLEMENTS_DIR/widget.plist"
)"
test "$app_groups" = "$widget_groups"
test "$app_groups" = "[\"$EXPECTED_APP_GROUP\"]"

# Gate 2：提交 ZIP 并等待；结果必须明确为 Accepted
xcrun notarytool submit <zip> --keychain-profile <profile> --wait

# Gate 3：装订公证票据并验证
xcrun stapler staple <app>
xcrun stapler validate <app>

# Gate 4：执行 Gatekeeper assessment
spctl --assess --type execute --verbose=4 <app>
```

本轮环境没有可用的真实签名 identity，因此 Gate 1 的 entitlement 提取与比较没有在真实签名产物上执行；脚本 fixture 矩阵通过不替代真实 identity 验证。

stapling 会修改 app，发布者应在 stapling 和 Gatekeeper 验证通过后重新生成最终分发 ZIP。

### 贡献者标识配置闭环

如果继续使用本仓库的 `com.amenggod.*` bundle IDs 和 `ZD9PK3NY5Z.CodexUsageMonitor.shared`，所选 Apple Developer Team 必须是 `ZD9PK3NY5Z`，并拥有这些标识及对应 App Group 权限。macOS 要求共享容器标识以签名团队 ID 开头；只传入 `DEVELOPMENT_TEAM` 不会替贡献者注册、授权或自动重命名 bundle ID 与 App Group。

改用自己的标识时，至少同步以下真实位置和值：

- `project.yml`：主应用 `com.amenggod.CodexUsageMonitor`、Widget `com.amenggod.CodexUsageMonitor.Widget`、登录项 `com.amenggod.CodexUsageMonitor.LoginItem`、菜单栏 Helper `com.amenggod.CodexUsageMonitor.MenuBar`、shared framework `com.amenggod.CodexUsageMonitor.Shared`，以及主应用、Widget 和 Helper entitlement 中的 `ZD9PK3NY5Z.CodexUsageMonitor.shared`。
- `Config/CodexUsageMonitor.entitlements`、`Config/CodexUsageMonitorWidget.entitlements` 与 `Config/CodexUsageMenuBar.entitlements`：这是 XcodeGen 从 `project.yml` 生成的 App Group 副本；不要只手工修改生成文件。
- `Sources/CodexUsageShared/WidgetSnapshotStore.swift`：`WidgetSnapshotStore.appGroupIdentifier` 当前为 `ZD9PK3NY5Z.CodexUsageMonitor.shared`，必须等于上述 App Group。
- `Sources/CodexUsageMonitor/Services/LaunchAtLoginController.swift`：`LoginItemLaunchAtLoginAdapter.service` 传给 `SMAppService.loginItem(identifier:)` 的当前值为 `com.amenggod.CodexUsageMonitor.LoginItem`，必须等于登录项 bundle ID。当前实现没有单独的 `LaunchAtLoginController.loginItemIdentifier` 常量，不能只搜索该符号名。
- `Scripts/verify-bundle.sh`：同步其中固定的主应用、Widget、登录项、菜单栏 Helper 和 shared framework 预期 bundle IDs；与它们配套的当前 App Group 是 `ZD9PK3NY5Z.CodexUsageMonitor.shared`。该脚本对 unsigned 产物不读取签名 entitlement，因此 App Group 的一致性仍由 `project.yml`、`WidgetSnapshotStore.appGroupIdentifier` 和真实签名/provisioning 共同保证，不能把 unsigned bundle 验证当作 App Group 授权验证。

若同时重命名深链或 Widget kind，还必须成对同步：

- dashboard 深链：当前值为 `codexusagemonitor://dashboard`；同步 `project.yml` 的 `CFBundleURLSchemes`、`AppLaunchCoordinator`、`CodexUsageWidgetBundle.dashboardURL` 和 `Scripts/verify-bundle.sh`。
- Widget kind：当前值为 `com.amenggod.CodexUsageMonitor.usage`；同步 `CodexUsageWidgetBundle.kind` 与 `SystemWidgetTimelineReloader` 的 `reloadTimelines(ofKind:)` 参数。

不要提交证书、私钥、Apple ID、app-specific password、API key、provisioning profile 或其他签名秘密。修改完成后使用 XcodeGen 2.45.4 重新生成并检查派生文件：

```bash
bash Scripts/generate-project.sh
git diff --exit-code -- CodexUsageMonitor.xcodeproj Config
```

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
- **小组件没有新数据或显示陈旧**：先看小组件底部的“更新于/上次更新”时间，再确认主应用仍在后台运行；打开完整仪表盘点击刷新，并查看页脚的 Token/实时限额状态和设置中的小组件共享错误。主应用会持续写入共享快照，并只在可见数据变化时请求 WidgetKit 重载；最终重绘时间仍由 macOS 决定。
- **退出后仍显示旧数据**：这是最后共享快照；退出主应用不会清除它，也不会继续扫描。重新启动主应用并完成一次成功刷新后才会更新。
- **没有菜单栏图标**：在设置中打开“显示菜单栏图标”。该开关只影响菜单栏，不影响系统小组件。
- **菜单栏开关已打开但仍看不到**：菜单栏入口由独立 Helper 提供；若安装了 Only Switch 等第三方菜单栏管理工具并启用了折叠，新图标可能被收入隐藏区。第三方工具可以主动隐藏任何状态项，应用无法绕过这一系统层行为；请在对应工具中取消隐藏。Codex Usage Monitor 使用固定宽度的紧凑模板图标，能随深浅菜单栏背景自动着色；点击图标可查看完整额度。
- **点击刷新但桌面小组件不变化**：主程序会先写入共享快照，再请求 WidgetKit 更新时间线。开发机若同时注册了 Xcode 构建目录与 `/Applications` 中的同名扩展，macOS 可能因版本不匹配拒绝时间线；注销构建目录中的重复扩展并重新注册正式安装版本后即可恢复。普通发布版安装不会产生这个开发目录冲突。
- **登录后未静默启动**：在设置中重新打开“登录时启动”，并前往“系统设置 > 通用 > 登录项与扩展”检查是否需要用户批准。启用后登录启动不会自动打开窗口。
- **没有用量数据**：运行 Codex 产生至少一条会话记录，确认 `CODEX_HOME` 或默认 `~/.codex` 目录存在。
- **限额一直缺失**：先确认 ChatGPT/Codex 已登录且安装包含可用的 Codex app-server，再点击刷新并查看页脚错误。Codex 不返回 5 小时窗口时隐藏该卡片是预期行为。
- **Gatekeeper 阻止启动**：先确认产物类型与来源。unsigned CI 产物不是安装包；Apple Development 构建只用于当前 Mac 的本机验证。对可信但未公证的自建版本，按 Finder 和“系统设置 > 隐私与安全性”给出的系统提示处理。面向用户的正式版本应使用 Developer ID 签名并完成 Apple 公证。
- **构建失败**：确认 Xcode 26.3+ 与 XcodeGen 2.45.4 可用，先运行 `bash Scripts/generate-project.sh`、`swift test`，再运行构建脚本定位阶段。

## 已知的格式兼容风险

本项目的 Token 统计依赖 Codex 本地 JSONL 字段，实时限额依赖当前为 experimental 的 Codex app-server 协议。它们都不是本项目控制的稳定接口；Codex 更新可能导致 Token 事件被安全忽略或实时限额进入 unavailable。程序不会在此时回退到无法验证的旧日志百分比。

## 贡献

欢迎提交 issue 和 pull request。贡献前请：

1. 不提交真实 Codex 会话、用户路径、签名证书、凭据或构建产物。
2. 为行为变更添加 Swift Testing 测试，并使用临时 `CODEX_HOME` 和合成 JSONL。
3. 运行 SwiftPM 与 Xcode 测试、生成项目检查、unsigned package/bundle 验证和 `actionlint`。
4. 保持隐私边界：主应用只处理汇总所需字段，Widget 只消费 App Group 中的脱敏快照。

## 许可证

本项目使用 MIT License，详见 [LICENSE](LICENSE)。
