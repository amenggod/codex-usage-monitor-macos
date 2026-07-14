import Foundation

enum IngestionUpdate: Equatable, Sendable {
    case completed
    case failed(String)
}

private struct WatcherFailure: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

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
    private let updateStream: AsyncStream<IngestionUpdate>
    private let updateContinuation: AsyncStream<IngestionUpdate>.Continuation
    private var fileMetadata: [String: FileMetadata] = [:]
    private var watcherTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var rebuilding = false
    private var pendingRescanDuringRebuild = false

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
        resetIndexOperation: (@Sendable () async throws -> Void)? = nil
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
            try startWatching()
        } catch {
            updateContinuation.yield(.failed(error.localizedDescription))
            scheduleWatcherRecovery()
            return
        }

        do {
            let missingRoot = try await scanChangedFiles(forceAll: true)
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
            updateContinuation.yield(.completed)
        } catch {
            updateContinuation.yield(.failed(error.localizedDescription))
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
        debounceTask?.cancel()
        debounceTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        do {
            try await resetIndexOperation()
            try await repository.migrate()
            fileMetadata.removeAll()
            var missingRoot = try await scanChangedFiles(forceAll: true)
            if pendingRescanDuringRebuild {
                pendingRescanDuringRebuild = false
                missingRoot = try await scanChangedFiles(forceAll: false) || missingRoot
            }
            rebuilding = false
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
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
        recoveryTask?.cancel()
        watcherTask = nil
        debounceTask = nil
        recoveryTask = nil
        watcher.stop()
        updateContinuation.finish()
    }

    private func startWatching() throws {
        let observedWatcher = watcher
        let events = observedWatcher.events()
        if let startupFailure = observedWatcher.startupFailure {
            throw WatcherFailure(message: startupFailure)
        }
        watcherTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.scheduleDebouncedRescan()
            }
            guard !Task.isCancelled else { return }
            await self?.watcherDidEnd(observedWatcher)
        }
    }

    private func watcherDidEnd(_ endedWatcher: any SessionFileWatching) {
        guard !stopped, watcher === endedWatcher else { return }
        let message = endedWatcher.startupFailure ?? "Codex 会话文件监听器意外停止"
        updateContinuation.yield(.failed(message))
        scheduleWatcherRecovery()
    }

    private func scheduleWatcherRecovery() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self, recoveryDelay] in
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
        watcherTask?.cancel()
        watcher.stop()
        watcher = watcherFactory(roots)

        do {
            try startWatching()
            let missingRoot = try await scanChangedFiles(forceAll: true)
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
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
            let missingRoot = try await scanChangedFiles(forceAll: forceAll)
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
            updateContinuation.yield(.completed)
        } catch {
            updateContinuation.yield(.failed(error.localizedDescription))
        }
    }

    private func scanChangedFiles(forceAll: Bool) async throws -> Bool {
        let discovered = try discoverJSONLFiles()
        let discoveredPaths = Set(discovered.files.map { $0.url.path })

        for file in discovered.files {
            let path = file.url.path
            guard forceAll || fileMetadata[path] != file.metadata else { continue }
            _ = try await scanner.scan(url: file.url)
            fileMetadata[path] = file.metadata
        }

        fileMetadata = fileMetadata.filter { discoveredPaths.contains($0.key) }
        return discovered.hasMissingRoot
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
        recoveryTask?.cancel()
        recoveryTask = nil
        guard missingRoot, !stopped else { return }

        let delay = recoveryDelay
        recoveryTask = Task { [weak self, delay] in
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
        recoveryTask?.cancel()
        let delay = recoveryDelay
        recoveryTask = Task { [weak self, delay] in
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
            let missingRoot = try await scanChangedFiles(forceAll: true)
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
            updateContinuation.yield(.completed)
        } catch {
            updateContinuation.yield(.failed(error.localizedDescription))
            scheduleRebuildRecovery()
        }
    }

}
