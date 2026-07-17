import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsViewState {
    private let launchAtLogin: any LaunchAtLoginServicing
    private let notificationSender: any NotificationSending
    private(set) var isLaunchAtLoginEnabled: Bool
    private(set) var launchAtLoginError: String?
    private(set) var canRetryLaunchAtLoginMigration: Bool
    private(set) var notificationsEnabled = false
    private(set) var twentyPercentNotificationsEnabled = true
    private(set) var tenPercentNotificationsEnabled = true
    private(set) var notificationMessage: String?
    private(set) var widgetSharingMessage: String?

    init(
        launchAtLogin: any LaunchAtLoginServicing,
        notificationSender: any NotificationSending,
        widgetSharingStatus: WidgetSharingStatus? = nil
    ) {
        self.launchAtLogin = launchAtLogin
        self.notificationSender = notificationSender
        isLaunchAtLoginEnabled = launchAtLogin.isEnabled
        launchAtLoginError = launchAtLogin.lastErrorDescription
        canRetryLaunchAtLoginMigration = launchAtLogin.hasMigrationError
        setWidgetSharingStatus(widgetSharingStatus)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            isLaunchAtLoginEnabled = try launchAtLogin.applyUserPreference(enabled: enabled)
            launchAtLoginError = launchAtLogin.lastErrorDescription
            canRetryLaunchAtLoginMigration = launchAtLogin.hasMigrationError
        } catch {
            isLaunchAtLoginEnabled = launchAtLogin.isEnabled
            launchAtLoginError = launchAtLogin.lastErrorDescription ?? error.localizedDescription
            canRetryLaunchAtLoginMigration = launchAtLogin.hasMigrationError
        }
    }

    func refreshLaunchAtLoginState() {
        isLaunchAtLoginEnabled = launchAtLogin.isEnabled
        launchAtLoginError = launchAtLogin.lastErrorDescription
        canRetryLaunchAtLoginMigration = launchAtLogin.hasMigrationError
    }

    func retryLaunchAtLoginMigration() {
        guard canRetryLaunchAtLoginMigration else { return }
        launchAtLoginError = nil
        do {
            try launchAtLogin.migrateLegacyRegistrationIfNeeded()
            refreshLaunchAtLoginState()
        } catch {
            launchAtLoginError = launchAtLogin.lastErrorDescription ?? error.localizedDescription
            canRetryLaunchAtLoginMigration = launchAtLogin.hasMigrationError
        }
    }

    func loadNotificationSettings() async {
        notificationsEnabled = await notificationSender.isEnabled()
        twentyPercentNotificationsEnabled = await notificationSender.isThresholdEnabled(20)
        tenPercentNotificationsEnabled = await notificationSender.isThresholdEnabled(10)
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        notificationMessage = nil
        if enabled {
            do {
                let granted = try await notificationSender.requestAuthorization()
                notificationsEnabled = granted
                notificationMessage = granted ? "通知已启用" : "未授予通知权限"
            } catch {
                notificationsEnabled = await notificationSender.isEnabled()
                notificationMessage = error.localizedDescription
            }
        } else {
            await notificationSender.setEnabled(false)
            notificationsEnabled = await notificationSender.isEnabled()
            notificationMessage = notificationsEnabled ? "无法关闭通知" : "通知已关闭"
        }
    }

    func setThresholdEnabled(_ enabled: Bool, threshold: Int) async {
        await notificationSender.setThresholdEnabled(enabled, threshold: threshold)
        let stored = await notificationSender.isThresholdEnabled(threshold)
        switch threshold {
        case 20:
            twentyPercentNotificationsEnabled = stored
        case 10:
            tenPercentNotificationsEnabled = stored
        default:
            break
        }
    }

    func setWidgetSharingStatus(_ status: WidgetSharingStatus?) {
        guard case let .unavailable(message) = status else {
            widgetSharingMessage = nil
            return
        }
        widgetSharingMessage = message
    }
}

