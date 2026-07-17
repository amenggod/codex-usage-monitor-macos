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
    func updateNotificationTriggersACompleteReadWithoutReinitializing() async throws {
        let transport = FakeRateLimitTransport()
        let store = LiveRateLimitStore()
        let service = CodexRateLimitService(
            transport: transport,
            store: store,
            now: { Date(timeIntervalSince1970: 2_000) },
            retryDelays: []
        )
        await transport.setReadResponse(readResponse(usedPercent: 31))
        await service.start()

        await transport.emit(Data(
            #"{"method":"account/rateLimits/updated","params":{"rateLimits":{}}}"#.utf8
        ))
        try await waitUntil { await transport.readCount == 2 }

        #expect(await transport.methods == [
            "initialize", "account/rateLimits/read", "account/rateLimits/read"
        ])
        await service.stop()
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

    init() {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stream = pair.stream
        continuation = pair.continuation
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

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    func start() async throws {
        if shouldFail { throw FakeFailure() }
    }

    func request(method: String, params: Data?, timeout: Duration) async throws -> Data {
        methods.append(method)
        if shouldFail { throw FakeFailure() }
        if method == "initialize" {
            return Data(#"{"id":1,"result":{}}"#.utf8)
        }
        return response
    }

    func notifications() async -> AsyncStream<Data> { stream }

    func stop() async {
        continuation.finish()
    }
}

private struct FakeFailure: Error {}
