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
    @Published private(set) var grainStyle: GrainStyle
    @Published var processSession: ProcessSession?
    @Published private(set) var hasDevelopBase = false

    private var cancellables = Set<AnyCancellable>()
    private let pendingLock = NSLock()
    private var pending = PendingCapture()

    override init() {
        grainStyle = GrainStyle.stored(UserDefaults.standard.string(forKey: StillArchive.grainStyleKey))
        super.init()
        captureCount = UserDefaults.standard.integer(forKey: StillArchive.countKey)
        canRetryPhotoSave = UserDefaults.standard.string(forKey: StillArchive.lastPathKey) != nil
            && UserDefaults.standard.bool(forKey: StillArchive.lastSavedKey) == false
        hasDevelopBase = StillArchive.loadBasePreview() != nil
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

    func setGrainStyle(_ style: GrainStyle) {
        grainStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: StillArchive.grainStyleKey)
    }

    /// Opens the last developed still, or the bundled sample when nothing has been captured.
    func openProcess() {
        if let base = StillArchive.loadBasePreview() {
            let recipe = StillArchive.loadRecipe() ?? StillRecipe(exposureEV: 0, style: grainStyle, originalWasRaw: false)
            present(
                base: base,
                recipe: recipe,
                isSample: false,
                status: lastSavedNote
            )
            return
        }
        openSample()
    }

    func openSample() {
        guard let image = UIImage(named: "SampleStill"), let base = StillPipeline.normalizedCGImage(from: image) else {
            camera.statusMessage = "样张没有装进 App。Sample still is missing."
            return
        }
        present(
            base: base,
            recipe: StillRecipe(exposureEV: 0, style: grainStyle, originalWasRaw: false),
            isSample: true,
            status: "样张，不是这次拍摄。Sample still, not a capture."
        )
    }

    func dismissProcess() {
        if let session = processSession, session.isSample == false {
            StillArchive.writeRecipe(StillRecipe(
                exposureEV: session.exposureEV,
                style: session.style,
                originalWasRaw: session.originalWasRaw
            ))
        }
        processSession = nil
    }

    func exportDeveloped(_ session: ProcessSession) async {
        await MainActor.run { session.isExporting = true }
        let base = session.base
        let ev = session.exposureEV
        let style = session.style
        let isSample = session.isSample
        let originalWasRaw = session.originalWasRaw
        let rendered = await Task.detached(priority: .userInitiated) {
            StillPipeline.render(base, exposureEV: ev, style: style, maxSide: nil)
        }.value
        guard let rendered, let encoded = StillPipeline.encodeDeveloped(rendered) else {
            await MainActor.run {
                session.isExporting = false
                session.status = "没有导出处理图。Couldn't render the still."
            }
            return
        }
        let stamp = Self.fileStamp()
        let filename = "PHI-\(style.title)-\(stamp).\(encoded.ext)"
        do {
            try await PhotoLibrary.save(data: encoded.data, typeIdentifier: encoded.uti, filename: filename)
            let note: String
            if isSample {
                note = "已把样张的处理图存入相册。Saved the sample develop."
            } else if originalWasRaw {
                note = "已另存处理图。RAW 原片没有改动。Saved a develop. The RAW file was left as captured."
            } else {
                note = "已另存处理图，没有覆盖拍摄原片。Saved a separate develop."
            }
            await MainActor.run {
                session.isExporting = false
                session.status = note
                self.lastSavedNote = note
            }
        } catch PhotoSaveError.notAuthorized {
            await MainActor.run {
                session.isExporting = false
                session.status = "没有相册权限，处理图还没写入。Allow Photos access to save it."
                self.camera.statusMessage = "没有相册权限。Allow Photos access in Settings."
            }
        } catch {
            await MainActor.run {
                session.isExporting = false
                session.status = "处理图没有写入相册。Couldn't save the develop."
            }
        }
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
        let style = grainStyle

        DispatchQueue.global(qos: .userInitiated).async {
            let url = try? StillArchive.write(data: payload, ext: ext)
            let base = preview.flatMap { StillPipeline.normalizedCGImage(from: $0) }
            if let base {
                try? StillArchive.writeBasePreview(base)
            }
            let recipe = StillRecipe(exposureEV: 0, style: style, originalWasRaw: savedRaw)
            if base != nil {
                StillArchive.writeRecipe(recipe)
            }
            let thumbSource = base.flatMap { StillPipeline.render($0, exposureEV: 0, style: style, maxSide: 900) }
            let thumb = thumbSource.map { StillArchive.thumbnail(from: UIImage(cgImage: $0)) } ?? preview.map { StillArchive.thumbnail(from: $0) }
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
                if usedRaw && !savedRaw {
                    self.camera.statusMessage = "这张没能存成 RAW，已改存 \(codec)。"
                }
                if let base {
                    self.hasDevelopBase = true
                    self.present(
                        base: base,
                        recipe: recipe,
                        isSample: false,
                        status: self.camera.statusMessage
                    )
                }
                guard let url else {
                    self.camera.statusMessage = "照片没有留在 App 内。Couldn't keep the still in the app."
                    return
                }
                UserDefaults.standard.set(url.path, forKey: StillArchive.lastPathKey)
                UserDefaults.standard.set(uti, forKey: StillArchive.lastUTIKey)
                UserDefaults.standard.set(false, forKey: StillArchive.lastSavedKey)
                self.canRetryPhotoSave = true
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
            await MainActor.run {
                self.lastSavedNote = note
                self.canRetryPhotoSave = false
                UserDefaults.standard.set(true, forKey: StillArchive.lastSavedKey)
                if self.camera.statusMessage?.contains("相册") == true {
                    self.camera.statusMessage = nil
                }
                if self.processSession?.isSample == false {
                    self.processSession?.status = note
                }
            }
        } catch PhotoSaveError.notAuthorized {
            await MainActor.run {
                self.canRetryPhotoSave = true
                self.camera.statusMessage = "没有相册权限，照片留在 App 内。Allow Photos access to save it."
                if self.processSession?.isSample == false {
                    self.processSession?.status = "原片还没写入相册。Allow Photos access, then retry the original."
                }
            }
        } catch {
            await MainActor.run {
                self.canRetryPhotoSave = true
                self.camera.statusMessage = "未能写入相册，照片留在 App 内。Couldn't save to Photos."
            }
        }
    }

    private func present(base: CGImage, recipe: StillRecipe, isSample: Bool, status: String?) {
        let session = ProcessSession(
            base: base,
            exposureEV: recipe.exposureEV,
            style: recipe.style,
            isSample: isSample,
            originalWasRaw: recipe.originalWasRaw,
            status: status
        )
        if isSample == false {
            session.onPreview = { [weak self] image in
                self?.storeThumbnail(image)
                self?.persist(session)
            }
            if session.status == nil {
                session.status = recipe.originalWasRaw
                    ? "RAW 原片单独保存，这里只改处理图。The RAW file stays as captured."
                    : "导出时另存处理图，不覆盖刚拍的原片。"
            }
        }
        session.schedule()
        processSession = session
    }

    private func persist(_ session: ProcessSession) {
        guard session.isSample == false else { return }
        StillArchive.writeRecipe(StillRecipe(
            exposureEV: session.exposureEV,
            style: session.style,
            originalWasRaw: session.originalWasRaw
        ))
    }

    private func storeThumbnail(_ image: UIImage) {
        let thumb = StillArchive.thumbnail(from: image)
        thumbnail = thumb
        if let jpeg = thumb.jpegData(compressionQuality: 0.82) {
            try? jpeg.write(to: StillArchive.thumbnailURL, options: .atomic)
        }
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
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
