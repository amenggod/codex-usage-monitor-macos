import SwiftUI

@MainActor
struct DesktopCardView: View {
    @Bindable var model: UsageViewModel
    let runtime: AppRuntime
    let isExpanded: Bool
    let onExpandedChange: (Bool) -> Void

    var body: some View {
        Group {
            if isExpanded {
                UsagePopoverView(model: model)
                    .overlay(alignment: .topLeading) {
                        expansionButton
                            .padding(10)
                    }
            } else {
                compactCard
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task { await runtime.launch() }
    }

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            }

            HStack(spacing: 12) {
                ForEach([LimitWindow.fiveHours, .week], id: \.storageKey) { window in
                    compactLimit(window)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text("总 Token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.snapshot.total.total.formatted(.number.notation(.compactName)))
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
        }
        .padding(18)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func compactLimit(_ window: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let status = model.snapshot.limits.first(where: { $0.window == window }) {
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
