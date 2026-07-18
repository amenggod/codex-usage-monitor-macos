# 登录启动用户偏好事务入口设计

## 目标

消除设置页和首次提示自行组合旧登录项迁移与 helper 启停的行为。所有用户意图通过 `LaunchAtLoginServicing.applyUserPreference(enabled:)` 进入 controller，启动协调器仍可显式调用一次迁移。

## 事务流程

`applyUserPreference(enabled:)` 按固定顺序执行：

1. 调用或重试 `migrateLegacyRegistrationIfNeeded()`。
2. 迁移成功后重新读取 helper 的真实注册状态。
3. 仅当当前 enabled 状态与用户目标不一致时调用 register 或 unregister。
4. 再次读取 helper 状态并返回真实的 `Bool`，UI 不自行推断结果。

旧登录项为 enabled 时，迁移已经注册 helper，因此目标 true 不会重复注册。旧登录项为 requiresApproval 时，迁移已经清理 helper，因此目标 false 不会重复注销。helper 已处于目标状态时不产生 ServiceManagement 写操作。

## 错误与状态

- 迁移失败立即终止，不执行目标变更；保留 migration error、未完成 marker 和原有 helper/legacy 一致性语义。
- 目标变更失败按普通启停错误记录，不伪装成迁移错误。
- Settings 使用 controller 返回的真实状态更新 toggle；失败则重新读取真实状态并展示 controller 的准确错误。
- UsagePopover 首次提示的 Enable 只调用事务入口。成功后结束提示；失败时不绕过迁移，controller 保留准确错误供设置页展示。

## 调用边界

- `SettingsViewState.setLaunchAtLoginEnabled` 只调用 `applyUserPreference(enabled:)`。
- `UsagePopoverView` 首次提示 Enable 只调用 `applyUserPreference(enabled: true)`。
- `AppLaunchCoordinator` 保留显式 `migrateLegacyRegistrationIfNeeded()`，用于无用户交互的启动迁移。
- 生产 UI 不直接调用 `setEnabled`；该低层接口可继续保留给 controller 内部兼容和既有单元测试。

## 验证

- controller：enabled 迁移后目标 true 仅注册一次；requiresApproval 清理后目标 false 不重复注销；目标状态幂等；迁移失败后可由用户意图重试且 marker/state/error 一致。
- Settings：只调用事务入口，以返回值更新 UI，迁移失败不继续切换。
- UsagePopover：启动迁移失败后 Enable 会重试迁移；成功不双注册，失败保留迁移错误。
- 启动协调、helper 类型检查和全量测试继续通过。
