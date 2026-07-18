import Foundation
import Testing
import CodexUsageShared
@testable import CodexUsageMonitor

@Suite("WidgetSnapshotPublisherTests")
struct WidgetSnapshotPublisherTests {
    @MainActor
    @Test func publisherWritesTodayAndAllTimeWithoutLeakingFullPaths() async throws {
        let privatePath = "/Users/alice/secret/monitor"
        let today = makeSnapshot(range: .today, total: 12, projects: [])
        let all = makeSnapshot(
            range: .all,
            total: 100,
            projects: [
                ProjectUsage(
                    id: privatePath,
                    displayName: "monitor",
                    fullPath: privatePath,
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
        #expect(written.projects == [
            WidgetProjectUsage(
                id: "605e0c2fcfe89bebbec3fd55af1013c0df275cc6eed77f83fcad13238325ed94",
                name: "monitor",
                tokens: 80
            )
        ])
        let json = try #require(String(
            data: JSONEncoder.widgetSnapshot.encode(written),
            encoding: .utf8
        ))
        #expect(!json.contains(privatePath))
        #expect(reloader.reloadCount == 1)
    }

    @Test func publisherWritesSixtyNinePercentWithFreshObservationTime() async throws {
        let observedAt = testNow.addingTimeInterval(-30)
        let week = LimitStatus(
            window: .week,
            usedPercent: 31,
            resetsAt: testNow.addingTimeInterval(86_400)
        )
        let store = WidgetStoreSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [week],
                    limitFreshness: .fresh(observedAt)
                ),
                makeSnapshot(range: .all, total: 100, projects: []),
            ]),
            store: store,
            reloader: WidgetReloaderSpy()
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)

        #expect(store.lastSnapshot?.weekLimit?.remainingPercent == 69)
        #expect(store.lastSnapshot?.limitFreshness == .fresh(observedAt: observedAt))
    }

    @Test func successfulSnapshotWritePostsCrossProcessChangeSignal() async {
        let poster = SnapshotChangePosterSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(range: .today, total: 12, projects: []),
                makeSnapshot(range: .all, total: 34, projects: []),
            ]),
            store: WidgetStoreSpy(),
            reloader: WidgetReloaderSpy(),
            changePoster: poster
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)

        #expect(poster.postCount == 1)
    }

    @Test func failedSnapshotWriteDoesNotPostCrossProcessChangeSignal() async {
        let poster = SnapshotChangePosterSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(range: .today, total: 12, projects: []),
                makeSnapshot(range: .all, total: 34, projects: []),
            ]),
            store: WidgetStoreSpy(writeError: WidgetStoreTestFailure()),
            reloader: WidgetReloaderSpy(),
            changePoster: poster
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)

        #expect(poster.postCount == 0)
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

    @Test func newerFreshObservationWritesSnapshotWithoutSpendingAnotherReload() async throws {
        let firstObservedAt = testNow.addingTimeInterval(-60)
        let secondObservedAt = testNow
        let week = LimitStatus(
            window: .week,
            usedPercent: 40,
            resetsAt: testNow.addingTimeInterval(86_400)
        )
        let all = makeSnapshot(range: .all, total: 100, projects: [])
        let store = WidgetStoreSpy()
        let reloader = WidgetReloaderSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [week],
                    limitFreshness: .fresh(firstObservedAt)
                ),
                all,
                makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [week],
                    limitFreshness: .fresh(secondObservedAt)
                ),
                all,
            ]),
            store: store,
            reloader: reloader
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)
        _ = await publisher.publish(
            now: testNow.addingTimeInterval(60),
            calendar: testCalendar
        )

        #expect(store.snapshots.count == 2)
        #expect(store.snapshots[0].generatedAt == testNow)
        #expect(store.snapshots[1].generatedAt == testNow.addingTimeInterval(60))
        #expect(try #require(store.lastSnapshot).limitFreshness == .fresh(
            observedAt: secondObservedAt
        ))
        #expect(reloader.reloadCount == 1)
    }

    @Test func freshnessCategoryChangeStillTriggersReload() async {
        let observedAt = testNow.addingTimeInterval(-60)
        let week = LimitStatus(
            window: .week,
            usedPercent: 40,
            resetsAt: testNow.addingTimeInterval(86_400)
        )
        let all = makeSnapshot(range: .all, total: 100, projects: [])
        let reloader = WidgetReloaderSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [week],
                    limitFreshness: .fresh(observedAt)
                ),
                all,
                makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [week],
                    limitFreshness: .stale(observedAt)
                ),
                all,
            ]),
            store: WidgetStoreSpy(),
            reloader: reloader
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)
        _ = await publisher.publish(
            now: testNow.addingTimeInterval(60),
            calendar: testCalendar
        )

        #expect(reloader.reloadCount == 2)
    }

    @Test func weekRemainingChangeTriggersReload() async {
        let observedAt = testNow
        let firstWeek = LimitStatus(
            window: .week,
            usedPercent: 40,
            resetsAt: testNow.addingTimeInterval(86_400)
        )
        let secondWeek = LimitStatus(
            window: .week,
            usedPercent: 41,
            resetsAt: firstWeek.resetsAt
        )
        let all = makeSnapshot(range: .all, total: 100, projects: [])
        let reloader = WidgetReloaderSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [firstWeek],
                    limitFreshness: .fresh(observedAt)
                ),
                all,
                makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [secondWeek],
                    limitFreshness: .fresh(observedAt)
                ),
                all,
            ]),
            store: WidgetStoreSpy(),
            reloader: reloader
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)
        _ = await publisher.publish(
            now: testNow.addingTimeInterval(60),
            calendar: testCalendar
        )

        #expect(reloader.reloadCount == 2)
    }

    @Test func visibleValueChangeTriggersASecondReload() async {
        let reloader = WidgetReloaderSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(range: .today, total: 12, projects: []),
                makeSnapshot(range: .all, total: 100, projects: []),
                makeSnapshot(range: .today, total: 13, projects: []),
                makeSnapshot(range: .all, total: 100, projects: []),
            ]),
            store: WidgetStoreSpy(),
            reloader: reloader
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)
        _ = await publisher.publish(
            now: testNow.addingTimeInterval(1),
            calendar: testCalendar
        )

        #expect(reloader.reloadCount == 2)
    }

    @Test func freshOrStaleLimitBecomingUnavailableTriggersReload() async {
        let week = LimitStatus(
            window: .week,
            usedPercent: 40,
            resetsAt: testNow.addingTimeInterval(86_400)
        )
        let unavailable = LimitDataFreshness.unavailable(
            lastSuccessfulAt: testNow,
            message: "实时限额暂不可用"
        )

        for initialFreshness in [
            LimitDataFreshness.fresh(testNow),
            .stale(testNow),
        ] {
            let reloadCount = await secondPublishReloadCount(
                firstToday: makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [week],
                    limitFreshness: initialFreshness
                ),
                firstAll: makeSnapshot(range: .all, total: 100, projects: []),
                secondToday: makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [week],
                    limitFreshness: unavailable
                ),
                secondAll: makeSnapshot(range: .all, total: 100, projects: [])
            )

            #expect(reloadCount == 2)
        }
    }

    @Test func visibleProjectRankingChangeTriggersReload() async {
        let firstProjects = [
            ProjectUsage(
                id: "alpha",
                displayName: "Alpha",
                fullPath: nil,
                usage: usage(80)
            )
        ]
        let secondProjects = [
            ProjectUsage(
                id: "beta",
                displayName: "Beta",
                fullPath: nil,
                usage: usage(90)
            )
        ]

        let reloadCount = await secondPublishReloadCount(
            firstToday: makeSnapshot(range: .today, total: 12, projects: []),
            firstAll: makeSnapshot(range: .all, total: 100, projects: firstProjects),
            secondToday: makeSnapshot(range: .today, total: 12, projects: []),
            secondAll: makeSnapshot(range: .all, total: 100, projects: secondProjects)
        )

        #expect(reloadCount == 2)
    }

    @Test func limitAppearanceAndDisappearanceEachTriggerReload() async {
        let week = LimitStatus(
            window: .week,
            usedPercent: 40,
            resetsAt: testNow.addingTimeInterval(86_400)
        )
        let all = makeSnapshot(range: .all, total: 100, projects: [])
        let reloader = WidgetReloaderSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(range: .today, total: 12, projects: [], limits: []),
                all,
                makeSnapshot(range: .today, total: 12, projects: [], limits: [week]),
                all,
                makeSnapshot(range: .today, total: 12, projects: [], limits: []),
                all,
            ]),
            store: WidgetStoreSpy(),
            reloader: reloader
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)
        #expect(reloader.reloadCount == 1)

        _ = await publisher.publish(
            now: testNow.addingTimeInterval(1),
            calendar: testCalendar
        )
        #expect(reloader.reloadCount == 2)

        _ = await publisher.publish(
            now: testNow.addingTimeInterval(2),
            calendar: testCalendar
        )
        #expect(reloader.reloadCount == 3)
    }

    @Test func widgetDataStateCategoryChangeTriggersReload() async {
        let reloadCount = await secondPublishReloadCount(
            firstToday: makeSnapshot(
                range: .today,
                total: 12,
                projects: [],
                freshness: .fresh(testNow)
            ),
            firstAll: makeSnapshot(range: .all, total: 100, projects: []),
            secondToday: makeSnapshot(
                range: .today,
                total: 12,
                projects: [],
                freshness: .stale(testNow)
            ),
            secondAll: makeSnapshot(range: .all, total: 100, projects: [])
        )

        #expect(reloadCount == 2)
    }

    @Test func partialFailedFileCountChangeTriggersReload() async {
        let reloadCount = await secondPublishReloadCount(
            firstToday: makeSnapshot(
                range: .today,
                total: 12,
                projects: [],
                freshness: .partial(testNow, failedFiles: 1)
            ),
            firstAll: makeSnapshot(range: .all, total: 100, projects: []),
            secondToday: makeSnapshot(
                range: .today,
                total: 12,
                projects: [],
                freshness: .partial(testNow, failedFiles: 2)
            ),
            secondAll: makeSnapshot(range: .all, total: 100, projects: [])
        )

        #expect(reloadCount == 2)
    }

    @Test func publisherMapsActiveLimitsAndHidesExpiredFiveHourLimit() async throws {
        let activeFiveHour = LimitStatus(
            limitID: "five",
            window: .fiveHours,
            usedPercent: 40,
            resetsAt: testNow.addingTimeInterval(3_600)
        )
        let activeWeek = LimitStatus(
            limitID: "week",
            window: .week,
            usedPercent: 28,
            resetsAt: testNow.addingTimeInterval(86_400)
        )
        let expiredFiveHour = LimitStatus(
            limitID: "five",
            window: .fiveHours,
            usedPercent: 41,
            resetsAt: testNow.addingTimeInterval(1)
        )
        let store = WidgetStoreSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [activeFiveHour, activeWeek]
                ),
                makeSnapshot(range: .all, total: 100, projects: []),
                makeSnapshot(
                    range: .today,
                    total: 12,
                    projects: [],
                    limits: [expiredFiveHour, activeWeek]
                ),
                makeSnapshot(range: .all, total: 100, projects: []),
            ]),
            store: store,
            reloader: WidgetReloaderSpy()
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)
        let active = try #require(store.lastSnapshot)
        #expect(active.fiveHourLimit == WidgetLimitStatus(
            id: "five",
            remainingPercent: 60,
            resetsAt: activeFiveHour.resetsAt
        ))
        #expect(active.weekLimit == WidgetLimitStatus(
            id: "week",
            remainingPercent: 72,
            resetsAt: activeWeek.resetsAt
        ))

        _ = await publisher.publish(
            now: testNow.addingTimeInterval(1),
            calendar: testCalendar
        )
        #expect(store.lastSnapshot?.fiveHourLimit == nil)
        #expect(store.lastSnapshot?.weekLimit?.id == "week")
    }

    @Test func publisherUsesPartialFreshnessOverride() async throws {
        let store = WidgetStoreSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(range: .today, total: 12, projects: []),
                makeSnapshot(range: .all, total: 100, projects: []),
            ]),
            store: store,
            reloader: WidgetReloaderSpy()
        )

        _ = await publisher.publish(
            now: testNow,
            calendar: testCalendar,
            freshness: .partial(testNow, failedFiles: 2)
        )

        #expect(try #require(store.lastSnapshot).state == .partial(
            lastSuccessfulAt: testNow,
            failedFiles: 2
        ))
    }

    @Test func publisherRequestsTodayAndAllFromOneAtomicBoundary() async {
        let aggregator = WidgetPublisherAggregatorSpy([
            makeSnapshot(range: .today, total: 12, projects: []),
            makeSnapshot(range: .all, total: 100, projects: []),
        ])
        let publisher = WidgetSnapshotPublisher(
            aggregator: aggregator,
            store: WidgetStoreSpy(),
            reloader: WidgetReloaderSpy()
        )

        _ = await publisher.publish(now: testNow, calendar: testCalendar)

        #expect(await aggregator.atomicRequestCount == 1)
        #expect(await aggregator.requestedRanges.isEmpty)
    }

    @Test func olderConcurrentPublishCannotOverwriteNewerSnapshot() async throws {
        let oldNow = testNow
        let newNow = testNow.addingTimeInterval(1)
        let aggregator = GatedWidgetPublisherAggregator()
        let store = WidgetStoreSpy()
        let reloader = WidgetReloaderSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: aggregator,
            store: store,
            reloader: reloader
        )

        let oldPublish = Task {
            await publisher.publish(now: oldNow, calendar: testCalendar)
        }
        #expect(await publisherEventually { await aggregator.hasRequest(now: oldNow) })
        let newPublish = Task {
            await publisher.publish(now: newNow, calendar: testCalendar)
        }
        #expect(await publisherEventually { await aggregator.hasRequest(now: newNow) })

        await aggregator.succeed(
            now: newNow,
            today: makeSnapshot(range: .today, total: 20, projects: []),
            all: makeSnapshot(range: .all, total: 200, projects: [])
        )
        _ = await newPublish.value
        await aggregator.succeed(
            now: oldNow,
            today: makeSnapshot(range: .today, total: 10, projects: []),
            all: makeSnapshot(range: .all, total: 100, projects: [])
        )
        _ = await oldPublish.value

        let written = try #require(store.lastSnapshot)
        #expect(store.snapshots.count == 1)
        #expect(written.generatedAt == newNow)
        #expect(written.todayTokens == 20)
        #expect(written.allTimeTokens == 200)
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

    @Test func rebuildingPreservesEveryTrustedFieldAndTheReliableSuccessTime() async throws {
        let lastSuccessfulAt = testNow.addingTimeInterval(-300)
        let original = makeStoredWidgetSnapshot(
            generatedAt: testNow.addingTimeInterval(-60),
            state: .fresh(lastSuccessfulAt: lastSuccessfulAt)
        )
        let store = WidgetStoreSpy(initialSnapshot: original)
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([]),
            store: store,
            reloader: WidgetReloaderSpy()
        )

        #expect(await publisher.publishRebuilding(now: testNow) == .ready(testNow))

        let written = try #require(store.lastSnapshot)
        #expect(written.generatedAt == original.generatedAt)
        #expect(written.todayTokens == original.todayTokens)
        #expect(written.allTimeTokens == original.allTimeTokens)
        #expect(written.fiveHourLimit == original.fiveHourLimit)
        #expect(written.weekLimit == original.weekLimit)
        #expect(written.projects == original.projects)
        #expect(written.state == .rebuilding(lastSuccessfulAt: lastSuccessfulAt))
    }

    @Test func rebuildingCarriesSuccessTimeFromEveryReliablePriorState() async throws {
        let reliableTime = testNow.addingTimeInterval(-600)
        let states: [WidgetDataState] = [
            .fresh(lastSuccessfulAt: reliableTime),
            .partial(lastSuccessfulAt: reliableTime, failedFiles: 2),
            .stale(lastSuccessfulAt: reliableTime),
            .rebuilding(lastSuccessfulAt: reliableTime),
        ]

        for state in states {
            let store = WidgetStoreSpy(
                initialSnapshot: makeStoredWidgetSnapshot(state: state)
            )
            let publisher = WidgetSnapshotPublisher(
                aggregator: WidgetPublisherAggregatorSpy([]),
                store: store,
                reloader: WidgetReloaderSpy()
            )

            _ = await publisher.publishRebuilding(now: testNow)

            #expect(try #require(store.lastSnapshot).state == .rebuilding(
                lastSuccessfulAt: reliableTime
            ))
        }
    }

    @Test func rebuildingWithoutPriorSnapshotPublishesUnavailableDisplayState() async throws {
        let store = WidgetStoreSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([]),
            store: store,
            reloader: WidgetReloaderSpy()
        )

        #expect(await publisher.publishRebuilding(now: testNow) == .ready(testNow))

        let written = try #require(store.lastSnapshot)
        #expect(written.generatedAt == testNow)
        #expect(written.state == .rebuilding(lastSuccessfulAt: nil))
        #expect(!WidgetDisplayModel(snapshot: written, now: testNow).canDisplayUsageValues)
    }

    @Test func repeatedRebuildingReloadsOnceAndCompletedPublishRestoresFreshValues() async throws {
        let priorTime = testNow.addingTimeInterval(-120)
        let store = WidgetStoreSpy(
            initialSnapshot: makeStoredWidgetSnapshot(
                state: .fresh(lastSuccessfulAt: priorTime)
            )
        )
        let reloader = WidgetReloaderSpy()
        let publisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([
                makeSnapshot(range: .today, total: 24, projects: []),
                makeSnapshot(range: .all, total: 240, projects: []),
            ]),
            store: store,
            reloader: reloader
        )

        _ = await publisher.publishRebuilding(now: testNow)
        _ = await publisher.publishRebuilding(now: testNow.addingTimeInterval(1))
        #expect(reloader.reloadCount == 1)

        let completedAt = testNow.addingTimeInterval(2)
        _ = await publisher.publish(
            now: completedAt,
            calendar: testCalendar,
            freshness: .fresh(completedAt)
        )

        let completed = try #require(store.lastSnapshot)
        #expect(completed.todayTokens == 24)
        #expect(completed.allTimeTokens == 240)
        #expect(completed.generatedAt == completedAt)
        #expect(completed.state == .fresh(lastSuccessfulAt: completedAt))
        #expect(reloader.reloadCount == 2)
    }

    @Test func rebuildingStoreReadOrWriteFailureReturnsUnavailable() async {
        let readFailurePublisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([]),
            store: WidgetStoreSpy(readFailure: WidgetStoreTestFailure()),
            reloader: WidgetReloaderSpy()
        )
        let writeFailurePublisher = WidgetSnapshotPublisher(
            aggregator: WidgetPublisherAggregatorSpy([]),
            store: WidgetStoreSpy(writeFailure: WidgetStoreTestFailure()),
            reloader: WidgetReloaderSpy()
        )

        #expect(
            await readFailurePublisher.publishRebuilding(now: testNow)
                == .unavailable("小组件共享不可用")
        )
        #expect(
            await writeFailurePublisher.publishRebuilding(now: testNow)
                == .unavailable("小组件共享不可用")
        )
    }
}

