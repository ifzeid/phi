import Foundation
import os

/// Intervals for album, editor, and save. The perf UITest reads the `PERF` lines.
enum PerfTrace {
    static let albumMs = 300.0
    static let editMs = 300.0
    static let hangMs = 250.0
    static let saveMs = 2000.0

    private static let started = CFAbsoluteTimeGetCurrent()
    private static let signposter = OSSignposter(subsystem: "com.zeid.phi", category: "perf")
    private static let log = Logger(subsystem: "com.zeid.phi", category: "perf")
    private static let lock = NSLock()
    private static var launchState: OSSignpostIntervalState?
    private static var launchLogged = false
    private static var albumBegan: CFAbsoluteTime?
    private static var albumState: OSSignpostIntervalState?
    private static var albumLogged = false
    private static var swipeBegan: CFAbsoluteTime?
    private static var swipeState: OSSignpostIntervalState?
    private static var editBegan: CFAbsoluteTime?
    private static var editState: OSSignpostIntervalState?
    private static var saveBegan: CFAbsoluteTime?
    private static var saveState: OSSignpostIntervalState?
    private static var hangOver100 = 0
    private static var hangOver250 = 0
    private static var watchdog: DispatchSourceTimer?
    private static var firstFrameWaiters: [() -> Void] = []
    private static var albumMilliseconds = -1.0
    private static var swipeMilliseconds = -1.0
    private static var editMilliseconds = -1.0

    static func boot() {
        lock.lock()
        defer { lock.unlock() }
        guard launchState == nil else { return }
        launchState = signposter.beginInterval("Launch")
    }

    static func noteFirstFrame() {
        lock.lock()
        let state = launchState
        let already = launchLogged
        launchLogged = true
        launchState = nil
        lock.unlock()
        guard already == false else { return }
        if let state {
            signposter.endInterval("Launch", state)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        emit(String(format: "PERF LAUNCH %.1f", ms))
    }

    static func beginAlbum() {
        lock.lock()
        defer { lock.unlock() }
        guard albumLogged == false, albumBegan == nil else { return }
        albumBegan = CFAbsoluteTimeGetCurrent()
        albumState = signposter.beginInterval("Album")
    }

    static func noteAlbumThumbnail() {
        lock.lock()
        guard albumLogged == false, let began = albumBegan else {
            lock.unlock()
            return
        }
        albumLogged = true
        let state = albumState
        albumState = nil
        albumBegan = nil
        lock.unlock()
        if let state {
            signposter.endInterval("Album", state)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        lock.lock()
        albumMilliseconds = ms
        lock.unlock()
        emit(String(format: "PERF ALBUM %.1f", ms))
    }

    static func beginSwipe() {
        lock.lock()
        defer { lock.unlock() }
        guard swipeBegan == nil else { return }
        swipeBegan = CFAbsoluteTimeGetCurrent()
        swipeState = signposter.beginInterval("Swipe")
    }

    static func endSwipe() {
        lock.lock()
        guard let began = swipeBegan else {
            lock.unlock()
            return
        }
        let state = swipeState
        swipeBegan = nil
        swipeState = nil
        lock.unlock()
        if let state {
            signposter.endInterval("Swipe", state)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        lock.lock()
        swipeMilliseconds = ms
        lock.unlock()
        emit(String(format: "PERF SWIPE %.1f", ms))
    }

    static func beginEdit() {
        lock.lock()
        defer { lock.unlock() }
        guard editBegan == nil else { return }
        editBegan = CFAbsoluteTimeGetCurrent()
        editState = signposter.beginInterval("Edit")
    }

    static func endEdit() {
        lock.lock()
        guard let began = editBegan else {
            lock.unlock()
            return
        }
        let state = editState
        editBegan = nil
        editState = nil
        let waiters = firstFrameWaiters
        firstFrameWaiters = []
        lock.unlock()
        if let state {
            signposter.endInterval("Edit", state)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        lock.lock()
        editMilliseconds = ms
        lock.unlock()
        emit(String(format: "PERF EDIT %.1f", ms))
        waiters.forEach { $0() }
    }

    static func cancelEdit() {
        lock.lock()
        let state = editState
        editBegan = nil
        editState = nil
        let waiters = firstFrameWaiters
        firstFrameWaiters = []
        lock.unlock()
        if let state {
            signposter.endInterval("Edit", state)
        }
        waiters.forEach { $0() }
    }

    /// Plate builds wait until the JPEG is up, but not forever if the view never draws.
    static func waitForFirstFrame(timeout: TimeInterval = 1) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await awaitFirstFrame() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
    }

    private static func awaitFirstFrame() async {
        let pending = lock.sync { editBegan != nil }
        guard pending else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if editBegan == nil {
                lock.unlock()
                continuation.resume()
                return
            }
            firstFrameWaiters.append {
                continuation.resume()
            }
            lock.unlock()
        }
    }

    static func beginSave() {
        lock.lock()
        defer { lock.unlock() }
        guard saveBegan == nil else { return }
        saveBegan = CFAbsoluteTimeGetCurrent()
        saveState = signposter.beginInterval("Save")
    }

    static func endSave() {
        lock.lock()
        guard let began = saveBegan else {
            lock.unlock()
            return
        }
        let state = saveState
        saveBegan = nil
        saveState = nil
        lock.unlock()
        if let state {
            signposter.endInterval("Save", state)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
        emit(String(format: "PERF SAVE %.1f", ms))
    }

    static func startWatchdog() {
        lock.lock()
        if watchdog != nil {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "phi.perf.watch"))
        watchdog = timer
        lock.unlock()
        timer.schedule(deadline: .now() + .milliseconds(80), repeating: .milliseconds(80))
        timer.setEventHandler {
            let start = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                guard ms > 100 else { return }
                noteHang(ms)
            }
        }
        timer.resume()
    }

    static func noteHang(_ ms: Double) {
        let state = signposter.beginInterval("Hang")
        signposter.endInterval("Hang", state)
        lock.lock()
        hangOver100 += 1
        if ms > hangMs {
            hangOver250 += 1
        }
        let count = hangOver100
        let over = hangOver250
        lock.unlock()
        emit(String(format: "PERF HANG %.1f count=%d over250=%d", ms, count, over))
    }

    static func intervals() -> (album: Double, swipe: Double, edit: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (albumMilliseconds, swipeMilliseconds, editMilliseconds)
    }

    static func hangSnapshot() -> (over100: Int, over250: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hangOver100, hangOver250)
    }

    private static func emit(_ line: String) {
        print(line)
        log.notice("\(line, privacy: .public)")
    }
}

private extension NSLock {
    func sync<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
