import SwiftUI
import WidgetKit
import CodexUsageShared

enum UsageWidgetLayoutPolicy {
    static func projectLimit(isAccessibilitySize: Bool) -> Int {
        isAccessibilitySize ? 1 : 3
    }
}

struct UsageWidgetView: View {
    let entry: UsageWidgetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        let model = WidgetDisplayModel(
            loadState: entry.loadState,
            now: entry.date
        )

        Group {
            if model.snapshot == nil || !model.canDisplayUsageValues {
                UnavailableUsageWidgetView(statusText: model.statusText)
            } else if family == .systemMedium {
                MediumUsageWidgetView(model: model)
            } else {
                SmallUsageWidgetView(model: model)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct UnavailableUsageWidgetView: View {
    let statusText: String

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                unavailableCopy
            }

            VStack(alignment: .leading, spacing: 3) {
                unavailableCopy
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityLabel("Codex 用量，数据不可用，\(statusText)")
    }

    private var unavailableCopy: some View {
        Group {
            Text("Codex 用量")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("数据不可用")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct SmallUsageWidgetView: View {
    let model: WidgetDisplayModel

    var body: some View {
        ViewThatFits(in: .vertical) {
            standardContent
            compactContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                "Codex 用量",
                systemImage: "gauge.with.dots.needle.50percent"
            )
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            todayMetric

            Spacer(minLength: 0)

            if let remaining = model.small.weekRemainingPercent {
                LimitProgressRow(
                    title: "周剩余",
                    remainingPercent: remaining
                )
            } else {
                Text("等待周限额")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(model.small.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Codex 用量")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            todayMetric
            Spacer(minLength: 0)
            if let remaining = model.small.weekRemainingPercent {
                CompactLimitText(
                    title: "周剩余",
                    remainingPercent: remaining
                )
            } else {
                Text("等待周限额")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(model.small.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }

    private var todayMetric: some View {
        Group {
            Text(
                WidgetDisplayFormatting.compactTokens(
                    model.small.todayTokens
                )
            )
            .font(.system(.title, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            Text("今日 Token")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct MediumUsageWidgetView: View {
    let model: WidgetDisplayModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .vertical) {
            standardContent
            compactContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var projectLimit: Int {
        UsageWidgetLayoutPolicy.projectLimit(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    private var visibleProjects: [WidgetProjectUsage] {
        Array(model.medium.projects.prefix(projectLimit))
    }

    private var standardContent: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    "Codex 用量",
                    systemImage: "gauge.with.dots.needle.50percent"
                )
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MetricText(
                        title: "今日",
                        tokens: model.medium.todayTokens,
                        emphasized: true
                    )
                    MetricText(
                        title: "总计",
                        tokens: model.medium.allTimeTokens,
                        emphasized: false
                    )
                }

                VStack(
                    alignment: .leading,
                    spacing: model.medium.usesExpandedWeekLayout ? 8 : 4
                ) {
                    if let fiveHour = model.medium.fiveHourRemainingPercent {
                        LimitProgressRow(
                            title: "5 小时剩余",
                            remainingPercent: fiveHour
                        )
                    }
                    if let week = model.medium.weekRemainingPercent {
                        LimitProgressRow(
                            title: "周剩余",
                            remainingPercent: week
                        )
                    } else {
                        Text("等待周限额")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Text(model.medium.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("项目")
                    .font(.headline)

                if visibleProjects.isEmpty {
                    Text("暂无项目数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleProjects, id: \.id) { project in
                        ProjectUsageRow(project: project)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var compactContent: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    MetricText(
                        title: "今日",
                        tokens: model.medium.todayTokens,
                        emphasized: true
                    )
                    MetricText(
                        title: "总计",
                        tokens: model.medium.allTimeTokens,
                        emphasized: false
                    )
                }

                if let fiveHour = model.medium.fiveHourRemainingPercent {
                    CompactLimitText(
                        title: "5 小时",
                        remainingPercent: fiveHour
                    )
                }
                if let week = model.medium.weekRemainingPercent {
                    CompactLimitText(
                        title: "周剩余",
                        remainingPercent: week
                    )
                } else {
                    Text("等待周限额")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(model.medium.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("项目")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if visibleProjects.isEmpty {
                    Text("暂无数据")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleProjects, id: \.id) { project in
                        ProjectUsageRow(project: project)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MetricText: View {
    let title: String
    let tokens: Int64
    let emphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(WidgetDisplayFormatting.compactTokens(tokens))
                .font(
                    emphasized
                        ? .system(.title3, design: .rounded, weight: .semibold)
                        : .system(.subheadline, design: .rounded, weight: .medium)
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProjectUsageRow: View {
    let project: WidgetProjectUsage

    var body: some View {
        HStack(spacing: 6) {
            Text(project.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 4)
            Text(WidgetDisplayFormatting.compactTokens(project.tokens))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .font(.caption)
    }
}

private struct LimitProgressRow: View {
    let title: String
    let remainingPercent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(WidgetDisplayFormatting.percent(remainingPercent))
                    .monospacedDigit()
            }
            .font(.caption2)

            ProgressView(value: remainingPercent, total: 100)
                .progressViewStyle(.linear)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(title) \(WidgetDisplayFormatting.percent(remainingPercent))"
        )
    }
}

private struct CompactLimitText: View {
    let title: String
    let remainingPercent: Double

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(WidgetDisplayFormatting.percent(remainingPercent))
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption2)
        .minimumScaleFactor(0.65)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(title) \(WidgetDisplayFormatting.percent(remainingPercent))"
        )
    }
}