private actor WidgetPublisherAggregatorSpy: UsageAggregating, WidgetSnapshotAggregating {
    private var snapshots: [DashboardSnapshot]
    private(set) var requestedRanges: [TokenRange] = []
    private(set) var atomicRequestCount = 0

    init(_ snapshots: [DashboardSnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot(
        range: TokenRange,
        now: Date,
        calendar: Calendar
    ) async throws -> DashboardSnapshot {
        requestedRanges.append(range)
        guard !snapshots.isEmpty else { throw WidgetStoreTestFailure() }
        return snapshots.removeFirst()
    }

    func widgetSnapshots(
        now: Date,
        calendar: Calendar
    ) async throws -> WidgetDashboardSnapshots {
        atomicRequestCount += 1
        guard snapshots.count >= 2 else { throw WidgetStoreTestFailure() }
        return WidgetDashboardSnapshots(
            today: snapshots.removeFirst(),
            all: snapshots.removeFirst()
        )
    }
}

private actor GatedWidgetPublisherAggregator: UsageAggregating, WidgetSnapshotAggregating {
    private struct PendingRequest {
        let now: Date
        let continuation: CheckedContinuation<WidgetDashboardSnapshots, any Error>
    }

    private var pendingRequests: [PendingRequest] = []

    func snapshot(
        range: TokenRange,
        now: Date,
        calendar: Calendar
    ) async throws -> DashboardSnapshot {
        throw WidgetStoreTestFailure()
    }

    func widgetSnapshots(
        now: Date,
        calendar: Calendar
    ) async throws -> WidgetDashboardSnapshots {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(PendingRequest(now: now, continuation: continuation))
        }
    }

    func hasRequest(now: Date) -> Bool {
        pendingRequests.contains { $0.now == now }
    }

    func succeed(now: Date, today: DashboardSnapshot, all: DashboardSnapshot) {
        guard let index = pendingRequests.firstIndex(where: { $0.now == now }) else {
            Issue.record("No pending widget request for \(now)")
            return
        }
        pendingRequests.remove(at: index).continuation.resume(
            returning: WidgetDashboardSnapshots(today: today, all: all)
        )
    }
}

private final class WidgetStoreSpy: @unchecked Sendable, WidgetSnapshotStoring {
    private let lock = NSLock()
    private var storedSnapshots: [WidgetUsageSnapshot] = []
    private let readFailure: WidgetStoreTestFailure?
    private let writeFailure: WidgetStoreTestFailure?
    private let writeError: Error?

    init(
        initialSnapshot: WidgetUsageSnapshot? = nil,
        readFailure: WidgetStoreTestFailure? = nil,
        writeFailure: WidgetStoreTestFailure? = nil,
        writeError: Error? = nil
    ) {
        if let initialSnapshot {
            storedSnapshots = [initialSnapshot]
        }
        self.readFailure = readFailure
        self.writeFailure = writeFailure
        self.writeError = writeError
    }

    var snapshots: [WidgetUsageSnapshot] { lock.withLock { storedSnapshots } }
    var lastSnapshot: WidgetUsageSnapshot? { snapshots.last }

    func read() throws -> WidgetUsageSnapshot? {
        if let readFailure { throw readFailure }
        return lastSnapshot
    }

    func write(_ snapshot: WidgetUsageSnapshot) throws {
        if let writeError { throw writeError }
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

private final class SnapshotChangePosterSpy: @unchecked Sendable,
    UsageSnapshotChangePosting {
    private let lock = NSLock()
    private var count = 0

    var postCount: Int { lock.withLock { count } }

    func postSnapshotChanged() {
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
    projects: [ProjectUsage],
    limits: [LimitStatus]? = nil,
    freshness: DataFreshness = .fresh(testNow),
    limitFreshness: LimitDataFreshness = .fresh(testNow)
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
        limits: limits ?? [
            LimitStatus(
                window: .week,
                usedPercent: 28,
                resetsAt: testNow.addingTimeInterval(86_400)
            )
        ],
        freshness: freshness,
        limitFreshness: limitFreshness
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

private func makeStoredWidgetSnapshot(
    generatedAt: Date = testNow.addingTimeInterval(-60),
    state: WidgetDataState = .fresh(lastSuccessfulAt: testNow.addingTimeInterval(-60))
) -> WidgetUsageSnapshot {
    WidgetUsageSnapshot(
        generatedAt: generatedAt,
        todayTokens: 12,
        allTimeTokens: 120,
        fiveHourLimit: WidgetLimitStatus(
            id: "five",
            remainingPercent: 64,
            resetsAt: testNow.addingTimeInterval(3_600)
        ),
        weekLimit: WidgetLimitStatus(
            id: "week",
            remainingPercent: 72,
            resetsAt: testNow.addingTimeInterval(86_400)
        ),
        limitFreshness: .fresh(observedAt: generatedAt),
        projects: [
            WidgetProjectUsage(id: "project", name: "Project", tokens: 80)
        ],
        state: state
    )
}

private func secondPublishReloadCount(
    firstToday: DashboardSnapshot,
    firstAll: DashboardSnapshot,
    secondToday: DashboardSnapshot,
    secondAll: DashboardSnapshot
) async -> Int {
    let reloader = WidgetReloaderSpy()
    let publisher = WidgetSnapshotPublisher(
        aggregator: WidgetPublisherAggregatorSpy([
            firstToday,
            firstAll,
            secondToday,
            secondAll,
        ]),
        store: WidgetStoreSpy(),
        reloader: reloader
    )

    _ = await publisher.publish(now: testNow, calendar: testCalendar)
    _ = await publisher.publish(
        now: testNow.addingTimeInterval(1),
        calendar: testCalendar
    )
    return reloader.reloadCount
}

private func publisherEventually(
    attempts: Int = 100,
    _ condition: @escaping () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
