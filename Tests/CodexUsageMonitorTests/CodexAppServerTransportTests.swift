import Foundation
import Testing
@testable import CodexUsageMonitor

@Suite
struct CodexAppServerTransportTests {
    @Test
    func pairsResponseAndPublishesNotification() async throws {
        let executable = try makeExecutable(
            body: #"""
            while IFS= read -r line; do
              printf '%s\n' '{"id":1,"result":{"ok":true}}'
              printf '%s\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{}}}'
            done
            """#
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = CodexAppServerTransport(executableURL: executable)
        let notifications = await transport.notifications()

        try await transport.start()
        let response = try await transport.request(
            method: "account/rateLimits/read",
            params: nil,
            timeout: .seconds(1)
        )
        let notification = await notifications.first { _ in true }
        await transport.stop()

        #expect(String(decoding: response, as: UTF8.self).contains(#""ok":true"#))
        #expect(notification.map(CodexRateLimitProtocol.isRateLimitsUpdatedNotification) == true)
    }

    @Test
    func timesOutAndStopIsIdempotent() async throws {
        let executable = try makeExecutable(body: "while IFS= read -r line; do :; done")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = CodexAppServerTransport(executableURL: executable)
        try await transport.start()

        await #expect(throws: CodexAppServerTransport.TransportError.self) {
            try await transport.request(
                method: "never/replies",
                params: nil,
                timeout: .milliseconds(20)
            )
        }
        await transport.stop()
        await transport.stop()
    }

    @Test
    func processExitFailsPendingRequest() async throws {
        let executable = try makeExecutable(body: "exit 0")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = CodexAppServerTransport(executableURL: executable)
        try await transport.start()

        await #expect(throws: Error.self) {
            try await transport.request(
                method: "account/rateLimits/read",
                params: nil,
                timeout: .seconds(1)
            )
        }
        await transport.stop()
    }

    private func makeExecutable(body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let executable = root.appending(path: "codex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }
}
