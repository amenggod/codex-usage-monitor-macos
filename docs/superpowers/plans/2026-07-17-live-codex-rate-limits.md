# Live Codex Rate Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace stale log-derived Codex quota percentages with the live `codex app-server` account rate-limit stream, and propagate freshness-aware values to the app, menu bar, notifications, and WidgetKit snapshot.

**Architecture:** A focused app-server client locates the bundled Codex executable, owns one stdio process, decodes only the `codex` account bucket, and publishes typed updates. An actor-backed store converts the last successful read into fresh/stale/unavailable state; aggregation continues to read Token totals from SQLite but receives limits exclusively from that store. The view model starts both data sources, refreshes both in parallel, and publishes one consistent snapshot to every presentation surface.

**Tech Stack:** Swift 6, Foundation `Process`/`Pipe`, Swift Concurrency actors and `AsyncStream`, Swift Testing, SwiftUI/WidgetKit, existing SQLite repository.

## Global Constraints

- Target macOS 14 and later; add no third-party runtime dependency.
- Treat `rateLimitsByLimitId["codex"]` as authoritative and never substitute `codex_bengalfox`.
- Map only 300 minutes to five-hour and 10080 minutes to week; hide a missing five-hour window.
- Mark data fresh through 10 minutes, stale through 30 minutes, and unavailable after 30 minutes.
- Notify only for fresh account limits; stale and unavailable states must not trigger thresholds.
- Send only `initialize` and `account/rateLimits/read`; never call reset-credit methods.
- Never persist credentials, prompt/response content, full app-server JSON, or credit information.
- WidgetKit reload is requested immediately, but macOS controls final widget rendering time.

---

## File Map

- `Sources/CodexUsageMonitor/RateLimits/CodexRateLimitProtocol.swift`: JSON-line request/response and account-bucket decoding.
- `Sources/CodexUsageMonitor/RateLimits/CodexExecutableLocator.swift`: deterministic executable discovery and validation.
- `Sources/CodexUsageMonitor/RateLimits/CodexAppServerTransport.swift`: long-lived stdio process, request ID matching, timeouts, and notifications.
- `Sources/CodexUsageMonitor/RateLimits/CodexRateLimitService.swift`: initialize/read/update lifecycle and typed update stream.
- `Sources/CodexUsageMonitor/RateLimits/LiveRateLimitStore.swift`: freshness classification and current limits provider.
- `Sources/CodexUsageMonitor/Domain/UsageModels.swift`: separate limit freshness on dashboard snapshots.
- `Sources/CodexUsageMonitor/Aggregation/UsageAggregator.swift`: combine SQLite Token totals with live limit state.
- `Sources/CodexUsageMonitor/Presentation/UsageViewModel.swift`: start, observe, and manually refresh both sources.
- `Sources/CodexUsageMonitor/App/LiveDependencies.swift`: assemble the production service/store/transport graph.
- `Sources/CodexUsageShared/WidgetUsageSnapshot.swift`: schema 2 limit freshness payload.
- `Sources/CodexUsageShared/WidgetDisplayModel.swift`: hide unavailable limits and label stale synchronization.
- `Sources/CodexUsageMonitor/Widget/WidgetSnapshotPublisher.swift`: publish schema 2 and reload on limit freshness changes.

### Task 1: Decode the authoritative Codex account bucket

**Files:**
- Create: `Sources/CodexUsageMonitor/RateLimits/CodexRateLimitProtocol.swift`
- Create: `Tests/CodexUsageMonitorTests/CodexRateLimitProtocolTests.swift`

**Interfaces:**
- Consumes: one JSON response line and an observation `Date`.
- Produces: `CodexRateLimitProtocol.decodeReadResult(from:observedAt:) throws -> [RateLimitObservation]` and `CodexRateLimitProtocol.isRateLimitsUpdatedNotification(_:) -> Bool`.

- [x] **Step 1: Write failing decoder tests**

```swift
@Test func accountBucketProducesSixtyNinePercentRemaining() throws {
    let observations = try CodexRateLimitProtocol.decodeReadResult(
        from: responseJSON(codexUsed: 31, bengalfoxUsed: 0),
        observedAt: observedAt
    )
    #expect(observations == [
        RateLimitObservation(limitID: "codex", planType: "prolite", window: .week,
            usedPercent: 31, resetsAt: resetAt, observedAt: observedAt)
    ])
}

@Test func modelBucketNeverReplacesAccountBucket() throws {
    let observations = try CodexRateLimitProtocol.decodeReadResult(
        from: responseJSON(codexUsed: 31, bengalfoxUsed: 0), observedAt: observedAt)
    #expect(observations.allSatisfy { $0.limitID == "codex" })
}
```

