import SwiftUI

enum MenuBarFormatter {
    static func title(limits: [LimitStatus]) -> String {
        let fiveHours = limits.first { $0.window == .fiveHours }
        let week = limits.first { $0.window == .week }

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

struct MenuBarLabel: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(MenuBarFormatter.title(limits: snapshot.limits))
        }
        .foregroundStyle(labelStyle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex 用量，\(MenuBarFormatter.title(limits: snapshot.limits))")
    }

    private var labelStyle: AnyShapeStyle {
        if isStale {
            return AnyShapeStyle(.secondary)
        }
        let mostSevereRemaining = snapshot.limits.map(\.remainingPercent).min() ?? 100
        return AnyShapeStyle(limitColor(remaining: mostSevereRemaining))
    }

    private var isStale: Bool {
        switch snapshot.freshness {
        case .stale, .failed:
            true
        default:
            false
        }
    }
}
