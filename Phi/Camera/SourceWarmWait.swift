import Foundation

/// One-shot resume so a timeout and a late source-ready event cannot resume twice.
final class OnceResume<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<Value, Never>, _ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        guard done == false else { return }
        done = true
        continuation.resume(returning: value)
    }
}

/// Bounded wait for a Mode 0 DNG (or any one-shot source) to arrive.
/// `wait` returns `true` if `markReady` ran, `false` if the timeout elapsed.
/// `withTaskGroup` is avoided: a non-cancellable continuation would otherwise hang the group.
final class SourceWarmGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var waiters: [() -> Void] = []

    var isReady: Bool { withLock { ready } }

    func markReady() {
        let pending: [() -> Void] = withLock {
            ready = true
            let items = waiters
            waiters.removeAll()
            return items
        }
        pending.forEach { $0() }
    }

    func wait(timeout: TimeInterval) async -> Bool {
        if withLock({ ready }) { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceResume<Bool>()
            let already: Bool = withLock {
                if ready { return true }
                waiters.append { once.resume(continuation, true) }
                return false
            }
            if already {
                once.resume(continuation, true)
                return
            }
            let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                once.resume(continuation, false)
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
