import CodexUsageMenuBarCore
import CodexUsageShared
import SwiftUI

@MainActor
struct MenuBarPopoverView: View {
    @Bindable var model: MenuBarSnapshotModel
    let router: MenuBarActionRouter

    var body: some View {
        let presentation = model.display.medium
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex 用量")
                .font(.headline)

            HStack {
                UsageValue(title: "今日", value: presentation.todayTokens)
                Spacer()
                UsageValue(title: "总计", value: presentation.allTimeTokens)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let fiveHour = presentation.fiveHourRemainingPercent {
                    LimitRow(title: "5 小时剩余", remaining: fiveHour)
                }
                if let week = presentation.weekRemainingPercent {
                    LimitRow(title: "周剩余", remaining: week)
                } else {
                    Text("等待周限额")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("项目")
                    .font(.subheadline.weight(.semibold))
                if presentation.projects.isEmpty {
                    Text("暂无项目用量")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(presentation.projects.prefix(3), id: \.id) { project in
                        HStack {
                            Text(project.name)
                                .lineLimit(1)
                            Spacer()
                            Text(WidgetDisplayFormatting.compactTokens(project.tokens))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text(model.presentationStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Button("刷新") { router.perform(.refresh) }
                Button("设置") { router.perform(.settings) }
                Spacer()
                Button("打开面板") { router.perform(.dashboard) }
                Button("退出") { router.quitAll() }
            }
            .controlSize(.small)
        }
        .padding()
        .frame(width: 420, height: 430)
    }
}

private struct UsageValue: View {
    let title: String
    let value: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(WidgetDisplayFormatting.compactTokens(value))
                .font(.title3.weight(.semibold))
        }
    }
}

private struct LimitRow: View {
    let title: String
    let remaining: Double

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(WidgetDisplayFormatting.percent(remaining))
                .fontWeight(.semibold)
        }
    }
}