Add cases for a legal single-bucket fallback, missing required values, unknown fields, a missing five-hour window, and `account/rateLimits/updated` method recognition.

- [x] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter CodexRateLimitProtocolTests`

Expected: compilation fails because `CodexRateLimitProtocol` does not exist.

- [x] **Step 3: Implement minimal typed decoding**

```swift
enum CodexRateLimitProtocol {
    static func decodeReadResult(from data: Data, observedAt: Date) throws
        -> [RateLimitObservation]
    static func isRateLimitsUpdatedNotification(_ data: Data) -> Bool
}
```

Decode `result.rateLimitsByLimitId.codex`, falling back only when `result.rateLimits.limitId == "codex"`; convert primary and secondary windows independently and ignore unsupported durations.

- [x] **Step 4: Run focused and full tests and verify GREEN**

Run: `swift test --filter CodexRateLimitProtocolTests && swift test`

Expected: all decoder cases and the existing 260-test baseline pass.

- [x] **Step 5: Commit the decoder**

```bash
git add Sources/CodexUsageMonitor/RateLimits/CodexRateLimitProtocol.swift Tests/CodexUsageMonitorTests/CodexRateLimitProtocolTests.swift
git commit -m "feat: decode live Codex account limits"
```

### Task 2: Locate Codex and provide a safe app-server transport

**Files:**
- Create: `Sources/CodexUsageMonitor/RateLimits/CodexExecutableLocator.swift`
- Create: `Sources/CodexUsageMonitor/RateLimits/CodexAppServerTransport.swift`
- Create: `Tests/CodexUsageMonitorTests/CodexExecutableLocatorTests.swift`
- Create: `Tests/CodexUsageMonitorTests/CodexAppServerTransportTests.swift`

**Interfaces:**
- Consumes: `CodexExecutableLocating.executableURL() throws -> URL`, injectable process session, newline JSON data.
- Produces: `CodexAppServerTransport.start() async throws`, `request(method:params:timeout:) async throws -> Data`, `notifications() async -> AsyncStream<Data>`, and `stop() async`.

- [x] **Step 1: Write failing locator and transport tests**

```swift
@Test func locatorPrefersInstalledChatGPTBundleCodex() throws {
    let locator = CodexExecutableLocator(bundleURL: bundleURL, fallbackURLs: [pathURL])
    #expect(try locator.executableURL() == bundleURL.appending(path: "Contents/Resources/codex"))
}

@Test func requestIDsResolveOutOfOrderResponses() async throws {
    let first = Task { try await transport.request(method: "first", params: nil, timeout: 1) }
    let second = Task { try await transport.request(method: "second", params: nil, timeout: 1) }
    await session.emit(responseForID: 2)
    await session.emit(responseForID: 1)
    #expect(try await first.value.containsJSONID(1))
    #expect(try await second.value.containsJSONID(2))
}
```

Cover executable permission rejection, JSON notifications, malformed lines, process exit, request timeout, and idempotent stop with an in-memory process-session fake.

- [x] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter CodexExecutableLocatorTests && swift test --filter CodexAppServerTransportTests`

Expected: compilation fails because locator and transport types do not exist.

- [x] **Step 3: Implement locator, process session, and actor transport**

```swift
protocol CodexAppServerTransporting: Sendable {
    func start() async throws
    func request(method: String, params: Data?, timeout: Duration) async throws -> Data
    func notifications() async -> AsyncStream<Data>
    func stop() async
}
```

Use `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")`, the fixed ChatGPT path, then `PATH`. Start `codex app-server --stdio`, write one JSON object per line, keep response continuations by integer ID, route messages without an ID to the notification stream, and fail every pending request on exit.

- [x] **Step 4: Run focused and full tests and verify GREEN**

Run: `swift test --filter CodexExecutableLocatorTests && swift test --filter CodexAppServerTransportTests && swift test`

Expected: lifecycle/error tests and the full suite pass without hanging processes.

- [x] **Step 5: Commit transport**

