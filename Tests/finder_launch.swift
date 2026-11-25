import Foundation

@main
enum FinderLaunchTests {
    static func main() {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        // Already on the finder: no work, and never a capture.
        expect(
            FinderLaunchPlanner.actions(for: .finder) == [.alreadyOnFinder],
            "bare finder should stay on the finder"
        )

        // Settings / raw menu close without resetting the camera.
        let settings = FinderLaunchPlanner.Surface(
            editorOpen: false, editorDirty: false, albumOpen: false, settingsOpen: true, rawMenuOpen: false
        )
        expect(
            FinderLaunchPlanner.actions(for: settings) == [.closeOverlays(settings: true, rawMenu: false)],
            "open settings should close the card only"
        )
        let raw = FinderLaunchPlanner.Surface(
            editorOpen: false, editorDirty: false, albumOpen: false, settingsOpen: false, rawMenuOpen: true
        )
        expect(
            FinderLaunchPlanner.actions(for: raw) == [.closeOverlays(settings: false, rawMenu: true)],
            "open RAW menu should close the menu only"
        )
        let both = FinderLaunchPlanner.Surface(
            editorOpen: false, editorDirty: false, albumOpen: false, settingsOpen: true, rawMenuOpen: true
        )
        expect(
            FinderLaunchPlanner.actions(for: both) == [.closeOverlays(settings: true, rawMenu: true)],
            "settings and RAW menu should both close"
        )

        // Clean editor returns to the finder; dirty editor uses the existing confirm and must not dismiss.
        let clean = FinderLaunchPlanner.Surface(
            editorOpen: true, editorDirty: false, albumOpen: false, settingsOpen: false, rawMenuOpen: false
        )
        expect(
            FinderLaunchPlanner.actions(for: clean) == [.dismissEditor],
            "clean editor should dismiss"
        )
        let dirty = FinderLaunchPlanner.Surface(
            editorOpen: true, editorDirty: true, albumOpen: false, settingsOpen: false, rawMenuOpen: false
        )
        expect(
            FinderLaunchPlanner.actions(for: dirty) == [.confirmDiscard],
            "dirty editor must confirm and must not silently dismiss"
        )
        let dirtyWithChrome = FinderLaunchPlanner.Surface(
            editorOpen: true, editorDirty: true, albumOpen: false, settingsOpen: true, rawMenuOpen: true
        )
        expect(
            FinderLaunchPlanner.actions(for: dirtyWithChrome) == [
                .confirmDiscard,
                .closeOverlays(settings: true, rawMenu: true)
            ],
            "dirty editor keeps confirm first and still closes finder chrome underneath"
        )
        let cleanWithSettings = FinderLaunchPlanner.Surface(
            editorOpen: true, editorDirty: false, albumOpen: true, settingsOpen: true, rawMenuOpen: false
        )
        expect(
            FinderLaunchPlanner.actions(for: cleanWithSettings) == [
                .dismissEditor,
                .closeOverlays(settings: true, rawMenu: false)
            ],
            "editor outranks album; clean editor dismisses without a discard prompt"
        )

        // Album alone is dismissed; a pending develop must not be treated as an editor here (planner has no develop flag).
        let album = FinderLaunchPlanner.Surface(
            editorOpen: false, editorDirty: false, albumOpen: true, settingsOpen: false, rawMenuOpen: false
        )
        expect(
            FinderLaunchPlanner.actions(for: album) == [.dismissAlbum],
            "album should close back to the finder"
        )
        let albumSettings = FinderLaunchPlanner.Surface(
            editorOpen: false, editorDirty: false, albumOpen: true, settingsOpen: true, rawMenuOpen: false
        )
        expect(
            FinderLaunchPlanner.actions(for: albumSettings) == [
                .dismissAlbum,
                .closeOverlays(settings: true, rawMenu: false)
            ],
            "album plus settings should close both"
        )

        // Pending box: cold start (request before a consumer exists) and no double consume.
        var pending = FinderLaunchPending()
        expect(pending.isPending == false && pending.generation == 0, "fresh pending is empty")
        expect(pending.take() == false, "take on empty should fail")
        pending.request()
        expect(pending.isPending && pending.generation == 1, "cold-start request stays pending")
        let first = pending.take()
        expect(first && pending.isPending == false && pending.generation == 1, "first take consumes but keeps generation")
        expect(pending.take() == false, "second take must not replay a consumed cold start")
        pending.request()
        expect(pending.isPending && pending.generation == 2, "a later request is a new generation")
        expect(pending.take() && pending.isPending == false, "hot/foreground consume of the second request")

        // Wrap-safe generation increment is not tested at UInt64.max; two requests is enough for routing.

        if notes.isEmpty {
            print("FINDER LAUNCH PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("FINDER LAUNCH FAILED \(notes.count)")
        }
    }
}
