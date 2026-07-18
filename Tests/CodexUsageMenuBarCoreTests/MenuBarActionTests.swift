import CodexUsageMenuBarCore
import CodexUsageShared
import Foundation
import Testing

@Suite
struct MenuBarActionTests {
    @Test func actionsUseExactMainApplicationURLs() {
        #expect(
            MenuBarAction.dashboard.url.absoluteString
                == "codexusagemonitor://dashboard"
        )
        #expect(
            MenuBarAction.refresh.url.absoluteString
                == "codexusagemonitor://refresh"
        )
        #expect(
            MenuBarAction.settings.url.absoluteString
                == "codexusagemonitor://settings"
        )
    }

    @Test func titleHidesMissingFiveHourLimit() {
        let model = WidgetDisplayModel(snapshot: .placeholder, now: .now)
        let title = MenuBarHelperFormatting.accessibilityTitle(model)

        #expect(title.contains("周"))
        #expect(!title.contains("5 小时"))
    }
}
