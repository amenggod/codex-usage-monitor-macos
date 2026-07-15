import Foundation
import Testing
@testable import CodexUsageShared

@Suite("WidgetUsageSnapshotTests")
struct WidgetUsageSnapshotTests {
    @Test func roundTripContainsOnlyDisplaySafeFields() throws {
        let snapshot = WidgetUsageSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            todayTokens: 12_345,
            allTimeTokens: 98_765,
            fiveHourLimit: nil,
            weekLimit: WidgetLimitStatus(
                id: "codex-week",
                remainingPercent: 72,
                resetsAt: Date(timeIntervalSince1970: 9_000)
            ),
            projects: [WidgetProjectUsage(id: "p1", name: "monitor", tokens: 500)],
            state: .fresh(lastSuccessfulAt: Date(timeIntervalSince1970: 1_000))
        )

        let data = try JSONEncoder.widgetSnapshot.encode(snapshot)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("fullPath"))
        #expect(!text.contains("prompt"))
        #expect(try JSONDecoder.widgetSnapshot.decode(WidgetUsageSnapshot.self, from: data) == snapshot)
    }

    @Test func atomicStoreReturnsNilForMissingFileAndRoundTripsACompleteSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try WidgetSnapshotStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try store.read() == nil)
        let snapshot = WidgetUsageSnapshot.fixture
        try store.write(snapshot)
        #expect(try store.read() == snapshot)
    }

    @Test func corruptSnapshotThrowsInsteadOfReturningZeroValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try WidgetSnapshotStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not-json".utf8).write(to: store.fileURL)

        #expect(throws: DecodingError.self) { try store.read() }
    }

    @Test func unsupportedSchemaThrowsInsteadOfRenderingUnknownData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try WidgetSnapshotStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder.widgetSnapshot.encode(WidgetUsageSnapshot.fixture)
            )
                as? [String: Any]
        )
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)

        #expect(throws: WidgetSnapshotStoreError.self) { try store.read() }
    }
}
