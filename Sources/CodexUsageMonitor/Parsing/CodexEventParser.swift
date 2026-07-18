import Foundation

enum ParsedCodexEvent: Equatable, Sendable {
    case session(SessionMetadata)
    case token(ParsedTokenEvent)
}

struct CodexEventParser {
    private let decoder = JSONDecoder()
    private let wholeSecondFormatter = ISO8601DateFormatter()
    private let fractionalSecondFormatter: ISO8601DateFormatter

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalSecondFormatter = formatter
    }

    func parse(line: Data) -> ParsedCodexEvent? {
        guard let envelope = try? decoder.decode(CodexEnvelope.self, from: line) else {
            return nil
        }
        guard let timestamp = date(envelope.timestamp) ?? date(envelope.payload.timestamp) else {
            return nil
        }

        if envelope.type == "session_meta", let id = envelope.payload.id {
            return .session(SessionMetadata(
                sessionID: id,
                startedAt: timestamp,
                workingDirectory: envelope.payload.cwd
            ))
        }

        guard envelope.type == "event_msg", envelope.payload.type == "token_count" else {
            return nil
        }
        return .token(ParsedTokenEvent(
            occurredAt: timestamp,
            lastUsage: usage(envelope.payload.info?.lastUsage),
            cumulativeUsage: usage(envelope.payload.info?.cumulativeUsage),
            limits: limits(envelope.payload.rateLimits, observedAt: timestamp)
        ))
    }

    private func usage(_ value: CodexTokenUsage?) -> TokenUsage? {
        guard let value else { return nil }
        return TokenUsage(
            input: value.input,
            cachedInput: value.cachedInput,
            output: value.output,
            reasoningOutput: value.reasoningOutput,
            total: value.total
        )
    }

    private func limits(_ value: CodexRateLimits?, observedAt: Date) -> [RateLimitObservation] {
        guard let value else { return [] }
        return [value.primary, value.secondary].compactMap { limit in
            guard let limit else { return nil }
            let window: LimitWindow = switch limit.windowMinutes {
            case 300: .fiveHours
            case 10_080: .week
            default: .other(minutes: limit.windowMinutes, label: value.label)
            }
            return RateLimitObservation(
                limitID: value.id ?? "unknown",
                planType: value.planType,
                window: window,
                usedPercent: limit.usedPercent,
                resetsAt: Date(timeIntervalSince1970: limit.resetsAt),
                observedAt: observedAt
            )
        }
    }

    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalSecondFormatter.date(from: value) ?? wholeSecondFormatter.date(from: value)
    }
}

private struct CodexEnvelope: Decodable {
    let timestamp: String?
    let type: String
    let payload: CodexPayload

    enum CodingKeys: String, CodingKey {
        case timestamp
        case type
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        type = try container.decode(String.self, forKey: .type)
        payload = try container.decode(CodexPayload.self, forKey: .payload)
    }
}

private struct CodexPayload: Decodable {
    let timestamp: String?
    let type: String?
    let id: String?
    let cwd: String?
    let info: CodexTokenInfo?
    let rateLimits: CodexRateLimits?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case type
        case id
        case cwd
        case info
        case rateLimits = "rate_limits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        info = try? container.decodeIfPresent(CodexTokenInfo.self, forKey: .info)
        rateLimits = try? container.decodeIfPresent(CodexRateLimits.self, forKey: .rateLimits)
    }
}

private struct CodexTokenInfo: Decodable {
    let lastUsage: CodexTokenUsage?
    let cumulativeUsage: CodexTokenUsage?

    enum CodingKeys: String, CodingKey {
        case lastUsage = "last_token_usage"
        case cumulativeUsage = "total_token_usage"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastUsage = try? container.decode(CodexTokenUsage.self, forKey: .lastUsage)
        cumulativeUsage = try? container.decode(CodexTokenUsage.self, forKey: .cumulativeUsage)
    }
}

private struct CodexTokenUsage: Decodable {
    let input: Int64
    let cachedInput: Int64
    let output: Int64
    let reasoningOutput: Int64
    let total: Int64

    enum CodingKeys: String, CodingKey {
        case input = "input_tokens"
        case cachedInput = "cached_input_tokens"
        case output = "output_tokens"
        case reasoningOutput = "reasoning_output_tokens"
        case total = "total_tokens"
    }
}

private struct CodexRateLimits: Decodable {
    let id: String?
    let label: String?
    let planType: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case id = "limit_id"
        case label = "limit_name"
        case planType = "plan_type"
        case primary
        case secondary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        label = try? container.decode(String.self, forKey: .label)
        planType = try? container.decode(String.self, forKey: .planType)
        primary = try? container.decode(CodexRateLimitWindow.self, forKey: .primary)
        secondary = try? container.decode(CodexRateLimitWindow.self, forKey: .secondary)
    }
}

private struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Double

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}