```bash
git add Sources/CodexUsageMonitor/RateLimits/CodexExecutableLocator.swift Sources/CodexUsageMonitor/RateLimits/CodexAppServerTransport.swift Tests/CodexUsageMonitorTests/CodexExecutableLocatorTests.swift Tests/CodexUsageMonitorTests/CodexAppServerTransportTests.swift
git commit -m "feat: add Codex app-server transport"
```

### Task 3: Add live service lifecycle and freshness-aware store

**Files:**
- Create: `Sources/CodexUsageMonitor/RateLimits/CodexRateLimitService.swift`
- Create: `Sources/CodexUsageMonitor/RateLimits/LiveRateLimitStore.swift`
- Create: `Tests/CodexUsageMonitorTests/CodexRateLimitServiceTests.swift`
- Create: `Tests/CodexUsageMonitorTests/LiveRateLimitStoreTests.swift`
- Modify: `Sources/CodexUsageMonitor/Domain/UsageModels.swift`

**Interfaces:**
- Consumes: `CodexAppServerTransporting`, decoded observations, and an injectable clock.
- Produces: `LiveRateLimitState`, `LiveRateLimitProviding.state(now:) async -> LiveRateLimitState`, and `RateLimitServicing.start/refresh/updates/stop`.

- [x] **Step 1: Write failing service and store tests**

```swift
@Test func stateTransitionsAtTenAndThirtyMinutes() async {
    await store.replace(limits: limits, observedAt: base)
    #expect(await store.state(now: base + 10.minutes) == .fresh(limits: limits, observedAt: base))
    #expect(await store.state(now: base + 20.minutes) == .stale(limits: limits, observedAt: base))
    #expect(await store.state(now: base + 31.minutes).isUnavailable)
}

@Test func updateNotificationPerformsFullRead() async throws {
    await service.start()
    await transport.emitRateLimitsUpdated()
    #expect(await transport.readRequestCount == 2)
}
```

Cover initialize-before-read, manual refresh bypassing backoff, a 60-second active reread without notifications, failure preserving a stale timestamp, transport restart after request failure, stop cleanup, and unsupported responses becoming unavailable rather than 0%/100%.

- [x] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter LiveRateLimitStoreTests && swift test --filter CodexRateLimitServiceTests`

Expected: compilation fails because `LiveRateLimitState` and service/store actors do not exist.

- [x] **Step 3: Implement the store and service**

```swift
enum LiveRateLimitState: Equatable, Sendable {
    case fresh(limits: [LimitStatus], observedAt: Date)
    case stale(limits: [LimitStatus], observedAt: Date)
    case unavailable(lastSuccessfulAt: Date?, message: String)
}

protocol RateLimitServicing: Sendable {
    func start() async
    func refresh() async
    func updates() async -> AsyncStream<LiveRateLimitState>
    func stop() async
}
```

Initialize with `experimentalApi: true`, read with a 10-second timeout, replace the store only after a complete valid response, reread on updates and every 60 seconds, restart the transport after request failures, and schedule bounded 5-second/30-second/2-minute retries that manual refresh cancels.

- [x] **Step 4: Run focused and full tests and verify GREEN**

Run: `swift test --filter LiveRateLimitStoreTests && swift test --filter CodexRateLimitServiceTests && swift test`

Expected: all service/store timing cases and the full suite pass.

- [x] **Step 5: Commit service/store**

```bash
git add Sources/CodexUsageMonitor/Domain/UsageModels.swift Sources/CodexUsageMonitor/RateLimits/CodexRateLimitService.swift Sources/CodexUsageMonitor/RateLimits/LiveRateLimitStore.swift Tests/CodexUsageMonitorTests/CodexRateLimitServiceTests.swift Tests/CodexUsageMonitorTests/LiveRateLimitStoreTests.swift
git commit -m "feat: track live Codex limit freshness"
```

### Task 4: Make app aggregation and refresh consume live limits only

**Files:**
- Modify: `Sources/CodexUsageMonitor/Aggregation/UsageAggregator.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/UsageViewModel.swift`
- Modify: `Sources/CodexUsageMonitor/App/LiveDependencies.swift`
- Modify: `Tests/CodexUsageMonitorTests/UsageAggregatorTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/UsageViewModelTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/NotificationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `LiveRateLimitProviding`, `RateLimitServicing`, existing local ingestion and repository.
- Produces: `DashboardSnapshot.limitFreshness`, parallel manual refresh, automatic refresh on live updates, and fresh-only notification evaluation.

