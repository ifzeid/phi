import Foundation
import Combine

/// Process-wide pending “打开取景” request. The intent writes here; the finder and editor consume it.
/// Cold start: `perform()` may run before `QuietFinderView` appears, so the request stays pending until `takePending()`.
@MainActor
final class FinderLaunchRouter: ObservableObject {
    static let shared = FinderLaunchRouter()

    @Published private(set) var generation: UInt64 = 0
    private var box = FinderLaunchPending()

    var isPending: Bool { box.isPending }

    func requestOpenFinder() {
        box.request()
        generation = box.generation
    }

    @discardableResult
    func takePending() -> Bool {
        box.take()
    }

    #if DEBUG
    func resetForTests() {
        box = FinderLaunchPending()
        generation = 0
    }
    #endif
}
