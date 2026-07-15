import Foundation
import Testing
@testable import CodexUsageShared

@Suite("WidgetUsageSnapshotTests")
struct WidgetUsageSnapshotTests {
    @Test func storedSnapshotMatchesTheDisplaySafeJSONWhitelist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try WidgetSnapshotStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = WidgetUsageSnapshot.fixture(fiveHourLimit: .fixture())

        try store.write(snapshot)
        let data = try Data(contentsOf: store.fileURL)
        let object = try JSONSerialization.jsonObject(with: data)

        try assertWidgetSnapshotJSONUsesPrivacyWhitelist(object)
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

private enum WidgetSnapshotJSONNode {
    case root
    case limit
    case projects
    case project
    case state
    case statePayload(String)
}

private func assertWidgetSnapshotJSONUsesPrivacyWhitelist(
    _ value: Any,
    node: WidgetSnapshotJSONNode = .root
) throws {
    switch node {
    case .root:
        let object = try #require(value as? [String: Any])
        #expect(Set(object.keys) == [
            "schemaVersion",
            "generatedAt",
            "todayTokens",
            "allTimeTokens",
            "fiveHourLimit",
            "weekLimit",
            "projects",
            "state",
        ])
        try assertJSONScalar(try #require(object["schemaVersion"]))
        try assertJSONScalar(try #require(object["generatedAt"]))
        try assertJSONScalar(try #require(object["todayTokens"]))
        try assertJSONScalar(try #require(object["allTimeTokens"]))
        try assertWidgetSnapshotJSONUsesPrivacyWhitelist(
            try #require(object["fiveHourLimit"]),
            node: .limit
        )
        try assertWidgetSnapshotJSONUsesPrivacyWhitelist(
            try #require(object["weekLimit"]),
            node: .limit
        )
        try assertWidgetSnapshotJSONUsesPrivacyWhitelist(
            try #require(object["projects"]),
            node: .projects
        )
        try assertWidgetSnapshotJSONUsesPrivacyWhitelist(
            try #require(object["state"]),
            node: .state
        )

    case .limit:
        let object = try #require(value as? [String: Any])
        #expect(Set(object.keys) == ["id", "remainingPercent", "resetsAt"])
        for key in object.keys {
            try assertJSONScalar(try #require(object[key]))
        }

    case .projects:
        let projects = try #require(value as? [Any])
        for project in projects {
            try assertWidgetSnapshotJSONUsesPrivacyWhitelist(project, node: .project)
        }

    case .project:
        let object = try #require(value as? [String: Any])
        #expect(Set(object.keys) == ["id", "name", "tokens"])
        for key in object.keys {
            try assertJSONScalar(try #require(object[key]))
        }

    case .state:
        let object = try #require(value as? [String: Any])
        let allowedCases: Set<String> = [
            "fresh",
            "partial",
            "rebuilding",
            "stale",
            "noData",
            "failed",
        ]
        #expect(object.count == 1)
        let stateCase = try #require(object.keys.first)
        #expect(allowedCases.contains(stateCase))
        try assertWidgetSnapshotJSONUsesPrivacyWhitelist(
            try #require(object[stateCase]),
            node: .statePayload(stateCase)
        )

    case let .statePayload(stateCase):
        let object = try #require(value as? [String: Any])
        let allowedKeys: Set<String>
        switch stateCase {
        case "fresh", "stale":
            allowedKeys = ["lastSuccessfulAt"]
        case "partial":
            allowedKeys = ["lastSuccessfulAt", "failedFiles"]
        case "rebuilding":
            allowedKeys = ["lastSuccessfulAt"]
        case "noData", "failed":
            allowedKeys = []
        default:
            allowedKeys = []
        }
        #expect(Set(object.keys) == allowedKeys)
        for key in object.keys {
            try assertJSONScalar(try #require(object[key]), allowingNull: stateCase == "rebuilding")
        }
    }
}

private func assertJSONScalar(_ value: Any, allowingNull: Bool = false) throws {
    if allowingNull, value is NSNull {
        return
    }
    #expect(!(value is [String: Any]))
    #expect(!(value is [Any]))
}
