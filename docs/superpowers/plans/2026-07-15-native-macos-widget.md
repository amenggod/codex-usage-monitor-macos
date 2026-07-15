# Native macOS Usage Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the simulated desktop `NSPanel` with a native macOS WidgetKit extension that displays the latest trustworthy Codex usage snapshot and opens one full dashboard window when clicked.

**Architecture:** The main app remains the only process that scans Codex logs, owns SQLite, computes usage, and sends notifications. It projects a privacy-safe `WidgetUsageSnapshot` into an App Group container and requests a WidgetKit reload only when visible fields change. A Widget Extension reads that snapshot and renders `systemSmall` and `systemMedium`; a signed login-item helper starts the main app with `--background`, while user-initiated launches and the widget deep link open a singleton SwiftUI-hosted dashboard window.

**Tech Stack:** Swift 6, SwiftUI, AppKit, WidgetKit, ServiceManagement, Foundation App Groups, Swift Testing, Swift Package Manager, XcodeGen, Xcode 26.3, GitHub Actions.

## Global Constraints

- Support macOS 14 Sonoma and later.
- Keep `swift test` as the fast logic-test entry point.
- The widget supports only `systemSmall` and `systemMedium` in this delivery.
- WidgetKit controls final refresh timing; never claim second-level widget refresh.
- The Widget Extension must not scan `~/.codex`, open the usage SQLite database, or send notifications.
- Never persist or expose prompts, responses, tool output, credentials, full project paths, or raw session events in the App Group.
- Hide an absent or expired 5-hour limit completely; never reserve an empty slot or notify for it.
- Preserve the current branch-history deduplication, schema-v2 ingestion, retry, and notification behavior.
- Bundle identifiers are `com.amenggod.CodexUsageMonitor`, `com.amenggod.CodexUsageMonitor.Widget`, and `com.amenggod.CodexUsageMonitor.LoginItem`.
- App Group is `group.com.amenggod.CodexUsageMonitor`; widget kind is `com.amenggod.CodexUsageMonitor.usage`.
- Widget deep link is `codexusagemonitor://dashboard`.
- Do not commit Apple certificates, private keys, Apple IDs, App Store Connect keys, provisioning profiles, or notarization credentials.
- Current development machine has Command Line Tools but no full Xcode. The user authorized installing full Xcode; complete installation and license acceptance before the first local Xcode build. Until then, run SwiftPM tests locally and Xcode-only compilation in GitHub Actions.
- Every behavior change follows red-green-refactor and ends in a focused commit.

---

## File Structure

### New shared module

- `Sources/CodexUsageShared/WidgetUsageSnapshot.swift`: stable Codable snapshot schema and privacy-safe value types.
- `Sources/CodexUsageShared/WidgetSnapshotStore.swift`: App Group URL resolution and atomic JSON storage.
- `Sources/CodexUsageShared/WidgetDisplayModel.swift`: time-dependent display model, limit filtering, stale state, and next refresh calculation.
- `Sources/CodexUsageShared/LoginItemMainApplicationLocator.swift`: pure containing-app URL calculation shared by helper and tests.
- `Tests/CodexUsageSharedTests/WidgetUsageSnapshotTests.swift`: schema, decoding, privacy, storage, and corruption coverage.
- `Tests/CodexUsageSharedTests/WidgetDisplayModelTests.swift`: small/medium layout policy and time-boundary coverage.

### Main application additions

- `Sources/CodexUsageMonitor/Widget/WidgetSnapshotPublisher.swift`: queries authoritative today/all snapshots, projects them, stores them, and deduplicates reload requests.
- `Sources/CodexUsageMonitor/Widget/SystemWidgetTimelineReloader.swift`: narrow `WidgetCenter` adapter.
- `Sources/CodexUsageMonitor/Presentation/MenuBarVisibilityStore.swift`: migrates old `DisplayMode` to one menu-bar boolean.
- `Sources/CodexUsageMonitor/Presentation/DashboardWindowController.swift`: owns one normal dashboard window and hosts `UsagePopoverView`.
- `Sources/CodexUsageMonitor/App/AppLaunchCoordinator.swift`: starts monitoring after launch and routes normal launch, reopen, and deep links.
- `Tests/CodexUsageMonitorTests/WidgetSnapshotPublisherTests.swift`: projection, App Group failure, and reload-deduplication coverage.
- `Tests/CodexUsageMonitorTests/AppLaunchCoordinatorTests.swift`: background/manual/reopen/deep-link routing.

### New extension and helper targets

- `Sources/CodexUsageMonitorWidget/CodexUsageWidgetBundle.swift`: Widget Extension entry point.
- `Sources/CodexUsageMonitorWidget/UsageTimelineProvider.swift`: reads snapshot and supplies timeline entries.
- `Sources/CodexUsageMonitorWidget/UsageWidgetView.swift`: family-specific SwiftUI widget rendering.
- `Sources/CodexUsageMonitorLoginItem/LoginItemMain.swift`: silently launches the containing app with `--background`, then exits.

### Project, configuration, and delivery

- `project.yml`: reproducible XcodeGen project definition.
- `CodexUsageMonitor.xcodeproj/`: generated and committed Xcode project.
- `Config/App-Info.plist`, `Config/Widget-Info.plist`, `Config/LoginItem-Info.plist`: target metadata.
- `Config/CodexUsageMonitor.entitlements`, `Config/CodexUsageMonitorWidget.entitlements`: shared App Group capabilities.
- `Scripts/generate-project.sh`: reproducibly regenerates the Xcode project.
- `Scripts/build-app.sh`: Xcode application/extension build and packaging.
- `.github/workflows/ci.yml`: Swift tests plus unsigned Xcode compile verification.
- `README.md`: native-widget installation, refresh, signing, and contribution instructions.

### Removed simulated-card files

- `Sources/CodexUsageMonitor/App/AppPresentationCoordinator.swift`
- `Sources/CodexUsageMonitor/Presentation/DesktopCardPlacement.swift`
- `Sources/CodexUsageMonitor/Presentation/DesktopCardPresentationController.swift`
- `Sources/CodexUsageMonitor/Presentation/DesktopCardView.swift`
- `Sources/CodexUsageMonitor/Presentation/DesktopCardWindowController.swift`
- `Sources/CodexUsageMonitor/Presentation/DisplayModeStore.swift`
- `Tests/CodexUsageMonitorTests/DesktopCardPlacementTests.swift`

---

### Task 1: Create the privacy-safe shared snapshot module

**Files:**
- Create: `Sources/CodexUsageShared/WidgetUsageSnapshot.swift`
- Create: `Sources/CodexUsageShared/WidgetSnapshotStore.swift`
- Create: `Tests/CodexUsageSharedTests/WidgetUsageSnapshotTests.swift`
- Create: `Tests/CodexUsageSharedTests/WidgetTestFixtures.swift`
- Modify: `Package.swift`

**Interfaces:**
- Produces: `WidgetUsageSnapshot`, `WidgetProjectUsage`, `WidgetLimitStatus`, `WidgetDataState`, `WidgetSnapshotStore`, and `WidgetSnapshotStoring`.
- `WidgetSnapshotStoring.read() throws -> WidgetUsageSnapshot?`
- `WidgetSnapshotStoring.write(_ snapshot: WidgetUsageSnapshot) throws`

- [ ] **Step 1: Write failing schema and storage tests**

