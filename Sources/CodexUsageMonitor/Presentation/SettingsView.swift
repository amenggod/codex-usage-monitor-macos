import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsViewState {
    private let launchAtLogin: any LaunchAtLoginServicing
    private(set) var isLaunchAtLoginEnabled: Bool
    private(set) var launchAtLoginError: String?

    init(launchAtLogin: any LaunchAtLoginServicing) {
        self.launchAtLogin = launchAtLogin
        isLaunchAtLoginEnabled = launchAtLogin.isEnabled
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        let previousValue = isLaunchAtLoginEnabled
        launchAtLoginError = nil
        do {
            try launchAtLogin.setEnabled(enabled)
            isLaunchAtLoginEnabled = launchAtLogin.isEnabled
        } catch {
            isLaunchAtLoginEnabled = previousValue
            launchAtLoginError = error.localizedDescription
        }
    }
}

@MainActor
struct SettingsView: View {
    let model: UsageViewModel
    private let notificationSender: any NotificationSending
    @State private var state: SettingsViewState
    @State private var notificationsEnabled = false
    @State private var notificationMessage: String?

    init(
        model: UsageViewModel,
        launchAtLogin: any LaunchAtLoginServicing = LaunchAtLoginController(),
        notificationSender: any NotificationSending = UserNotificationSender()
    ) {
        self.model = model
        self.notificationSender = notificationSender
        _state = State(initialValue: SettingsViewState(launchAtLogin: launchAtLogin))
    }

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动", isOn: launchAtLoginBinding)
                    .accessibilityHint("控制 Codex Usage Monitor 是否在登录后自动运行")
                if let error = state.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("登录启动设置失败，\(error)")
                }
            }

            Section("通知") {
                LabeledContent("低用量提醒") {
                    Text(notificationsEnabled ? "已启用" : "未启用")
                        .foregroundStyle(.secondary)
                }
                if !notificationsEnabled {
                    Button("启用通知") {
                        Task { await requestNotificationAuthorization() }
                    }
                }
                if let notificationMessage {
                    Text(notificationMessage)
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
            notificationsEnabled = await notificationSender.isEnabled()
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { state.isLaunchAtLoginEnabled },
            set: { state.setLaunchAtLoginEnabled($0) }
        )
    }

    private func requestNotificationAuthorization() async {
        do {
            let granted = try await notificationSender.requestAuthorization()
            notificationsEnabled = granted
            notificationMessage = granted ? "通知已启用" : "未授予通知权限"
        } catch {
            notificationsEnabled = false
            notificationMessage = error.localizedDescription
        }
    }
}
