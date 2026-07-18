import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite(.serialized)
struct IngestionCoordinatorTests {
    @Test
    func watcherStartupFailurePublishesFailedThenRecovers() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let roots = [directoryURL.appending(path: "sessions", directoryHint: .isDirectory)]
        try FileManager.default.createDirectory(at: roots[0], withIntermediateDirectories: true)
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let failedWatcher = ControlledWatcher(startupFailure: "synthetic watcher start failure")
        let recoveredWatcher = ControlledWatcher()
        let coordinator = IngestionCoordinator(
            roots: roots,
            repository: repository,
            scanner: scanner,
            watcher: failedWatcher,
            watcherFactory: { _ in recoveredWatcher },
            recoveryDelay: .milliseconds(10)
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }

        await coordinator.start()

        #expect(await recorder.waitForCount(1))
        #expect(await recorder.value(at: 0) == .failed("synthetic watcher start failure"))
        #expect(await recorder.waitForCount(2))
        #expect(await recorder.value(at: 1) == .completed)
        #expect(recoveredWatcher.eventsCallCount == 1)

        await coordinator.stop()
    }

    @Test
    func explicitStopDoesNotReportWatcherFailure() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let roots = [directoryURL.appending(path: "sessions", directoryHint: .isDirectory)]
        try FileManager.default.createDirectory(at: roots[0], withIntermediateDirectories: true)
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let watcher = ControlledWatcher()
        let coordinator = IngestionCoordinator(
            roots: roots,
            repository: repository,
            scanner: scanner,
            watcher: watcher,
            watcherFactory: { _ in ControlledWatcher() },
            recoveryDelay: .milliseconds(10)
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }
        await coordinator.start()
        #expect(await recorder.waitForCount(1))

        await coordinator.stop()
        try await Task.sleep(for: .milliseconds(50))

        #expect(await recorder.count == 1)
        #expect(await recorder.value(at: 0) == .completed)
    }

    @Test
    func watcherEndingDuringScanCannotBeHiddenByScanCompletion() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSyntheticLog(at: root.appending(path: "gated.jsonl"))
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let watcher = ControlledWatcher()
        let scanGate = OneShotScanGate()
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: watcher,
            watcherFactory: { _ in ControlledWatcher() },
            recoveryDelay: .seconds(30),
            scanFileOperation: { url in
                await scanGate.suspendFirstScan()
                return try await scanner.scan(url: url)
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }

        let startTask = Task { await coordinator.start() }
        await scanGate.waitUntilSuspended()
        watcher.finishUnexpectedly()
        #expect(await recorder.waitForCount(1))
        #expect(await recorder.value(at: 0) == .failed("Codex 会话文件监听器意外停止"))

        await scanGate.resume()
        await startTask.value
        #expect(await recorder.count == 1)

        await coordinator.stop()
    }

    @Test
    func initialScanRecursesAcrossLiveAndArchivedRoots() async throws {
        let fixture = try CoordinatorFixture(createArchivedRoot: true)
        defer { fixture.remove() }
        try fixture.writeLog(
            root: fixture.sessionsRoot,
            relativePath: "2026/07/live.jsonl",
            sessionID: "live",
            total: 10
        )
        try fixture.writeLog(
            root: fixture.archivedRoot,
            relativePath: "archived.jsonl",
            sessionID: "archived",
            total: 20
        )
        let recorder = await fixture.start()
        defer { Task { await recorder.stop() } }

        #expect(await recorder.waitForCount(1))
        #expect(await recorder.value(at: 0) == .completed)
        #expect(try await fixture.totalUsage() == 30)

        await fixture.coordinator.stop()
    }

    @Test
    func oneBrokenFileDoesNotBlockHealthyFilesAndCanRecover() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSyntheticLog(at: root.appending(path: "broken.jsonl"))
        try writeSyntheticLog(at: root.appending(path: "healthy.jsonl"))
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let scanController = FailureIsolationController()
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: ControlledWatcher(),
            recoveryDelay: .seconds(30),
            scanFileOperation: { url in
                try await scanController.scan(url, using: scanner)
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }

        await coordinator.start()

        #expect(await scanController.scannedNames == ["broken.jsonl", "healthy.jsonl"])
        #expect(await recorder.waitForCount(1))
        #expect(await recorder.value(at: 0) == .partial(failedFiles: 1))

        await scanController.allowBrokenFile()
        await coordinator.rescanAll()

        #expect(await recorder.waitForValue(.completed))
        await coordinator.stop()
    }

    @Test
    func changedFileFailureRetainsOldMetadataAndRetriesSuccessfully() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logURL = root.appending(path: "retry.jsonl")
        try writeSyntheticLog(at: logURL)
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let scanController = SecondScanErrorController(suspendsBeforeError: false)
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: ControlledWatcher(),
            recoveryDelay: .seconds(30),
            scanFileOperation: { url in
                try await scanController.beforeScan()
                return try await scanner.scan(url: url)
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }
        await coordinator.start()
        #expect(await recorder.waitForCount(1))

        try appendSyntheticToken(to: logURL, second: 2, cumulativeTotal: 2)
        await coordinator.rescanAll()
        #expect(await recorder.waitForValue(.partial(failedFiles: 1)))

        await coordinator.rescanAll()

        #expect(await recorder.waitForLastValue(.completed, minimumCount: 3))
        #expect(await scanController.scanCount == 3)
        #expect(try await repository.queryUsage(from: nil, to: .distantFuture)
            .map(\.usage.total)
            .reduce(0, +) == 2)
        await coordinator.stop()
    }

    @Test
    func rebuildWithBrokenAndHealthyFilesPublishesPartialAfterAllProgress() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let scanController = FailureIsolationController()
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: ControlledWatcher(),
            recoveryDelay: .seconds(30),
            scanFileOperation: { url in
                try await scanController.scan(url, using: scanner)
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }
        await coordinator.start()
        #expect(await recorder.waitForCount(1))
        try writeSyntheticLog(at: root.appending(path: "broken.jsonl"))
        try writeSyntheticLog(at: root.appending(path: "healthy.jsonl"))

        try await coordinator.rebuildIndex()

        #expect(await recorder.waitForCount(5))
        #expect(await recorder.value(at: 1) == .rebuilding(completed: 0, total: 2))
        #expect(await recorder.value(at: 2) == .rebuilding(completed: 1, total: 2))
        #expect(await recorder.value(at: 3) == .rebuilding(completed: 2, total: 2))
        #expect(await recorder.value(at: 4) == .partial(failedFiles: 1))
        #expect(await scanController.scannedNames == ["broken.jsonl", "healthy.jsonl"])
        #expect(try await repository.queryUsage(from: nil, to: .distantFuture)
            .map(\.usage.total)
            .reduce(0, +) == 1)
        await coordinator.stop()
    }

    @Test
    func cancellationIsRethrownWithoutPartialOrRecovery() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSyntheticLog(at: root.appending(path: "cancelled.jsonl"))
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let scanCounter = ScanCallCounter()
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: ControlledWatcher(),
            recoveryDelay: .milliseconds(10),
            scanFileOperation: { _ -> ScanResult in
                await scanCounter.increment()
                throw CancellationError()
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }

        await coordinator.start()

        #expect(await recorder.waitForCount(1))
        if case .failed = await recorder.value(at: 0) {
            // Expected: cancellation escapes the per-file isolation boundary.
        } else {
            Issue.record("Expected cancellation to publish a top-level failure")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await scanCounter.value == 1)
        #expect(await recorder.count == 1)
        await coordinator.stop()
    }

    @Test
    func rebuildCancellationDoesNotScheduleRecovery() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSyntheticLog(at: root.appending(path: "cancel-rebuild.jsonl"))
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let scanController = SecondScanCancellationController()
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: ControlledWatcher(),
            recoveryDelay: .milliseconds(10),
            scanFileOperation: { url in
                try await scanController.beforeScan()
                return try await scanner.scan(url: url)
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }
        await coordinator.start()
        #expect(await recorder.waitForCount(1))

        do {
            try await coordinator.rebuildIndex()
            Issue.record("Expected rebuild cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(await recorder.waitForCount(3))
        if case .failed = await recorder.value(at: 2) {
            // Expected top-level cancellation publication.
        } else {
            Issue.record("Expected cancellation to publish failed after progress")
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await scanController.scanCount == 2)
        #expect(await recorder.count == 3)
        await coordinator.stop()
    }

    @Test
    func metadataReadFailureDoesNotBlockHealthyFileAndCanRecover() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSyntheticLog(at: root.appending(path: "broken.jsonl"))
        try writeSyntheticLog(at: root.appending(path: "healthy.jsonl"))
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let metadataController = MetadataFailureController(failingName: "broken.jsonl")
        let scanRecorder = RecordingScanOperation()
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: ControlledWatcher(),
            recoveryDelay: .milliseconds(10),
            scanFileOperation: { url in
                try await scanRecorder.scan(url, using: scanner)
            },
            fileMetadataOperation: { url in
                try metadataController.metadata(for: url)
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }

        await coordinator.start()

        #expect(await recorder.waitForCount(1))
        #expect(await recorder.value(at: 0) == .partial(failedFiles: 1))
        #expect(await scanRecorder.scannedNames == ["healthy.jsonl"])

        metadataController.allowFailedFile()

        #expect(await recorder.waitForLastValue(.completed, minimumCount: 2))
        #expect(await scanRecorder.scannedNames == ["broken.jsonl", "healthy.jsonl"])
        #expect(metadataController.failedFileAttempts >= 2)
        await coordinator.stop()
    }

    @Test
    func rebuildPublishesProgressAfterEachDiscoveredFile() async throws {
        let fixture = try CoordinatorFixture(createArchivedRoot: true)
        defer { fixture.remove() }
        try fixture.writeLog(
            root: fixture.sessionsRoot,
            relativePath: "first.jsonl",
            sessionID: "first",
            total: 10
        )
        try fixture.writeLog(
            root: fixture.archivedRoot,
            relativePath: "second.jsonl",
            sessionID: "second",
            total: 20
        )
        let recorder = await fixture.start()
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitForCount(1))

        try await fixture.coordinator.rebuildIndex()

        #expect(await recorder.waitForCount(5))
        #expect(await recorder.value(at: 1) == .rebuilding(completed: 0, total: 2))
        #expect(await recorder.value(at: 2) == .rebuilding(completed: 1, total: 2))
        #expect(await recorder.value(at: 3) == .rebuilding(completed: 2, total: 2))
        #expect(await recorder.value(at: 4) == .completed)
        await fixture.coordinator.stop()
    }

    @Test
    func fileEventsAreDebouncedAndPublishAfterScanning() async throws {
        let fixture = try CoordinatorFixture(createArchivedRoot: true)
        defer { fixture.remove() }
        let logURL = try fixture.writeLog(
            root: fixture.sessionsRoot,
            relativePath: "live.jsonl",
            sessionID: "live",
            total: 10
        )
        let recorder = await fixture.start()
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitForCount(1))

        try fixture.appendToken(to: logURL, second: 2, lastTotal: 2, cumulativeTotal: 12)
        try await Task.sleep(for: .milliseconds(50))
        try fixture.appendToken(to: logURL, second: 3, lastTotal: 3, cumulativeTotal: 15)

        try await Task.sleep(for: .milliseconds(150))
        #expect(await recorder.count == 1)
        #expect(await recorder.waitForCount(2, attempts: 120))
        #expect(await recorder.value(at: 1) == .completed)
        #expect(try await fixture.totalUsage() == 15)

        await fixture.coordinator.stop()
    }

    @Test
    func missingArchivedRootCanAppearAndBeRescanned() async throws {
        let fixture = try CoordinatorFixture(createArchivedRoot: false)
        defer { fixture.remove() }
        try fixture.writeLog(
            root: fixture.sessionsRoot,
            relativePath: "live.jsonl",
            sessionID: "live",
            total: 10
        )
        let recorder = await fixture.start()
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitForCount(1))

        try FileManager.default.createDirectory(
            at: fixture.archivedRoot,
            withIntermediateDirectories: true
        )
        try fixture.writeLog(
            root: fixture.archivedRoot,
            relativePath: "recovered.jsonl",
            sessionID: "recovered",
            total: 20
        )

        #expect(await recorder.waitForCount(2, attempts: 120))
        #expect(try await fixture.totalUsage() == 30)

        await fixture.coordinator.stop()
    }

    @Test
    func rebuildClearsTheIndexBeforeFullRescan() async throws {
        let fixture = try CoordinatorFixture(createArchivedRoot: true)
        defer { fixture.remove() }
        try fixture.writeLog(
            root: fixture.sessionsRoot,
            relativePath: "live.jsonl",
            sessionID: "live",
            total: 10
        )
        let recorder = await fixture.start()
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitForCount(1))

        try await fixture.coordinator.rebuildIndex()

        #expect(await recorder.waitForCount(2))
        #expect(try await fixture.totalUsage() == 10)

        await fixture.coordinator.stop()
    }

    @Test
    func rebuildDefersWatcherEventsUntilOneFinalUpdate() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sessionsRoot = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        let archivedRoot = directoryURL.appending(path: "archived", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let watcher = ControlledWatcher()
        let gate = SuspensionGate()
        let coordinator = IngestionCoordinator(
            roots: [sessionsRoot, archivedRoot],
            repository: repository,
            scanner: scanner,
            watcher: watcher,
            watcherFactory: { _ in ControlledWatcher() },
            recoveryDelay: .seconds(30),
            debounceDelay: .milliseconds(10),
            resetIndexOperation: {
                try await repository.resetIndex()
                await gate.suspend()
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }
        await coordinator.start()
        #expect(await recorder.waitForCount(1))

        let rebuildTask = Task {
            try await coordinator.rebuildIndex()
        }
        await gate.waitUntilSuspended()
        try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        watcher.emit()
        try await Task.sleep(for: .milliseconds(250))

        #expect(await recorder.count == 1)

        await gate.resume()
        try await rebuildTask.value
        #expect(await recorder.waitForLastValue(.completed, minimumCount: 2))
        let updateCount = await recorder.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.count == updateCount)
        #expect(await recorder.occurrenceCount(of: .completed) == 2)

        await coordinator.stop()
    }

    @Test
    func rebuildWaitsForInflightScanAndConsumesEventArrivingDuringMerge() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logURL = root.appending(path: "sequenced.jsonl")
        try writeSyntheticLog(at: logURL)
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let watcher = ControlledWatcher()
        let scanSequence = SequencedScanGate(gatedCalls: [2, 3, 4])
        let resetGate = SuspensionGate()
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: watcher,
            watcherFactory: { _ in ControlledWatcher() },
            debounceDelay: .milliseconds(10),
            resetIndexOperation: {
                try await repository.resetIndex()
                await resetGate.suspend()
            },
            scanFileOperation: { url in
                await scanSequence.beforeScan()
                return try await scanner.scan(url: url)
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }
        await coordinator.start()
        #expect(await recorder.waitForCount(1))

        try appendSyntheticToken(to: logURL, second: 2, cumulativeTotal: 2)
        watcher.emit()
        await scanSequence.waitUntilCall(2)

        let rebuildTask = Task { try await coordinator.rebuildIndex() }
        for _ in 0..<20 { await Task.yield() }
        #expect(await !resetGate.isSuspended)

        await scanSequence.resume(call: 2)
        await resetGate.waitUntilSuspended()
        #expect(await recorder.count == 1)

        watcher.emit()
        await resetGate.resume()
        await scanSequence.waitUntilCall(3)
        try appendSyntheticToken(to: logURL, second: 3, cumulativeTotal: 3)
        watcher.emit()
        await scanSequence.resume(call: 3)

        await scanSequence.waitUntilCall(4)
        try appendSyntheticToken(to: logURL, second: 4, cumulativeTotal: 4)
        watcher.emit()
        await scanSequence.resume(call: 4)

        try await rebuildTask.value
        #expect(await scanSequence.callCount >= 5)
        #expect(await recorder.waitForLastValue(.completed, minimumCount: 2))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.occurrenceCount(of: .completed) == 2)
        #expect(try await repository.queryUsage(from: nil, to: .distantFuture)
            .map(\.usage.total)
            .reduce(0, +) == 4)

        await coordinator.stop()
    }

    @Test
    func staleScanErrorAfterRebuildGenerationChangeIsDiscarded() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logURL = root.appending(path: "stale-error.jsonl")
        try writeSyntheticLog(at: logURL)
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let watcher = ControlledWatcher()
        let scanController = SecondScanErrorController(suspendsBeforeError: true)
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: watcher,
            debounceDelay: .milliseconds(10),
            scanFileOperation: { url in
                try await scanController.beforeScan()
                return try await scanner.scan(url: url)
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }
        await coordinator.start()
        #expect(await recorder.waitForCount(1))

        try appendSyntheticToken(to: logURL, second: 2, cumulativeTotal: 2)
        watcher.emit()
        await scanController.waitUntilSecondScanSuspended()

        let rebuildTask = Task { try await coordinator.rebuildIndex() }
        for _ in 0..<100 { await Task.yield() }
        await scanController.resumeSecondScan()
        try await rebuildTask.value

        #expect(await recorder.waitForLastValue(.completed, minimumCount: 2))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.value(at: 0) == .completed)
        #expect(await recorder.occurrenceCount(of: .completed) == 2)
        #expect(await recorder.occurrenceCount(of: .failed("synthetic scan failure")) == 0)

        await coordinator.stop()
    }

    @Test
    func currentGenerationScanErrorPublishesPartial() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logURL = root.appending(path: "current-error.jsonl")
        try writeSyntheticLog(at: logURL)
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let watcher = ControlledWatcher()
        let scanController = SecondScanErrorController(suspendsBeforeError: false)
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: watcher,
            debounceDelay: .milliseconds(10),
            scanFileOperation: { url in
                try await scanController.beforeScan()
                return try await scanner.scan(url: url)
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }
        await coordinator.start()
        #expect(await recorder.waitForCount(1))

        try appendSyntheticToken(to: logURL, second: 2, cumulativeTotal: 2)
        watcher.emit()

        #expect(await recorder.waitForCount(2))
        #expect(await recorder.value(at: 1) == .partial(failedFiles: 1))

        await coordinator.stop()
    }

    @Test
    func rebuildFailurePublishesFailedAndSchedulesRecovery() async throws {
        let directoryURL = try temporaryCoordinatorDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let root = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        let scanner = SessionScanner(repository: repository)
        let watcher = ControlledWatcher()
        let coordinator = IngestionCoordinator(
            roots: [root],
            repository: repository,
            scanner: scanner,
            watcher: watcher,
            watcherFactory: { _ in ControlledWatcher() },
            recoveryDelay: .milliseconds(10),
            resetIndexOperation: {
                throw SyntheticCoordinatorError(message: "synthetic rebuild failure")
            }
        )
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        defer { Task { await recorder.stop() } }
        await coordinator.start()
        #expect(await recorder.waitForCount(1))

        do {
            try await coordinator.rebuildIndex()
            Issue.record("expected rebuild failure")
        } catch {}

        #expect(await recorder.waitForCount(2))
        #expect(await recorder.value(at: 1) == .failed("synthetic rebuild failure"))
        #expect(await recorder.waitForCount(3, attempts: 20))
        #expect(await recorder.value(at: 2) == .completed)

        await coordinator.stop()
    }

    @Test
    func watcherStopIsIdempotentAndFinishesEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SessionFileWatcherTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = SessionFileWatcher(roots: [root])
        let events = watcher.events()

        watcher.stop()
        watcher.stop()

        var iterator = events.makeAsyncIterator()
        let event: Void? = await iterator.next()
        #expect(event == nil)
    }
}

