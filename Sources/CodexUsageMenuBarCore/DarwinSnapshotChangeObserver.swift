import CodexUsageShared
import CoreFoundation
import Foundation

@MainActor
public final class DarwinSnapshotChangeObserver: SnapshotChangeObserving {
    private var handler: (@MainActor () -> Void)?
    private var isObserving = false

    public init() {}

    public func start(_ handler: @escaping @MainActor () -> Void) {
        guard !isObserving else { return }
        self.handler = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            darwinSnapshotChangeCallback,
            Self.notificationName,
            nil,
            .deliverImmediately
        )
        isObserving = true
    }

    public func stop() {
        guard isObserving else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(Self.notificationName),
            nil
        )
        handler = nil
        isObserving = false
    }

    private static let notificationName = UsageSnapshotChangeSignal.rawName as CFString

    fileprivate func notifyChange() {
        handler?()
    }
}

private func darwinSnapshotChangeCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    guard let observer else { return }
    let changeObserver = Unmanaged<DarwinSnapshotChangeObserver>
        .fromOpaque(observer)
        .takeUnretainedValue()
    Task { @MainActor in
        changeObserver.notifyChange()
    }
}

@MainActor
public final class TimerMenuBarFallbackScheduler: MenuBarFallbackScheduling {
    public init() {}

    public func schedule(
        every interval: TimeInterval,
        _ handler: @escaping @MainActor () -> Void
    ) -> any MenuBarFallbackCancellation {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                handler()
            }
        }
        return TimerMenuBarFallbackCancellation(timer: timer)
    }
}

@MainActor
private final class TimerMenuBarFallbackCancellation: MenuBarFallbackCancellation {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer.invalidate()
    }
}
