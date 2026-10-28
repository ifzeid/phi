import AVFoundation
import Combine
import CoreLocation
import os
import Photos
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
    @Published private(set) var captureFormat: CaptureFormat = .jpegAndRaw
    @Published private(set) var photoAspect: PhotoAspect = .threeByFour
    @Published var processSession: ProcessSession?
    @Published private(set) var hasDevelopBase = false
    @Published private(set) var albumRevision = 0

    private var cancellables = Set<AnyCancellable>()
    private let pendingLock = NSLock()
    private var pending = PendingCapture()

    override init() {
        super.init()
        captureFormat = CaptureFormat.stored(UserDefaults.standard.string(forKey: CaptureFormat.storageKey))
        photoAspect = PhotoAspect.stored(UserDefaults.standard.string(forKey: PhotoAspect.storageKey))
        camera.setCaptureFormat(captureFormat)
        camera.setPhotoAspect(photoAspect)
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

    func setCaptureFormat(_ format: CaptureFormat) {
        captureFormat = format
        UserDefaults.standard.set(format.rawValue, forKey: CaptureFormat.storageKey)
        camera.setCaptureFormat(format)
    }

    func setPhotoAspect(_ aspect: PhotoAspect) {
        photoAspect = aspect
        UserDefaults.standard.set(aspect.rawValue, forKey: PhotoAspect.storageKey)
        camera.setPhotoAspect(aspect)
    }

    func openLocalShot(id: String) {
        guard let shot = PhiLocalShots.shot(id: id) else { return }
        let dngPath = shot.files.first { $0.filename.lowercased().hasSuffix(".dng") }?.path
        let displayPath = (shot.files.first { $0.alternate == false } ?? shot.files.first)?.path
        let hasRaw = shot.hasRaw
        let aspect = shot.aspect.flatMap(PhotoAspect.init(rawValue:)) ?? photoAspect
        Task {
            let dng = dngPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            if let dng, let preview = RawDevelop.image(
                dng: dng,
                exposureEV: 0,
                style: .off,
                look: .none,
                halo: false,
                aspect: aspect,
                maxSide: 1600,
                draft: false
            ) {
                let metadata = PhotoMetadata.properties(of: dng)
                await MainActor.run {
                    self.present(
                        base: preview,
                        recipe: StillRecipe(exposureEV: 0, style: .off, originalWasRaw: true),
                        isSample: false,
                        status: "从 App 内的 DNG 显影。",
                        sourceDNG: dng,
                        sourceMetadata: metadata,
                        aspect: aspect
                    )
                }
                return
            }
            if let displayPath, let data = try? Data(contentsOf: URL(fileURLWithPath: displayPath)), let image = UIImage(data: data) {
                await MainActor.run {
                    self.openDevelop(image: image, originalWasRaw: hasRaw)
                }
            }
        }
    }

    func retryLocalShot(id: String) {
        guard let shot = PhiLocalShots.shot(id: id), let payloads = LibraryRecord(files: shot.files).payloads() else {
            camera.statusMessage = "App 内的照片文件不在了。"
            return
        }
        canRetryPhotoSave = true
        Task {
            await self.saveToPhotos(payloads, skippedRaw: false, croppedAspect: false, localShotID: id)
        }
    }

    /// Opens Process for a still chosen in the PHI album. The library original is not overwritten.
    func openLibraryShot(localIdentifier: String) {
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        guard let asset else {
            camera.statusMessage = "这张照片不在 PHI 相册里。"
            return
        }
        let aspect = PhiShotIndex.aspect(for: localIdentifier) ?? photoAspect
        let rawShot = PhiRawAsset.contains(asset)
        Task {
            let dng = await PhotoLibrary.loadAlternateData(for: asset)
            if let dng, let preview = RawDevelop.image(
                dng: dng,
                exposureEV: 0,
                style: .off,
                look: .none,
                halo: false,
                aspect: aspect,
                maxSide: 1600,
                draft: false
            ) {
                let metadata = PhotoMetadata.properties(of: dng)
                await MainActor.run {
                    self.present(
                        base: preview,
                        recipe: StillRecipe(exposureEV: 0, style: .off, originalWasRaw: true),
                        isSample: false,
                        status: "从相册里的 Bayer DNG 重新显影。",
                        sourceDNG: dng,
                        sourceMetadata: metadata,
                        aspect: aspect,
                        location: asset.location
                    )
                }
                return
            }
            if let image = await AlbumImage.load(asset, target: PHImageManagerMaximumSize, fast: false) {
                await MainActor.run {
                    self.openDevelop(image: image, originalWasRaw: rawShot)
                }
            }
        }
    }

    func openDevelop(image: UIImage, originalWasRaw: Bool) {
        guard let base = StillPipeline.normalizedCGImage(from: image) else {
            camera.statusMessage = "这张照片打不开。Couldn't open that still."
            return
        }
        let status = originalWasRaw
            ? "RAW 原片留在相册里，这里只改处理图。"
            : "导出时另存处理图，不覆盖相册里的原片。"
        present(
            base: base,
            recipe: StillRecipe(exposureEV: 0, style: .off, originalWasRaw: originalWasRaw),
            isSample: false,
            status: status
        )
    }

    /// Opens the last developed still, or the bundled sample when nothing has been captured.
    func openProcess() {
        if let base = StillArchive.loadBasePreview() {
            let recipe = StillArchive.loadRecipe() ?? StillRecipe(exposureEV: 0, style: .off, originalWasRaw: false)
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
            recipe: StillRecipe(exposureEV: 0, style: .off, originalWasRaw: false),
            isSample: true,
            status: "样张，不是这次拍摄。Sample still, not a capture."
        )
    }

    func dismissProcess() {
        if let session = processSession, session.isSample == false {
            StillArchive.writeRecipe(StillRecipe(
                exposureEV: session.exposureEV,
                style: session.style,
                originalWasRaw: session.originalWasRaw,
                colorLook: session.colorLook,
                halo: session.halo
            ))
        }
        processSession = nil
    }

    func exportDeveloped(_ session: ProcessSession) async {
        guard session.isSample || session.sourceDNG != nil else {
            await MainActor.run {
                session.isExporting = false
                session.status = "没有 Bayer RAW，不会把系统成片另存成 PHI。"
                session.developInfo = "来源 系统成片 · 未导出"
            }
            return
        }
        await MainActor.run { session.isExporting = true }
        let base = session.base
        let ev = session.exposureEV
        let style = session.style
        let isSample = session.isSample
        let originalWasRaw = session.originalWasRaw
        let dng = session.sourceDNG
        let metadata = session.sourceMetadata
        let aspect = session.framedAspect
        let look = session.colorLook
        let halo = session.halo
        let rendered = await Task.detached(priority: .userInitiated) {
            if let dng {
                return RawDevelop.image(
                    dng: dng,
                    exposureEV: ev,
                    style: style,
                    look: look,
                    halo: halo,
                    aspect: aspect,
                    maxSide: nil,
                    draft: false
                )
            }
            return StillPipeline.render(base, exposureEV: ev, style: style, maxSide: nil)
        }.value
        guard let rendered, let encoded = StillPipeline.encodeDeveloped(rendered, metadata: metadata) else {
            await MainActor.run {
                session.isExporting = false
                session.status = "没有导出处理图。Couldn't render the still."
            }
            return
        }
        let bytes = encoded.data.count
        let info = "DNG · \(rendered.width)×\(rendered.height) · HEIF \(RawDevelop.exportQuality) · \(bytes) bytes"
        Logger(subsystem: "com.zeid.phi", category: "develop").info("\(info, privacy: .public)")
        await MainActor.run { session.developInfo = info }
        let stamp = Self.fileStamp()
        let filename = "PHI-\(style.title)-\(stamp).\(encoded.ext)"
        do {
            try await PhotoLibrary.save(
                data: encoded.data,
                typeIdentifier: encoded.uti,
                filename: filename,
                location: session.captureLocation
            )
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
        } catch let error as PhotoSaveError {
            await MainActor.run {
                session.isExporting = false
                session.status = "处理图没有写入相册（\(error.codeLine)）。"
                session.developInfo = error.debugLine
            }
        } catch {
            let ns = error as NSError
            await MainActor.run {
                session.isExporting = false
                session.status = "处理图没有写入相册（\(ns.domain) \(ns.code)）。"
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
        Task { await self.saveToPhotos(payloads, skippedRaw: false, croppedAspect: false) }
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
        let packed = PhotoMetadata.fileData(from: photo, location: CaptureLocation.shared.location)
        if pending.location == nil {
            pending.location = CaptureLocation.shared.location
        }
        if photo.isRawPhoto {
            pending.raw = packed.data
            pending.metadata = packed.metadata
        } else {
            pending.processed = packed.data
            if pending.metadata == nil {
                pending.metadata = packed.metadata
            }
            if let data = packed.data, let image = UIImage(data: data) {
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

        let aspect = photoAspect
        let codec = snapshot.codec
        let rawUTI = UTType(filenameExtension: "dng")?.identifier ?? "com.adobe.raw-image"
        let saveRaw = format.wantsRaw && hasRaw && aspect.allowsRaw
        let skippedRaw = format.wantsRaw && saveRaw == false && hasProcessed
        let preview = snapshot.preview
        let rawData = snapshot.raw
        let originalProcessed = snapshot.processed
        let shotLocation = snapshot.location

        DispatchQueue.global(qos: .userInitiated).async {
            let spokenCodec = codec
            let processedExt = codec == "HEIC" ? "heic" : "jpg"
            let processedUTI = codec == "HEIC" ? UTType.heic.identifier : UTType.jpeg.identifier
            // Keep Apple's HEIF/JPEG bytes. Develop runs later, from the stored DNG, when the user taps 编辑.
            // Photos rejects a DNG that is the only resource, so RAW mode still pairs Apple's file as the primary.
            let stamp = StillArchive.stamp()
            var files: [LibraryRecord.File] = []
            var payloads: [LibraryPayload] = []
            if let originalProcessed,
               let url = try? StillArchive.write(data: originalProcessed, stamp: stamp, ext: processedExt) {
                let file = LibraryRecord.File(
                    path: url.path,
                    typeIdentifier: processedUTI,
                    filename: url.lastPathComponent,
                    alternate: false
                )
                files.append(file)
                payloads.append(LibraryPayload(
                    data: originalProcessed,
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
            let keptRaw = files.contains { $0.filename.lowercased().hasSuffix(".dng") }
            let sourceThumb = preview ?? originalProcessed.flatMap { UIImage(data: $0) }
            let thumbImage = sourceThumb.flatMap { image -> UIImage? in
                guard let cg = StillPipeline.normalizedCGImage(from: image) else { return image }
                return UIImage(cgImage: aspect.cropped(cg))
            }
            let thumb = thumbImage.map { StillArchive.thumbnail(from: $0) }
            let jpeg = thumb?.jpegData(compressionQuality: 0.82)
            let noRaw = format.wantsRaw && aspect.allowsRaw && rawData == nil
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
                if noRaw {
                    let toast = aspect.allowsRaw
                        ? "这一档没有 Bayer RAW。"
                        : "这一画幅按取景裁切，已改存 \(spokenCodec)。"
                    self.camera.statusMessage = toast
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        if self.camera.statusMessage == toast {
                            self.camera.statusMessage = nil
                        }
                    }
                }
                guard files.isEmpty == false else {
                    self.camera.statusMessage = "照片没有留在 App 内。Couldn't keep the still in the app."
                    return
                }
                let record = LibraryRecord(files: files)
                StillArchive.storeLastRecord(record)
                let localShot = PhiLocalShots.Shot(
                    id: stamp,
                    files: files,
                    hasRaw: keptRaw,
                    savedToPhotos: false,
                    photosIdentifier: nil,
                    saveFailed: nil,
                    aspect: aspect.rawValue
                )
                PhiLocalShots.remember(localShot)
                self.albumRevision += 1
                if let primary = files.first(where: { $0.alternate == false }) ?? files.first {
                    UserDefaults.standard.set(primary.path, forKey: StillArchive.lastPathKey)
                    UserDefaults.standard.set(primary.typeIdentifier, forKey: StillArchive.lastUTIKey)
                }
                UserDefaults.standard.set(false, forKey: StillArchive.lastSavedKey)
                self.canRetryPhotoSave = true
                Task {
                    await self.saveToPhotos(
                        payloads,
                        skippedRaw: skippedRaw,
                        croppedAspect: aspect != .threeByFour,
                        location: shotLocation,
                        aspect: aspect,
                        thumb: thumb,
                        localShotID: stamp
                    )
                }
            }
        }
    }

    private func saveToPhotos(
        _ payloads: [LibraryPayload],
        skippedRaw: Bool,
        croppedAspect: Bool,
        location: CLLocation? = nil,
        aspect: PhotoAspect = .threeByFour,
        thumb: UIImage? = nil,
        localShotID: String = ""
    ) async {
        do {
            let identifier = try await PhotoLibrary.save(payloads: payloads, fileInAlbum: true, location: location)
            if let identifier {
                let hasRaw = payloads.contains { $0.alternate || $0.filename.lowercased().hasSuffix(".dng") }
                PhiShotIndex.append(localIdentifier: identifier, hasRaw: hasRaw, aspect: aspect.rawValue)
                PhiLocalShots.markSaved(id: localShotID, photosIdentifier: identifier)
                if let thumb {
                    DevelopCache.store(thumb, identifier: identifier)
                }
            }
            let note = Self.savedNote(payloads: payloads, skippedRaw: skippedRaw, croppedAspect: croppedAspect)
            await MainActor.run {
                self.albumRevision += 1
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
        } catch let error as PhotoSaveError {
            let line = error.debugLine
            let short = error.codeLine
            Logger(subsystem: "com.zeid.phi", category: "photos").error("\(line, privacy: .public)")
            if localShotID.isEmpty == false {
                PhiLocalShots.markFailed(id: localShotID)
            }
            await MainActor.run {
                self.albumRevision += 1
                self.canRetryPhotoSave = true
                self.camera.statusMessage = "未能写入相册（\(short)）。照片留在 App 内。"
                if self.processSession?.isSample == false {
                    self.processSession?.status = line
                    self.processSession?.developInfo = line
                }
            }
        } catch {
            let ns = error as NSError
            let line = "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
            Logger(subsystem: "com.zeid.phi", category: "photos").error("\(line, privacy: .public)")
            if localShotID.isEmpty == false {
                PhiLocalShots.markFailed(id: localShotID)
            }
            await MainActor.run {
                self.albumRevision += 1
                self.canRetryPhotoSave = true
                self.camera.statusMessage = "未能写入相册（\(ns.domain) \(ns.code)）。照片留在 App 内。"
                if self.processSession?.isSample == false {
                    self.processSession?.developInfo = line
                }
            }
        }
    }

    private static func savedNote(payloads: [LibraryPayload], skippedRaw: Bool, croppedAspect: Bool) -> String {
        let rawFile = payloads.first { $0.filename.lowercased().hasSuffix(".dng") }
        let processed = payloads.first { $0.filename.lowercased().hasSuffix(".dng") == false }
        let processedName = processed?.filename.lowercased().hasSuffix(".heic") == true ? "HEIC" : "JPEG"
        if skippedRaw {
            if croppedAspect {
                return "这一画幅按取景裁切，已改存 \(processedName)。Saved the cropped \(processedName)."
            }
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

    private func present(
        base: CGImage,
        recipe: StillRecipe,
        isSample: Bool,
        status: String?,
        sourceDNG: Data? = nil,
        sourceMetadata: [String: Any]? = nil,
        aspect: PhotoAspect = .threeByFour,
        location: CLLocation? = nil
    ) {
        let session = ProcessSession(
            base: base,
            exposureEV: recipe.exposureEV,
            style: recipe.style,
            isSample: isSample,
            originalWasRaw: recipe.originalWasRaw,
            status: status,
            sourceDNG: sourceDNG,
            sourceMetadata: sourceMetadata,
            framedAspect: aspect,
            captureLocation: location,
            colorLook: recipe.colorLook,
            halo: recipe.halo
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
            originalWasRaw: session.originalWasRaw,
            colorLook: session.colorLook,
            halo: session.halo
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
    var metadata: [String: Any]?
    var location: CLLocation?
}
