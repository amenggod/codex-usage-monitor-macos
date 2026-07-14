import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite(.serialized)
struct IngestionCoordinatorTests {
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
