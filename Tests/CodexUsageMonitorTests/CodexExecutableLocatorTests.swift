import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct CodexExecutableLocatorTests {
    @Test
    func prefersTheCodexInsideTheLocatedApplicationBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let bundle = root.appending(path: "ChatGPT.app", directoryHint: .isDirectory)
        let codex = bundle.appending(path: "Contents/Resources/codex")
        try FileManager.default.createDirectory(
            at: codex.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: codex)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codex.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = CodexExecutableLocator(
            applicationURL: { bundle },
            fallbackURLs: [],
            environmentPath: ""
        )

        #expect(try locator.executableURL() == codex)
    }

    @Test
    func rejectsNonExecutableCandidatesAndReportsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: "codex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not executable".utf8).write(to: codex)
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = CodexExecutableLocator(
            applicationURL: { nil },
            fallbackURLs: [codex],
            environmentPath: ""
        )

        #expect(throws: CodexExecutableLocator.LocatorError.self) {
            try locator.executableURL()
        }
    }
}
