import Foundation

enum IngestionUpdate: Equatable, Sendable {
    case completed
    case failed(String)
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
    private let watcher: SessionFileWatcher
    private let updateStream: AsyncStream<IngestionUpdate>
    private let updateContinuation: AsyncStream<IngestionUpdate>.Continuation
    private var fileMetadata: [String: FileMetadata] = [:]
    private var watcherTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    init(
        roots: [URL],
        repository: UsageRepository,
        scanner: SessionScanner,
        watcher: SessionFileWatcher
    ) {
        self.roots = roots
        self.repository = repository
        self.scanner = scanner
        self.watcher = watcher
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
            startWatching()
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
        debounceTask?.cancel()
        debounceTask = nil
        do {
            try await repository.resetIndex()
            try await repository.migrate()
            fileMetadata.removeAll()
            let missingRoot = try await scanChangedFiles(forceAll: true)
            scheduleRecoveryIfNeeded(missingRoot: missingRoot)
            updateContinuation.yield(.completed)
        } catch {
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

    private func startWatching() {
        let events = watcher.events()
        watcherTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { return }
                await self?.scheduleDebouncedRescan()
            }
        }
    }

    private func scheduleDebouncedRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.scanAndPublish(forceAll: false)
        }
    }

    private func scanAndPublish(forceAll: Bool) async {
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

        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.scanAndPublish(forceAll: false)
        }
    }
}
