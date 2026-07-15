import WidgetKit

struct SystemWidgetTimelineReloader: WidgetTimelineReloading {
    func reloadUsageWidget() {
        WidgetCenter.shared.reloadTimelines(
            ofKind: "com.amenggod.CodexUsageMonitor.usage"
        )
    }
}
