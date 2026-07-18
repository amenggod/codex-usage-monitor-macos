import Foundation

protocol RateLimitServicing: Sendable {
    func start() async
    func refresh() async
    func updates() async -> AsyncStream<LiveRateLimitState>
    func stop() async
}

actor NoopRateLimitService: RateLimitServicing {
    private let stream: AsyncStream<LiveRateLimitState>

    init() {
        stream = AsyncStream { continuation in
            continuation.finish()
        }
    }

    func start() async {}
    func refresh() async {}
    func updates() async -> AsyncStream<LiveRateLimitState> { stream }
    func stop() async {}
}

actor CodexRateLimitService: RateLimitServicing {
    private struct ActiveRefresh {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private struct LimitRead {
        let limits: [LimitStatus]
        let observedAt: Date
    }

    private let transport: any CodexAppServerTransporting
    private let store: LiveRateLimitStore
    private let now: @Sendable () -> Date
    private let retryDelays: [Duration]
    private let pollInterval: Duration
    private let updateStream: AsyncStream<LiveRateLimitState>
    private let updateContinuation: AsyncStream<LiveRateLimitState>.Continuation
    private var pollingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryIndex = 0
    private var started = false
    private var stopping = false
    private var nextRefreshID: UInt64 = 0
    private var activeRefresh: ActiveRefresh?

    init(
        transport: any CodexAppServerTransporting,
        store: LiveRateLimitStore,
        now: @escaping @Sendable () -> Date = Date.init,
        retryDelays: [Duration] = [
            .seconds(5), .seconds(30), .seconds(120)
        ],
        pollInterval: Duration = .seconds(60)
    ) {
        self.transport = transport
        self.store = store
        self.now = now
        self.retryDelays = retryDelays
        self.pollInterval = pollInterval
        let pair = AsyncStream<LiveRateLimitState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        updateStream = pair.stream
        updateContinuation = pair.continuation
    }

    func start() async {
        guard !started, !stopping else { return }
        started = true
        await runSingleFlightRefresh(scheduleRetryOnFailure: true)
        guard started else { return }
        pollingTask = Task { [weak self] in
            await self?.pollUntilStopped()
        }
    }

    func refresh() async {
        retryTask?.cancel()
        retryTask = nil
        retryIndex = 0
        await runSingleFlightRefresh(scheduleRetryOnFailure: true)
    }

    func updates() async -> AsyncStream<LiveRateLimitState> {
        updateStream
    }

    func stop() async {
        guard !stopping else { return }
        stopping = true
        started = false
        pollingTask?.cancel()
        pollingTask = nil
        retryTask?.cancel()
        retryTask = nil
        activeRefresh?.task.cancel()
        await transport.stop()
        activeRefresh = nil
        updateContinuation.finish()
        stopping = false
    }

    private func pollUntilStopped() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
            guard started, !Task.isCancelled else { return }
            await runSingleFlightRefresh(scheduleRetryOnFailure: true)
        }
    }

    private func runSingleFlightRefresh(
        scheduleRetryOnFailure: Bool
    ) async {
        if let activeRefresh {
            await activeRefresh.task.value
            return
        }

        nextRefreshID &+= 1
        let id = nextRefreshID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(
                scheduleRetryOnFailure: scheduleRetryOnFailure
            )
        }
        activeRefresh = ActiveRefresh(id: id, task: task)
        await task.value
        if activeRefresh?.id == id {
            activeRefresh = nil
        }
    }

    private func performRefresh(scheduleRetryOnFailure: Bool) async {
        do {
            let read = try await readLimits()
            await store.replace(
                limits: read.limits,
                observedAt: read.observedAt
            )
            retryTask?.cancel()
            retryTask = nil
            retryIndex = 0
            updateContinuation.yield(await store.state(now: read.observedAt))
        } catch {
            await store.markUnavailable(message: Self.safeMessage(for: error))
            updateContinuation.yield(await store.state(now: now()))
            if scheduleRetryOnFailure {
                scheduleRetry()
            }
        }
    }

    private func readLimits() async throws -> LimitRead {
        do {
            try await transport.start()
            _ = try await transport.request(
                method: "initialize",
                params: Self.initializeParameters,
                timeout: .seconds(10)
            )
            let response = try await transport.request(
                method: "account/rateLimits/read",
                params: nil,
                timeout: .seconds(10)
            )
            let observedAt = now()
            let observations = try CodexRateLimitProtocol.decodeReadResult(
                from: response,
                observedAt: observedAt
            )
            let limits = observations.map {
                LimitStatus(
                    limitID: $0.limitID,
                    window: $0.window,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
            await transport.stop()
            return LimitRead(limits: limits, observedAt: observedAt)
        } catch {
            await transport.stop()
            throw error
        }
    }

    private func scheduleRetry() {
        guard started, retryTask == nil, retryIndex < retryDelays.count else { return }
        let delay = retryDelays[retryIndex]
        retryIndex += 1
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.runScheduledRetry()
        }
    }

    private func runScheduledRetry() async {
        retryTask = nil
        await runSingleFlightRefresh(scheduleRetryOnFailure: true)
    }

    private static var initializeParameters: Data {
        Data(#"{"clientInfo":{"name":"codex-usage-monitor","version":"0.2.3"},"capabilities":{"experimentalApi":true}}"#.utf8)
    }

    private static func safeMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "Codex 实时限额暂不可用"
    }
}
