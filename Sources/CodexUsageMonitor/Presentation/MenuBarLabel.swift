import AppKit
import SwiftUI

enum MenuBarFormatter {
    @MainActor
    static func templateImage(title: String) -> NSImage {
        let image = NSImage(
            systemSymbolName: "chart.bar.fill",
            accessibilityDescription: title
        ) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    static func title(limits: [LimitStatus], now: Date = .now) -> String {
        let activeLimits = UsagePresentationPolicy.activeLimits(limits: limits, now: now)
        let fiveHours = activeLimits.first { $0.window == .fiveHours }
        let week = activeLimits.first { $0.window == .week }

        return switch (fiveHours, week) {
        case let (.some(fiveHours), .some(week)):
            "5h \(Int(fiveHours.remainingPercent.rounded()))% · 周 \(Int(week.remainingPercent.rounded()))%"
        case let (.some(fiveHours), .none):
            "5h \(Int(fiveHours.remainingPercent.rounded()))%"
        case let (.none, .some(week)):
            "周 \(Int(week.remainingPercent.rounded()))%"
        case (.none, .none):
            "Codex --"
        }
    }
}

func limitColor(remaining: Double) -> Color {
    if remaining < 10 { return .red }
    if remaining < 20 { return .orange }
    return .accentColor
}
