import SwiftUI

struct LimitCard: View {
    let status: LimitStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.window.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(Int(status.remainingPercent.rounded()))%")
                .font(.system(size: 32, weight: .semibold, design: .rounded))

            ProgressView(value: status.remainingPercent, total: 100)
                .tint(limitColor(remaining: status.remainingPercent))

            Text("重置于 \(status.resetsAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(status.resetsAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(status.window.displayName)，剩余 \(Int(status.remainingPercent.rounded()))%，重置于 \(status.resetsAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }
}
