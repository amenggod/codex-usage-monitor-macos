import CodexUsageMenuBarCore
import CodexUsageShared
import Foundation
import Testing

@Suite("MenuBarSnapshotMonitorTests")
struct MenuBarSnapshotMonitorTests {
    @Test @MainActor
    func startsWithImmediateReadThenReloadsForSignalAndFallback() {
        let reader = SnapshotReaderStub(results: [
            .success(.placeholder),
            .success(makeSnapshot(today: 20)),
            .success(makeSnapshot(today: 30)),
        ])
        let observer = SnapshotObserverSpy()
        let scheduler = FallbackSchedulerSpy()
        let model = MenuBarSnapshotModel()
        let monitor = MenuBarSnapshotMonitor(
            model: model,
            reader: reader,
            observer: observer,
            scheduler: scheduler,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        monitor.start()

        #expect(model.display.snapshot?.todayTokens == 12_345)
        #expect(scheduler.interval == 60)
        observer.fire()
        #expect(model.display.snapshot?.todayTokens == 20)
        scheduler.fire()
        #expect(model.display.snapshot?.todayTokens == 30)
    }

    @Test @MainActor
    func matchingSignalKeepsDisplayWhileFallbackForcesTimeUpdate() {
        let snapshot = makeSnapshot(today: 20)
        let reader = SnapshotReaderStub(results: [
            .success(snapshot),
            .success(snapshot),
            .success(snapshot),
        ])
        let observer = SnapshotObserverSpy()
        let scheduler = FallbackSchedulerSpy()
        let dates = DateSequence([
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 200),
            Date(timeIntervalSince1970: 300),
        ])
        let model = MenuBarSnapshotModel()
        let monitor = MenuBarSnapshotMonitor(
            model: model,
            reader: reader,
            observer: observer,
            scheduler: scheduler,
            now: dates.next
        )

        monitor.start()
        let initialDisplay = model.display
        observer.fire()

        #expect(model.display == initialDisplay)
        scheduler.fire()
        #expect(model.display.now == Date(timeIntervalSince1970: 300))
    }

    @Test @MainActor
    func failedReadRetainsLastValidSnapshotAndPresentsReadError() {
        let reader = SnapshotReaderStub(results: [
            .success(makeSnapshot(today: 20)),
            .failure(SnapshotReaderError.corrupt),
        ])
        let observer = SnapshotObserverSpy()
        let scheduler = FallbackSchedulerSpy()
        let model = MenuBarSnapshotModel()
        let monitor = MenuBarSnapshotMonitor(
            model: model,
            reader: reader,
            observer: observer,
            scheduler: scheduler,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        monitor.start()
        observer.fire()

        #expect(model.display.snapshot?.todayTokens == 20)
        #expect(model.lastValidSnapshot?.todayTokens == 20)
        #expect(model.hasReadError)
        #expect(model.presentationStatusText == "快照读取失败 · 显示上次有效数据")
    }

    @Test @MainActor
    func successfulReadAfterFailureClearsPresentedReadError() {
        let reader = SnapshotReaderStub(results: [
            .success(makeSnapshot(today: 20)),
            .failure(SnapshotReaderError.corrupt),
            .success(makeSnapshot(today: 30)),
        ])
        let observer = SnapshotObserverSpy()
        let scheduler = FallbackSchedulerSpy()
        let model = MenuBarSnapshotModel()
        let monitor = MenuBarSnapshotMonitor(
            model: model,
            reader: reader,
            observer: observer,
            scheduler: scheduler,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        monitor.start()
        observer.fire()
        #expect(model.hasReadError)

        observer.fire()

        #expect(model.display.snapshot?.todayTokens == 30)
        #expect(model.hasReadError == false)
        #expect(model.presentationStatusText == model.display.statusText)
    }
}

private final class SnapshotReaderStub: MenuBarSnapshotReading, @unchecked Sendable {
    private var results: [Result<WidgetUsageSnapshot?, Error>]

    init(results: [Result<WidgetUsageSnapshot?, Error>]) {
        self.results = results
    }

    func read() throws -> WidgetUsageSnapshot? {
        try results.removeFirst().get()
    }
}

@MainActor
private final class SnapshotObserverSpy: SnapshotChangeObserving {
    private var handler: (@MainActor () -> Void)?

    func start(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func fire() {
        handler?()
    }
}

@MainActor
private final class FallbackSchedulerSpy: MenuBarFallbackScheduling {
    private(set) var interval: TimeInterval?
    private var handler: (@MainActor () -> Void)?
    private let cancellation = FallbackCancellationSpy()

    func schedule(
        every interval: TimeInterval,
        _ handler: @escaping @MainActor () -> Void
    ) -> any MenuBarFallbackCancellation {
        self.interval = interval
        self.handler = handler
        return cancellation
    }

    func fire() {
        handler?()
    }
}

@MainActor
private final class FallbackCancellationSpy: MenuBarFallbackCancellation {
    func cancel() {}
}

private final class DateSequence {
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        dates.removeFirst()
    }
}

private enum SnapshotReaderError: Error {
    case corrupt
}

private func makeSnapshot(today: Int64) -> WidgetUsageSnapshot {
    WidgetUsageSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_000),
        todayTokens: today,
        allTimeTokens: today,
        fiveHourLimit: nil,
        weekLimit: nil,
        limitFreshness: .unavailable,
        projects: [],
        state: .fresh(lastSuccessfulAt: Date(timeIntervalSince1970: 1_000))
    )
}
