import Foundation

enum ParsedCodexEvent: Equatable, Sendable {
    case session(SessionMetadata)
    case token(ParsedTokenEvent)
}

struct CodexEventParser {
    private let formatter = ISO8601DateFormatter()

    func parse(line: Data) -> ParsedCodexEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String,
            let payload = object["payload"] as? [String: Any]
        else { return nil }

        guard let timestamp = date(object["timestamp"]) ?? date(payload["timestamp"]) else {
            return nil
        }

        if type == "session_meta", let id = payload["id"] as? String {
            return .session(SessionMetadata(
                sessionID: id,
                startedAt: timestamp,
                workingDirectory: payload["cwd"] as? String
            ))
        }

        guard type == "event_msg", payload["type"] as? String == "token_count" else {
            return nil
        }
        let info = payload["info"] as? [String: Any]
        return .token(ParsedTokenEvent(
            occurredAt: timestamp,
            lastUsage: usage(info?["last_token_usage"]),
            cumulativeUsage: usage(info?["total_token_usage"]),
            limits: limits(payload["rate_limits"], observedAt: timestamp)
        ))
    }

    private func usage(_ raw: Any?) -> TokenUsage? {
        guard let value = raw as? [String: Any] else { return nil }
        return TokenUsage(
            input: int64(value["input_tokens"]),
            cachedInput: int64(value["cached_input_tokens"]),
            output: int64(value["output_tokens"]),
            reasoningOutput: int64(value["reasoning_output_tokens"]),
            total: int64(value["total_tokens"])
        )
    }

    private func limits(_ raw: Any?, observedAt: Date) -> [RateLimitObservation] {
        guard let root = raw as? [String: Any] else { return [] }
        let id = root["limit_id"] as? String ?? "unknown"
        let label = root["limit_name"] as? String

        return ["primary", "secondary"].compactMap { key in
            guard
                let value = root[key] as? [String: Any],
                let minutes = int(value["window_minutes"]),
                let used = double(value["used_percent"]),
                let reset = double(value["resets_at"])
            else { return nil }

            let window: LimitWindow = switch minutes {
            case 300: .fiveHours
            case 10_080: .week
            default: .other(minutes: minutes, label: label)
            }
            return RateLimitObservation(
                limitID: id,
                window: window,
                usedPercent: used,
                resetsAt: Date(timeIntervalSince1970: reset),
                observedAt: observedAt
            )
        }
    }

    private func date(_ raw: Any?) -> Date? {
        guard let string = raw as? String else { return nil }
        return formatter.date(from: string)
    }

    private func int64(_ raw: Any?) -> Int64 {
        (raw as? NSNumber)?.int64Value ?? 0
    }

    private func int(_ raw: Any?) -> Int? {
        (raw as? NSNumber)?.intValue
    }

    private func double(_ raw: Any?) -> Double? {
        (raw as? NSNumber)?.doubleValue
    }
}