private func temporaryCoordinatorDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appending(path: "InjectedCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

private func writeSyntheticLog(at url: URL) throws {
    let contents =
        """
        {"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"gated","cwd":"/synthetic/gated"}}
        {"timestamp":"2026-07-14T01:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":1},"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":1}}}}
        """ + "\n"
    try Data(contents.utf8).write(to: url)
}

private func appendSyntheticToken(to url: URL, second: Int, cumulativeTotal: Int64) throws {
    let line =
        """
        {"timestamp":"2026-07-14T01:00:\(String(format: "%02d", second))Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":1},"total_token_usage":{"input_tokens":\(cumulativeTotal),"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\(cumulativeTotal)}}}}
        """ + "\n"
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(line.utf8))
}

private final class ControlledWatcher: SessionFileWatching, @unchecked Sendable {
    private let lock = NSLock()
    private let pair = AsyncStream<Void>.makeStream()
    private let configuredStartupFailure: String?
    private var eventCalls = 0

    init(startupFailure: String? = nil) {
        configuredStartupFailure = startupFailure
    }

    var startupFailure: String? {
        configuredStartupFailure
    }

    var eventsCallCount: Int {
        lock.withLock { eventCalls }
    }

    func events() -> AsyncStream<Void> {
        lock.withLock { eventCalls += 1 }
        if configuredStartupFailure != nil {
            pair.continuation.finish()
        }
        return pair.stream
    }

