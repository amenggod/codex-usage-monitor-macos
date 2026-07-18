import CodexUsageShared
import Foundation

public protocol MenuBarSnapshotReading: Sendable {
    func read() throws -> WidgetUsageSnapshot?
}

extension WidgetSnapshotStore: MenuBarSnapshotReading {}

@MainActor
public protocol SnapshotChangeObserving: AnyObject {
    func start(_ handler: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
public protocol MenuBarFallbackCancellation: AnyObject {
    func cancel()
}

@MainActor
public protocol MenuBarFallbackScheduling: AnyObject {
    func schedule(
        every interval: TimeInterval,
        _ handler: @escaping @MainActor () -> Void
    ) -> any MenuBarFallbackCancellation
}

@MainActor
public final class MenuBarSnapshotMonitor {
    public static let fallbackInterval: TimeInterval = 60

    private let model: MenuBarSnapshotModel
    private let reader: any MenuBarSnapshotReading
    private let observer: any SnapshotChangeObserving
    private let scheduler: any MenuBarFallbackScheduling
    private let now: () -> Date
    private var cancellation: (any MenuBarFallbackCancellation)?
    private var started = false

    public init(
        model: MenuBarSnapshotModel,
        reader: any MenuBarSnapshotReading,
        observer: any SnapshotChangeObserving,
        scheduler: any MenuBarFallbackScheduling,
        now: @escaping () -> Date
    ) {
        self.model = model
        self.reader = reader
        self.observer = observer
        self.scheduler = scheduler
        self.now = now
    }

    public func start() {
        guard !started else { return }
        started = true
        observer.start { [weak self] in
            self?.reload(forceTimeUpdate: false)
        }
        cancellation = scheduler.schedule(every: Self.fallbackInterval) { [weak self] in
            self?.reload(forceTimeUpdate: true)
        }
        reload(forceTimeUpdate: true)
    }

    public func stop() {
        observer.stop()
        cancellation?.cancel()
        cancellation = nil
        started = false
    }

    public func reload(forceTimeUpdate: Bool = false) {
        do {
            model.apply(
                snapshot: try reader.read(),
                now: now(),
                forceTimeUpdate: forceTimeUpdate
            )
        } catch {
            model.applyReadFailure(now: now())
        }
    }
}
