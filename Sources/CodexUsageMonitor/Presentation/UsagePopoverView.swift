import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class LaunchAtLoginPromptState {
    private let launchAtLogin: any LaunchAtLoginServicing
    private(set) var errorDescription: String?

    init(launchAtLogin: any LaunchAtLoginServicing) {
        self.launchAtLogin = launchAtLogin
        errorDescription = launchAtLogin.lastErrorDescription
    }

    @discardableResult
    func enable() -> Bool {
        do {
            let enabled = try launchAtLogin.applyUserPreference(enabled: true)
            errorDescription = launchAtLogin.lastErrorDescription
            return enabled
        } catch {
            errorDescription = launchAtLogin.lastErrorDescription ?? error.localizedDescription
            return launchAtLogin.isEnabled
        }
    }
}

@MainActor
struct UsagePopoverView: View {
    @Bindable var model: UsageViewModel
    let launchAtLogin: any LaunchAtLoginServicing
    private let dashboard: (any DashboardPresenting)?
    @AppStorage("didAskLaunchAtLogin") private var didAskLaunchAtLogin = false
    @State private var showLaunchAtLoginPrompt = false
    @State private var launchPromptState: LaunchAtLoginPromptState

    init(
        model: UsageViewModel,
        launchAtLogin: any LaunchAtLoginServicing,
        dashboard: (any DashboardPresenting)? = nil
    ) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        self.dashboard = dashboard
        _launchPromptState = State(initialValue: LaunchAtLoginPromptState(
            launchAtLogin: launchAtLogin
        ))
    }

    var body: some View {
        TimelineView(
            .periodic(from: .now, by: UsagePresentationPolicy.refreshInterval)
        ) { context in
            VStack(spacing: 0) {
                header
                Divider()
                dashboard(now: context.date)
                Divider()
                footer
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "登录时自动启动？",
            isPresented: $showLaunchAtLoginPrompt,
            titleVisibility: .visible
        ) {
            Button("Enable") { enableLaunchAtLoginFromPrompt() }
            Button("Not Now", role: .cancel) { didAskLaunchAtLogin = true }
        } message: {
            Text("Codex Usage Monitor 可在登录后自动运行并持续更新用量。")
        }
        .task {
            guard !didAskLaunchAtLogin else { return }
            await Task.yield()
            showLaunchAtLoginPrompt = true
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Usage")
                    .font(.headline)
                Text("本地统计，不读取提示词内容")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("统计范围", selection: rangeBinding) {
                ForEach(TokenRange.allCases, id: \.rawValue) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .accessibilityLabel("Token 统计范围")
        }
        .padding(16)
    }

    private func dashboard(now: Date) -> some View {
        let activeLimits = UsagePresentationPolicy.activeLimits(
            limits: model.snapshot.limits,
            now: now
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ForEach(
                        UsagePresentationPolicy.visibleWindows(limits: activeLimits, now: now),
                        id: \.storageKey
                    ) { window in
                        if let status = activeLimits.first(where: { $0.window == window }) {
                            LimitCard(status: status)
                        } else {
                            MissingLimitCard(window: window)
                        }
                    }
                }

                totalRow

                VStack(alignment: .leading, spacing: 8) {
                    Text("项目排行")
                        .font(.subheadline.weight(.semibold))
                    if model.snapshot.projects.isEmpty {
                        ContentUnavailableView(
                            "暂无项目用量",
                            systemImage: "chart.bar.xaxis",
                            description: Text("完成一次 Codex 会话后，这里会显示本地项目统计。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 110)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(model.snapshot.projects) { project in
                                ProjectRow(project: project)
                                    .padding(.vertical, 7)
                                if project.id != model.snapshot.projects.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var totalRow: some View {
        HStack {
            Label("总 Token", systemImage: "sum")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(model.snapshot.total.total.formatted(.number.notation(.compactName)))
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("总 Token，\(model.snapshot.total.total)")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label(
                FreshnessFormatter.text(for: model.snapshot.freshness),
                systemImage: FreshnessFormatter.symbol(for: model.snapshot.freshness)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(2)
                .accessibilityLabel(
                    "数据状态，\(FreshnessFormatter.text(for: model.snapshot.freshness))"
                )

            if let launchPromptError = launchPromptState.errorDescription {
                Text(launchPromptError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .accessibilityLabel("登录启动设置失败，\(launchPromptError)")
            }

            Spacer()

            if let dashboard {
                Button {
                    dashboard.showDashboard()
                } label: {
                    Label("打开完整统计", systemImage: "macwindow")
                }
                .help("打开完整统计")
            }

            Button {
                Task { await model.retry() }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("重新扫描 Codex 会话")

            Button {
                Task { await model.rebuildIndex() }
            } label: {
                Label("重建", systemImage: "arrow.triangle.2.circlepath")
            }
            .labelStyle(.iconOnly)
            .help("清空本地索引并重新构建")

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    private var rangeBinding: Binding<TokenRange> {
        Binding(
            get: { model.selectedRange },
            set: { range in Task { await model.selectRange(range) } }
        )
    }

    private func enableLaunchAtLoginFromPrompt() {
        didAskLaunchAtLogin = true
        launchPromptState.enable()
    }
}

private struct MissingLimitCard: View {
    let window: LimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(window.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("--")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            ProgressView(value: 0, total: 100)
            Text("等待限额数据")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.displayName)，等待限额数据")
    }
}
