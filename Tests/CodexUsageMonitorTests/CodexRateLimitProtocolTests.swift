import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct CodexRateLimitProtocolTests {
    private let observedAt = Date(timeIntervalSince1970: 2_000)

    @Test
    func decodesOnlyTheAuthoritativeCodexAccountBucket() throws {
        let observations = try CodexRateLimitProtocol.decodeReadResult(
            from: response(
                rateLimits: bucket(id: "codex_bengalfox", used: 0),
                buckets: [
                    "codex": bucket(id: "codex", used: 31),
                    "codex_bengalfox": bucket(id: "codex_bengalfox", used: 0),
                ]
            ),
            observedAt: observedAt
        )

        #expect(observations == [
            RateLimitObservation(
                limitID: "codex",
                planType: "prolite",
                window: .week,
                usedPercent: 31,
                resetsAt: Date(timeIntervalSince1970: 9_000),
                observedAt: observedAt
            )
        ])
        #expect(observations.first?.usedPercent == 31)
    }

    @Test
    func fallsBackToSingleBucketOnlyWhenItIsCodex() throws {
        let valid = try CodexRateLimitProtocol.decodeReadResult(
            from: response(rateLimits: bucket(id: "codex", used: 42), buckets: nil),
            observedAt: observedAt
        )
        let wrongBucket = try CodexRateLimitProtocol.decodeReadResult(
            from: response(rateLimits: bucket(id: "codex_bengalfox", used: 0), buckets: nil),
            observedAt: observedAt
        )

        #expect(valid.map(\.usedPercent) == [42])
        #expect(wrongBucket.isEmpty)
    }

    @Test
    func mapsOnlyKnownCompleteWindowsAndHidesMissingFiveHourWindow() throws {
        let account: [String: Any] = [
            "limitId": "codex",
            "planType": "prolite",
            "primary": ["usedPercent": 12, "windowDurationMins": 300, "resetsAt": 8_000],
            "secondary": ["usedPercent": 31, "windowDurationMins": 10_080, "resetsAt": 9_000],
        ]
        let observations = try CodexRateLimitProtocol.decodeReadResult(
            from: response(rateLimits: account, buckets: ["codex": account]),
            observedAt: observedAt
        )

        #expect(observations.map(\.window) == [.fiveHours, .week])

        let incomplete: [String: Any] = [
            "limitId": "codex",
            "planType": "prolite",
            "primary": ["usedPercent": 12, "windowDurationMins": 300],
            "secondary": ["usedPercent": 31, "windowDurationMins": 999, "resetsAt": 9_000],
        ]
        let hidden = try CodexRateLimitProtocol.decodeReadResult(
            from: response(rateLimits: incomplete, buckets: ["codex": incomplete]),
            observedAt: observedAt
        )
        #expect(hidden.isEmpty)
    }

    @Test
    func ignoresUnknownFieldsAndRejectsMissingResult() throws {
        var account = bucket(id: "codex", used: 31)
        account["futureField"] = ["private": "ignored"]
        let decoded = try CodexRateLimitProtocol.decodeReadResult(
            from: response(rateLimits: account, buckets: ["codex": account]),
            observedAt: observedAt
        )

        #expect(decoded.count == 1)
        #expect(throws: Error.self) {
            try CodexRateLimitProtocol.decodeReadResult(
                from: Data(#"{"id":2,"error":{"message":"not available"}}"#.utf8),
                observedAt: observedAt
            )
        }
    }

    @Test
    func recognizesOnlyRateLimitUpdateNotifications() {
        #expect(CodexRateLimitProtocol.isRateLimitsUpdatedNotification(
            Data(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{}}}"#.utf8)
        ))
        #expect(!CodexRateLimitProtocol.isRateLimitsUpdatedNotification(
            Data(#"{"method":"account/updated","params":{}}"#.utf8)
        ))
        #expect(!CodexRateLimitProtocol.isRateLimitsUpdatedNotification(Data("not-json".utf8)))
    }

    private func bucket(id: String, used: Int) -> [String: Any] {
        [
            "limitId": id,
            "planType": "prolite",
            "primary": NSNull(),
            "secondary": [
                "usedPercent": used,
                "windowDurationMins": 10_080,
                "resetsAt": 9_000,
            ],
        ]
    }

    private func response(
        rateLimits: [String: Any],
        buckets: [String: [String: Any]]?
    ) throws -> Data {
        var result: [String: Any] = ["rateLimits": rateLimits]
        if let buckets {
            result["rateLimitsByLimitId"] = buckets
        }
        return try JSONSerialization.data(withJSONObject: ["id": 2, "result": result])
    }
}