- [x] **Step 1: Write failing aggregation and view-model tests**

```swift
@Test func localLogLimitsCannotOverrideLiveAccountLimits() async throws {
    try await repository.insert(logLimitWithUsedPercent: 27)
    await liveStore.replace(limits: [weekUsed31], observedAt: now)
    let snapshot = try await aggregator.snapshot(range: .today, now: now, calendar: calendar)
    #expect(snapshot.limits.first?.remainingPercent == 69)
}

@Test func retryRefreshesTokensAndLiveLimits() async {
    await viewModel.retry()
    #expect(await ingestion.rescanCount == 1)
    #expect(await rateLimits.refreshCount == 1)
}
```

Add cases proving startup starts both sources, a rate-limit update refreshes without a click, unavailable limits do not erase Token totals, stale limits do not notify, and `codex_bengalfox` cannot enter the dashboard.

- [x] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter UsageAggregatorTests && swift test --filter UsageViewModelTests`

Expected: new assertions fail because aggregation still reads `repository.latestLimits()` and retry only rescans logs.

- [x] **Step 3: Wire live state through aggregation and presentation**

```swift
struct DashboardSnapshot: Equatable, Sendable {
    let range: TokenRange
    let total: TokenUsage
    let projects: [ProjectUsage]
    let limits: [LimitStatus]
    let freshness: DataFreshness
    let limitFreshness: LiveRateLimitFreshness
}
```

Have the aggregator fetch Token rows and live state independently; have `UsageViewModel.start()` observe both streams, `retry()` launch local rescan and `rateLimitService.refresh()` together, and call the notifier only when `limitFreshness` is fresh. Assemble the locator, transport, store, service, aggregator, and publisher once in `LiveDependencies`.

- [x] **Step 4: Run focused and full tests and verify GREEN**

Run: `swift test --filter UsageAggregatorTests && swift test --filter UsageViewModelTests && swift test --filter NotificationCoordinatorTests && swift test`

Expected: 69% live-state behavior, dual refresh, update propagation, fresh-only notifications, and all legacy tests pass.

- [x] **Step 5: Commit integration**

```bash
git add Sources/CodexUsageMonitor/Aggregation/UsageAggregator.swift Sources/CodexUsageMonitor/Presentation/UsageViewModel.swift Sources/CodexUsageMonitor/App/LiveDependencies.swift Tests/CodexUsageMonitorTests/UsageAggregatorTests.swift Tests/CodexUsageMonitorTests/UsageViewModelTests.swift Tests/CodexUsageMonitorTests/NotificationCoordinatorTests.swift
git commit -m "fix: refresh dashboard from live Codex limits"
```

### Task 5: Publish schema 2 freshness to WidgetKit

**Files:**
- Modify: `Sources/CodexUsageShared/WidgetUsageSnapshot.swift`
- Modify: `Sources/CodexUsageShared/WidgetDisplayModel.swift`
- Modify: `Sources/CodexUsageMonitor/Widget/WidgetSnapshotPublisher.swift`
- Modify: `Sources/CodexUsageMonitorWidget/UsageTimelineProvider.swift`
- Modify: `Tests/CodexUsageSharedTests/WidgetTestFixtures.swift`
- Modify: `Tests/CodexUsageSharedTests/WidgetUsageSnapshotTests.swift`
- Modify: `Tests/CodexUsageSharedTests/WidgetDisplayModelTests.swift`
- Modify: `Tests/CodexUsageMonitorTests/WidgetSnapshotPublisherTests.swift`
- Modify: `Tests/CodexUsageMonitorWidgetTests/UsageTimelineProviderTests.swift`

**Interfaces:**
- Consumes: dashboard `limitFreshness` and active live limits.
- Produces: `WidgetUsageSnapshot.currentSchemaVersion == 2` and `WidgetLimitFreshness` encoded without sensitive fields.

- [x] **Step 1: Write failing schema and display tests**

```swift
@Test func schemaTwoCarriesFreshLimitObservationTime() throws {
    let snapshot = fixture(limitFreshness: .fresh(observedAt: observedAt))
    #expect(snapshot.schemaVersion == 2)
    #expect(try roundTrip(snapshot).limitFreshness == .fresh(observedAt: observedAt))
}

