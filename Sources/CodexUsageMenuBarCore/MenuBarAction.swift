import CodexUsageShared
import Foundation

public enum MenuBarAction: Sendable {
    case dashboard
    case refresh
    case settings

    public var url: URL {
        switch self {
        case .dashboard:
            URL(string: "codexusagemonitor://dashboard")!
        case .refresh:
            URL(string: "codexusagemonitor://refresh")!
        case .settings:
            URL(string: "codexusagemonitor://settings")!
        }
    }
}

public enum MenuBarHelperFormatting {
    public static func accessibilityTitle(_ model: WidgetDisplayModel) -> String {
        let medium = model.medium
        var parts: [String] = []
        if let fiveHour = medium.fiveHourRemainingPercent {
            parts.append("5 小时 \(WidgetDisplayFormatting.percent(fiveHour))")
        }
        if let week = medium.weekRemainingPercent {
            parts.append("周 \(WidgetDisplayFormatting.percent(week))")
        }
        return parts.isEmpty ? "Codex 用量" : parts.joined(separator: "，")
    }
}
