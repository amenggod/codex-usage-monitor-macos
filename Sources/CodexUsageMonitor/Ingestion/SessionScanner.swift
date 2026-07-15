import Foundation

struct ScanResult: Equatable, Sendable {
    let processedLines: Int
    let finalOffset: UInt64
}

actor SessionScanner {
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
        let wasTruncated = savedOffset > fileSize
        let startOffset = wasTruncated ? 0 : savedOffset

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)
        guard let available = try handle.readToEnd(),
              let finalNewline = available.lastIndex(of: 0x0A) else {
            return ScanResult(processedLines: 0, finalOffset: startOffset)
        }

        let complete = available[available.startIndex...finalNewline]
        var activeSessionID = wasTruncated ? nil : savedCursor?.activeSessionID
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
        _ = try await repository.apply(FileIngestionBatch(
            sessions: sessions,
            events: events,
            limits: limits,
            cursor: FileCursor(
                fileKey: fileKey,
                path: fileURL.path,
                offset: finalOffset,
                modifiedAt: modifiedAt,
                activeSessionID: activeSessionID
            )
        ))
        return ScanResult(processedLines: processedLines, finalOffset: finalOffset)
    }
}
