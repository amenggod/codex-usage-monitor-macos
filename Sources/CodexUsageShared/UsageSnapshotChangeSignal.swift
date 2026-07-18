import CoreFoundation
import Foundation

public enum UsageSnapshotChangeSignal {
    public static let rawName =
        "com.amenggod.CodexUsageMonitor.snapshot-changed.v1"
}

public protocol UsageSnapshotChangePosting: Sendable {
    func postSnapshotChanged()
}

public struct DarwinUsageSnapshotChangePoster:
    UsageSnapshotChangePosting,
    Sendable {
    public init() {}

    public func postSnapshotChanged() {
        let name = CFNotificationName(
            UsageSnapshotChangeSignal.rawName as CFString
        )
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }
}
