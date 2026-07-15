import CryptoKit
import Foundation

enum TokenEventIdentity {
    static func make(sessionID: String, event: ParsedTokenEvent) -> String {
        var payload = Data()
        let sessionData = Data(sessionID.utf8)
        append(Int64(sessionData.count), to: &payload)
        payload.append(sessionData)
        append(
            Int64((event.occurredAt.timeIntervalSince1970 * 1_000).rounded()),
            to: &payload
        )
        append(event.lastUsage, to: &payload)
        append(event.cumulativeUsage, to: &payload)

        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func append(_ usage: TokenUsage?, to data: inout Data) {
        guard let usage else {
            data.append(0)
            return
        }
        data.append(1)
        append(usage.input, to: &data)
        append(usage.cachedInput, to: &data)
        append(usage.output, to: &data)
        append(usage.reasoningOutput, to: &data)
        append(usage.total, to: &data)
    }

    private static func append(_ integer: Int64, to data: inout Data) {
        var bigEndian = integer.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
