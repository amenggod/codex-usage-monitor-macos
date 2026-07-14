import CoreServices
import Foundation

private final class WatcherContext: @unchecked Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}

private let fseventsCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
    guard let info else { return }
    Unmanaged<WatcherContext>
        .fromOpaque(info)
        .takeUnretainedValue()
        .continuation
        .yield(())
}

protocol SessionFileWatching: AnyObject, Sendable {
    var startupFailure: String? { get }
    func events() -> AsyncStream<Void>
    func stop()
}

final class SessionFileWatcher: SessionFileWatching, @unchecked Sendable {
    private let roots: [URL]
    private let queue = DispatchQueue(label: "CodexUsageMonitor.SessionFileWatcher")
    private let lock = NSLock()
    private var streamReference: FSEventStreamRef?
    private var retainedContext: Unmanaged<WatcherContext>?
    private var continuation: AsyncStream<Void>.Continuation?
    private var eventStream: AsyncStream<Void>?
    private var stopped = false
    private var failureMessage: String?

    init(roots: [URL]) {
        self.roots = roots
    }

    deinit {
        stop()
    }

    var startupFailure: String? {
        lock.withLock { failureMessage }
    }

    func events() -> AsyncStream<Void> {
        lock.lock()
        defer { lock.unlock() }

        if let eventStream {
            return eventStream
        }
        guard !stopped else {
            return AsyncStream { $0.finish() }
        }

        let pair = AsyncStream<Void>.makeStream()
        let stream = pair.stream
        let continuation = pair.continuation
        self.eventStream = stream
        self.continuation = continuation

        let contextObject = WatcherContext(continuation: continuation)
        let unmanagedContext = Unmanaged.passRetained(contextObject)
        var context = FSEventStreamContext(
            version: 0,
            info: unmanagedContext.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = roots.map(\.path) as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let streamReference = FSEventStreamCreate(
            kCFAllocatorDefault,
            fseventsCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            unmanagedContext.release()
            failureMessage = "无法创建 Codex 会话文件监听器"
            stopped = true
            continuation.finish()
            return stream
        }

        FSEventStreamSetDispatchQueue(streamReference, queue)
        guard FSEventStreamStart(streamReference) else {
            FSEventStreamInvalidate(streamReference)
            FSEventStreamRelease(streamReference)
            unmanagedContext.release()
            failureMessage = "无法启动 Codex 会话文件监听器"
            stopped = true
            continuation.finish()
            return stream
        }

        self.streamReference = streamReference
        retainedContext = unmanagedContext
        continuation.onTermination = { [weak self] _ in
            self?.stop()
        }
        return stream
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let streamReference = self.streamReference
        let retainedContext = self.retainedContext
        let continuation = self.continuation
        self.streamReference = nil
        self.retainedContext = nil
        self.continuation = nil
        lock.unlock()

        if let streamReference {
            FSEventStreamStop(streamReference)
            FSEventStreamInvalidate(streamReference)
            FSEventStreamRelease(streamReference)
            queue.sync {}
        }
        continuation?.finish()
        retainedContext?.release()
    }
}
