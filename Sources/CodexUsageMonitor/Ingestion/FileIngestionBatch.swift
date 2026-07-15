import Foundation

struct SessionUpsert: Sendable {
    let metadata: SessionMetadata
    let project: ProjectIdentity
}

struct LogicalTokenEvent: Sendable {
    let id: String
    let sessionID: String
    let occurredAt: Date
    let lastUsage: TokenUsage?
    let cumulativeUsage: TokenUsage?
}

struct FileIngestionBatch: Sendable {
    let sessions: [SessionUpsert]
    let events: [LogicalTokenEvent]
    let limits: [RateLimitObservation]
    let cursor: FileCursor
}

struct FileIngestionResult: Equatable, Sendable {
    let insertedEvents: Int
    let duplicateEvents: Int
}
