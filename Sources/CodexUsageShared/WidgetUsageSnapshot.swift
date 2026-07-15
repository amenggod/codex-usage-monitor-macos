import Foundation

public struct WidgetUsageSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let generatedAt: Date
    public let todayTokens: Int64
    public let allTimeTokens: Int64
    public let fiveHourLimit: WidgetLimitStatus?
    public let weekLimit: WidgetLimitStatus?
    public let projects: [WidgetProjectUsage]
    public let state: WidgetDataState

    public init(
        generatedAt: Date,
        todayTokens: Int64,
        allTimeTokens: Int64,
        fiveHourLimit: WidgetLimitStatus?,
        weekLimit: WidgetLimitStatus?,
        projects: [WidgetProjectUsage],
        state: WidgetDataState
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.todayTokens = todayTokens
        self.allTimeTokens = allTimeTokens
        self.fiveHourLimit = fiveHourLimit
        self.weekLimit = weekLimit
        self.projects = Array(projects.prefix(3))
        self.state = state
    }
}

public struct WidgetProjectUsage: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let tokens: Int64

    public init(id: String, name: String, tokens: Int64) {
        self.id = id
        self.name = name
        self.tokens = tokens
    }
}

public struct WidgetLimitStatus: Codable, Equatable, Sendable {
    public let id: String
    public let remainingPercent: Double
    public let resetsAt: Date

    public init(id: String, remainingPercent: Double, resetsAt: Date) {
        self.id = id
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetsAt = resetsAt
    }
}

public enum WidgetDataState: Codable, Equatable, Sendable {
    case fresh(lastSuccessfulAt: Date)
    case partial(lastSuccessfulAt: Date, failedFiles: Int)
    case rebuilding(lastSuccessfulAt: Date?)
    case stale(lastSuccessfulAt: Date)
    case noData
    case failed
}

public extension WidgetUsageSnapshot {
    static let placeholder = WidgetUsageSnapshot(
        generatedAt: .now,
        todayTokens: 12_345,
        allTimeTokens: 98_765,
        fiveHourLimit: nil,
        weekLimit: WidgetLimitStatus(
            id: "placeholder-week",
            remainingPercent: 72,
            resetsAt: .now.addingTimeInterval(86_400)
        ),
        projects: [
            WidgetProjectUsage(id: "one", name: "restaurant", tokens: 42_100),
            WidgetProjectUsage(id: "two", name: "monitor", tokens: 31_400),
            WidgetProjectUsage(id: "three", name: "notes", tokens: 25_265),
        ],
        state: .fresh(lastSuccessfulAt: .now)
    )
}

public extension JSONEncoder {
    static var widgetSnapshot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var widgetSnapshot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
