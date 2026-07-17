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
    private let transport: any CodexAppServerTransporting
    private let store: LiveRateLimitStore
    private let now: @Sendable () -> Date
    private let retryDelays: [Duration]
    private let updateStream: AsyncStream<LiveRateLimitState>
    private let updateContinuation: AsyncStream<LiveRateLimitState>.Continuation
    private var notificationTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryIndex = 0
    private var initialized = false
    private var started = false

    init(
        transport: any CodexAppServerTransporting,
        store: LiveRateLimitStore,
        now: @escaping @Sendable () -> Date = Date.init,
        retryDelays: [Duration] = [
            .seconds(5), .seconds(30), .seconds(120)
        ]
    ) {
        self.transport = transport
        self.store = store
        self.now = now
        self.retryDelays = retryDelays
        let pair = AsyncStream<LiveRateLimitState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        updateStream = pair.stream
        updateContinuation = pair.continuation
    }

    func start() async {
        guard !started else { return }
        started = true
        let notifications = await transport.notifications()
        notificationTask = Task { [weak self] in
            for await data in notifications {
                guard !Task.isCancelled else { return }
                if CodexRateLimitProtocol.isRateLimitsUpdatedNotification(data) {
                    await self?.refreshFromNotification()
                }
            }
        }
        await performRefresh(scheduleRetryOnFailure: true)
    }

    func refresh() async {
        retryTask?.cancel()
        retryTask = nil
        retryIndex = 0
        await performRefresh(scheduleRetryOnFailure: true)
    }

    func updates() async -> AsyncStream<LiveRateLimitState> {
        updateStream
    }

    func stop() async {
        started = false
        notificationTask?.cancel()
        notificationTask = nil
        retryTask?.cancel()
        retryTask = nil
        initialized = false
        await transport.stop()
        updateContinuation.finish()
    }

    private func refreshFromNotification() async {
        await performRefresh(scheduleRetryOnFailure: true)
    }

    private func performRefresh(scheduleRetryOnFailure: Bool) async {
        do {
            try await transport.start()
            if !initialized {
                _ = try await transport.request(
                    method: "initialize",
                    params: Self.initializeParameters,
                    timeout: .seconds(10)
                )
                initialized = true
            }
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
            await store.replace(limits: limits, observedAt: observedAt)
            retryTask?.cancel()
            retryTask = nil
            retryIndex = 0
            updateContinuation.yield(await store.state(now: observedAt))
        } catch {
            if error is CodexAppServerTransport.TransportError {
                initialized = false
            }
            await store.markUnavailable(message: Self.safeMessage(for: error))
            updateContinuation.yield(await store.state(now: now()))
            if scheduleRetryOnFailure {
                scheduleRetry()
            }
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
        await performRefresh(scheduleRetryOnFailure: true)
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
