import Foundation
import WidgetKit
import CodexUsageShared

struct UsageWidgetEntry: TimelineEntry, Equatable, Sendable {
    let date: Date
    let loadState: WidgetSnapshotLoadState
}

struct UsageTimelinePlan: Equatable, Sendable {
    let entry: UsageWidgetEntry
    let refreshAt: Date
}

struct UsageTimelineProvider: TimelineProvider {
    private let now: () -> Date
    private let readSnapshot: () throws -> WidgetUsageSnapshot?

    init(
        now: @escaping () -> Date = Date.init,
        readSnapshot: @escaping () throws -> WidgetUsageSnapshot? = {
            try WidgetSnapshotStore.appGroup().read()
        }
    ) {
        self.now = now
        self.readSnapshot = readSnapshot
    }

    func placeholder(in context: Context) -> UsageWidgetEntry {
        makePlaceholderEntry(at: now())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (UsageWidgetEntry) -> Void
    ) {
        completion(makeEntry(at: now()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<UsageWidgetEntry>) -> Void
    ) {
        let plan = makeTimelinePlan(at: now())
        completion(
            Timeline(
                entries: [plan.entry],
                policy: .after(plan.refreshAt)
            )
        )
    }

    func makePlaceholderEntry(at date: Date) -> UsageWidgetEntry {
        UsageWidgetEntry(
            date: date,
            loadState: .available(.placeholder)
        )
    }

    func makeEntry(at date: Date) -> UsageWidgetEntry {
        UsageWidgetEntry(date: date, loadState: loadState())
    }

    func makeTimelinePlan(at date: Date) -> UsageTimelinePlan {
        let entry = makeEntry(at: date)
        let model = WidgetDisplayModel(
            loadState: entry.loadState,
            now: date
        )
        return UsageTimelinePlan(
            entry: entry,
            refreshAt: model.nextRefreshAt
        )
    }

    private func loadState() -> WidgetSnapshotLoadState {
        do {
            guard let snapshot = try readSnapshot() else {
                return .missing
            }
            return .available(snapshot)
        } catch {
            return .invalid
        }
    }
}
