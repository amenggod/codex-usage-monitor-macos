import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct CodexRateLimitServiceTests {
    @Test
    func initializesBeforeReadingAndStoresTheAccountLimit() async throws {
        let transport = FakeRateLimitTransport()
        let store = LiveRateLimitStore()
        let now = Date(timeIntervalSince1970: 2_000)
        await transport.setReadResponse(readResponse(usedPercent: 31))
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { now },
            retryDelays: []
        )

        await service.start()

        #expect(await transport.startCount == 1)
        #expect(await transport.stopCount == 1)
        #expect(await transport.methods == ["initialize", "account/rateLimits/read"])
        guard case let .fresh(limits, observedAt) = await store.state(now: now) else {
            Issue.record("expected fresh live limits")
            return
        }
        #expect(observedAt == now)
        #expect(limits.first?.remainingPercent == 69)
        await service.stop()
    }

    @Test
    func everyRefreshUsesAFreshShortLivedTransport() async {
        let transport = FakeRateLimitTransport()
        let store = LiveRateLimitStore()
        await transport.setReadResponse(readResponse(usedPercent: 31))
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { Date(timeIntervalSince1970: 2_000) },
            retryDelays: []
        )

        await service.start()
        await service.refresh()

        #expect(await transport.startCount == 2)
        #expect(await transport.stopCount == 2)
        #expect(await transport.methods == [
            "initialize", "account/rateLimits/read",
            "initialize", "account/rateLimits/read",
        ])
        await service.stop()
    }

    @Test
    func overlappingManualRefreshesShareOneTransportSession() async {
        let gate = AsyncGate()
        let transport = FakeRateLimitTransport(readGate: gate)
        let store = LiveRateLimitStore()
        await transport.setReadResponse(readResponse(usedPercent: 31))
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { Date(timeIntervalSince1970: 2_000) },
            retryDelays: []
        )

        let first = Task { await service.refresh() }
        await gate.waitUntilEntered()
        let second = Task { await service.refresh() }
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(await transport.startCount == 1)
        await gate.open()
        await first.value
        await second.value

        #expect(await transport.startCount == 1)
        #expect(await transport.readCount == 1)
        #expect(await transport.stopCount == 1)
    }

    @Test
    func stopCancelsAnOverlappingRefreshWithoutStartingAnotherSession() async throws {
        let gate = AsyncGate()
        let transport = FakeRateLimitTransport(readGate: gate)
        let store = LiveRateLimitStore()
        let completions = AsyncCounter()
        await transport.setReadResponse(readResponse(usedPercent: 31))
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { Date(timeIntervalSince1970: 2_000) },
            retryDelays: []
        )

        let first = Task {
            await service.refresh()
            await completions.increment()
        }
        await gate.waitUntilEntered()
        let second = Task {
            await service.refresh()
            await completions.increment()
        }
        for _ in 0..<10 {
            await Task.yield()
        }

        await service.stop()
        try await waitUntil(timeout: .milliseconds(100)) {
            await completions.value == 2
        }
        #expect(await completions.value == 2)

        await gate.open()
        await first.value
        await second.value
        #expect(await transport.startCount == 1)
        #expect((1...2).contains(await transport.stopCount))
    }

    @Test
    func startDuringStopDoesNotRestartTheService() async throws {
        let stopGate = AsyncGate()
        let transport = FakeRateLimitTransport()
        let store = LiveRateLimitStore()
        await transport.setReadResponse(readResponse(usedPercent: 31))
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { Date(timeIntervalSince1970: 2_000) },
            retryDelays: [],
            pollInterval: .milliseconds(20)
        )
        await service.start()
        await transport.setStopGate(stopGate)

        let stopping = Task { await service.stop() }
        await stopGate.waitUntilEntered()
        let restart = Task { await service.start() }
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(await transport.startCount == 1)
        await stopGate.open()
        await stopping.value
        await restart.value
        try await Task.sleep(for: .milliseconds(50))

        #expect(await transport.startCount == 1)
    }

    @Test
    func overlappingStopsShareOneTransportShutdown() async {
        let stopGate = AsyncGate()
        let transport = FakeRateLimitTransport()
        let store = LiveRateLimitStore()
        await transport.setReadResponse(readResponse(usedPercent: 31))
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { Date(timeIntervalSince1970: 2_000) },
            retryDelays: []
        )
        await service.start()
        await transport.setStopGate(stopGate)

        let first = Task { await service.stop() }
        await stopGate.waitUntilEntered()
        let second = Task { await service.stop() }
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(await transport.stopCount == 2)
        await stopGate.open()
        await first.value
        await second.value
        #expect(await transport.stopCount == 2)
    }

    @Test
    func manualRefreshRetriesImmediatelyAfterFailure() async throws {
        let transport = FakeRateLimitTransport()
        let store = LiveRateLimitStore()
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { Date(timeIntervalSince1970: 2_000) },
            retryDelays: [.seconds(60)]
        )
        await transport.setFailure(true)
        await service.start()
        await transport.setFailure(false)
        await transport.setReadResponse(readResponse(usedPercent: 31))

        await service.refresh()

        #expect(await transport.readCount == 1)
        let startCount = await transport.startCount
        let stopCount = await transport.stopCount
        #expect(stopCount == startCount)
        await service.stop()
    }

    @Test
    func initializationFailureStopsTransport() async {
        let transport = FakeRateLimitTransport()
        let store = LiveRateLimitStore()
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { Date(timeIntervalSince1970: 2_000) },
            retryDelays: []
        )
        await transport.failNextInitialize()

        await service.start()

        #expect(await transport.startCount == 1)
        let startCount = await transport.startCount
        let stopCount = await transport.stopCount
        #expect(stopCount == startCount)
        #expect(await transport.methods == ["initialize"])
        await service.stop()
    }

    @Test
    func readFailureStopsTransport() async {
        let transport = FakeRateLimitTransport()
        let store = LiveRateLimitStore()
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { Date(timeIntervalSince1970: 2_000) },
            retryDelays: []
        )
        await transport.setReadResponse(readResponse(usedPercent: 31))
        await transport.failNextRead()

        await service.start()

        #expect(await transport.startCount == 1)
        let startCount = await transport.startCount
        let stopCount = await transport.stopCount
        #expect(stopCount == startCount)
        #expect(await transport.methods == [
            "initialize", "account/rateLimits/read",
        ])
        await service.stop()
    }

    @Test
    func periodicallyReadsLimitsWithoutReceivingANotification() async throws {
        let transport = FakeRateLimitTransport()
        let store = LiveRateLimitStore()
        await transport.setReadResponse(readResponse(usedPercent: 31))
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { Date(timeIntervalSince1970: 2_000) },
            retryDelays: [],
            pollInterval: .milliseconds(20)
        )

        await service.start()
        try await waitUntil {
            let readCount = await transport.readCount
            let startCount = await transport.startCount
            let stopCount = await transport.stopCount
            return readCount >= 2 && stopCount == startCount
        }

        #expect(await transport.readCount >= 2)
        let startCount = await transport.startCount
        let stopCount = await transport.stopCount
        #expect(stopCount == startCount)
        await service.stop()
    }

    private func readResponse(usedPercent: Int) -> Data {
        let template = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"prolite","primary":null,"secondary":{"usedPercent":VALUE,"windowDurationMins":10080,"resetsAt":9000}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"prolite","primary":null,"secondary":{"usedPercent":VALUE,"windowDurationMins":10080,"resetsAt":9000}}}}}"#
        return Data(template.replacingOccurrences(
            of: "VALUE",
            with: String(usedPercent)
        ).utf8)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition timed out")
    }
}

