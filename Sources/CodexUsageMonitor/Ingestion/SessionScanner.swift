import CryptoKit
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
        let startOffset = savedOffset > fileSize ? 0 : savedOffset

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)
        guard let available = try handle.readToEnd(),
              let finalNewline = available.lastIndex(of: 0x0A) else {
            return ScanResult(processedLines: 0, finalOffset: startOffset)
        }

        let complete = available[available.startIndex...finalNewline]
        var lineStartOffset = startOffset
        var sessionID = try await repository.sessionID(forFileKey: fileKey)
        var processedLines = 0

        for rawLine in complete.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = Data(rawLine)
            defer { lineStartOffset += UInt64(rawLine.count + 1) }
            guard !line.isEmpty, let event = parser.parse(line: line) else { continue }
            processedLines += 1

            switch event {
            case let .session(metadata):
                sessionID = metadata.sessionID
                let project = normalizer.identity(for: metadata.workingDirectory)
                try await repository.upsertSession(
                    metadata,
                    fileKey: fileKey,
                    project: project
                )

            case let .token(token):
                guard let sessionID else { continue }
                let previous = try await repository.previousCumulativeUsage(sessionID: sessionID)
                let usage = TokenDeltaCalculator.delta(
                    lastUsage: token.lastUsage,
                    cumulativeUsage: token.cumulativeUsage,
                    previousCumulative: previous
                )
                let digest = SHA256.hash(data: line)
                    .map { String(format: "%02x", $0) }
                    .joined()
                try await repository.insertUsageEvent(
                    id: "\(fileKey):\(lineStartOffset):\(digest)",
                    sessionID: sessionID,
                    occurredAt: token.occurredAt,
                    usage: usage
                )
                if let cumulative = token.cumulativeUsage {
                    try await repository.saveCumulativeUsage(cumulative, sessionID: sessionID)
                }
                try await repository.replaceLatestLimits(token.limits)
            }
        }

        let finalOffset = startOffset + UInt64(complete.count)
        try await repository.saveCursor(FileCursor(
            fileKey: fileKey,
            path: fileURL.path,
            offset: finalOffset,
            modifiedAt: modifiedAt
        ))
        return ScanResult(processedLines: processedLines, finalOffset: finalOffset)
    }
}
