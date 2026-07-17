import Foundation
import Testing
@testable import CodexUsageShared

@Suite("WidgetUsageSnapshotTests")
struct WidgetUsageSnapshotTests {
    @Test func appGroupUsesTheSigningTeamPrefixRequiredByMacOS() {
        let teamIdentifier = "ZD9PK3NY5Z"

        #expect(
            WidgetSnapshotStore.appGroupIdentifier
                == "ZD9PK3NY5Z.CodexUsageMonitor.shared"
        )
        #expect(
            WidgetSnapshotStore.appGroupIdentifier
                .hasPrefix("\(teamIdentifier).")
        )
    }

    @Test(arguments: WidgetUsageSnapshot.privacyFixtures)
    func storedSnapshotMatchesTheDisplaySafeJSONWhitelist(
        snapshot: WidgetUsageSnapshot
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try WidgetSnapshotStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.write(snapshot)
        let data = try Data(contentsOf: store.fileURL)
        let object = try JSONSerialization.jsonObject(with: data)

        try assertWidgetSnapshotJSONUsesPrivacyWhitelist(object, matching: snapshot)
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
    case root(WidgetUsageSnapshot)
    case limit
    case projects
    case project
    case state(WidgetDataState)
    case statePayload(WidgetDataState)
}

private func assertWidgetSnapshotJSONUsesPrivacyWhitelist(
    _ value: Any,
    matching snapshot: WidgetUsageSnapshot
) throws {
    try assertWidgetSnapshotJSONUsesPrivacyWhitelist(value, node: .root(snapshot))
}

private func assertWidgetSnapshotJSONUsesPrivacyWhitelist(
    _ value: Any,
    node: WidgetSnapshotJSONNode
) throws {
    switch node {
    case let .root(snapshot):
        let object = try #require(value as? [String: Any])
        var expectedKeys: Set<String> = [
            "schemaVersion",
            "generatedAt",
            "todayTokens",
            "allTimeTokens",
            "projects",
            "state",
        ]
        if snapshot.fiveHourLimit != nil {
            expectedKeys.insert("fiveHourLimit")
        }
        if snapshot.weekLimit != nil {
            expectedKeys.insert("weekLimit")
        }
        #expect(Set(object.keys) == expectedKeys)
        try assertJSONScalar(try #require(object["schemaVersion"]))
        try assertJSONScalar(try #require(object["generatedAt"]))
        try assertJSONScalar(try #require(object["todayTokens"]))
        try assertJSONScalar(try #require(object["allTimeTokens"]))
        if snapshot.fiveHourLimit != nil {
            try assertWidgetSnapshotJSONUsesPrivacyWhitelist(
                try #require(object["fiveHourLimit"]),
                node: .limit
            )
        } else {
            #expect(object["fiveHourLimit"] == nil)
        }
        if snapshot.weekLimit != nil {
            try assertWidgetSnapshotJSONUsesPrivacyWhitelist(
                try #require(object["weekLimit"]),
                node: .limit
            )
        } else {
            #expect(object["weekLimit"] == nil)
        }
        try assertWidgetSnapshotJSONUsesPrivacyWhitelist(
            try #require(object["projects"]),
            node: .projects
        )
        try assertWidgetSnapshotJSONUsesPrivacyWhitelist(
            try #require(object["state"]),
            node: .state(snapshot.state)
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

    case let .state(expectedState):
        let object = try #require(value as? [String: Any])
        let stateCase: String
        switch expectedState {
        case .fresh:
            stateCase = "fresh"
        case .partial:
            stateCase = "partial"
        case .rebuilding:
            stateCase = "rebuilding"
        case .stale:
            stateCase = "stale"
        case .noData:
            stateCase = "noData"
        case .failed:
            stateCase = "failed"
        }
        #expect(Set(object.keys) == [stateCase])
        try assertWidgetSnapshotJSONUsesPrivacyWhitelist(
            try #require(object[stateCase]),
            node: .statePayload(expectedState)
        )

    case let .statePayload(expectedState):
        let object = try #require(value as? [String: Any])
        let allowedKeys: Set<String>
        switch expectedState {
        case .fresh, .stale:
            allowedKeys = ["lastSuccessfulAt"]
        case .partial:
            allowedKeys = ["lastSuccessfulAt", "failedFiles"]
        case let .rebuilding(lastSuccessfulAt):
            allowedKeys = lastSuccessfulAt == nil ? [] : ["lastSuccessfulAt"]
        case .noData, .failed:
            allowedKeys = []
        }
        #expect(Set(object.keys) == allowedKeys)
        for key in object.keys {
            try assertJSONScalar(try #require(object[key]))
        }
    }
}

private func assertJSONScalar(_ value: Any) throws {
    #expect(!(value is [String: Any]))
    #expect(!(value is [Any]))
}