    func stop() {
        pair.continuation.finish()
    }

    func emit() {
        pair.continuation.yield(())
    }

    func finishUnexpectedly() {
        pair.continuation.finish()
    }
}

private actor OneShotScanGate {
    private let gate = SuspensionGate()
    private var shouldSuspend = true

    func suspendFirstScan() async {
        guard shouldSuspend else { return }
        shouldSuspend = false
        await gate.suspend()
    }

    func waitUntilSuspended() async {
        await gate.waitUntilSuspended()
    }

    func resume() async {
        await gate.resume()
    }
}

private actor SequencedScanGate {
    private let gatedCalls: Set<Int>
    private var gates: [Int: SuspensionGate] = [:]
    private(set) var callCount = 0

    init(gatedCalls: Set<Int>) {
        self.gatedCalls = gatedCalls
        for call in gatedCalls {
            gates[call] = SuspensionGate()
        }
    }

    func beforeScan() async {
        callCount += 1
        guard gatedCalls.contains(callCount), let gate = gates[callCount] else { return }
        await gate.suspend()
    }

    func waitUntilCall(_ call: Int) async {
        guard let gate = gates[call] else { return }
        await gate.waitUntilSuspended()
    }

    func resume(call: Int) async {
        await gates[call]?.resume()
    }
}

