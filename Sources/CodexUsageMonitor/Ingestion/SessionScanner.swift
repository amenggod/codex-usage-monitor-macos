import CryptoKit
import Foundation

struct ScanResult: Equatable, Sendable {
    let processedLines: Int
    let finalOffset: UInt64
}

actor SessionScanner {
    private static let fingerprintWindowSize = 4_096
    private let repository: UsageRepository
    private let parser = CodexEventParser()
    private let normalizer = ProjectPathNormalizer()

    init(repository: UsageRepository) {
        self.repository = repository
    }

    func scan(url: URL) async throws -> ScanResult {
        let fileURL = URL(fileURLWithPath: url.path)
        let values = try fileURL.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let fileKey = values.fileResourceIdentifier
            .map { String(describing: $0) }
            ?? fileURL.standardizedFileURL.path
        let fileSize = UInt64(values.fileSize ?? 0)
        let modifiedAt = values.contentModificationDate ?? .distantPast
        let savedCursor = try await repository.cursor(for: fileKey)
        let savedOffset = savedCursor?.offset ?? 0

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let boundaryMatches: Bool
        if let savedCursor, savedOffset > 0, savedOffset <= fileSize,
           let savedFingerprint = savedCursor.boundaryFingerprint {
            boundaryMatches = try Self.boundaryFingerprint(
                in: handle,
                endingAt: savedOffset
            ) == savedFingerprint
        } else {
            boundaryMatches = savedOffset == 0
        }
        let requiresReset = savedOffset > fileSize || !boundaryMatches
        let startOffset = requiresReset ? 0 : savedOffset
        try handle.seek(toOffset: startOffset)
        guard let available = try handle.readToEnd(),
              let finalNewline = available.lastIndex(of: 0x0A) else {
            return ScanResult(processedLines: 0, finalOffset: startOffset)
        }

        let complete = available[available.startIndex...finalNewline]
        var activeSessionID = requiresReset ? nil : savedCursor?.activeSessionID
        var sessions: [SessionUpsert] = []
        var events: [LogicalTokenEvent] = []
        var limits: [RateLimitObservation] = []
        var processedLines = 0

        for rawLine in complete.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = Data(rawLine)
            guard !line.isEmpty, let event = parser.parse(line: line) else { continue }
            processedLines += 1

            switch event {
            case let .session(metadata):
                activeSessionID = metadata.sessionID
                sessions.append(SessionUpsert(
                    metadata: metadata,
                    project: normalizer.identity(for: metadata.workingDirectory)
                ))

            case let .token(token):
                guard let activeSessionID else { continue }
                events.append(LogicalTokenEvent(
                    id: TokenEventIdentity.make(sessionID: activeSessionID, event: token),
                    sessionID: activeSessionID,
                    occurredAt: token.occurredAt,
                    lastUsage: token.lastUsage,
                    cumulativeUsage: token.cumulativeUsage
                ))
                limits.append(contentsOf: token.limits)
            }
        }

        let finalOffset = startOffset + UInt64(complete.count)
        let boundaryFingerprint = try Self.boundaryFingerprint(
            in: handle,
            endingAt: finalOffset
        )
        _ = try await repository.apply(FileIngestionBatch(
            sessions: sessions,
            events: events,
            limits: limits,
            cursor: FileCursor(
                fileKey: fileKey,
                path: fileURL.path,
                offset: finalOffset,
                modifiedAt: modifiedAt,
                activeSessionID: activeSessionID,
                boundaryFingerprint: boundaryFingerprint
            )
        ))
        return ScanResult(processedLines: processedLines, finalOffset: finalOffset)
    }

    private static func boundaryFingerprint(
        in handle: FileHandle,
        endingAt offset: UInt64
    ) throws -> String {
        let length = min(UInt64(fingerprintWindowSize), offset)
        try handle.seek(toOffset: offset - length)
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }
}