```swift
import Foundation
import Testing
@testable import CodexUsageShared

@Suite("WidgetUsageSnapshotTests")
struct WidgetUsageSnapshotTests {
    @Test func roundTripContainsOnlyDisplaySafeFields() throws {
        let snapshot = WidgetUsageSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            todayTokens: 12_345,
            allTimeTokens: 98_765,
            fiveHourLimit: nil,
            weekLimit: WidgetLimitStatus(
                id: "codex-week",
                remainingPercent: 72,
                resetsAt: Date(timeIntervalSince1970: 9_000)
            ),
            projects: [WidgetProjectUsage(id: "p1", name: "monitor", tokens: 500)],
            state: .fresh(lastSuccessfulAt: Date(timeIntervalSince1970: 1_000))
        )

        let data = try JSONEncoder.widgetSnapshot.encode(snapshot)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("fullPath"))
        #expect(!text.contains("prompt"))
        #expect(try JSONDecoder.widgetSnapshot.decode(WidgetUsageSnapshot.self, from: data) == snapshot)
    }

    @Test func atomicStoreReturnsNilForMissingFileAndRoundTripsACompleteSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try WidgetSnapshotStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try store.read() == nil)
        let snapshot = WidgetUsageSnapshot.fixture
        try store.write(snapshot)
        #expect(try store.read() == snapshot)
    }

    @Test func corruptSnapshotThrowsInsteadOfReturningZeroValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try WidgetSnapshotStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not-json".utf8).write(to: store.fileURL)

        #expect(throws: DecodingError.self) { try store.read() }
    }

    @Test func unsupportedSchemaThrowsInsteadOfRenderingUnknownData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try WidgetSnapshotStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder.widgetSnapshot.encode(.fixture))
                as? [String: Any]
        )
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)

        #expect(throws: WidgetSnapshotStoreError.self) { try store.read() }
    }
}

// Tests/CodexUsageSharedTests/WidgetTestFixtures.swift
extension WidgetUsageSnapshot {
    static var fixture: Self { fixture() }

    static func fixture(
        generatedAt: Date = Date(timeIntervalSince1970: 1_000),
        todayTokens: Int64 = 12_345,
        fiveHourLimit: WidgetLimitStatus? = nil,
        weekLimit: WidgetLimitStatus? = .fixture()
    ) -> Self {
        Self(
            generatedAt: generatedAt,
            todayTokens: todayTokens,
            allTimeTokens: 98_765,
            fiveHourLimit: fiveHourLimit,
            weekLimit: weekLimit,
            projects: [
                WidgetProjectUsage(id: "one", name: "restaurant", tokens: 42_100),
                WidgetProjectUsage(id: "two", name: "monitor", tokens: 31_400),
                WidgetProjectUsage(id: "three", name: "notes", tokens: 25_265),
            ],
            state: .fresh(lastSuccessfulAt: generatedAt)
        )
    }
}

extension WidgetLimitStatus {
    static func fixture(
        resetsAt: Date = Date(timeIntervalSince1970: 9_000)
    ) -> Self {
        Self(id: "codex", remainingPercent: 72, resetsAt: resetsAt)
    }
}
```

- [ ] **Step 2: Run the shared tests and verify RED**

Run: `swift test --filter WidgetUsageSnapshotTests`

Expected: FAIL because product/module `CodexUsageShared` and its snapshot types do not exist.

- [ ] **Step 3: Add the shared package target and minimal model**

```swift
// Package.swift target additions
products: [
    .library(name: "CodexUsageShared", targets: ["CodexUsageShared"]),
    .executable(name: "CodexUsageMonitor", targets: ["CodexUsageMonitor"]),
],
targets: [
    .target(name: "CodexUsageShared"),
    .executableTarget(
        name: "CodexUsageMonitor",
        dependencies: ["CodexUsageShared"],
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .testTarget(
        name: "CodexUsageSharedTests",
        dependencies: ["CodexUsageShared", .product(name: "Testing", package: "swift-testing")],
        linkerSettings: testingLinkerSettings
    ),
    .testTarget(
        name: "CodexUsageMonitorTests",
        dependencies: [
            "CodexUsageMonitor",
            "CodexUsageShared",
            .product(name: "Testing", package: "swift-testing"),
        ],
        resources: [.copy("Fixtures")],
        linkerSettings: testingLinkerSettings
    ),
]
```

```swift
public struct WidgetUsageSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let generatedAt: Date
    public let todayTokens: Int64
    public let allTimeTokens: Int64
    public let fiveHourLimit: WidgetLimitStatus?
    public let weekLimit: WidgetLimitStatus?
    public let projects: [WidgetProjectUsage]
    public let state: WidgetDataState

    public init(
        generatedAt: Date,
        todayTokens: Int64,
        allTimeTokens: Int64,
        fiveHourLimit: WidgetLimitStatus?,
        weekLimit: WidgetLimitStatus?,
        projects: [WidgetProjectUsage],
        state: WidgetDataState
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.todayTokens = todayTokens
        self.allTimeTokens = allTimeTokens
        self.fiveHourLimit = fiveHourLimit
        self.weekLimit = weekLimit
        self.projects = Array(projects.prefix(3))
        self.state = state
    }
}

public struct WidgetProjectUsage: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let tokens: Int64

    public init(id: String, name: String, tokens: Int64) {
        self.id = id
        self.name = name
        self.tokens = tokens
    }
}

public struct WidgetLimitStatus: Codable, Equatable, Sendable {
    public let id: String
    public let remainingPercent: Double
    public let resetsAt: Date

    public init(id: String, remainingPercent: Double, resetsAt: Date) {
        self.id = id
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetsAt = resetsAt
    }
}

public enum WidgetDataState: Codable, Equatable, Sendable {
    case fresh(lastSuccessfulAt: Date)
    case partial(lastSuccessfulAt: Date, failedFiles: Int)
    case rebuilding(lastSuccessfulAt: Date?)
    case stale(lastSuccessfulAt: Date)
    case noData
    case failed
}

public extension WidgetUsageSnapshot {
    static let placeholder = WidgetUsageSnapshot(
        generatedAt: .now,
        todayTokens: 12_345,
        allTimeTokens: 98_765,
        fiveHourLimit: nil,
        weekLimit: WidgetLimitStatus(
            id: "placeholder-week",
            remainingPercent: 72,
            resetsAt: .now.addingTimeInterval(86_400)
        ),
        projects: [
            WidgetProjectUsage(id: "one", name: "restaurant", tokens: 42_100),
            WidgetProjectUsage(id: "two", name: "monitor", tokens: 31_400),
            WidgetProjectUsage(id: "three", name: "notes", tokens: 25_265),
        ],
        state: .fresh(lastSuccessfulAt: .now)
    )
}

public extension JSONEncoder {
    static var widgetSnapshot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var widgetSnapshot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

```swift
public protocol WidgetSnapshotStoring: Sendable {
    func read() throws -> WidgetUsageSnapshot?
    func write(_ snapshot: WidgetUsageSnapshot) throws
}

public enum WidgetSnapshotStoreError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case unsupportedSchema(Int)
}

public struct WidgetSnapshotStore: WidgetSnapshotStoring, Sendable {
    public static let appGroupIdentifier = "group.com.amenggod.CodexUsageMonitor"
    public let fileURL: URL

    public init(directoryURL: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("widget-usage-v1.json")
    }

    public static func appGroup(fileManager: FileManager = .default) throws -> Self {
        guard let url = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { throw WidgetSnapshotStoreError.appGroupUnavailable }
        return try Self(directoryURL: url, fileManager: fileManager)
    }

