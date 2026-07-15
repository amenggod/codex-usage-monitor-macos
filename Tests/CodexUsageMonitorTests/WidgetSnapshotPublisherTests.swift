import Foundation
import Testing
import CodexUsageShared
@testable import CodexUsageMonitor

@Suite("WidgetSnapshotPublisherTests")
struct WidgetSnapshotPublisherTests {
    @MainActor
    @Test func publisherWritesTodayAndAllTimeWithoutLeakingFullPaths() async throws {
        let today = makeSnapshot(range: .today, total: 12, projects: [])
        let all = makeSnapshot(
            range: .all,
            total: 100,
            projects: [
                ProjectUsage(
                    id: "p",
                    displayName: "monitor",
                    fullPath: "/secret/path",
                    usage: usage(80)
                )
            ]
        )
        let store = WidgetStoreSpy()
        let reloader = WidgetReloaderSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([today, all]),
            store: store,
            reloader: reloader
        )

        #expect(await publisher.publish(now: testNow, calendar: testCalendar) == .ready(testNow))
        let written = try #require(store.lastSnapshot)
        #expect(written.todayTokens == 12)
        #expect(written.allTimeTokens == 100)
        #expect(written.projects == [WidgetProjectUsage(id: "p", name: "monitor", tokens: 80)])
        #expect(reloader.reloadCount == 1)
    }

    @Test func identicalVisibleValuesWriteFreshTimeButReloadOnlyOnce() async {
        let today = makeSnapshot(range: .today, total: 12, projects: [])
        let all = makeSnapshot(range: .all, total: 100, projects: [])
        let store = WidgetStoreSpy()
        let reloader = WidgetReloaderSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([today, all, today, all]),
            store: store,
            reloader: reloader
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)
        _ = await publisher.publish(
            now: testNow.addingTimeInterval(1),
            calendar: testCalendar
        )

        #expect(store.snapshots.count == 2)
        #expect(reloader.reloadCount == 1)
    }

    @Test func storeFailureReturnsUnavailableWithoutBreakingUsageRefresh() async {
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(range: .today, total: 12, projects: []),
                makeSnapshot(range: .all, total: 100, projects: []),
            ]),
            store: WidgetStoreSpy(writeFailure: WidgetStoreTestFailure()),
            reloader: WidgetReloaderSpy()
        )

        #expect(
            await publisher.publish(now: testNow, calendar: testCalendar)
                == .unavailable("小组件共享不可用")
        )
    }
}

private actor WidgetPublisherAggregatorSpy: UsageAggregating {
    private var snapshots: [DashboardSnapshot]

    init(_ snapshots: [DashboardSnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot(
        range: TokenRange,
        now: Date,
        calendar: Calendar
    ) async throws -> DashboardSnapshot {
        guard !snapshots.isEmpty else { throw WidgetStoreTestFailure() }
        return snapshots.removeFirst()
    }
}

private final class WidgetStoreSpy: @unchecked Sendable, WidgetSnapshotStoring {
    private let lock = NSLock()
    private var storedSnapshots: [WidgetUsageSnapshot] = []
    private let writeFailure: WidgetStoreTestFailure?

    init(writeFailure: WidgetStoreTestFailure? = nil) {
        self.writeFailure = writeFailure
    }

    var snapshots: [WidgetUsageSnapshot] { lock.withLock { storedSnapshots } }
    var lastSnapshot: WidgetUsageSnapshot? { snapshots.last }

    func read() throws -> WidgetUsageSnapshot? { lastSnapshot }

    func write(_ snapshot: WidgetUsageSnapshot) throws {
        if let writeFailure { throw writeFailure }
        lock.withLock { storedSnapshots.append(snapshot) }
    }
}

private final class WidgetReloaderSpy: @unchecked Sendable, WidgetTimelineReloading {
    private let lock = NSLock()
    private var count = 0
    var reloadCount: Int { lock.withLock { count } }

    func reloadUsageWidget() {
        lock.withLock { count += 1 }
    }
}

private struct WidgetStoreTestFailure: Error, Sendable {}

private let testNow = Date(timeIntervalSince1970: 1_784_164_800)
private let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

private func makeSnapshot(
    range: TokenRange,
    total: Int64,
    projects: [ProjectUsage]
) -> DashboardSnapshot {
    DashboardSnapshot(
        range: range,
        total: TokenUsage(
            input: total,
            cachedInput: 0,
            output: 0,
            reasoningOutput: 0,
            total: total
        ),
        projects: projects,
        limits: [
            LimitStatus(
                window: .week,
                usedPercent: 28,
                resetsAt: testNow.addingTimeInterval(86_400)
            )
        ],
        freshness: .fresh(testNow)
    )
}

private func usage(_ total: Int64) -> TokenUsage {
    TokenUsage(
        input: total,
        cachedInput: 0,
        output: 0,
        reasoningOutput: 0,
        total: total
    )
}