@Test func unavailableLimitFreshnessHidesNumericPercentages() {
    let model = WidgetDisplayModel(snapshot: fixture(limitFreshness: .unavailable), now: now)
    #expect(model.visibleFiveHourLimit == nil)
    #expect(model.visibleWeekLimit == nil)
}
```

Cover schema 1 rejection, 10–30 minute stale copy, over-30-minute hiding, fresh 69% publication, fingerprint-triggered reload, and Token values remaining visible when only limits are unavailable.

- [x] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter WidgetUsageSnapshotTests && swift test --filter WidgetDisplayModelTests && swift test --filter WidgetSnapshotPublisherTests`

Expected: schema/freshness assertions fail because the shared payload is still schema 1.

- [x] **Step 3: Implement schema 2 projection and UI policy**

```swift
public enum WidgetLimitFreshness: Codable, Equatable, Sendable {
    case fresh(observedAt: Date)
    case stale(observedAt: Date)
    case unavailable
}
```

Add `limitFreshness` to the whitelist payload and fingerprint; expose limits only for fresh/stale states with unexpired reset times; use `更新于` for fresh, `上次实时同步` for stale, and `实时限额不可用` for unavailable. Treat schema 1 as invalid until the main app republishes.

- [x] **Step 4: Run focused and full tests and verify GREEN**

Run: `swift test --filter WidgetUsageSnapshotTests && swift test --filter WidgetDisplayModelTests && swift test --filter WidgetSnapshotPublisherTests && swift test --filter UsageTimelineProviderTests && swift test`

Expected: schema 2, privacy whitelist, visibility, copy, timeline, and full suite pass.

- [x] **Step 5: Commit WidgetKit propagation**

```bash
git add Sources/CodexUsageShared Sources/CodexUsageMonitor/Widget Sources/CodexUsageMonitorWidget Tests/CodexUsageSharedTests Tests/CodexUsageMonitorWidgetTests Tests/CodexUsageMonitorTests/WidgetSnapshotPublisherTests.swift
git commit -m "feat: publish live limit freshness to widget"
```

### Task 6: Build, install, and verify against the live account

**Files:**
- Modify: `project.yml`
- Modify: `CodexUsageMonitor.xcodeproj/project.pbxproj`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-17-live-codex-rate-limits-design.md`

**Interfaces:**
- Consumes: signed app bundle, installed ChatGPT login, live app-server response, App Group snapshot.
- Produces: version 0.2.3 build 5, verified installation, current live percentage parity, and documented WidgetKit timing limitation.

- [x] **Step 1: Add release-facing assertions/documentation**

Update README behavior: app/menu bar/alerts consume live account limits; WidgetKit receives immediate reload requests but remains scheduled by macOS; missing five-hour values stay hidden; unavailable live data never falls back to old log percentages.

- [x] **Step 2: Run complete automated verification**

Run: `swift test`

Expected: every test passes with 0 failures.

- [x] **Step 3: Build a signed release app**

Run: `CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=ZD9PK3NY5Z CODE_SIGN_STYLE=Automatic bash Scripts/build-app.sh`

Expected: app, login item, and widget extension build successfully and `codesign` reports Team ID `ZD9PK3NY5Z` with App Group `ZD9PK3NY5Z.CodexUsageMonitor.shared`.

- [x] **Step 4: Install and perform real-device acceptance**

Quit the prior monitor, preserve it in `/tmp`, install the new bundle with `ditto`, launch it, click refresh, and compare the app plus App Group JSON against a fresh read from `/Applications/ChatGPT.app/Contents/Resources/codex app-server --stdio`. Verify the main `codex` remaining percentage matches, the model bucket is ignored, and WidgetKit accepts the reload request.

- [x] **Step 5: Commit release metadata and push**

```bash
git add project.yml CodexUsageMonitor.xcodeproj/project.pbxproj README.md docs/superpowers/specs/2026-07-17-live-codex-rate-limits-design.md docs/superpowers/plans/2026-07-17-live-codex-rate-limits.md
git commit -m "release: prepare live quota monitor 0.2.3"
git push origin codex/usage-monitor-v2
```

- [x] **Step 6: Verify GitHub PR checks**

Run: `gh pr checks 1 --watch`

Expected: every required GitHub Actions job passes before reporting completion.
