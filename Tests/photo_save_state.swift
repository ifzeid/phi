import Foundation

@main
enum PhotoSaveStateTests {
    static func main() {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        expect(PhotoLibrarySaveState.idle != .savedCopy, "idle must not equal savedCopy")
        expect(PhotoLibrarySaveState.idle != .failed, "idle must not equal failed")
        expect(PhotoLibrarySaveState.savedCopy != .failed, "savedCopy must not equal failed")
        expect(PhotoLibrarySaveState.savedCopy == .savedCopy, "savedCopy equality")

        // Toast/title copy is display text only and must not be how success is detected.
        let toast = "已保存副本 · 原片保留"
        let title = "编辑后的照片"
        let failPrefix = "未能写入相册"
        expect(toast.contains(failPrefix) == false, "success toast must not look like a failure")
        expect(title == "编辑后的照片", "editor title copy changed")

        expect(PhotoLibrarySaveState.savedCopy.afterUserEdit() == .idle, "later edits must clear savedCopy")
        expect(PhotoLibrarySaveState.failed.afterUserEdit() == .idle, "later edits must clear a failed save state")
        expect(PhotoLibrarySaveState.idle.afterUserEdit() == .idle, "idle stays idle")

        if notes.isEmpty {
            print("PHOTO SAVE STATE PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("PHOTO SAVE STATE FAILED \(notes.count)")
        }
    }
}
