import Darwin
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
            timeout: .seconds(5)
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

    @Test
    func stopWaitsForProcessToExit() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).pid")
        let executable = try makeExecutable(
            body: #"""
            printf '%s\n' "$$" > '\#(pidFile.path)'
            trap 'sleep 0.25; exit 0' TERM
            while IFS= read -r line; do :; done
            while :; do sleep 0.01; done
            """#
        )
        defer {
            try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pidFile)
        }
        let transport = CodexAppServerTransport(executableURL: executable)

        try await withStartedTransport(transport) {
            try await waitUntil(timeout: .seconds(3)) {
                FileManager.default.fileExists(atPath: pidFile.path)
            }
            let pidText = try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let processID = pid_t(pidText) else { throw FixtureError.invalidProcessID }

            await transport.stop()
            let exitedWhenStopReturned = processDoesNotExist(processID)
            #expect(exitedWhenStopReturned)
            if !exitedWhenStopReturned {
                try await waitUntil { processDoesNotExist(processID) }
            }

            #expect(Darwin.kill(processID, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test
    func drainsStderrWhileRequestIsInFlight() async throws {
        let executable = try makeExecutable(
            body: #"""
            while IFS= read -r line; do
              i=0
              while [ "$i" -lt 256 ]; do
                printf '%01024d\n' 0 >&2
                i=$((i + 1))
              done
              printf '%s\n' '{"id":1,"result":{"ok":true}}'
            done
            """#
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = CodexAppServerTransport(executableURL: executable)

        let response = try await withStartedTransport(transport) {
            try await transport.request(
                method: "account/rateLimits/read",
                params: nil,
                timeout: .seconds(5)
            )
        }

        #expect(String(decoding: response, as: UTF8.self).contains(#""ok":true"#))
    }

    @Test
    func startDuringStopFinalizationCannotEscapeAnOverlappingStop() async throws {
        let finalizationGate = AsyncGate()
        let executable = try makeExecutable(
            body: #"""
            while IFS= read -r line; do
              printf '%s\n' '{"id":1,"result":{"ok":true}}'
            done
            """#
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = CodexAppServerTransport(
            executableURL: executable,
            stopFinalizationHook: {
                await finalizationGate.enterAndWait()
            }
        )
        try await transport.start()

        let firstStop = Task { await transport.stop() }
        await finalizationGate.waitUntilEntered()
        do {
            try await transport.start()
            let overlappingStop = Task { await transport.stop() }
            await finalizationGate.open()
            await firstStop.value
            await overlappingStop.value

            await #expect(throws: CodexAppServerTransport.TransportError.self) {
                try await transport.request(
                    method: "account/rateLimits/read",
                    params: nil,
                    timeout: .seconds(1)
                )
            }

            try await transport.start()
            let restartedResponse = try await transport.request(
                method: "account/rateLimits/read",
                params: nil,
                timeout: .seconds(5)
            )
            #expect(String(decoding: restartedResponse, as: UTF8.self).contains(#""ok":true"#))
        } catch {
            await finalizationGate.open()
            await firstStop.value
            await transport.stop()
            throw error
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

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw FixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func processDoesNotExist(_ processID: pid_t) -> Bool {
        Darwin.kill(processID, 0) == -1 && errno == ESRCH
    }

    private func withStartedTransport<Result>(
        _ transport: CodexAppServerTransport,
        operation: () async throws -> Result
    ) async throws -> Result {
        try await transport.start()
        do {
            let result = try await operation()
            await transport.stop()
            return result
        } catch {
            await transport.stop()
            throw error
        }
    }

    private enum FixtureError: Error {
        case invalidProcessID
        case timedOut
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var hasEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        hasEntered = true
        let enteredWaiters = enteredWaiters
        self.enteredWaiters.removeAll()
        for waiter in enteredWaiters {
            waiter.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let openWaiters = openWaiters
        self.openWaiters.removeAll()
        for waiter in openWaiters {
            waiter.resume()
        }
    }
}
