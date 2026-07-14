import SwiftUI

struct ProjectRow: View {
    let project: ProjectUsage

    var body: some View {
        HStack(spacing: 12) {
            Text(project.displayName)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(project.usage.total.formatted(.number.notation(.compactName)))
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
        }
        .help(project.fullPath ?? project.displayName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.displayName)，\(project.usage.total) Token")
        .accessibilityHint(project.fullPath ?? "")
    }
}
