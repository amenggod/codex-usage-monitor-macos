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

    init(
        launchAtLogin: any LaunchAtLoginServicing,
        notificationSender: any NotificationSending
    ) {
        self.launchAtLogin = launchAtLogin
        self.notificationSender = notificationSender
        isLaunchAtLoginEnabled = launchAtLogin.isEnabled
        launchAtLoginError = launchAtLogin.lastErrorDescription
        canRetryLaunchAtLoginMigration = launchAtLogin.hasMigrationError
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        let previousValue = isLaunchAtLoginEnabled
        launchAtLoginError = nil
        canRetryLaunchAtLoginMigration = false
        do {
            try launchAtLogin.migrateLegacyRegistrationIfNeeded()
            try launchAtLogin.setEnabled(enabled)
            isLaunchAtLoginEnabled = launchAtLogin.isEnabled
        } catch {
            isLaunchAtLoginEnabled = previousValue
            launchAtLoginError = error.localizedDescription
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
            notificationSender: notificationSender
        ))
        _menuBarVisibilityStore = State(initialValue: menuBarVisibilityStore)
    }

    var body: some View {
        Form {
            Section("显示") {
                Toggle("显示顶部菜单栏", isOn: menuBarVisibilityBinding)
                Text("桌面小组件由 macOS 管理：在桌面空白处右键，选择“编辑小组件”，然后搜索 Codex Usage Monitor。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("启动") {
                Toggle("登录时启动", isOn: launchAtLoginBinding)
                    .accessibilityHint("控制 Codex Usage Monitor 是否在登录后自动运行")
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
            await state.loadNotificationSettings()
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
