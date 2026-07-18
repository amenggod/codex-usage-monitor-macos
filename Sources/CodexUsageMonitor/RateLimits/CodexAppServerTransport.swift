import Darwin
import Foundation

protocol CodexAppServerTransporting: Sendable {
    func start() async throws
    func request(method: String, params: Data?, timeout: Duration) async throws -> Data
    func notifications() async -> AsyncStream<Data>
    func stop() async
}

actor CodexAppServerTransport: CodexAppServerTransporting {
    enum TransportError: LocalizedError {
        case notRunning
        case invalidParameters
        case invalidResponse
        case requestTimedOut
        case processExited
        case server(String)
        case stopped

        var errorDescription: String? {
            switch self {
            case .notRunning: "Codex 实时限额服务未启动"
            case .invalidParameters: "Codex 实时限额请求无效"
            case .invalidResponse: "Codex 实时限额响应无效"
            case .requestTimedOut: "Codex 实时限额请求超时"
            case .processExited: "Codex 实时限额服务已退出"
            case let .server(message): "Codex 实时限额服务错误：\(message)"
            case .stopped: "Codex 实时限额服务已停止"
            }
        }
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct MessageHeader: Decodable {
        struct ServerError: Decodable {
            let message: String
        }

        let id: Int?
        let method: String?
        let error: ServerError?
    }

    private struct ActiveStop {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private let executableURL: URL
    private let stopFinalizationHook: (@Sendable () async -> Void)?
    private let notificationStream: AsyncStream<Data>
    private let notificationContinuation: AsyncStream<Data>.Continuation
    private var process: Process?
    private var terminationWaiter: ProcessTerminationWaiter?
    private var input: FileHandle?
    private var readingTask: Task<Void, Never>?
    private var errorReadingTask: Task<Void, Never>?
    private var nextStopID: UInt64 = 0
    private var activeStop: ActiveStop?
    private var nextRequestID = 0
    private var pending: [Int: PendingRequest] = [:]

    init(
        executableURL: URL,
        stopFinalizationHook: (@Sendable () async -> Void)? = nil
    ) {
        self.executableURL = executableURL
        self.stopFinalizationHook = stopFinalizationHook
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(16))
        notificationStream = pair.stream
        notificationContinuation = pair.continuation
    }

    func start() async throws {
        guard activeStop == nil, process == nil else { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let terminationWaiter = ProcessTerminationWaiter(process: process)
        try process.run()

        self.process = process
        self.terminationWaiter = terminationWaiter
        input = inputPipe.fileHandleForWriting
        let output = outputPipe.fileHandleForReading
        let error = errorPipe.fileHandleForReading
        readingTask = Task { [weak self] in
            do {
                for try await line in output.bytes.lines {
                    guard !Task.isCancelled else { return }
                    await self?.receive(Data(line.utf8))
                }
            } catch {
                // EOF and pipe failures are represented by the same safe unavailable state.
            }
            guard !Task.isCancelled else { return }
            await self?.processDidExit(process)
        }
        errorReadingTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    guard let chunk = try error.read(upToCount: 64 * 1_024),
                          !chunk.isEmpty else {
                        return
                    }
                } catch {
                    return
                }
            }
        }
    }

    func request(
        method: String,
        params: Data?,
        timeout: Duration
    ) async throws -> Data {
        guard process != nil, let input else { throw TransportError.notRunning }
        nextRequestID += 1
        let id = nextRequestID

        var object: [String: Any] = ["id": id, "method": method]
        if let params {
            guard let value = try? JSONSerialization.jsonObject(with: params) else {
                throw TransportError.invalidParameters
            }
            object["params"] = value
        } else {
            object["params"] = NSNull()
        }
        var requestData = try JSONSerialization.data(withJSONObject: object)
        requestData.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self?.expire(id: id)
            }
            pending[id] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            do {
                try input.write(contentsOf: requestData)
            } catch {
                let request = pending.removeValue(forKey: id)
                request?.timeoutTask.cancel()
                request?.continuation.resume(throwing: error)
            }
        }
    }

    func notifications() async -> AsyncStream<Data> {
        notificationStream
    }

    func stop() async {
        if let activeStop {
            await activeStop.task.value
            return
        }
        guard let process, let terminationWaiter else {
            failPending(with: TransportError.stopped)
            return
        }

        let input = input
        let readingTask = readingTask
        let errorReadingTask = errorReadingTask
        nextStopID &+= 1
        let id = nextStopID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStop(
                process: process,
                terminationWaiter: terminationWaiter,
                input: input,
                readingTask: readingTask,
                errorReadingTask: errorReadingTask
            )
        }
        activeStop = ActiveStop(id: id, task: task)
        await task.value
        if activeStop?.id == id {
            activeStop = nil
        }
    }

    private func receive(_ data: Data) {
        guard let header = try? JSONDecoder().decode(MessageHeader.self, from: data) else {
            return
        }
        guard let id = header.id else {
            if header.method != nil {
                notificationContinuation.yield(data)
            }
            return
        }
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        if let error = header.error {
            request.continuation.resume(throwing: TransportError.server(error.message))
        } else {
            request.continuation.resume(returning: data)
        }
    }

    private func expire(id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: TransportError.requestTimedOut)
    }

    private func processDidExit(_ exitedProcess: Process) {
        guard process === exitedProcess, activeStop == nil else { return }
        process = nil
        terminationWaiter = nil
        input = nil
        readingTask = nil
        errorReadingTask?.cancel()
        errorReadingTask = nil
        failPending(with: TransportError.processExited)
    }

    private func performStop(
        process: Process,
        terminationWaiter: ProcessTerminationWaiter,
        input: FileHandle?,
        readingTask: Task<Void, Never>?,
        errorReadingTask: Task<Void, Never>?
    ) async {
        try? input?.close()
        readingTask?.cancel()
        errorReadingTask?.cancel()
        if process.isRunning {
            process.terminate()
            await terminationWaiter.wait(timeout: .seconds(2))
        }
        while process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            await terminationWaiter.wait(timeout: .seconds(2))
        }

        guard self.process === process else { return }
        self.process = nil
        self.terminationWaiter = nil
        self.input = nil
        self.readingTask = nil
        self.errorReadingTask = nil
        failPending(with: TransportError.stopped)
        if let stopFinalizationHook {
            await stopFinalizationHook()
        }
    }

    private func failPending(with error: TransportError) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
