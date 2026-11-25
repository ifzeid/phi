import Foundation

@main
enum AlbumDeleteSyncTests {
    static func main() {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        let locals: [(id: String, photosIdentifier: String?)] = [
            ("local-only", nil),
            ("synced-a", "photo-a"),
            ("synced-b", "photo-b"),
            ("unrelated", "photo-c"),
        ]

        // Mixed selection: user deletes a library row; matching local record must be listed.
        let synced = AlbumDeleteSync.localIDs(matching: ["photo-a", "photo-b"], records: locals)
        expect(Set(synced) == Set(["synced-a", "synced-b"]), "synced delete IDs \(synced)")

        // Cancel must not clear records.
        expect(AlbumDeleteSync.shouldClearLocalRecords(photosConfirmed: false, cancelled: true) == false,
               "cancel should keep local records")
        expect(AlbumDeleteSync.shouldClearLocalRecords(photosConfirmed: true, cancelled: true) == false,
               "Photos cancel after a confirmed flag still must not clear")
        expect(AlbumDeleteSync.shouldClearLocalRecords(photosConfirmed: true, cancelled: false),
               "successful Photos delete should clear matching locals")

        let cancelledIDs = AlbumDeleteSync.shouldClearLocalRecords(photosConfirmed: false, cancelled: true)
            ? AlbumDeleteSync.localIDs(matching: ["photo-a"], records: locals)
            : []
        expect(cancelledIDs.isEmpty, "mixed-selection cancel must not yield IDs to remove")

        let localOnly = AlbumDeleteSync.localIDs(matching: ["missing"], records: locals)
        expect(localOnly.isEmpty, "unknown photosIdentifier should not remove locals")

        if notes.isEmpty {
            print("ALBUM DELETE SYNC PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("ALBUM DELETE SYNC FAILED \(notes.count)")
        }
    }
}
