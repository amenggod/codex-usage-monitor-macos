import CodexUsageShared
import Foundation
import Observation

@MainActor
@Observable
public final class MenuBarSnapshotModel {
    public private(set) var display = WidgetDisplayModel(
        loadState: .missing,
        now: .now
    )
    public private(set) var lastValidSnapshot: WidgetUsageSnapshot?
    public private(set) var hasReadError = false

    public var presentationStatusText: String {
        guard hasReadError else { return display.statusText }
        return lastValidSnapshot == nil
            ? "快照读取失败"
            : "快照读取失败 · 显示上次有效数据"
    }

    public init() {}

    func apply(
        snapshot: WidgetUsageSnapshot?,
        now: Date,
        forceTimeUpdate: Bool
    ) {
        let next = WidgetDisplayModel(snapshot: snapshot, now: now)
        guard forceTimeUpdate || next.loadState != display.loadState else {
            hasReadError = false
            return
        }
        lastValidSnapshot = snapshot ?? lastValidSnapshot
        hasReadError = false
        display = next
    }

    func applyReadFailure(now: Date) {
        hasReadError = true
        display = lastValidSnapshot.map {
            WidgetDisplayModel(snapshot: $0, now: now)
        } ?? WidgetDisplayModel(loadState: .invalid, now: now)
    }
}
