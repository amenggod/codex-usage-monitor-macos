import Foundation

enum CodexRateLimitProtocol {
    enum ProtocolError: LocalizedError {
        case missingResult

        var errorDescription: String? {
            switch self {
            case .missingResult: "Codex 实时限额响应无效"
            }
        }
    }

    static func decodeReadResult(
        from data: Data,
        observedAt: Date
    ) throws -> [RateLimitObservation] {
        let envelope = try JSONDecoder().decode(ReadEnvelope.self, from: data)
        guard let result = envelope.result else { throw ProtocolError.missingResult }

        let account: RateLimitSnapshot?
        if let buckets = result.rateLimitsByLimitId {
            account = buckets["codex"]
        } else if result.rateLimits.limitId == "codex" {
            account = result.rateLimits
        } else {
            account = nil
        }

        guard let account else { return [] }
        return [account.primary, account.secondary]
            .compactMap { window in
                observation(
                    window,
                    planType: account.planType,
                    observedAt: observedAt
                )
            }
    }

    static func isRateLimitsUpdatedNotification(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(NotificationEnvelope.self, from: data).method)
            == "account/rateLimits/updated"
    }

    private static func observation(
        _ value: RateLimitWindow?,
        planType: String?,
        observedAt: Date
    ) -> RateLimitObservation? {
        guard let value,
              let duration = value.windowDurationMins,
              let reset = value.resetsAt else { return nil }

        let window: LimitWindow
        switch duration {
        case 300: window = .fiveHours
        case 10_080: window = .week
        default: return nil
        }

        return RateLimitObservation(
            limitID: "codex",
            planType: planType,
            window: window,
            usedPercent: value.usedPercent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(reset)),
            observedAt: observedAt
        )
    }
}

private struct ReadEnvelope: Decodable {
    let result: ReadResult?
}

private struct ReadResult: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

private struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

private struct NotificationEnvelope: Decodable {
    let method: String
}
