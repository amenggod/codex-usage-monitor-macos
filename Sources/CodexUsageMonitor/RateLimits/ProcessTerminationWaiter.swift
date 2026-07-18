import Foundation

final class ProcessTerminationWaiter: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private struct Waiter {
            let continuation: CheckedContinuation<Void, Never>
            var timeoutTask: Task<Void, Never>?
        }

        private let lock = NSLock()
        private var terminated = false
        private var waiters: [UUID: Waiter] = [:]

        func register(
            id: UUID,
            continuation: CheckedContinuation<Void, Never>
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !terminated else { return false }
            waiters[id] = Waiter(continuation: continuation, timeoutTask: nil)
            return true
        }

        func attachTimeout(_ timeoutTask: Task<Void, Never>, to id: UUID) {
            lock.lock()
            guard var waiter = waiters[id] else {
                lock.unlock()
                timeoutTask.cancel()
                return
            }
            waiter.timeoutTask = timeoutTask
            waiters[id] = waiter
            lock.unlock()
        }

        func resume(id: UUID) {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.timeoutTask?.cancel()
            waiter?.continuation.resume()
        }

        func markTerminated() {
            lock.lock()
            guard !terminated else {
                lock.unlock()
                return
            }
            terminated = true
            let pendingWaiters = Array(waiters.values)
            waiters.removeAll()
            lock.unlock()

            for waiter in pendingWaiters {
                waiter.timeoutTask?.cancel()
                waiter.continuation.resume()
            }
        }
    }

    private let state: State

    init(process: Process) {
        let terminationState = State()
        state = terminationState
        process.terminationHandler = { _ in
            terminationState.markTerminated()
        }
    }

    func wait(timeout: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.register(id: id, continuation: continuation) else {
                    continuation.resume()
                    return
                }
                guard !Task.isCancelled else {
                    state.resume(id: id)
                    return
                }
                let timeoutTask = Task { [state] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    state.resume(id: id)
                }
                state.attachTimeout(timeoutTask, to: id)
            }
        } onCancel: {
            state.resume(id: id)
        }
    }
}
