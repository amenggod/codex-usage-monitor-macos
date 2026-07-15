import SwiftUI

@MainActor
struct DesktopCardView: View {
    @Bindable var model: UsageViewModel
    let runtime: AppRuntime
    let isExpanded: Bool
    let onExpandedChange: (Bool) -> Void

    var body: some View {
        TimelineView(
            .periodic(from: .now, by: UsagePresentationPolicy.refreshInterval)
        ) { context in
            Group {
                if isExpanded {
                    UsagePopoverView(model: model)
                        .overlay(alignment: .topLeading) {
                            expansionButton
                                .padding(10)
                        }
                } else {
                    compactCard(now: context.date)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task { await runtime.launch() }
    }

    private func compactCard(now: Date) -> some View {
        let activeLimits = UsagePresentationPolicy.activeLimits(
            limits: model.snapshot.limits,
            now: now
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Usage")
                        .font(.headline)
                    Text("本地统计")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                expansionButton
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("打开设置")
                .accessibilityLabel("打开设置")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("退出 Codex Usage Monitor")
                .accessibilityLabel("退出 Codex Usage Monitor")
            }

            HStack(spacing: 12) {
                ForEach(
                    UsagePresentationPolicy.visibleWindows(limits: activeLimits, now: now),
                    id: \.storageKey
                ) { window in
                    compactLimit(window, limits: activeLimits)
                }
            }

            HStack {
                Text("今日 Token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.todayTotal.total.formatted(.number.notation(.compactName)))
                    .font(.title3.monospacedDigit().weight(.semibold))
            }

            Label(
                FreshnessFormatter.text(for: model.snapshot.freshness),
                systemImage: FreshnessFormatter.symbol(for: model.snapshot.freshness)
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .accessibilityLabel(
                "数据状态，\(FreshnessFormatter.text(for: model.snapshot.freshness))"
            )
        }
        .padding(16)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func compactLimit(
        _ window: LimitWindow,
        limits: [LimitStatus]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let status = limits.first(where: { $0.window == window }) {
                Text("\(Int(status.remainingPercent.rounded()))%")
                    .font(.title2.monospacedDigit().weight(.semibold))
                ProgressView(value: status.remainingPercent, total: 100)
            } else {
                Text("--")
                    .font(.title2.monospacedDigit().weight(.semibold))
                ProgressView(value: 0, total: 100)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expansionButton: some View {
        Button {
            onExpandedChange(!isExpanded)
        } label: {
            Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.borderless)
        .help(isExpanded ? "收起桌面卡片" : "展开桌面卡片")
        .accessibilityLabel(isExpanded ? "收起桌面卡片" : "展开桌面卡片")
    }
}
