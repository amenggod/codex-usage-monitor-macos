import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct CodexHomeLocatorTests {
    @Test
    func environmentOverrideWins() {
        let result = CodexHomeLocator.home(
            environment: ["CODEX_HOME": "/synthetic/codex"],
            homeDirectory: URL(fileURLWithPath: "/synthetic/home")
        )

        #expect(result.path == "/synthetic/codex")
    }

    @Test
    func defaultUsesDotCodex() {
        let result = CodexHomeLocator.home(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/synthetic/home")
        )

        #expect(result.path == "/synthetic/home/.codex")
    }

    @Test
    func sessionRootsIncludeLiveAndArchivedSessions() {
        let home = URL(fileURLWithPath: "/synthetic/codex", isDirectory: true)

        #expect(CodexHomeLocator.sessionRoots(home: home).map(\.lastPathComponent) == [
            "sessions",
            "archived_sessions"
        ])
    }
}
