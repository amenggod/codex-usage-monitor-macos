import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct UsageAggregatorTests {
    @Test
    func todayStartsAtLocalMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = Date(timeIntervalSince1970: 1_783_975_200)

        let bounds = UsageAggregator.bounds(for: .today, now: now, calendar: calendar)

        #expect(bounds.start == calendar.startOfDay(for: now))
        #expect(bounds.end == now)
    }

    @Test
    func sevenDaysIsExactlySevenTimesTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_783_975_200)

        let bounds = UsageAggregator.bounds(for: .sevenDays, now: now, calendar: .current)

        #expect(bounds.start == now.addingTimeInterval(-7 * 24 * 60 * 60))
        #expect(bounds.end == now)
    }

    @Test
    func allHasNoLowerBound() {
        let now = Date(timeIntervalSince1970: 1_783_975_200)

        let bounds = UsageAggregator.bounds(for: .all, now: now, calendar: .current)

        #expect(bounds.start == nil)
        #expect(bounds.end == now)
    }

    @Test
    func snapshotsRespectTodaySevenDaysAndAllRanges() async throws {
        let databaseURL = temporaryAggregationDatabaseURL()
        defer { removeAggregationDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = Date(timeIntervalSince1970: 1_783_975_200)
        let dayStart = calendar.startOfDay(for: now)
        let project = ProjectIdentity(key: "/synthetic/range", displayName: "range", fullPath: "/synthetic/range")
        try await insertAggregationEvent(
            repository: repository,
            id: "today",
            sessionID: "range-session",
            project: project,
            occurredAt: dayStart.addingTimeInterval(60 * 60),
            usage: usage(total: 1)
        )
        try await repository.insertUsageEvent(
            id: "three-days",
            sessionID: "range-session",
            occurredAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
            usage: usage(total: 2)
        )
        try await repository.insertUsageEvent(
            id: "ten-days",
            sessionID: "range-session",
            occurredAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            usage: usage(total: 3)
        )
        let aggregator = UsageAggregator(repository: repository)

        let today = try await aggregator.snapshot(range: .today, now: now, calendar: calendar)
        let sevenDays = try await aggregator.snapshot(range: .sevenDays, now: now, calendar: calendar)
        let all = try await aggregator.snapshot(range: .all, now: now, calendar: calendar)
        let widget = try await aggregator.widgetSnapshots(now: now, calendar: calendar)

        #expect(today.total.total == 1)
        #expect(sevenDays.total.total == 3)
        #expect(all.total.total == 6)
        #expect(widget.today == today)
        #expect(widget.all == all)
    }

    @Test
    func repositoryReadsWidgetInputsFromOneActorBoundary() async throws {
        let databaseURL = temporaryAggregationDatabaseURL()
        defer { removeAggregationDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = Date(timeIntervalSince1970: 1_783_975_200)
        let dayStart = calendar.startOfDay(for: now)
        let project = ProjectIdentity(
            key: "/synthetic/widget",
            displayName: "widget",
            fullPath: "/synthetic/widget"
        )
        try await insertAggregationEvent(
            repository: repository,
            id: "today-widget",
            sessionID: "widget-session",
            project: project,
            occurredAt: dayStart.addingTimeInterval(60),
            usage: usage(total: 1)
        )
        try await repository.insertUsageEvent(
            id: "old-widget",
            sessionID: "widget-session",
            occurredAt: dayStart.addingTimeInterval(-60),
            usage: usage(total: 2)
        )
        let limit = RateLimitObservation(
            limitID: "codex",
            window: .week,
            usedPercent: 28,
            resetsAt: now.addingTimeInterval(86_400),
            observedAt: now
        )
        try await repository.replaceLatestLimits([limit])

        let inputs = try await repository.widgetUsageInputs(
            todayFrom: dayStart,
            to: now
        )

        #expect(inputs.todayRows.map(\.usage.total) == [1])
        #expect(inputs.allRows.map(\.usage.total) == [3])
        #expect(inputs.limits == [limit])
    }

    @Test
    func snapshotSortsProjectsAddsDuplicateParentSuffixAndSumsAuthoritativeTotals() async throws {
        let databaseURL = temporaryAggregationDatabaseURL()
        defer { removeAggregationDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let now = Date(timeIntervalSince1970: 1_783_975_200)
        try await insertAggregationEvent(
            repository: repository,
            id: "alpha-event",
            sessionID: "alpha-session",
            project: ProjectIdentity(key: "/synthetic/alpha", displayName: "alpha", fullPath: "/synthetic/alpha"),
            occurredAt: now.addingTimeInterval(-10),
            usage: TokenUsage(input: 10, cachedInput: 2, output: 3, reasoningOutput: 1, total: 20)
        )
        try await insertAggregationEvent(
            repository: repository,
            id: "shared-first-event",
            sessionID: "shared-first-session",
            project: ProjectIdentity(
                key: "/synthetic/first/shared",
                displayName: "shared",
                fullPath: "/synthetic/first/shared"
            ),
            occurredAt: now.addingTimeInterval(-9),
            usage: TokenUsage(input: 4, cachedInput: 1, output: 1, reasoningOutput: 0, total: 5)
        )
        try await insertAggregationEvent(
            repository: repository,
            id: "shared-second-event",
            sessionID: "shared-second-session",
            project: ProjectIdentity(
                key: "/synthetic/second/shared",
                displayName: "shared",
                fullPath: "/synthetic/second/shared"
            ),
            occurredAt: now.addingTimeInterval(-8),
            usage: TokenUsage(input: 8, cachedInput: 2, output: 2, reasoningOutput: 1, total: 10)
        )
        let limit = RateLimitObservation(
            limitID: "codex",
            window: .fiveHours,
            usedPercent: 42,
            resetsAt: now.addingTimeInterval(3_600),
            observedAt: now
        )
        try await repository.replaceLatestLimits([limit])

        let liveStore = LiveRateLimitStore()
        await liveStore.replace(
            limits: [LimitStatus(
                window: .fiveHours,
                usedPercent: 42,
                resetsAt: limit.resetsAt
            )],
            observedAt: now
        )
        let snapshot = try await UsageAggregator(
            repository: repository,
            limitProvider: liveStore
        ).snapshot(
            range: .all,
            now: now,
            calendar: .current
        )

        #expect(snapshot.projects.map(\.displayName) == ["alpha", "shared — second", "shared — first"])
        #expect(snapshot.total == TokenUsage(input: 22, cachedInput: 5, output: 6, reasoningOutput: 2, total: 35))
        #expect(snapshot.limits == [LimitStatus(window: .fiveHours, usedPercent: 42, resetsAt: limit.resetsAt)])
        #expect(snapshot.freshness == .fresh(now))
    }

    @Test
    func emptySnapshotHasZeroTotalsAndNoDataFreshness() async throws {
        let databaseURL = temporaryAggregationDatabaseURL()
        defer { removeAggregationDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let now = Date(timeIntervalSince1970: 1_783_975_200)

        let snapshot = try await UsageAggregator(repository: repository).snapshot(
            range: .today,
            now: now,
            calendar: .current
        )

        #expect(snapshot.total == .zero)
        #expect(snapshot.projects.isEmpty)
        #expect(snapshot.freshness == .noData)
    }

    @Test
    func snapshotOmitsExpiredLimitsAndKeepsAnActiveSingleWindow() async throws {
        let databaseURL = temporaryAggregationDatabaseURL()
        defer { removeAggregationDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let now = Date(timeIntervalSince1970: 2_000)
        let expiredFiveHours = RateLimitObservation(
            limitID: "codex",
            window: .fiveHours,
            usedPercent: 80,
            resetsAt: now,
            observedAt: now.addingTimeInterval(-100)
        )
        let activeWeek = RateLimitObservation(
            limitID: "codex",
            window: .week,
            usedPercent: 52,
            resetsAt: now.addingTimeInterval(1_000),
            observedAt: now
        )
        try await repository.replaceLatestLimits([expiredFiveHours, activeWeek])

        let liveStore = LiveRateLimitStore()
        await liveStore.replace(
            limits: [
                LimitStatus(
                    window: .fiveHours,
                    usedPercent: 80,
                    resetsAt: expiredFiveHours.resetsAt
                ),
                LimitStatus(
                    window: .week,
                    usedPercent: 52,
                    resetsAt: activeWeek.resetsAt
                ),
            ],
            observedAt: now
        )
        let snapshot = try await UsageAggregator(
            repository: repository,
            limitProvider: liveStore
        ).snapshot(
            range: .all,
            now: now,
            calendar: .current
        )

        #expect(snapshot.limits == [
            LimitStatus(window: .week, usedPercent: 52, resetsAt: activeWeek.resetsAt),
        ])
    }

    @Test
    func liveAccountLimitOverridesOlderLogObservation() async throws {
        let databaseURL = temporaryAggregationDatabaseURL()
        defer { removeAggregationDatabase(at: databaseURL) }
        let repository = try UsageRepository(url: databaseURL)
        try await repository.migrate()
        let now = Date(timeIntervalSince1970: 2_000)
        try await repository.replaceLatestLimits([
            RateLimitObservation(
                limitID: "codex",
                planType: "prolite",
                window: .week,
                usedPercent: 27,
                resetsAt: now.addingTimeInterval(86_400),
                observedAt: now.addingTimeInterval(-3_600)
            )
        ])
        let liveStore = LiveRateLimitStore()
        await liveStore.replace(
            limits: [LimitStatus(
                window: .week,
                usedPercent: 31,
                resetsAt: now.addingTimeInterval(86_400)
            )],
            observedAt: now
        )

        let snapshot = try await UsageAggregator(
            repository: repository,
            limitProvider: liveStore
        ).snapshot(range: .all, now: now, calendar: .current)

        #expect(snapshot.limits.map(\.remainingPercent) == [69])
        #expect(snapshot.limitFreshness == .fresh(now))
    }
}

private func temporaryAggregationDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "UsageAggregatorTests-\(UUID().uuidString)")
        .appendingPathExtension("sqlite")
}

private func removeAggregationDatabase(at url: URL) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
}

private func usage(total: Int64) -> TokenUsage {
    TokenUsage(input: total, cachedInput: 0, output: 0, reasoningOutput: 0, total: total)
}

private func insertAggregationEvent(
    repository: UsageRepository,
    id: String,
    sessionID: String,
    project: ProjectIdentity,
    occurredAt: Date,
    usage: TokenUsage
) async throws {
    try await repository.upsertSession(
        SessionMetadata(sessionID: sessionID, startedAt: occurredAt, workingDirectory: project.fullPath),
        project: project
    )
    try await repository.insertUsageEvent(
        id: id,
        sessionID: sessionID,
        occurredAt: occurredAt,
        usage: usage
    )
}