    public func read() throws -> WidgetUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let snapshot = try JSONDecoder.widgetSnapshot.decode(
            WidgetUsageSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        guard snapshot.schemaVersion == WidgetUsageSnapshot.currentSchemaVersion else {
            throw WidgetSnapshotStoreError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
    }

    public func write(_ snapshot: WidgetUsageSnapshot) throws {
        try JSONEncoder.widgetSnapshot.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run focused and full tests**

Run: `swift test --filter WidgetUsageSnapshotTests`

Expected: PASS with all shared snapshot tests successful.

Run: `swift test`

Expected: all existing suites plus `WidgetUsageSnapshotTests` pass with 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/CodexUsageShared Tests/CodexUsageSharedTests
git commit -m "feat: add shared widget snapshot storage"
```

---

### Task 2: Publish authoritative widget snapshots from the main app

**Files:**
- Create: `Sources/CodexUsageMonitor/Widget/WidgetSnapshotPublisher.swift`
- Create: `Sources/CodexUsageMonitor/Widget/SystemWidgetTimelineReloader.swift`
- Create: `Tests/CodexUsageMonitorTests/WidgetSnapshotPublisherTests.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/UsageViewModel.swift`
- Modify: `Sources/CodexUsageMonitor/App/LiveDependencies.swift`

**Interfaces:**
- Consumes: `WidgetSnapshotStoring`, `UsageAggregating`, `DashboardSnapshot`.
- Produces: `WidgetSnapshotPublishing.publish(now:calendar:) async -> WidgetSharingStatus`.
- Produces: `WidgetTimelineReloading.reloadUsageWidget()`.
- Project ranking in the widget is all-time ranking; today and all-time totals are queried independently of the selected dashboard range.

- [ ] **Step 1: Write failing publisher tests**

```swift
@MainActor
@Test func publisherWritesTodayAndAllTimeWithoutLeakingFullPaths() async throws {
    let today = makeSnapshot(range: .today, total: 12, projects: [])
    let all = makeSnapshot(
        range: .all,
        total: 100,
        projects: [ProjectUsage(id: "p", displayName: "monitor", fullPath: "/secret/path", usage: usage(80))]
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
    func reloadUsageWidget() { lock.withLock { count += 1 } }
}

private struct WidgetStoreTestFailure: Error, Sendable {}

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
```

- [ ] **Step 2: Run the publisher suite and verify RED**

Run: `swift test --filter WidgetSnapshotPublisherTests`

Expected: FAIL because `WidgetSnapshotPublisher`, `WidgetSharingStatus`, and reload interfaces are undefined.

- [ ] **Step 3: Implement minimal projection, fingerprinting, and reload adapter**

```swift
enum WidgetSharingStatus: Equatable, Sendable {
    case ready(Date)
    case unavailable(String)
}

protocol WidgetSnapshotPublishing: Sendable {
    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus
}

protocol WidgetTimelineReloading: Sendable {
    func reloadUsageWidget()
}

actor WidgetSnapshotPublisher: WidgetSnapshotPublishing {
    private let aggregator: any UsageAggregating
    private let store: any WidgetSnapshotStoring
    private let reloader: any WidgetTimelineReloading
    private var lastFingerprint: WidgetSnapshotFingerprint?

    init(
        aggregator: any UsageAggregating,
        store: any WidgetSnapshotStoring,
        reloader: any WidgetTimelineReloading
    ) {
        self.aggregator = aggregator
        self.store = store
        self.reloader = reloader
    }

    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus {
        do {
            let today = try await aggregator.snapshot(range: .today, now: now, calendar: calendar)
            let all = try await aggregator.snapshot(range: .all, now: now, calendar: calendar)
            let snapshot = WidgetUsageSnapshot.project(today: today, all: all, now: now)
            let fingerprint = WidgetSnapshotFingerprint(snapshot)
            try store.write(snapshot)
            if fingerprint != lastFingerprint {
                reloader.reloadUsageWidget()
                lastFingerprint = fingerprint
            }
            return .ready(now)
        } catch {
            return .unavailable("小组件共享不可用")
        }
    }
}

private struct WidgetSnapshotFingerprint: Equatable, Sendable {
    let todayTokens: Int64
    let allTimeTokens: Int64
    let fiveHourLimit: WidgetLimitStatus?
    let weekLimit: WidgetLimitStatus?
    let projects: [WidgetProjectUsage]
    let stateKind: String
    let failedFiles: Int?

    init(_ snapshot: WidgetUsageSnapshot) {
        todayTokens = snapshot.todayTokens
        allTimeTokens = snapshot.allTimeTokens
        fiveHourLimit = snapshot.fiveHourLimit
        weekLimit = snapshot.weekLimit
        projects = snapshot.projects
        switch snapshot.state {
        case .fresh:
            stateKind = "fresh"
            failedFiles = nil
        case let .partial(_, count):
            stateKind = "partial"
            failedFiles = count
        case .rebuilding:
            stateKind = "rebuilding"
            failedFiles = nil
        case .stale:
            stateKind = "stale"
            failedFiles = nil
        case .noData:
            stateKind = "noData"
            failedFiles = nil
        case .failed:
            stateKind = "failed"
            failedFiles = nil
        }
    }
}

private extension WidgetUsageSnapshot {
    static func project(
        today: DashboardSnapshot,
        all: DashboardSnapshot,
        now: Date
    ) -> Self {
        let activeLimits = today.limits.filter { $0.resetsAt > now }
        return Self(
            generatedAt: now,
            todayTokens: today.total.total,
            allTimeTokens: all.total.total,
            fiveHourLimit: activeLimits.first { $0.window == .fiveHours }.map {
                WidgetLimitStatus(
                    id: $0.limitID,
                    remainingPercent: $0.remainingPercent,
                    resetsAt: $0.resetsAt
                )
            },
            weekLimit: activeLimits.first { $0.window == .week }.map {
                WidgetLimitStatus(
                    id: $0.limitID,
                    remainingPercent: $0.remainingPercent,
                    resetsAt: $0.resetsAt
                )
            },
            projects: all.projects.prefix(3).map {
                WidgetProjectUsage(
                    id: $0.id,
                    name: $0.displayName,
                    tokens: $0.usage.total
                )
            },
            state: today.freshness.widgetState
        )
    }
}

private extension DataFreshness {
    var widgetState: WidgetDataState {
        switch self {
        case let .fresh(date): .fresh(lastSuccessfulAt: date)
        case let .stale(date): .stale(lastSuccessfulAt: date)
        case let .partial(date, failedFiles):
            .partial(lastSuccessfulAt: date, failedFiles: failedFiles)
        case .rebuilding: .rebuilding(lastSuccessfulAt: nil)
        case .noData, .loading: .noData
        case .failed: .failed
        }
    }
}
```

```swift
import WidgetKit

struct SystemWidgetTimelineReloader: WidgetTimelineReloading {
    func reloadUsageWidget() {
        WidgetCenter.shared.reloadTimelines(
            ofKind: "com.amenggod.CodexUsageMonitor.usage"
        )
    }
}
```

Add `widgetSharingStatus` and an optional `widgetPublisher` to `UsageViewModel`. After a successful aggregation and notification evaluation, call the publisher once; never let widget sharing failure replace the main dashboard snapshot:

```swift
private let widgetPublisher: (any WidgetSnapshotPublishing)?
private(set) var widgetSharingStatus: WidgetSharingStatus?

init(
    aggregator: any UsageAggregating,
    coordinator: any IngestionControlling,
    notifier: any LimitNotifying = NoopLimitNotifier(),
    widgetPublisher: (any WidgetSnapshotPublishing)? = nil
) {
    self.aggregator = aggregator
    self.coordinator = coordinator
    self.notifier = notifier
    self.widgetPublisher = widgetPublisher
}

// At the end of the successful refresh path, after notifier.evaluate:
if let widgetPublisher {
    widgetSharingStatus = await widgetPublisher.publish(now: now, calendar: calendar)
}
```

In `LiveDependencies.makeViewModel`, create `WidgetSnapshotStore.appGroup()`, `WidgetSnapshotPublisher`, and `SystemWidgetTimelineReloader`. If App Group store construction fails, inject an `UnavailableWidgetSnapshotPublisher` that returns `.unavailable("小组件共享不可用")`; do not route that error through `makeFailureViewModel`.

```swift
struct UnavailableWidgetSnapshotPublisher: WidgetSnapshotPublishing {
    let message: String
    func publish(now: Date, calendar: Calendar) async -> WidgetSharingStatus {
        .unavailable(message)
    }
}
```

- [ ] **Step 4: Verify focused and full suites**

Run: `swift test --filter WidgetSnapshotPublisherTests`

Expected: PASS, including one reload for repeated identical visible values.

Run: `swift test --filter UsageViewModelTests`

Expected: PASS, including a new test proving `.unavailable` does not change the successful dashboard.

Run: `swift test`

Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexUsageMonitor/Widget Sources/CodexUsageMonitor/Presentation/UsageViewModel.swift Sources/CodexUsageMonitor/App/LiveDependencies.swift Tests/CodexUsageMonitorTests
git commit -m "feat: publish widget usage snapshots"
```

---

### Task 3: Define time-dependent widget display policy

**Files:**
- Create: `Sources/CodexUsageShared/WidgetDisplayModel.swift`
- Create: `Tests/CodexUsageSharedTests/WidgetDisplayModelTests.swift`

**Interfaces:**
- Consumes: `WidgetUsageSnapshot` and a caller-supplied `Date`.
- Produces: `WidgetDisplayModel.init(snapshot:now:)`.
- Produces: `WidgetDisplayModel.nextRefreshAt`, `visibleFiveHourLimit`, `visibleWeekLimit`, `isStale`, and `statusText`; a `nil` snapshot represents first-sync or decode failure.

- [ ] **Step 1: Write failing time-boundary tests**

```swift
@Test func expiredFiveHourLimitIsRemovedWithoutRemovingWeek() {
    let model = WidgetDisplayModel(
        snapshot: .fixture(
            fiveHourLimit: .fixture(resetsAt: testNow),
            weekLimit: .fixture(resetsAt: testNow.addingTimeInterval(3_600))
        ),
        now: testNow
    )
    #expect(model.visibleFiveHourLimit == nil)
    #expect(model.visibleWeekLimit != nil)
}

@Test func snapshotOlderThanFifteenMinutesKeepsValuesAndShowsLastUpdate() {
    let snapshot = WidgetUsageSnapshot.fixture(
        generatedAt: testNow.addingTimeInterval(-901),
        todayTokens: 42
    )
    let model = WidgetDisplayModel(snapshot: snapshot, now: testNow)
    #expect(model.todayTokens == 42)
    #expect(model.isStale)
    #expect(model.statusText.hasPrefix("上次更新"))
}

@Test func nextRefreshUsesEarliestResetOrFiveMinuteFreshnessTick() {
    let reset = testNow.addingTimeInterval(120)
    let model = WidgetDisplayModel(
        snapshot: .fixture(fiveHourLimit: .fixture(resetsAt: reset)),
        now: testNow
    )
    #expect(model.nextRefreshAt == reset)
}

@Test func missingAndInvalidSnapshotsUseDifferentRecoveryCopy() {
    #expect(
        WidgetDisplayModel(loadState: .missing, now: testNow).statusText
            == "打开 Codex Usage Monitor 完成首次同步"
    )
    #expect(
        WidgetDisplayModel(loadState: .invalid, now: testNow).statusText
            == "等待 Codex Usage Monitor 重新同步"
    )
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter WidgetDisplayModelTests`

Expected: FAIL because `WidgetDisplayModel` does not exist.

- [ ] **Step 3: Implement the pure display model**

```swift
public enum WidgetSnapshotLoadState: Equatable, Sendable {
    case available(WidgetUsageSnapshot)
    case missing
    case invalid
}

public struct WidgetDisplayModel: Equatable, Sendable {
    public static let staleInterval: TimeInterval = 15 * 60
    public static let fallbackRefreshInterval: TimeInterval = 5 * 60

    public let loadState: WidgetSnapshotLoadState
    public let now: Date

    public init(snapshot: WidgetUsageSnapshot?, now: Date) {
        loadState = snapshot.map(WidgetSnapshotLoadState.available) ?? .missing
        self.now = now
    }

    public init(loadState: WidgetSnapshotLoadState, now: Date) {
        self.loadState = loadState
        self.now = now
    }

    public var snapshot: WidgetUsageSnapshot? {
        guard case let .available(snapshot) = loadState else { return nil }
        return snapshot
    }

    public var todayTokens: Int64 { snapshot?.todayTokens ?? 0 }

    public var visibleFiveHourLimit: WidgetLimitStatus? {
        snapshot?.fiveHourLimit.flatMap { $0.resetsAt > now ? $0 : nil }
    }

    public var visibleWeekLimit: WidgetLimitStatus? {
        snapshot?.weekLimit.flatMap { $0.resetsAt > now ? $0 : nil }
    }

    public var isStale: Bool {
        guard let generatedAt = snapshot?.generatedAt else { return true }
        return now.timeIntervalSince(generatedAt) > Self.staleInterval
    }

    public var nextRefreshAt: Date {
        let fallback = now.addingTimeInterval(Self.fallbackRefreshInterval)
        let resets = [visibleFiveHourLimit?.resetsAt, visibleWeekLimit?.resetsAt].compactMap { $0 }
        return resets.min().map { min($0, fallback) } ?? fallback
    }

    public var statusText: String {
        switch loadState {
        case .missing:
            return "打开 Codex Usage Monitor 完成首次同步"
        case .invalid:
            return "等待 Codex Usage Monitor 重新同步"
        case .available:
            break
        }
        guard let snapshot else { return "等待 Codex Usage Monitor 重新同步" }
        if isStale {
            return "上次更新 \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened))"
        }
        return "更新于 \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened))"
    }
}
```

- [ ] **Step 4: Verify focused and full suites**

Run: `swift test --filter WidgetDisplayModelTests`

Expected: PASS for missing, corrupt-placeholder input, expiry, stale, and refresh-date cases.

Run: `swift test`

Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexUsageShared/WidgetDisplayModel.swift Tests/CodexUsageSharedTests/WidgetDisplayModelTests.swift
git commit -m "feat: define widget display policy"
```

---

### Task 4: Replace desktop-card presentation with a reachable dashboard window

**Files:**
- Create: `Sources/CodexUsageMonitor/Presentation/MenuBarVisibilityStore.swift`
- Create: `Sources/CodexUsageMonitor/Presentation/DashboardWindowController.swift`
- Create: `Sources/CodexUsageMonitor/App/AppLaunchCoordinator.swift`
- Create: `Tests/CodexUsageMonitorTests/AppLaunchCoordinatorTests.swift`
- Modify: `Sources/CodexUsageMonitor/App/CodexUsageMonitorApp.swift`
- Modify: `Sources/CodexUsageMonitor/App/AppDelegate.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/SettingsView.swift`
- Modify: `Sources/CodexUsageMonitor/Presentation/UsagePopoverView.swift`
- Modify: `Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift`
- Delete: simulated-card files listed in the File Structure section.

**Interfaces:**
- Produces: `DashboardPresenting.showDashboard()` and a singleton `DashboardWindowController`.
- Produces: `AppLaunchCoordinator.applicationDidFinishLaunching()`, `handleReopen()`, and `handle(urls:)`.
- Produces: `MenuBarVisibilityStore.isVisible` with one-time migration from old `displayMode`.
- Main monitoring starts from application launch, not from a menu-bar or desktop-card `.task`.

- [ ] **Step 1: Write failing launch and migration tests**

```swift
@MainActor
@Test func normalLaunchStartsRuntimeAndShowsDashboardAfterApplicationLaunch() async {
    let runtime = AppRuntimeLauncherSpy()
    let dashboard = DashboardPresenterSpy()
    let coordinator = AppLaunchCoordinator(
        arguments: ["CodexUsageMonitor"],
        runtime: runtime,
        dashboard: dashboard
    )

    await coordinator.applicationDidFinishLaunching()

    #expect(runtime.startCount == 1)
    #expect(dashboard.showCount == 1)
}

@MainActor
@Test func backgroundLaunchStartsRuntimeWithoutShowingDashboard() async {
    let runtime = AppRuntimeLauncherSpy()
    let dashboard = DashboardPresenterSpy()
    let coordinator = AppLaunchCoordinator(
        arguments: ["CodexUsageMonitor", "--background"],
        runtime: runtime,
        dashboard: dashboard
    )
    await coordinator.applicationDidFinishLaunching()
    #expect(runtime.startCount == 1)
    #expect(dashboard.showCount == 0)
}

@MainActor
@Test func widgetURLAndReopenShowTheSameDashboard() async {
    let dashboard = DashboardPresenterSpy()
    let coordinator = AppLaunchCoordinator(
        arguments: [],
        runtime: AppRuntimeLauncherSpy(),
        dashboard: dashboard
    )
    coordinator.handle(urls: [URL(string: "codexusagemonitor://dashboard")!])
    coordinator.handleReopen()
    #expect(dashboard.showCount == 2)
}

@Test func oldDisplayModesMigrateToMenuBarBoolean() throws {
    let defaults = isolatedDefaults()
    defaults.set("both", forKey: "displayMode")
    #expect(MenuBarVisibilityStore(defaults: defaults).isVisible)
    defaults.removeObject(forKey: "menuBarVisible")
    defaults.set("desktop", forKey: "displayMode")
    #expect(!MenuBarVisibilityStore(defaults: defaults).isVisible)
}

@MainActor
private final class AppRuntimeLauncherSpy: AppRuntimeLaunching {
    private(set) var startCount = 0
    func launch() async { startCount += 1 }
}

@MainActor
private final class DashboardPresenterSpy: DashboardPresenting {
    private(set) var showCount = 0
    func showDashboard() { showCount += 1 }
}

private func isolatedDefaults() -> UserDefaults {
    let name = "AppLaunchCoordinatorTests-\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter AppLaunchCoordinatorTests`

Expected: FAIL because the new coordinator and visibility store do not exist.

- [ ] **Step 3: Implement launch routing and one dashboard surface**

```swift
@MainActor
protocol DashboardPresenting: AnyObject {
    func showDashboard()
}

@MainActor
protocol AppRuntimeLaunching: AnyObject {
    func launch() async
}

extension AppRuntime: AppRuntimeLaunching {}

@MainActor
final class AppLaunchCoordinator {
    private let isBackgroundLaunch: Bool
    private let runtime: any AppRuntimeLaunching
    private let dashboard: any DashboardPresenting
    private let notificationCenter: NotificationCenter
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(
        arguments: [String],
        runtime: any AppRuntimeLaunching,
        dashboard: any DashboardPresenting,
        notificationCenter: NotificationCenter = .default
    ) {
        isBackgroundLaunch = arguments.contains("--background")
        self.runtime = runtime
        self.dashboard = dashboard
        self.notificationCenter = notificationCenter
        observers = [
            notificationCenter.addObserver(
                forName: .usageAppDidFinishLaunching,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.applicationDidFinishLaunching()
                }
            },
            notificationCenter.addObserver(
                forName: .usageAppReopenRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleReopen() }
            },
            notificationCenter.addObserver(
                forName: .usageAppURLsOpened,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handle(urls: notification.object as? [URL] ?? [])
                }
            },
        ]
    }

    func applicationDidFinishLaunching() async {
        await runtime.launch()
        if !isBackgroundLaunch { dashboard.showDashboard() }
    }

    func handleReopen() { dashboard.showDashboard() }

    func handle(urls: [URL]) {
        if urls.contains(where: { $0.scheme == "codexusagemonitor" && $0.host == "dashboard" }) {
            dashboard.showDashboard()
        } else if !urls.isEmpty {
            dashboard.showDashboard()
        }
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }
}
```

`DashboardWindowController.swift` contains:

```swift
import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSWindowController, DashboardPresenting {
    private let model: UsageViewModel

    init(model: UsageViewModel) {
        self.model = model
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func showDashboard() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Codex Usage Monitor"
            window.contentView = NSHostingView(rootView: UsagePopoverView(model: model))
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

`AppDelegate.swift` posts lifecycle events only after AppKit reaches the corresponding phase:

```swift
extension Notification.Name {
    static let usageAppDidFinishLaunching = Notification.Name("usage.appDidFinishLaunching")
    static let usageAppReopenRequested = Notification.Name("usage.appReopenRequested")
    static let usageAppURLsOpened = Notification.Name("usage.appURLsOpened")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.post(name: .usageAppDidFinishLaunching, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .usageAppReopenRequested, object: nil)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .usageAppURLsOpened, object: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
```

In `AppLaunchCoordinator.init`, register main-queue observers for these three notifications. The launch observer starts `Task { await applicationDidFinishLaunching() }`; reopen and URL observers call the synchronous routing methods. Remove observers in `deinit`.

`CodexUsageMonitorApp` constructs and retains the coordinator before the app run loop begins; do not call `showDashboard()` from `CodexUsageMonitorApp.init()`.

`MenuBarVisibilityStore.swift` writes `menuBarVisible`; when absent, map old `menuBar`/`both` to `true` and old `desktop`/missing to `false`:

```swift
import Foundation
import Observation

@MainActor
@Observable
final class MenuBarVisibilityStore {
    private static let key = "menuBarVisible"
    private let defaults: UserDefaults
    private(set) var isVisible: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.key) != nil {
            isVisible = defaults.bool(forKey: Self.key)
        } else {
            let oldMode = defaults.string(forKey: "displayMode")
            isVisible = oldMode == "menuBar" || oldMode == "both"
            defaults.set(isVisible, forKey: Self.key)
        }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        defaults.set(visible, forKey: Self.key)
    }
}
```

- [ ] **Step 4: Replace settings and remove the simulated card**

```swift
Section("显示") {
    Toggle("显示顶部菜单栏", isOn: menuBarVisibilityBinding)
    Text("桌面小组件由 macOS 管理：在桌面空白处右键，选择“编辑小组件”，然后搜索 Codex Usage Monitor。")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

Add an “打开完整统计” button to the menu-bar popover footer. Remove `DesktopCard*`, `DisplayModeStore`, `AppPresentationCoordinator`, their tests, and the runtime `.task` from `MenuBarLabel`.

- [ ] **Step 5: Verify launch regression and full suite**

Run: `swift test --filter AppLaunchCoordinatorTests`

Expected: PASS for normal launch, background launch, reopen, deep link, singleton routing, and menu-bar migration.

Run: `swift test --filter AppPresentationStateTests`

Expected: PASS with no desktop-card expectations remaining.

Run: `swift test`

Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexUsageMonitor Tests/CodexUsageMonitorTests
git commit -m "feat: open a reachable usage dashboard"
```

---

### Task 5: Add the silent login-item helper and migrate registration

**Files:**
- Create: `Sources/CodexUsageMonitorLoginItem/LoginItemMain.swift`
- Create: `Sources/CodexUsageShared/LoginItemMainApplicationLocator.swift`
- Modify: `Sources/CodexUsageMonitor/Services/LaunchAtLoginController.swift`
- Modify: `Tests/CodexUsageMonitorTests/LaunchAtLoginControllerTests.swift`

**Interfaces:**
- Produces: login item identifier `com.amenggod.CodexUsageMonitor.LoginItem`.
- Produces: `LoginItemMainApplicationLocating.mainApplicationURL(from:) -> URL`.
- `LaunchAtLoginController` registers `SMAppService.loginItem(identifier:)` and unregisters legacy `SMAppService.mainApp` once during migration.

- [ ] **Step 1: Write failing URL-location and migration tests**

```swift
@Test func loginHelperFindsContainingMainApplication() {
    let helper = URL(fileURLWithPath: "/Applications/Codex Usage Monitor.app/Contents/Library/LoginItems/CodexUsageMonitorLoginItem.app")
    #expect(
        LoginItemMainApplicationLocator.mainApplicationURL(from: helper).path
            == "/Applications/Codex Usage Monitor.app"
    )
}

@Test func controllerUsesHelperServiceAndUnregistersLegacyMainApp() throws {
    let helper = LaunchAtLoginAdapterSpy(enabled: false)
    let legacy = LaunchAtLoginAdapterSpy(enabled: true)
    let controller = LaunchAtLoginController(adapter: helper, legacyAdapter: legacy)
    try controller.migrateLegacyRegistrationIfNeeded()
    try controller.setEnabled(true)
    #expect(legacy.operations == [.unregister])
    #expect(helper.operations == [.register])
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter LaunchAtLoginControllerTests`

Expected: FAIL because helper locator and legacy migration interface do not exist.

- [ ] **Step 3: Implement the helper and ServiceManagement adapter**

```swift
import Foundation

public enum LoginItemMainApplicationLocator {
    public static func mainApplicationURL(from helperBundleURL: URL) -> URL {
        var url = helperBundleURL
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }
}
```

Place the locator above in `Sources/CodexUsageShared/LoginItemMainApplicationLocator.swift`. The helper entry point contains:

```swift
import AppKit
import CodexUsageShared
import Darwin

@main
struct LoginItemMain {
    static func main() {
        let mainURL = LoginItemMainApplicationLocator.mainApplicationURL(
            from: Bundle.main.bundleURL
        )
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--background"]
        NSWorkspace.shared.openApplication(at: mainURL, configuration: configuration) { _, error in
            exit(error == nil ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        RunLoop.main.run()
    }
}
```

```swift
private struct LoginItemLaunchAtLoginAdapter: LaunchAtLoginServiceAdapting {
    private let service = SMAppService.loginItem(
        identifier: "com.amenggod.CodexUsageMonitor.LoginItem"
    )
    var isEnabled: Bool { service.status == .enabled }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}
```

Persist a `didMigrateLoginItemV2` boolean only after legacy unregister succeeds. Preserve the existing setting and error rollback behavior.

- [ ] **Step 4: Verify tests**

Run: `swift test --filter LaunchAtLoginControllerTests`

Expected: PASS for enable, disable, error propagation, helper location, and legacy migration.

Run: `swift test`

Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexUsageMonitorLoginItem Sources/CodexUsageShared/LoginItemMainApplicationLocator.swift Sources/CodexUsageMonitor/Services/LaunchAtLoginController.swift Tests/CodexUsageMonitorTests/LaunchAtLoginControllerTests.swift
git commit -m "feat: add silent login item helper"
```

---

### Task 6: Create the reproducible Xcode application and extension project

**Files:**
- Create: `project.yml`
- Create: `Scripts/generate-project.sh`
- Create: `Config/App-Info.plist`
- Create: `Config/Widget-Info.plist`
- Create: `Config/LoginItem-Info.plist`
- Create: `Config/CodexUsageMonitor.entitlements`
- Create: `Config/CodexUsageMonitorWidget.entitlements`
- Generate: `CodexUsageMonitor.xcodeproj/`
- Remove: `Config/Info.plist`

**Interfaces:**
- App embeds Widget Extension under `Contents/PlugIns`.
- App embeds login item under `Contents/Library/LoginItems`.
- App and widget share `group.com.amenggod.CodexUsageMonitor`.
- URL scheme routes `codexusagemonitor://dashboard` to the app.

- [ ] **Step 1: Write the project-generation contract**

Create `project.yml` with these target dependencies and settings:

```yaml
name: CodexUsageMonitor
options:
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "0.2.0"
    CURRENT_PROJECT_VERSION: "2"
packages:
  SwiftTesting:
    url: https://github.com/swiftlang/swift-testing.git
    revision: swift-6.3.2-RELEASE
targets:
  CodexUsageShared:
    type: framework
    platform: macOS
    sources: [Sources/CodexUsageShared]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.amenggod.CodexUsageMonitor.Shared
  CodexUsageMonitor:
    type: application
    platform: macOS
    sources: [Sources/CodexUsageMonitor]
    info:
      path: Config/App-Info.plist
    entitlements:
      path: Config/CodexUsageMonitor.entitlements
    settings:
      base:
        PRODUCT_NAME: Codex Usage Monitor
        EXECUTABLE_NAME: CodexUsageMonitor
        PRODUCT_BUNDLE_IDENTIFIER: com.amenggod.CodexUsageMonitor
    dependencies:
      - target: CodexUsageShared
      - target: CodexUsageMonitorWidget
        embed: true
      - target: CodexUsageMonitorLoginItem
    postBuildScripts:
      - name: Embed Login Item
        script: |
          set -euo pipefail
          destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LoginItems"
          mkdir -p "$destination"
          ditto "$BUILT_PRODUCTS_DIR/CodexUsageMonitorLoginItem.app" "$destination/CodexUsageMonitorLoginItem.app"
  CodexUsageMonitorWidget:
    type: app-extension
    platform: macOS
    sources: [Sources/CodexUsageMonitorWidget]
    info:
      path: Config/Widget-Info.plist
    entitlements:
      path: Config/CodexUsageMonitorWidget.entitlements
    dependencies:
      - target: CodexUsageShared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.amenggod.CodexUsageMonitor.Widget
        APPLICATION_EXTENSION_API_ONLY: YES
        SKIP_INSTALL: YES
  CodexUsageMonitorLoginItem:
    type: application
    platform: macOS
    sources: [Sources/CodexUsageMonitorLoginItem]
    info:
      path: Config/LoginItem-Info.plist
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.amenggod.CodexUsageMonitor.LoginItem
        SKIP_INSTALL: YES
  CodexUsageMonitorTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests/CodexUsageMonitorTests
        excludes: [Fixtures]
      - path: Tests/CodexUsageSharedTests
    resources: [Tests/CodexUsageMonitorTests/Fixtures]
    dependencies:
      - target: CodexUsageMonitor
      - target: CodexUsageShared
      - package: SwiftTesting
        product: Testing
```

- [ ] **Step 2: Add complete target metadata and entitlements**

`Config/App-Info.plist` is:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleDisplayName</key><string>Codex Usage Monitor</string>
<key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Codex Usage Monitor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
<key>LSMinimumSystemVersion</key><string>$(MACOSX_DEPLOYMENT_TARGET)</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>Codex Usage Monitor Dashboard</string>
    <key>CFBundleURLSchemes</key>
    <array><string>codexusagemonitor</string></array>
  </dict>
</array>
</dict></plist>
```

`Config/Widget-Info.plist` is:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Codex Usage Widget</string>
<key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.widgetkit-extension</string>
</dict>
</dict></plist>
```

`Config/LoginItem-Info.plist` is:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Codex Usage Monitor Login Item</string>
<key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
<key>LSUIElement</key><true/>
</dict></plist>
```

`Config/CodexUsageMonitor.entitlements` is:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.application-groups</key>
<array><string>group.com.amenggod.CodexUsageMonitor</string></array>
</dict></plist>
```

`Config/CodexUsageMonitorWidget.entitlements` is:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key>
<array><string>group.com.amenggod.CodexUsageMonitor</string></array>
</dict></plist>
```

- [ ] **Step 3: Generate and validate the project**

`Scripts/generate-project.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v xcodegen >/dev/null || { echo "xcodegen is required" >&2; exit 1; }
xcodegen generate --spec project.yml
```

Install full Xcode 26.3 or later from the Mac App Store, then run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -version
```

Expected: `xcodebuild -version` reports the selected full Xcode. If App Store authentication is required, the user completes that sign-in step directly.

Run: `brew install xcodegen`

Expected: XcodeGen installs successfully without modifying repository files.

Run: `bash Scripts/generate-project.sh`

Expected: `CodexUsageMonitor.xcodeproj/project.pbxproj` is generated.

Run: `git diff --exit-code -- CodexUsageMonitor.xcodeproj` immediately after a second generation.

Expected: exit 0, proving deterministic generation.

- [ ] **Step 4: Run available verification**

Run: `swift test`

Expected: 0 failures.

If full Xcode is installed, run:

`xcodebuild -project CodexUsageMonitor.xcodeproj -scheme CodexUsageMonitor -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: `** BUILD SUCCEEDED **`.

If full Xcode is not installed, push this task branch and require the Xcode compile job added in Task 8 before declaring Task 6 delivery-verified.

- [ ] **Step 5: Commit**

```bash
git add project.yml CodexUsageMonitor.xcodeproj Scripts/generate-project.sh Config Package.swift
git commit -m "build: add app and widget Xcode targets"
```

---

### Task 7: Implement the WidgetKit provider and native views

**Files:**
- Create: `Sources/CodexUsageMonitorWidget/CodexUsageWidgetBundle.swift`
- Create: `Sources/CodexUsageMonitorWidget/UsageTimelineProvider.swift`
- Create: `Sources/CodexUsageMonitorWidget/UsageWidgetView.swift`
- Modify: `Sources/CodexUsageShared/WidgetDisplayModel.swift`
- Modify: `Tests/CodexUsageSharedTests/WidgetDisplayModelTests.swift`

**Interfaces:**
- Produces widget kind `com.amenggod.CodexUsageMonitor.usage`.
- Produces `UsageWidgetEntry(date:snapshot:)` and `UsageTimelineProvider`.
- Root widget view uses `.widgetURL(URL(string: "codexusagemonitor://dashboard"))`.

- [ ] **Step 1: Extend failing display tests for both families**

```swift
@Test func smallPresentationContainsTodayWeekAndFreshnessOnly() {
    let model = WidgetDisplayModel(snapshot: .fixture, now: testNow)
    #expect(model.small.todayTokens == 12_345)
    #expect(model.small.weekRemainingPercent == 72)
    #expect(model.small.projects.isEmpty)
}

@Test func mediumPresentationReflowsWhenFiveHourLimitIsMissing() {
    let model = WidgetDisplayModel(snapshot: .fixture(fiveHourLimit: nil), now: testNow)
    #expect(model.medium.fiveHourRemainingPercent == nil)
    #expect(model.medium.projects.count == 3)
    #expect(model.medium.usesExpandedWeekLayout)
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter WidgetDisplayModelTests`

Expected: FAIL because family-specific presentation values are not defined.

- [ ] **Step 3: Add the provider and family-specific SwiftUI**

First add explicit family projections to `WidgetDisplayModel`:

```swift
public struct SmallWidgetPresentation: Equatable, Sendable {
    public let todayTokens: Int64
    public let weekRemainingPercent: Double?
    public let statusText: String
    public let projects: [WidgetProjectUsage]
}

public struct MediumWidgetPresentation: Equatable, Sendable {
    public let todayTokens: Int64
    public let allTimeTokens: Int64
    public let fiveHourRemainingPercent: Double?
    public let weekRemainingPercent: Double?
    public let projects: [WidgetProjectUsage]
    public let statusText: String
    public var usesExpandedWeekLayout: Bool { fiveHourRemainingPercent == nil }
}

public extension WidgetDisplayModel {
    var small: SmallWidgetPresentation {
        SmallWidgetPresentation(
            todayTokens: snapshot?.todayTokens ?? 0,
            weekRemainingPercent: visibleWeekLimit?.remainingPercent,
            statusText: statusText,
            projects: []
        )
    }

    var medium: MediumWidgetPresentation {
        MediumWidgetPresentation(
            todayTokens: snapshot?.todayTokens ?? 0,
            allTimeTokens: snapshot?.allTimeTokens ?? 0,
            fiveHourRemainingPercent: visibleFiveHourLimit?.remainingPercent,
            weekRemainingPercent: visibleWeekLimit?.remainingPercent,
            projects: snapshot?.projects ?? [],
            statusText: statusText
        )
    }
}
```

```swift
struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let loadState: WidgetSnapshotLoadState
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: .now, loadState: .available(.placeholder))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        completion(UsageWidgetEntry(date: .now, loadState: loadState()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        let now = Date()
        let state = loadState()
        let model = WidgetDisplayModel(loadState: state, now: now)
        completion(Timeline(
            entries: [UsageWidgetEntry(date: now, loadState: state)],
            policy: .after(model.nextRefreshAt)
        ))
    }

    private func loadState() -> WidgetSnapshotLoadState {
        do {
            guard let snapshot = try WidgetSnapshotStore.appGroup().read() else {
                return .missing
            }
            return .available(snapshot)
        } catch {
            return .invalid
        }
    }
}
```

```swift
struct CodexUsageWidget: Widget {
    let kind = "com.amenggod.CodexUsageMonitor.usage"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "codexusagemonitor://dashboard"))
        }
        .configurationDisplayName("Codex 用量")
        .description("查看最近一次同步的 Token 用量与限额。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
```

`UsageWidgetView.swift` contains the concrete family split and never renders a numeric zero when no snapshot exists:

```swift
import SwiftUI
import WidgetKit
import CodexUsageShared

struct UsageWidgetView: View {
    let entry: UsageWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let model = WidgetDisplayModel(loadState: entry.loadState, now: entry.date)
        Group {
            if model.snapshot == nil {
                ContentUnavailableView("Codex 用量", systemImage: "gauge", description: Text(model.statusText))
            } else if family == .systemMedium {
                MediumUsageWidgetView(model: model)
            } else {
                SmallUsageWidgetView(model: model)
            }
        }
    }
}

private struct SmallUsageWidgetView: View {
    let model: WidgetDisplayModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex").font(.headline)
            Text(model.small.todayTokens.formatted(.number.notation(.compactName)))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("今日 Token").font(.caption).foregroundStyle(.secondary)
            if let remaining = model.small.weekRemainingPercent {
                Gauge(value: remaining, in: 0...100) { Text("周剩余") } currentValueLabel: {
                    Text("\(Int(remaining.rounded()))%")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                Text("等待周限额").font(.caption)
            }
            Text(model.small.statusText).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct MediumUsageWidgetView: View {
    let model: WidgetDisplayModel
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("今日 \(model.medium.todayTokens.formatted(.number.notation(.compactName)))")
                    .font(.title2.monospacedDigit().weight(.semibold))
                Text("全部 \(model.medium.allTimeTokens.formatted(.number.notation(.compactName)))")
                    .font(.caption).foregroundStyle(.secondary)
                if let fiveHour = model.medium.fiveHourRemainingPercent {
                    ProgressView("5 小时剩余 \(Int(fiveHour.rounded()))%", value: fiveHour, total: 100)
                }
                if let week = model.medium.weekRemainingPercent {
                    ProgressView("周剩余 \(Int(week.rounded()))%", value: week, total: 100)
                } else {
                    Text("等待周限额").font(.caption)
                }
                Spacer()
                Text(model.medium.statusText).font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("项目").font(.headline)
                ForEach(model.medium.projects, id: \.id) { project in
                    HStack {
                        Text(project.name).lineLimit(1)
                        Spacer()
                        Text(project.tokens.formatted(.number.notation(.compactName)))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

- [ ] **Step 4: Verify logic and Xcode compilation**

Run: `swift test --filter WidgetDisplayModelTests`

Expected: PASS.

Run on full Xcode or CI:

`xcodebuild -project CodexUsageMonitor.xcodeproj -scheme CodexUsageMonitor -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: `** BUILD SUCCEEDED **` and a built `CodexUsageMonitorWidget.appex` inside the app products.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodexUsageMonitorWidget Sources/CodexUsageShared Tests/CodexUsageSharedTests
git commit -m "feat: add native Codex usage widgets"
```

---

### Task 8: Replace packaging and add Xcode CI gates

**Files:**
- Modify: `Scripts/build-app.sh`
- Modify: `.github/workflows/ci.yml`
- Create: `Scripts/verify-bundle.sh`

**Interfaces:**
- `Scripts/build-app.sh` produces `dist/Codex Usage Monitor.app` and `dist/Codex-Usage-Monitor-macOS.zip` from the Xcode Release product.
- Unsigned CI proves compilation and structure only; installable widget builds require a valid Apple Development or Developer ID identity.

- [ ] **Step 1: Add a failing structural bundle verifier**

```bash
#!/usr/bin/env bash
set -euo pipefail
APP="${1:?usage: verify-bundle.sh /path/to/app}"
test -x "$APP/Contents/MacOS/CodexUsageMonitor"
test -d "$APP/Contents/PlugIns/CodexUsageMonitorWidget.appex"
test -d "$APP/Contents/Library/LoginItems/CodexUsageMonitorLoginItem.app"
plutil -lint "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/PlugIns/CodexUsageMonitorWidget.appex/Contents/Info.plist"
plutil -lint "$APP/Contents/Library/LoginItems/CodexUsageMonitorLoginItem.app/Contents/Info.plist"
```

Run against the current legacy app bundle.

Expected: FAIL because the widget extension and login item are absent.

- [ ] **Step 2: Build from Xcode and package the complete app**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.build/xcode-derived"
APP="$ROOT/dist/Codex Usage Monitor.app"
ZIP="$ROOT/dist/Codex-Usage-Monitor-macOS.zip"
cd "$ROOT"
rm -rf "$DERIVED" "$APP" "$ZIP"
xcodebuild \
  -project CodexUsageMonitor.xcodeproj \
  -scheme CodexUsageMonitor \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
  build
ditto "$DERIVED/Build/Products/Release/Codex Usage Monitor.app" "$APP"
bash Scripts/verify-bundle.sh "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
```

For signed builds, pass `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE=Automatic`, and `CODE_SIGNING_ALLOWED=YES` through a separate release invocation; do not bake a team ID or identity into the script.

- [ ] **Step 3: Add CI project reproducibility and compile jobs**

CI sequence:

```yaml
- name: Select Xcode 26.3
  run: sudo xcode-select -s /Applications/Xcode_26.3.app/Contents/Developer
- name: Install XcodeGen
  run: brew install xcodegen
- name: Verify generated project is current
  run: |
    bash Scripts/generate-project.sh
    git diff --exit-code -- CodexUsageMonitor.xcodeproj
- name: Test Swift package
  run: swift test
- name: Compile app and widget without signing
  run: CODE_SIGNING_ALLOWED=NO bash Scripts/build-app.sh
```

- [ ] **Step 4: Verify locally available checks and CI**

Run: `swift test`

Expected: 0 failures.

Run on CI: push the branch and inspect the new workflow run.

Expected: project reproducibility, Swift tests, Xcode app compile, extension embedding, helper embedding, plist validation, and ZIP creation all pass.

- [ ] **Step 5: Commit**

```bash
git add Scripts .github/workflows/ci.yml
git commit -m "ci: build and verify the widget app bundle"
```

---

### Task 9: Update settings, migration copy, README, and privacy documentation

**Files:**
- Modify: `README.md`
- Modify: `Sources/CodexUsageMonitor/Presentation/SettingsView.swift`
- Modify: `Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift`

**Interfaces:**
- Settings exposes menu-bar visibility, login helper status, notification settings, rescan, widget setup help, and widget-sharing error state.
- README distinguishes unsigned CI artifacts, Apple Development builds, and notarized Developer ID releases.

- [ ] **Step 1: Write failing settings-state copy tests**

```swift
@MainActor
@Test func widgetSharingFailureAppearsWithoutChangingNotificationOrLoginState() {
    let state = SettingsViewState(
        launchAtLogin: LaunchAtLoginServiceSpy(enabled: true),
        notificationSender: PresentationNotificationSenderSpy(enabled: false),
        widgetSharingStatus: .unavailable("小组件共享不可用")
    )
    #expect(state.widgetSharingMessage == "小组件共享不可用")
    #expect(state.isLaunchAtLoginEnabled)
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter AppPresentationStateTests`

Expected: FAIL because widget sharing copy is not exposed by settings state.

- [ ] **Step 3: Complete user-facing settings and documentation**

README must include these exact operational facts:

- Add the widget by right-clicking empty desktop space, choosing “编辑小组件”, and searching “Codex Usage Monitor”.
- The widget shows the last shared snapshot and may update later than the full app because WidgetKit schedules refreshes.
- Clicking the widget opens the full dashboard.
- The app must run in the background for new Codex log events to reach the shared snapshot.
- Missing or expired 5-hour quota disappears by design.
- An unsigned CI bundle is only a compile artifact and is not the installable release.
- A distributable widget build needs matching signatures and App Group entitlements for the app and extension.
- Contributors must set their own Team, bundle IDs, and App Group without committing secrets.

Remove all instructions for dragging, expanding, or selecting the old desktop card. Update troubleshooting for missing widget discovery, stale snapshot, menu-bar visibility, login-item approval, and Gatekeeper.

- [ ] **Step 4: Verify docs and behavior tests**

Run: `swift test --filter AppPresentationStateTests`

Expected: PASS.

Run: `rg -n '可拖动|展开桌面卡片|仅桌面卡片|桌面与菜单栏' README.md Sources Tests`

Expected: no product copy or active tests reference the removed simulated desktop card; historical design documents are excluded from this scan.

Run: `git diff --check`

Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add README.md Sources/CodexUsageMonitor/Presentation/SettingsView.swift Tests/CodexUsageMonitorTests/AppPresentationStateTests.swift
git commit -m "docs: explain native widget setup and refresh"
```

---

### Task 10: Perform full regression, signed installation, and real desktop-widget verification

**Files:**
- Modify only if verification finds a defect; every defect first receives a failing regression test in the owning test file.
- Update: existing GitHub Pull Request description and verification evidence after all gates pass.

**Interfaces:**
- Delivery is complete only when logic tests, Xcode compilation, embedded bundle validation, signing checks, widget discovery, click routing, and privacy inspection all have current evidence.

- [ ] **Step 1: Run complete automated regression**

Run: `swift test`

Expected: every suite passes with 0 failures.

Run ten times for concurrency-sensitive ingestion coverage:

```bash
for run in {1..10}; do
  swift test --filter IngestionCoordinatorTests || exit 1
done
```

Expected: all ten runs pass.

- [ ] **Step 2: Run unsigned Xcode build and bundle structure checks**

Run with full Xcode selected:

```bash
sudo xcode-select -s /Applications/Xcode_26.3.app/Contents/Developer
bash Scripts/generate-project.sh
CODE_SIGNING_ALLOWED=NO bash Scripts/build-app.sh
bash Scripts/verify-bundle.sh "dist/Codex Usage Monitor.app"
```

Expected: build success, complete app, `.appex`, login item, valid plists, and ZIP.

- [ ] **Step 3: Produce a properly signed local validation build**

Prerequisites: full Xcode, an Apple Developer team, registered App Group, and an Apple Development identity.

```bash
xcodebuild \
  -project CodexUsageMonitor.xcodeproj \
  -scheme CodexUsageMonitor \
  -configuration Release \
  -derivedDataPath .build/signed-derived \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  build
```

Expected: `** BUILD SUCCEEDED **` without replacing the App Group entitlement.

Verify signatures and entitlements:

```bash
codesign --verify --deep --strict --verbose=4 ".build/signed-derived/Build/Products/Release/Codex Usage Monitor.app"
codesign -d --entitlements :- ".build/signed-derived/Build/Products/Release/Codex Usage Monitor.app"
codesign -d --entitlements :- ".build/signed-derived/Build/Products/Release/Codex Usage Monitor.app/Contents/PlugIns/CodexUsageMonitorWidget.appex"
```

Expected: valid nested signatures and the same App Group in app and extension.

- [ ] **Step 4: Verify real installation behavior on macOS**

1. Copy the signed app to `/Applications` and launch it from Finder.
2. Confirm one dashboard window appears and monitoring starts.
3. Close the dashboard, relaunch from Finder, and confirm the same dashboard returns.
4. Right-click the desktop, choose “编辑小组件”, search “Codex Usage Monitor”, and add small and medium widgets.
5. Confirm small shows today, week, and update state; medium shows today, all-time, valid limits, and up to three projects.
6. Confirm an unavailable 5-hour limit leaves no blank slot.
7. Produce a Codex log event and confirm the full app updates first, then the widget shows a newer timestamp when WidgetKit refreshes.
8. Click the widget and confirm the existing dashboard is opened or brought forward, not duplicated.
9. Enable login start, log out/in or use the registered helper, and confirm monitoring starts with no dashboard window.
10. Quit the app and confirm the widget retains the last values while its timestamp becomes stale.

- [ ] **Step 5: Verify privacy boundary and CI evidence**

Run:

```bash
rg -n 'prompt|response|tool_output|fullPath|workingDirectory' Sources/CodexUsageShared Sources/CodexUsageMonitorWidget
```

Expected: no shared snapshot or widget payload field stores sensitive session content or full paths; any test assertion is explicitly negative.

Open the latest GitHub Actions run.

Expected: Swift tests and Xcode build jobs both succeed on the final commit.

- [ ] **Step 6: Prepare notarization only after signed validation passes**

Archive and sign with Developer ID Application, then run the established `notarytool submit --wait`, `stapler staple`, `stapler validate`, and `spctl --assess --type execute` release flow. Do not label the downloadable ZIP “notarized” until all four commands succeed on that exact artifact.

- [ ] **Step 7: Commit any verification-only fixes and update the PR**

```bash
git status --short
git log --oneline main..HEAD
git push -u origin codex/usage-monitor-v2
gh pr edit 1 --title "Add native macOS usage widget and fix ingestion" --body-file .superpowers/sdd/pr-body.md
```

Expected: clean worktree, remote branch equals local HEAD, PR describes WidgetKit refresh limits, signing status, test counts, CI URL, and any remaining external signing gate.

---

## Completion Gate

Do not claim the native desktop widget is delivered merely because `swift test` or an unsigned Xcode build passes. Delivery requires a signed app whose Widget Extension appears in the macOS widget gallery and whose click opens the dashboard. If full Xcode, App Group registration, or Apple signing is unavailable, report the exact blocked gate while still delivering all source, tests, and CI evidence completed before it.
