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



/// In-app editor notice. Processing, success, and failure are mutually exclusive:
/// a save in flight never shows the previous "already saved" or failure banner.
enum EditorPrompt: Equatable {
    case processing
    case success
    case failure

    static func current(isExporting: Bool, save: PhotoLibrarySaveState) -> EditorPrompt? {
        if isExporting { return .processing }
        switch save {
        case .savedCopy: return .success
        case .failed: return .failure
        case .idle: return nil
        }
    }
}