private actor SecondScanErrorController {
    private let suspendsBeforeError: Bool
    private let gate = SuspensionGate()
    private var callCount = 0

    init(suspendsBeforeError: Bool) {
        self.suspendsBeforeError = suspendsBeforeError
    }

    var scanCount: Int { callCount }

    func beforeScan() async throws {
        callCount += 1
        guard callCount == 2 else { return }
        if suspendsBeforeError {
            await gate.suspend()
        }
        throw SyntheticCoordinatorError(message: "synthetic scan failure")
    }

    func waitUntilSecondScanSuspended() async {
        await gate.waitUntilSuspended()
    }

    func resumeSecondScan() async {
        await gate.resume()
    }
}

private actor ScanCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor SecondScanCancellationController {
    private var callCount = 0

    var scanCount: Int { callCount }

    func beforeScan() throws {
        callCount += 1
        if callCount == 2 {
            throw CancellationError()
        }
    }
}

private actor RecordingScanOperation {
    private var names: [String] = []

    var scannedNames: [String] { names.sorted() }

    func scan(_ url: URL, using scanner: SessionScanner) async throws -> ScanResult {
        names.append(url.lastPathComponent)
        return try await scanner.scan(url: url)
    }
}

private final class MetadataFailureController: @unchecked Sendable {
    typealias Metadata = (fileKey: String, size: UInt64, modifiedAt: Date)

