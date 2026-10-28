import AVFoundation
import Combine
import UIKit
import UniformTypeIdentifiers

/// Builds each still at `.speed`, prefers Bayer RAW, and saves it to Photos.
final class CaptureService: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let camera = CameraSession()

    @Published private(set) var isCapturing = false
    @Published private(set) var shutterTick = 0
    @Published private(set) var captureCount = 0
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var lastSavedNote: String?
    @Published private(set) var canRetryPhotoSave = false

    private var cancellables = Set<AnyCancellable>()
    private let pendingLock = NSLock()
    private var pending = PendingCapture()

    override init() {
        super.init()
        captureCount = UserDefaults.standard.integer(forKey: StillArchive.countKey)
        canRetryPhotoSave = UserDefaults.standard.string(forKey: StillArchive.lastPathKey) != nil
            && UserDefaults.standard.bool(forKey: StillArchive.lastSavedKey) == false
        if let data = try? Data(contentsOf: StillArchive.thumbnailURL), let image = UIImage(data: data) {
            thumbnail = image
        }
        camera.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        shutterTick += 1
        camera.statusMessage = nil
        resetPending()
        camera.capturePhoto(delegate: self, note: { [weak self] usingRaw, codec in
            self?.noteSettings(usingRaw: usingRaw, codec: codec)
        }, completion: { [weak self] started in
            if !started {
                self?.isCapturing = false
            }
        })
    }

    func retryPhotoSave() {
        let status = PhotoLibrary.addOnlyStatus()
        if status == .denied || status == .restricted {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
            return
        }
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: StillArchive.lastPathKey),
              let uti = defaults.string(forKey: StillArchive.lastUTIKey) else {
            camera.statusMessage = "没有可重试的照片。"
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            camera.statusMessage = "App 内的照片文件不在了。"
            canRetryPhotoSave = false
            return
        }
        Task { await self.saveToPhotos(data: data, uti: uti, filename: url.lastPathComponent, announceFallback: false) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if let error {
            pending.error = error.localizedDescription
            return
        }
        if photo.isRawPhoto {
            pending.raw = photo.fileDataRepresentation()
        } else {
            pending.processed = photo.fileDataRepresentation()
            if let data = pending.processed, let image = UIImage(data: data) {
                pending.preview = image
            }
        }
        if pending.preview == nil, let preview = photo.previewCGImageRepresentation() ?? photo.cgImageRepresentation() {
            pending.preview = UIImage(cgImage: preview)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        pendingLock.lock()
        if let error {
            pending.error = error.localizedDescription
        }
        let snapshot = pending
        pending = PendingCapture()
        pendingLock.unlock()
        DispatchQueue.main.async {
            self.finish(snapshot)
        }
    }

    private func finish(_ snapshot: PendingCapture) {
        let payload = snapshot.raw ?? snapshot.processed
        guard let payload else {
            isCapturing = false
            camera.statusMessage = snapshot.error ?? "没有得到照片数据。No photo data."
            return
        }

        let savedRaw = snapshot.raw != nil
        let ext = savedRaw ? "dng" : (snapshot.codec == "HEIC" ? "heic" : "jpg")
        let uti = savedRaw
            ? (UTType(filenameExtension: "dng")?.identifier ?? "com.adobe.raw-image")
            : (snapshot.codec == "HEIC" ? UTType.heic.identifier : UTType.jpeg.identifier)
        let preview = snapshot.preview
        let codec = snapshot.codec
        let usedRaw = snapshot.usedRaw

        DispatchQueue.global(qos: .userInitiated).async {
            let url = try? StillArchive.write(data: payload, ext: ext)
            let thumb = preview.map { StillArchive.thumbnail(from: $0) }
            let jpeg = thumb?.jpegData(compressionQuality: 0.82)
            DispatchQueue.main.async {
                self.isCapturing = false
                if let thumb {
                    self.thumbnail = thumb
                }
                if let jpeg {
                    try? jpeg.write(to: StillArchive.thumbnailURL, options: .atomic)
                }
                self.captureCount += 1
                UserDefaults.standard.set(self.captureCount, forKey: StillArchive.countKey)
                guard let url else {
                    self.camera.statusMessage = "照片没有留在 App 内。Couldn't keep the still in the app."
                    return
                }
                UserDefaults.standard.set(url.path, forKey: StillArchive.lastPathKey)
                UserDefaults.standard.set(uti, forKey: StillArchive.lastUTIKey)
                UserDefaults.standard.set(false, forKey: StillArchive.lastSavedKey)
                self.canRetryPhotoSave = true
                if usedRaw && !savedRaw {
                    self.camera.statusMessage = "这张没能存成 RAW，已改存 \(codec)。"
                }
                Task {
                    await self.saveToPhotos(
                        data: payload,
                        uti: uti,
                        filename: url.lastPathComponent,
                        announceFallback: usedRaw && !savedRaw
                    )
                }
            }
        }
    }

    private func saveToPhotos(data: Data, uti: String, filename: String, announceFallback: Bool) async {
        do {
            try await PhotoLibrary.save(data: data, typeIdentifier: uti, filename: filename)
            let note: String
            if uti.contains("raw") || filename.lowercased().hasSuffix(".dng") {
                note = "已保存 RAW（DNG）到相册。Saved a Bayer RAW still."
            } else if announceFallback {
                note = "RAW 没有写入，已改存处理过的静帧。Saved the processed still instead of RAW."
            } else {
                note = "已保存到相册。Saved to Photos."
            }
            lastSavedNote = note
            canRetryPhotoSave = false
            UserDefaults.standard.set(true, forKey: StillArchive.lastSavedKey)
            if camera.statusMessage?.contains("相册") == true {
                camera.statusMessage = nil
            }
        } catch PhotoSaveError.notAuthorized {
            canRetryPhotoSave = true
            camera.statusMessage = "没有相册权限，照片留在 App 内。Allow Photos access to save it."
        } catch {
            canRetryPhotoSave = true
            camera.statusMessage = "未能写入相册，照片留在 App 内。Couldn't save to Photos."
        }
    }

    private func resetPending() {
        pendingLock.lock()
        pending = PendingCapture()
        pendingLock.unlock()
    }

    private func noteSettings(usingRaw: Bool, codec: String) {
        pendingLock.lock()
        pending.usedRaw = usingRaw
        pending.codec = codec
        pendingLock.unlock()
    }
}

private struct PendingCapture {
    var raw: Data?
    var processed: Data?
    var preview: UIImage?
    var usedRaw = false
    var codec = "JPEG"
    var error: String?
}