@MainActor
struct SettingsView: View {
    let model: UsageViewModel
    let launchAtLogin: any LaunchAtLoginServicing
    @State private var state: SettingsViewState
    @State private var menuBarVisibilityStore: MenuBarVisibilityStore

    init(
        model: UsageViewModel,
        launchAtLogin: any LaunchAtLoginServicing,
        notificationSender: any NotificationSending = UserNotificationSender(),
        menuBarVisibilityStore: MenuBarVisibilityStore
    ) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        _state = State(initialValue: SettingsViewState(
            launchAtLogin: launchAtLogin,
            notificationSender: notificationSender,
            widgetSharingStatus: model.widgetSharingStatus
        ))
        _menuBarVisibilityStore = State(initialValue: menuBarVisibilityStore)
    }

    var body: some View {
        Form {
            Section("显示") {
                Toggle("显示菜单栏图标", isOn: menuBarVisibilityBinding)
                Text("菜单栏使用紧凑图标以适应拥挤空间；点击图标可查看完整额度。若使用 Only Switch，请不要折叠该状态项。关闭图标不会移除系统桌面小组件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("桌面小组件") {
                Text("在桌面空白处右键，选择“编辑小组件”，搜索 Codex Usage Monitor，再添加小号或中号小组件。应用无法自动将小组件固定到桌面。")
                Text("小组件显示最近一次有效值和更新时间；点击会打开完整面板。刷新时机由 WidgetKit 决定，不保证秒级更新。")
                Text("主应用需在后台运行，才会监控新的 Codex 日志并将脱敏快照写入 App Group；5 小时限额缺失或过期时会自动隐藏。")
                if let message = state.widgetSharingMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("小组件共享失败，\(message)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Section("启动") {
                Toggle("登录时启动", isOn: launchAtLoginBinding)
                    .accessibilityHint("控制 Codex Usage Monitor 是否在登录后自动运行")
                Text("登录时启动会在登录后静默运行并继续监控，不会自动打开窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = state.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("登录启动设置失败，\(error)")
                    if state.canRetryLaunchAtLoginMigration {
                        Button("重试登录项迁移") {
                            state.retryLaunchAtLoginMigration()
                        }
                    }
                }
            }

            Section("通知") {
                Toggle("低用量提醒", isOn: notificationsEnabledBinding)
                Toggle("剩余低于 20%", isOn: twentyPercentBinding)
                    .disabled(!state.notificationsEnabled)
                Toggle("剩余低于 10%", isOn: tenPercentBinding)
                    .disabled(!state.notificationsEnabled)
                if let message = state.notificationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("数据") {
                Button("重新扫描") {
                    Task { await model.retry() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            state.refreshLaunchAtLoginState()
            state.setWidgetSharingStatus(model.widgetSharingStatus)
            await state.loadNotificationSettings()
        }
        .onChange(of: model.widgetSharingStatus) { _, status in
            state.setWidgetSharingStatus(status)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { state.isLaunchAtLoginEnabled },
            set: { state.setLaunchAtLoginEnabled($0) }
        )
    }

    var menuBarVisibilityBinding: Binding<Bool> {
        Binding(
            get: { menuBarVisibilityStore.isVisible },
            set: { menuBarVisibilityStore.setVisible($0) }
        )
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.notificationsEnabled },
            set: { enabled in
                Task { await state.setNotificationsEnabled(enabled) }
            }
        )
    }

    private var twentyPercentBinding: Binding<Bool> {
        Binding(
            get: { state.twentyPercentNotificationsEnabled },
            set: { enabled in
                Task { await state.setThresholdEnabled(enabled, threshold: 20) }
            }
        )
    }

    private var tenPercentBinding: Binding<Bool> {
        Binding(
            get: { state.tenPercentNotificationsEnabled },
            set: { enabled in
                Task { await state.setThresholdEnabled(enabled, threshold: 10) }
            }
        )
    }
}
