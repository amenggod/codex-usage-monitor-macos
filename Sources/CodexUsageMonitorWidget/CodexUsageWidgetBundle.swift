import SwiftUI
import WidgetKit

#if WIDGET_EXTENSION
@main
#endif
struct CodexUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexUsageWidget()
    }
}

struct CodexUsageWidget: Widget {
    static let kind = "com.amenggod.CodexUsageMonitor.usage"
    static let dashboardURL = URL(string: "codexusagemonitor://dashboard")!

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: Self.kind,
            provider: UsageTimelineProvider()
        ) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(Self.dashboardURL)
        }
        .configurationDisplayName("Codex 用量")
        .description("查看最近一次同步的 Token 用量与限额。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
