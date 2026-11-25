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
        let toast = "已保存新照片，原片保留"
        let title = "编辑后的照片"
        let failPrefix = "未能写入相册"
        expect(toast.contains(failPrefix) == false, "success toast must not look like a failure")
        expect(title == "编辑后的照片", "editor title copy changed")

        expect(PhotoLibrarySaveState.savedCopy.afterUserEdit() == .idle, "later edits must clear savedCopy")
        expect(PhotoLibrarySaveState.failed.afterUserEdit() == .idle, "later edits must clear a failed save state")
        expect(PhotoLibrarySaveState.idle.afterUserEdit() == .idle, "idle stays idle")

        // Processing, success, and failure are mutually exclusive: a save in flight hides both banners.
        expect(EditorPrompt.current(isExporting: true, save: .savedCopy) == .processing, "export must hide a previous success")
        expect(EditorPrompt.current(isExporting: true, save: .failed) == .processing, "export must hide a previous failure")
        expect(EditorPrompt.current(isExporting: true, save: .idle) == .processing, "export shows processing")
        expect(EditorPrompt.current(isExporting: false, save: .savedCopy) == .success, "saved copy shows success")
        expect(EditorPrompt.current(isExporting: false, save: .failed) == .failure, "failed save shows failure")
        expect(EditorPrompt.current(isExporting: false, save: .idle) == nil, "idle shows no notice")

        if notes.isEmpty {
            print("PHOTO SAVE STATE PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("PHOTO SAVE STATE FAILED \(notes.count)")
        }
    }
}
