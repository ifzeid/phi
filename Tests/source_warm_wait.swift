import Foundation

@main
enum SourceWarmWaitTests {
    static func main() async {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        let already = SourceWarmGate()
        already.markReady()
        let alreadyStart = CFAbsoluteTimeGetCurrent()
        let alreadyOK = await already.wait(timeout: 2)
        let alreadyElapsed = CFAbsoluteTimeGetCurrent() - alreadyStart
        expect(alreadyOK, "already-ready wait should return true")
        expect(alreadyElapsed < 0.5, "already-ready wait took \(alreadyElapsed)s")

        let timed = SourceWarmGate()
        let timedStart = CFAbsoluteTimeGetCurrent()
        let timedOK = await timed.wait(timeout: 0.2)
        let timedElapsed = CFAbsoluteTimeGetCurrent() - timedStart
        expect(timedOK == false, "timeout should return false, got \(timedOK)")
        expect(timedElapsed >= 0.15, "timeout returned too early: \(timedElapsed)s")
        expect(timedElapsed < 1.0, "timeout did not bound the wait: \(timedElapsed)s")
        // A late markReady after timeout must not hang or crash (double-resume).
        timed.markReady()

        let ordered = SourceWarmGate()
        final class Flag: @unchecked Sendable { var warmAssigned = false }
        let flag = Flag()
        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            flag.warmAssigned = true
            ordered.markReady()
        }
        let arrived = await ordered.wait(timeout: 1)
        expect(arrived, "source should arrive before timeout")
        expect(flag.warmAssigned, "wait must not return before warmTask would have been assigned")

        let many = SourceWarmGate()
        async let a = many.wait(timeout: 1)
        async let b = many.wait(timeout: 1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        many.markReady()
        let pair = await (a, b)
        expect(pair.0 && pair.1, "both waiters should see ready, got \(pair)")

        if notes.isEmpty {
            print("SOURCE WARM WAIT PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("SOURCE WARM WAIT FAILED \(notes.count)")
        }
    }
}
