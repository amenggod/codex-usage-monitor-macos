import Foundation

enum IngestionUpdate: Equatable, Sendable {
    case completed
    case failed(String)
}

private struct WatcherFailure: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private struct ScanInvalidated: Error {}

actor IngestionCoordinator {
    private struct FileMetadata: Equatable, Sendable {
        let size: UInt64
        let modifiedAt: Date
    }

    private struct DiscoveredFiles: Sendable {
        let files: [(url: URL, metadata: FileMetadata)]
        let hasMissingRoot: Bool
    }

    private let roots: [URL]
    private let repository: UsageRepository
    private let scanner: SessionScanner
    private var watcher: any SessionFileWatching
    private let watcherFactory: @Sendable ([URL]) -> any SessionFileWatching
    private let recoveryDelay: Duration
    private let debounceDelay: Duration
    private let resetIndexOperation: @Sendable () async throws -> Void
    private let scanFileOperation: @Sendable (URL) async throws -> ScanResult
    private let updateStream: AsyncStream<IngestionUpdate>
    private let updateContinuation: AsyncStream<IngestionUpdate>.Continuation
    private var fileMetadata: [String: FileMetadata] = [:]
    private var watcherTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var watcherRecoveryTask: Task<Void, Never>?
    private var missingRootRecoveryTask: Task<Void, Never>?
    private var rebuildRecoveryTask: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var rebuilding = false
    private var pendingRescanDuringRebuild = false
    private var watcherIsActive = false
    private var watcherNeedsRecovery = false
    private var scanGeneration: UInt64 = 0
    private var activeRegularScans = 0
    private var scanIdleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        roots: [URL],
        repository: UsageRepository,
        scanner: SessionScanner,
        watcher: any SessionFileWatching,
        watcherFactory: @escaping @Sendable ([URL]) -> any SessionFileWatching = {
            SessionFileWatcher(roots: $0)
        },
        recoveryDelay: Duration = .seconds(30),
        debounceDelay: Duration = .milliseconds(300),
        resetIndexOperation: (@Sendable () async throws -> Void)? = nil,
        scanFileOperation: (@Sendable (URL) async throws -> ScanResult)? = nil
    ) {
        self.roots = roots
        self.repository = repository
        self.scanner = scanner
        self.watcher = watcher
        self.watcherFactory = watcherFactory
        self.recoveryDelay = recoveryDelay
        self.debounceDelay = debounceDelay
        self.resetIndexOperation = resetIndexOperation ?? {
            try await repository.resetIndex()
        }
        self.scanFileOperation = scanFileOperation ?? { url in
            try await scanner.scan(url: url)
        }
        let pair = AsyncStream<IngestionUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(20)
        )
        updateStream = pair.stream
        updateContinuation = pair.continuation
    }

    func start() async {
        guard !started, !stopped else { return }
        started = true

        do {
            try await repository.migrate()
        } catch {
            updateContinuation.yield(.failed(error.localizedDescription))
            return
        }

        do {
            let activeWatcher = try startWatching()
            guard let missingRoot = try await performRegularScan(forceAll: true) else { return }
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
            guard watcherIsActive, watcher === activeWatcher else { return }
            updateContinuation.yield(.completed)
        } catch {
            updateContinuation.yield(.failed(error.localizedDescription))
            if watcherNeedsRecovery {
                scheduleWatcherRecovery()
            }
        }
    }

    func updates() async -> AsyncStream<IngestionUpdate> {
        updateStream
    }

    func rescanAll() async {
        await scanAndPublish(forceAll: false)
    }

    func rebuildIndex() async throws {
        guard !rebuilding else {
            pendingRescanDuringRebuild = true
            return
        }
        rebuilding = true
        pendingRescanDuringRebuild = false
        scanGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        watcherRecoveryTask?.cancel()
        watcherRecoveryTask = nil
        missingRootRecoveryTask?.cancel()
        missingRootRecoveryTask = nil
        rebuildRecoveryTask?.cancel()
        rebuildRecoveryTask = nil
        await waitForRegularScansToFinish()
        let rebuildGeneration = scanGeneration
        do {
            try await resetIndexOperation()
            try await repository.migrate()
            fileMetadata.removeAll()
            var missingRoot = try await scanChangedFiles(
                forceAll: true,
                generation: rebuildGeneration,
                allowsRebuild: true
            )
            while pendingRescanDuringRebuild {
                pendingRescanDuringRebuild = false
                missingRoot = try await scanChangedFiles(
                    forceAll: false,
                    generation: rebuildGeneration,
                    allowsRebuild: true
                ) || missingRoot
            }
            rebuilding = false
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
            if watcherNeedsRecovery {
                scheduleWatcherRecovery()
            }
            updateContinuation.yield(.completed)
        } catch {
            rebuilding = false
            pendingRescanDuringRebuild = false
            scheduleRebuildRecovery()
            updateContinuation.yield(.failed(error.localizedDescription))
            throw error
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        watcherTask?.cancel()
        debounceTask?.cancel()
        watcherRecoveryTask?.cancel()
        missingRootRecoveryTask?.cancel()
        rebuildRecoveryTask?.cancel()
        watcherTask = nil
        debounceTask = nil
        watcherRecoveryTask = nil
        missingRootRecoveryTask = nil
        rebuildRecoveryTask = nil
        watcherIsActive = false
        watcherNeedsRecovery = false
        watcher.stop()
        updateContinuation.finish()
    }

    @discardableResult
    private func startWatching() throws -> any SessionFileWatching {
        let observedWatcher = watcher
        let events = observedWatcher.events()
        if let startupFailure = observedWatcher.startupFailure {
            watcherIsActive = false
            watcherNeedsRecovery = true
            throw WatcherFailure(message: startupFailure)
        }
        watcherIsActive = true
        watcherNeedsRecovery = false
        watcherTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.scheduleDebouncedRescan()
            }
            guard !Task.isCancelled else { return }
            await self?.watcherDidEnd(observedWatcher)
        }
        return observedWatcher
    }

    private func watcherDidEnd(_ endedWatcher: any SessionFileWatching) {
        guard !stopped, watcher === endedWatcher else { return }
        watcherIsActive = false
        watcherNeedsRecovery = true
        let message = endedWatcher.startupFailure ?? "Codex 会话文件监听器意外停止"
        updateContinuation.yield(.failed(message))
        scheduleWatcherRecovery()
    }

    private func scheduleWatcherRecovery() {
        watcherRecoveryTask?.cancel()
        watcherRecoveryTask = Task { [weak self, recoveryDelay] in
            do {
                try await Task.sleep(for: recoveryDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.recoverWatcher()
        }
    }

    private func recoverWatcher() async {
        guard !stopped else { return }
        guard !rebuilding else {
            watcherNeedsRecovery = true
            return
        }
        watcherTask?.cancel()
        watcher.stop()
        watcher = watcherFactory(roots)

        do {
            let recoveredWatcher = try startWatching()
            guard let missingRoot = try await performRegularScan(forceAll: true) else {
                watcherNeedsRecovery = true
                return
            }
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
            guard watcherIsActive, watcher === recoveredWatcher else { return }
            updateContinuation.yield(.completed)
        } catch {
            updateContinuation.yield(.failed(error.localizedDescription))
            scheduleWatcherRecovery()
        }
    }

    private func scheduleDebouncedRescan() {
        guard !rebuilding else {
            pendingRescanDuringRebuild = true
            return
        }
        debounceTask?.cancel()
        let delay = debounceDelay
        debounceTask = Task { [weak self, delay] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.scanAndPublish(forceAll: false)
        }
    }

    private func scanAndPublish(forceAll: Bool) async {
        guard !rebuilding else {
            pendingRescanDuringRebuild = true
            return
        }
        do {
            guard let missingRoot = try await performRegularScan(forceAll: forceAll) else { return }
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
            updateContinuation.yield(.completed)
        } catch {
            updateContinuation.yield(.failed(error.localizedDescription))
        }
    }

    private func performRegularScan(forceAll: Bool) async throws -> Bool? {
        guard !rebuilding else {
            pendingRescanDuringRebuild = true
            return nil
        }
        let generation = scanGeneration
        activeRegularScans += 1
        defer { finishRegularScan() }

        do {
            return try await scanChangedFiles(
                forceAll: forceAll,
                generation: generation,
                allowsRebuild: false
            )
        } catch {
            guard generation == scanGeneration, !rebuilding else {
                return nil
            }
            throw error
        }
    }

    private func scanChangedFiles(
        forceAll: Bool,
        generation: UInt64,
        allowsRebuild: Bool
    ) async throws -> Bool {
        try validateScan(generation: generation, allowsRebuild: allowsRebuild)
        let discovered = try discoverJSONLFiles()
        let discoveredPaths = Set(discovered.files.map { $0.url.path })

        for file in discovered.files {
            try validateScan(generation: generation, allowsRebuild: allowsRebuild)
            let path = file.url.path
            guard forceAll || fileMetadata[path] != file.metadata else { continue }
            _ = try await scanFileOperation(file.url)
            try validateScan(generation: generation, allowsRebuild: allowsRebuild)
            fileMetadata[path] = file.metadata
        }

        try validateScan(generation: generation, allowsRebuild: allowsRebuild)
        fileMetadata = fileMetadata.filter { discoveredPaths.contains($0.key) }
        return discovered.hasMissingRoot
    }

    private func validateScan(generation: UInt64, allowsRebuild: Bool) throws {
        let validState = allowsRebuild ? rebuilding : !rebuilding
        guard generation == scanGeneration, validState else {
            throw ScanInvalidated()
        }
    }

    private func finishRegularScan() {
        activeRegularScans -= 1
        guard activeRegularScans == 0 else { return }
        let waiters = scanIdleWaiters
        scanIdleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForRegularScansToFinish() async {
        guard activeRegularScans > 0 else { return }
        await withCheckedContinuation { continuation in
            scanIdleWaiters.append(continuation)
        }
    }

    private func discoverJSONLFiles() throws -> DiscoveredFiles {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        var files: [(url: URL, metadata: FileMetadata)] = []
        var missingRoot = false

        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                missingRoot = true
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else {
                missingRoot = true
                continue
            }

            for case let enumeratedURL as URL in enumerator {
                guard enumeratedURL.pathExtension.lowercased() == "jsonl" else { continue }
                let fileURL = URL(fileURLWithPath: enumeratedURL.path)
                let values = try fileURL.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                let metadata = FileMetadata(
                    size: UInt64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
                files.append((fileURL, metadata))
            }
        }

        return DiscoveredFiles(files: files, hasMissingRoot: missingRoot)
    }

    private func scheduleRecoveryIfNeeded(missingRoot: Bool) {
        missingRootRecoveryTask?.cancel()
        missingRootRecoveryTask = nil
        guard missingRoot, !stopped else { return }

        let delay = recoveryDelay
        missingRootRecoveryTask = Task { [weak self, delay] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.scanAndPublish(forceAll: false)
        }
    }

    private func scheduleRebuildRecovery() {
        rebuildRecoveryTask?.cancel()
        let delay = recoveryDelay
        rebuildRecoveryTask = Task { [weak self, delay] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.recoverFailedRebuild()
        }
    }

    private func recoverFailedRebuild() async {
        guard !stopped, !rebuilding else { return }
        do {
            try await repository.migrate()
            fileMetadata.removeAll()
            guard let missingRoot = try await performRegularScan(forceAll: true) else { return }
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
            if watcherNeedsRecovery {
                scheduleWatcherRecovery()
            }
            updateContinuation.yield(.completed)
        } catch {
            updateContinuation.yield(.failed(error.localizedDescription))
            scheduleRebuildRecovery()
        }
    }

}
