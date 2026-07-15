import Foundation

public protocol WidgetSnapshotStoring: Sendable {
    func read() throws -> WidgetUsageSnapshot?
    func write(_ snapshot: WidgetUsageSnapshot) throws
}

public enum WidgetSnapshotStoreError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case unsupportedSchema(Int)
}

public struct WidgetSnapshotStore: WidgetSnapshotStoring, Sendable {
    public static let appGroupIdentifier = "group.com.amenggod.CodexUsageMonitor"
    public let fileURL: URL

    public init(directoryURL: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("widget-usage-v1.json")
    }

    public static func appGroup(fileManager: FileManager = .default) throws -> Self {
        guard let url = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { throw WidgetSnapshotStoreError.appGroupUnavailable }
        return try Self(directoryURL: url, fileManager: fileManager)
    }

    public func read() throws -> WidgetUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let snapshot = try JSONDecoder.widgetSnapshot.decode(
            WidgetUsageSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        guard snapshot.schemaVersion == WidgetUsageSnapshot.currentSchemaVersion else {
            throw WidgetSnapshotStoreError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
    }

    public func write(_ snapshot: WidgetUsageSnapshot) throws {
        try JSONEncoder.widgetSnapshot.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
