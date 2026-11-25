import Foundation

/// Pure routing for the “打开取景” Action Button / Shortcuts entry.
/// No shutter, no camera reset: only decide how to reveal the finder from the current surface.
enum FinderLaunchPlanner {
    struct Surface: Equatable {
        var editorOpen: Bool
        var editorDirty: Bool
        var albumOpen: Bool
        var settingsOpen: Bool
        var rawMenuOpen: Bool

        static let finder = Surface(
            editorOpen: false,
            editorDirty: false,
            albumOpen: false,
            settingsOpen: false,
            rawMenuOpen: false
        )
    }

    enum Action: Equatable {
        /// Already on the finder with no overlay to dismiss.
        case alreadyOnFinder
        /// Close in-finder chrome (settings card and/or RAW menu) without touching the camera session.
        case closeOverlays(settings: Bool, rawMenu: Bool)
        /// Editor has no unsaved edits: dismiss it and return to the finder.
        case dismissEditor
        /// Editor is dirty: show the existing discard confirmation; cancel stays in the editor.
        case confirmDiscard
        /// Close the album cover. Any pending “open this shot in the editor” is dropped so the intent cannot silently enter develop.
        case dismissAlbum
    }

    /// Editor takes priority over album. Overlays under an editor are also closed, but the camera is never reset.
    static func actions(for surface: Surface) -> [Action] {
        var result: [Action] = []
        if surface.editorOpen {
            result.append(surface.editorDirty ? .confirmDiscard : .dismissEditor)
        } else if surface.albumOpen {
            result.append(.dismissAlbum)
        }
        if surface.settingsOpen || surface.rawMenuOpen {
            result.append(.closeOverlays(settings: surface.settingsOpen, rawMenu: surface.rawMenuOpen))
        }
        if result.isEmpty {
            result.append(.alreadyOnFinder)
        }
        return result
    }
}

/// Holds a single “open the finder” request until the UI can apply it (cold start) or immediately (hot/foreground).
struct FinderLaunchPending: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isPending = false

    mutating func request() {
        isPending = true
        generation &+= 1
    }

    /// True the first time a ready surface consumes this request. A second take does not re-apply a stale launch.
    mutating func take() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }
}