    private let lock = NSLock()
    private let failingName: String
    private var shouldFail = true
    private var attempts = 0

    init(failingName: String) {
        self.failingName = failingName
    }

    var failedFileAttempts: Int {
        lock.withLock { attempts }
    }

    func allowFailedFile() {
        lock.withLock { shouldFail = false }
    }

    func metadata(for url: URL) throws -> Metadata? {
        if url.lastPathComponent == failingName {
            let fails = lock.withLock {
                attempts += 1
                return shouldFail
            }
            if fails {
                throw SyntheticCoordinatorError(message: "synthetic metadata failure")
            }
        }

        let keys: Set<URLResourceKey> = [
            .fileResourceIdentifierKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true else { return nil }
        return (
            fileKey: values.fileResourceIdentifier
                .map { String(describing: $0) }
                ?? url.standardizedFileURL.path,
            size: UInt64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? .distantPast
        )
    }
}

private actor FailureIsolationController {
    private var shouldFailBrokenFile = true
    private var recordedNames: [String] = []

    var scannedNames: [String] { recordedNames.sorted() }

    func scan(_ url: URL, using scanner: SessionScanner) async throws -> ScanResult {
        recordedNames.append(url.lastPathComponent)
        if shouldFailBrokenFile, url.lastPathComponent == "broken.jsonl" {
            throw SyntheticCoordinatorError(message: "synthetic broken file")
        }
        return try await scanner.scan(url: url)
    }

    func allowBrokenFile() {
        shouldFailBrokenFile = false
    }
}

private actor SuspensionGate {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool { suspended }

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private struct SyntheticCoordinatorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private actor UpdateRecorder {
    private var values: [IngestionUpdate] = []
    private var observationTask: Task<Void, Never>?

    var count: Int { values.count }

    func observe(_ stream: AsyncStream<IngestionUpdate>) {
        observationTask = Task { [weak self] in
            for await value in stream {
                await self?.record(value)
            }
        }
    }

    func waitForCount(_ expected: Int, attempts: Int = 60) async -> Bool {
        for _ in 0..<attempts {
            if values.count >= expected { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return values.count >= expected
    }

    func waitForValue(_ expected: IngestionUpdate, attempts: Int = 60) async -> Bool {
        for _ in 0..<attempts {
            if values.contains(expected) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return values.contains(expected)
    }

    func waitForLastValue(
        _ expected: IngestionUpdate,
        minimumCount: Int,
        attempts: Int = 60
    ) async -> Bool {
        for _ in 0..<attempts {
            if values.count >= minimumCount, values.last == expected { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return values.count >= minimumCount && values.last == expected
    }

    func occurrenceCount(of expected: IngestionUpdate) -> Int {
        values.count { $0 == expected }
    }

    func value(at index: Int) -> IngestionUpdate? {
        values.indices.contains(index) ? values[index] : nil
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func record(_ value: IngestionUpdate) {
        values.append(value)
    }
}

private final class CoordinatorFixture: @unchecked Sendable {
    let directoryURL: URL
    let sessionsRoot: URL
    let archivedRoot: URL
    let repository: UsageRepository
    let scanner: SessionScanner
    let watcher: SessionFileWatcher
    let coordinator: IngestionCoordinator

    init(createArchivedRoot: Bool) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "IngestionCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        sessionsRoot = directoryURL.appending(path: "sessions", directoryHint: .isDirectory)
        archivedRoot = directoryURL.appending(path: "archived_sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        if createArchivedRoot {
            try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        }

        repository = try UsageRepository(url: directoryURL.appending(path: "index.sqlite"))
        scanner = SessionScanner(repository: repository)
        watcher = SessionFileWatcher(roots: [sessionsRoot, archivedRoot])
        coordinator = IngestionCoordinator(
            roots: [sessionsRoot, archivedRoot],
            repository: repository,
            scanner: scanner,
            watcher: watcher
        )
    }

    func start() async -> UpdateRecorder {
        let recorder = UpdateRecorder()
        await recorder.observe(await coordinator.updates())
        await coordinator.start()
        return recorder
    }

    @discardableResult
    func writeLog(
        root: URL,
        relativePath: String,
        sessionID: String,
        total: Int64
    ) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = [
            sessionLine(id: sessionID),
            tokenLine(second: 1, lastTotal: total, cumulativeTotal: total)
        ].joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: url)
        return url
    }

    func appendToken(
        to url: URL,
        second: Int,
        lastTotal: Int64,
        cumulativeTotal: Int64
    ) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (tokenLine(second: second, lastTotal: lastTotal, cumulativeTotal: cumulativeTotal) + "\n").utf8
        ))
    }

    func totalUsage() async throws -> Int64 {
        try await repository.queryUsage(from: nil, to: .distantFuture)
            .map(\.usage.total)
            .reduce(0, +)
    }

    func remove() {
        watcher.stop()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func sessionLine(id: String) -> String {
        """
        {"timestamp":"2026-07-14T01:00:00Z","type":"session_meta","payload":{"id":"\(id)","cwd":"/synthetic/projects/\(id)"}}
        """
    }

    private func tokenLine(second: Int, lastTotal: Int64, cumulativeTotal: Int64) -> String {
        """
        {"timestamp":"2026-07-14T01:00:\(String(format: "%02d", second))Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(lastTotal),"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\(lastTotal)},"total_token_usage":{"input_tokens":\(cumulativeTotal),"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\(cumulativeTotal)}}}}
        """
    }
}
