import Foundation

/// Outcome of writing a developed still (or a retried original) to the Photos library.
/// Editor chrome keys off this instead of matching localized status strings.
enum PhotoLibrarySaveState: Equatable {
    case idle
    case savedCopy
    case failed
}

extension PhotoLibrarySaveState {
    /// A later edit is no longer the copy that was just saved, or the attempt that failed.
    func afterUserEdit() -> PhotoLibrarySaveState { .idle }
}

