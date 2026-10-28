import AVFoundation
import Combine
import UIKit
import UniformTypeIdentifiers

/// Builds each still at `.speed`. JPEG+RAW is the default; RAW is skipped when this stop cannot deliver Bayer.
final class CaptureService: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let camera = CameraSession()

    @Published private(set) var isCapturing = false
    @Published private(set) var shutterTick = 0
    @Published private(set) var captureCount = 0
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var lastSavedNote: String?
    @Published private(set) var canRetryPhotoSave = false
    @Published private(set) var grainStyle: GrainStyle
    @Published private(set) var captureFormat: CaptureFormat = .jpegAndRaw
    @Published var processSession: ProcessSession?
    @Published private(set) var hasDevelopBase = false

    private var cancellables = Set<AnyCancellable>()
    private let pendingLock = NSLock()
    private var pending = PendingCapture()

    override init() {
        grainStyle = GrainStyle.stored(UserDefaults.standard.string(forKey: StillArchive.grainStyleKey))
        super.init()
        captureFormat = CaptureFormat.stored(UserDefaults.standard.string(forKey: CaptureFormat.storageKey))
        camera.setCaptureFormat(captureFormat)
        captureCount = UserDefaults.standard.integer(forKey: StillArchive.countKey)
        let unfinished = UserDefaults.standard.bool(forKey: StillArchive.lastSavedKey) == false
        canRetryPhotoSave = unfinished && (StillArchive.loadLastRecord()?.files.isEmpty == false
            || UserDefaults.standard.string(forKey: StillArchive.lastPathKey) != nil)
        hasDevelopBase = FileManager.default.fileExists(atPath: StillArchive.basePreviewURL.path)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let data = try? Data(contentsOf: StillArchive.thumbnailURL),
                  let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.thumbnail = image
            }
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

    func setCaptureFormat(_ format: CaptureFormat) {
        captureFormat = format
        UserDefaults.standard.set(format.rawValue, forKey: CaptureFormat.storageKey)
        camera.setCaptureFormat(format)
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
        let format = captureFormat
        camera.capturePhoto(format: format, delegate: self, note: { [weak self] usingRaw, codec in
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
        guard let record = StillArchive.loadLastRecord() ?? Self.legacyRecord(),
              let payloads = record.payloads() else {
            camera.statusMessage = "没有可重试的照片。"
            canRetryPhotoSave = false
            return
        }
        Task { await self.saveToPhotos(payloads, skippedRaw: false) }
    }

    private static func legacyRecord() -> LibraryRecord? {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: StillArchive.lastPathKey),
              let uti = defaults.string(forKey: StillArchive.lastUTIKey) else { return nil }
        let url = URL(fileURLWithPath: path)
        return LibraryRecord(files: [
            LibraryRecord.File(path: path, typeIdentifier: uti, filename: url.lastPathComponent, alternate: false)
        ])
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
        let format = captureFormat
        let hasRaw = snapshot.raw != nil
        let hasProcessed = snapshot.processed != nil
        guard hasRaw || hasProcessed else {
            isCapturing = false
            camera.statusMessage = snapshot.error ?? "没有得到照片数据。No photo data."
            return
        }

        let codec = snapshot.codec
        let processedExt = codec == "HEIC" ? "heic" : "jpg"
        let processedUTI = codec == "HEIC" ? UTType.heic.identifier : UTType.jpeg.identifier
        let rawUTI = UTType(filenameExtension: "dng")?.identifier ?? "com.adobe.raw-image"
        let saveRaw = format.wantsRaw && hasRaw
        let saveProcessed = format != .raw || saveRaw == false
        let skippedRaw = format.wantsRaw && saveRaw == false && hasProcessed
        let preview = snapshot.preview
        let style = grainStyle
        let rawData = snapshot.raw
        let processedData = snapshot.processed

        DispatchQueue.global(qos: .userInitiated).async {
            let stamp = StillArchive.stamp()
            var files: [LibraryRecord.File] = []
            var payloads: [LibraryPayload] = []
            if saveProcessed, let processedData,
               let url = try? StillArchive.write(data: processedData, stamp: stamp, ext: processedExt) {
                let file = LibraryRecord.File(
                    path: url.path,
                    typeIdentifier: processedUTI,
                    filename: url.lastPathComponent,
                    alternate: false
                )
                files.append(file)
                payloads.append(LibraryPayload(
                    data: processedData,
                    typeIdentifier: processedUTI,
                    filename: file.filename,
                    alternate: false
                ))
            }
            if saveRaw, let rawData,
               let url = try? StillArchive.write(data: rawData, stamp: stamp, ext: "dng") {
                let alternate = files.isEmpty == false
                let file = LibraryRecord.File(
                    path: url.path,
                    typeIdentifier: rawUTI,
                    filename: url.lastPathComponent,
                    alternate: alternate
                )
                files.append(file)
                payloads.append(LibraryPayload(
                    data: rawData,
                    typeIdentifier: rawUTI,
                    filename: file.filename,
                    alternate: alternate
                ))
            }
            let base = preview.flatMap { StillPipeline.normalizedCGImage(from: $0) }
            if let base {
                try? StillArchive.writeBasePreview(base)
            }
            let keptRaw = files.contains { $0.filename.lowercased().hasSuffix(".dng") }
            let recipe = StillRecipe(exposureEV: 0, style: style, originalWasRaw: keptRaw)
            if base != nil {
                StillArchive.writeRecipe(recipe)
            }
            let thumbSource = base.flatMap { StillPipeline.render($0, exposureEV: 0, style: style, maxSide: 900) }
            let thumb = thumbSource.map { StillArchive.thumbnail(from: UIImage(cgImage: $0)) } ?? preview.map { StillArchive.thumbnail(from: $0) }
            let jpeg = thumb?.jpegData(compressionQuality: 0.82)
            let captureStatus = Self.captureStatus(codec: codec, savedRaw: keptRaw, savedProcessed: files.contains { $0.alternate == false && $0.filename.lowercased().hasSuffix(".dng") == false }, skippedRaw: skippedRaw)
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
                if skippedRaw {
                    let toast = "这一档不能保存 RAW，已改存 \(codec)。"
                    self.camera.statusMessage = toast
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        if self.camera.statusMessage == toast {
                            self.camera.statusMessage = nil
                        }
                    }
                }
                if let base {
                    self.hasDevelopBase = true
                    self.present(base: base, recipe: recipe, isSample: false, status: captureStatus)
                }
                guard files.isEmpty == false else {
                    self.camera.statusMessage = "照片没有留在 App 内。Couldn't keep the still in the app."
                    return
                }
                let record = LibraryRecord(files: files)
                StillArchive.storeLastRecord(record)
                if let primary = files.first(where: { $0.alternate == false }) ?? files.first {
                    UserDefaults.standard.set(primary.path, forKey: StillArchive.lastPathKey)
                    UserDefaults.standard.set(primary.typeIdentifier, forKey: StillArchive.lastUTIKey)
                }
                UserDefaults.standard.set(false, forKey: StillArchive.lastSavedKey)
                self.canRetryPhotoSave = true
                Task {
                    await self.saveToPhotos(payloads, skippedRaw: skippedRaw)
                }
            }
        }
    }

    private static func captureStatus(codec: String, savedRaw: Bool, savedProcessed: Bool, skippedRaw: Bool) -> String? {
        if skippedRaw {
            return "这一档不能保存 RAW，已改存 \(codec)。Saved \(codec) instead."
        }
        if savedRaw && savedProcessed {
            return "RAW 和 \(codec) 会一起写入相册。这里只改处理图，不覆盖原片。"
        }
        if savedRaw {
            return "RAW 原片单独保存，这里只改处理图。The RAW file stays as captured."
        }
        return nil
    }

    private func saveToPhotos(_ payloads: [LibraryPayload], skippedRaw: Bool) async {
        do {
            try await PhotoLibrary.save(payloads: payloads)
            let note = Self.savedNote(payloads: payloads, skippedRaw: skippedRaw)
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

    private static func savedNote(payloads: [LibraryPayload], skippedRaw: Bool) -> String {
        let rawFile = payloads.first { $0.filename.lowercased().hasSuffix(".dng") }
        let processed = payloads.first { $0.filename.lowercased().hasSuffix(".dng") == false }
        let processedName = processed?.filename.lowercased().hasSuffix(".heic") == true ? "HEIC" : "JPEG"
        if skippedRaw {
            return "这一档不能保存 RAW，已改存 \(processedName)。Saved \(processedName) instead."
        }
        if rawFile != nil, processed != nil {
            return "已保存 RAW 和 \(processedName) 到相册。Saved RAW and \(processedName) together."
        }
        if rawFile != nil {
            return "已保存 RAW（DNG）到相册。Saved a Bayer RAW still."
        }
        return "已保存到相册。Saved to Photos."
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
