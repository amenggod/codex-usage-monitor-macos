import Foundation

enum CodexHomeLocator {
    static func home(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    static func sessionRoots(home: URL) -> [URL] {
        [
            home.appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
    }
}
