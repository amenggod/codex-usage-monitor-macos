import SwiftUI

enum MenuBarFormatter {
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

@MainActor
struct MenuBarLabel: View {
    let snapshot: DashboardSnapshot
    let runtime: AppRuntime

    var body: some View {
        TimelineView(
            .periodic(from: .now, by: UsagePresentationPolicy.refreshInterval)
        ) { context in
            let activeLimits = UsagePresentationPolicy.activeLimits(
                limits: snapshot.limits,
                now: context.date
            )
            let title = MenuBarFormatter.title(limits: activeLimits, now: context.date)

            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text(title)
            }
            .foregroundStyle(labelStyle(limits: activeLimits))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Codex 用量，\(title)")
        }
        .task { await runtime.launch() }
    }

    private func labelStyle(limits: [LimitStatus]) -> AnyShapeStyle {
        if isStale {
            return AnyShapeStyle(.secondary)
        }
        let mostSevereRemaining = limits.map(\.remainingPercent).min() ?? 100
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