private actor FakeRateLimitTransport: CodexAppServerTransporting {
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private(set) var methods: [String] = []
    private var response = Data(#"{"id":1,"result":{}}"#.utf8)
    private var shouldFail = false
    private var shouldFailNextInitialize = false
    private var shouldFailNextRead = false
    private let readGate: AsyncGate?
    private var stopGate: AsyncGate?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(readGate: AsyncGate? = nil) {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stream = pair.stream
        continuation = pair.continuation
        self.readGate = readGate
    }

    var readCount: Int {
        methods.filter { $0 == "account/rateLimits/read" }.count
    }

    func setReadResponse(_ response: Data) {
        self.response = response
    }

    func setFailure(_ value: Bool) {
        shouldFail = value
    }

    func failNextRead() {
        shouldFailNextRead = true
    }

    func failNextInitialize() {
        shouldFailNextInitialize = true
    }

    func setStopGate(_ gate: AsyncGate?) {
        stopGate = gate
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    func start() async throws {
        startCount += 1
        if shouldFail { throw FakeFailure() }
    }

    func request(method: String, params: Data?, timeout: Duration) async throws -> Data {
        methods.append(method)
        if shouldFail { throw FakeFailure() }
        if method == "initialize" {
            if shouldFailNextInitialize {
                shouldFailNextInitialize = false
                throw FakeFailure()
            }
            return Data(#"{"id":1,"result":{}}"#.utf8)
        }
        if shouldFailNextRead {
            shouldFailNextRead = false
            throw CodexAppServerTransport.TransportError.requestTimedOut
        }
        if let readGate {
            await readGate.enterAndWait()
            try Task.checkCancellation()
        }
        return response
    }

    func notifications() async -> AsyncStream<Data> { stream }

    func stop() async {
        stopCount += 1
        if let stopGate {
            await stopGate.enterAndWait()
        }
    }
}

private struct FakeFailure: Error {}

private actor AsyncGate {
    private var isOpen = false
    private var hasEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID: UInt64 = 0

    func enterAndWait() async {
        hasEntered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                } else {
                    openWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = Array(openWaiters.values)
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func cancel(waiterID: UInt64) {
        openWaiters.removeValue(forKey: waiterID)?.resume()
    }
}

private actor AsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
