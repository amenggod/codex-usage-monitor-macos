import Foundation

enum LiveDependencies {
    @MainActor
    static func makeViewModel() -> UsageViewModel {
        do {
            let supportRoot = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("CodexUsageMonitor", isDirectory: true)
            try FileManager.default.createDirectory(
                at: supportRoot,
                withIntermediateDirectories: true
            )

            let repository = try UsageRepository.openRecovering(
                url: supportRoot.appendingPathComponent("usage.sqlite")
            )
            let home = CodexHomeLocator.home()
            let roots = CodexHomeLocator.sessionRoots(home: home)
            let scanner = SessionScanner(repository: repository)
            let watcher = SessionFileWatcher(roots: roots)
            let coordinator = IngestionCoordinator(
                roots: roots,
                repository: repository,
                scanner: scanner,
                watcher: watcher
            )
            let notifier = NotificationCoordinator(
                repository: repository,
                sender: UserNotificationSender()
            )
            return UsageViewModel(
                aggregator: UsageAggregator(repository: repository),
                coordinator: coordinator,
                notifier: notifier
            )
        } catch {
            return makeFailureViewModel(error: error)
        }
    }

    @MainActor
    static func makeFailureViewModel(error: Error) -> UsageViewModel {
        UsageViewModel(
            aggregator: StartupFailureAggregator(message: error.localizedDescription),
            coordinator: StartupFailureIngestionController()
        )
    }
}

private struct StartupFailureAggregator: UsageAggregating {
    let message: String

    func snapshot(
        range: TokenRange,
        now: Date,
        calendar: Calendar
    ) async throws -> DashboardSnapshot {
        throw StartupDependencyFailure(message: message)
    }
}

private struct StartupDependencyFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private actor StartupFailureIngestionController: IngestionControlling {
    private let stream: AsyncStream<IngestionUpdate>
    private let continuation: AsyncStream<IngestionUpdate>.Continuation

    init() {
        let pair = AsyncStream<IngestionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func start() async {
        continuation.yield(.completed)
    }

    func updates() async -> AsyncStream<IngestionUpdate> {
        stream
    }

    func rescanAll() async {
        continuation.yield(.completed)
    }

    func rebuildIndex() async throws {
        continuation.yield(.completed)
    }

    func stop() async {
        continuation.finish()
    }
}
