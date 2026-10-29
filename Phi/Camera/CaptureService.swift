import AVFoundation
import Combine
import CoreLocation
import os
import Photos
import UIKit
import UniformTypeIdentifiers

/// Builds each still at `.quality`. RAW is skipped when this stop cannot deliver Bayer.
final class CaptureService: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let camera = CameraSession()

    @Published private(set) var isCapturing = false
    @Published private(set) var shutterTick = 0
    @Published private(set) var captureCount = 0
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var lastSavedNote: String?
    @Published private(set) var canRetryPhotoSave = false
    @Published private(set) var processMode: ProcessMode = .bayer
    @Published private(set) var saveHEIF = true
    @Published private(set) var processedCodec: ProcessedCodec = .heic
    @Published private(set) var photoAspect: PhotoAspect = .threeByFour
    @Published var processSession: ProcessSession?
    @Published private(set) var hasDevelopBase = false
    @Published private(set) var albumRevision = 0
    /// Local id of an edited HEIF whose Photos write failed. Album 重试 and the editor 重试 both use it.
    private var developRetryID: String?
    private var previewPublish = 0

    private var cancellables = Set<AnyCancellable>()
    private var cameraPublishQueued = false
    private let pendingLock = NSLock()
    private var pending = PendingCapture()

    override init() {
        super.init()
        let preference = ProcessMode.load()
        processMode = preference.mode
        saveHEIF = preference.saveHEIF
        processedCodec = ProcessedCodec.loadStored()
        photoAspect = PhotoAspect.stored(UserDefaults.standard.string(forKey: PhotoAspect.storageKey))
        camera.setProcessMode(processMode)
        camera.setProcessedCodec(processedCodec)
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
                guard let self else { return }
                if self.cameraPublishQueued { return }
                self.cameraPublishQueued = true
                DispatchQueue.main.async {
                    self.cameraPublishQueued = false
                    self.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }

    func setProcessMode(_ mode: ProcessMode) {
        SettingsTiming.measure("setProcessMode", label: mode.mark) {
            processMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: ProcessMode.storageKey)
            camera.setProcessMode(mode)
        }
    }

    func setSaveHEIF(_ enabled: Bool) {
        SettingsTiming.measure("setSaveHEIF", label: enabled ? "on" : "off") {
            saveHEIF = enabled
            UserDefaults.standard.set(enabled, forKey: ProcessMode.saveProcessedKey)
            UserDefaults.standard.set(enabled, forKey: ProcessMode.saveHEIFKey)
        }
    }

    func setProcessedCodec(_ codec: ProcessedCodec) {
        SettingsTiming.measure("setProcessedCodec", label: codec.title) {
            processedCodec = codec
            UserDefaults.standard.set(codec.rawValue, forKey: ProcessedCodec.storageKey)
            camera.setProcessedCodec(codec)
        }
    }

    func setPhotoAspect(_ aspect: PhotoAspect) {
        SettingsTiming.measure("setPhotoAspect", label: aspect.title) {
            photoAspect = aspect
            UserDefaults.standard.set(aspect.rawValue, forKey: PhotoAspect.storageKey)
            camera.setPhotoAspect(aspect)
        }
    }

    func openLocalShot(id: String) {
        guard let shot = PhiLocalShots.shot(id: id) else {
            camera.statusMessage = "这张照片不在相册里。"
            return
        }
        let dngStored = shot.files.first { $0.filename.lowercased().hasSuffix(".dng") }?.path
        let displayStored = PhiLocalShots.displayFile(of: shot)?.path
        let hasRaw = shot.hasRaw
        let aspect = shot.aspect.flatMap(PhotoAspect.init(rawValue:)) ?? photoAspect
        let zoom = shot.lensZoom ?? 1
        Task {
            let displayURL = displayStored.flatMap { StillArchive.resolve($0) }
            let displayImage = displayURL.flatMap { AlbumImage.fileImage(url: $0, maxSide: nil) }
            let displayData = displayURL.flatMap { try? Data(contentsOf: $0) }
            let dngURL = dngStored.flatMap { StillArchive.resolve($0) }
            let dng = dngURL.flatMap { try? Data(contentsOf: $0) }
            if let displayImage, let pixels = displayImage.cgImage {
                let metadata = dng.flatMap { PhotoMetadata.properties(of: $0) }
                await MainActor.run {
                    self.present(
                        base: pixels,
                        recipe: StillRecipe(exposureEV: 0, style: .off, originalWasRaw: dng != nil),
                        isSample: false,
                        status: "原片。改一项之后才重新显影。",
                        sourceDNG: dng,
                        sourceMetadata: metadata,
                        aspect: aspect,
                        lensZoom: zoom,
                        originalImage: displayImage,
                        originalData: displayData
                    )
                }
                return
            }
            if let dng, let url = dngURL, let image = AlbumImage.fileImage(url: url, maxSide: nil), let pixels = image.cgImage {
                await MainActor.run {
                    self.present(
                        base: pixels,
                        recipe: StillRecipe(exposureEV: 0, style: .off, originalWasRaw: true),
                        isSample: false,
                        status: "原片。改一项之后才重新显影。",
                        sourceDNG: dng,
                        sourceMetadata: PhotoMetadata.properties(of: dng),
                        aspect: aspect,
                        lensZoom: zoom,
                        originalImage: image
                    )
                }
                return
            }
            _ = hasRaw
            await MainActor.run {
                self.camera.statusMessage = "文件丢失"
            }
        }
    }

    func retryLocalShot(id: String) {
        guard let shot = PhiLocalShots.shot(id: id), let payloads = LibraryRecord(files: shot.files).payloads() else {
            camera.statusMessage = "文件丢失"
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
        let zoom = PhiShotIndex.lensZoom(for: localIdentifier)
        let rawShot = PhiRawAsset.contains(asset)
        Task {
            let dng = await PhotoLibrary.loadAlternateData(for: asset)
            if let image = await AlbumImage.loadOriginal(asset), let pixels = image.cgImage {
                await MainActor.run {
                    self.present(
                        base: pixels,
                        recipe: StillRecipe(exposureEV: 0, style: .off, originalWasRaw: dng != nil || rawShot),
                        isSample: false,
                        status: "原片。改一项之后才重新显影。",
                        sourceDNG: dng,
                        sourceMetadata: dng.flatMap { PhotoMetadata.properties(of: $0) },
                        aspect: aspect,
                        lensZoom: zoom,
                        location: asset.location,
                        originalImage: image
                    )
                }
                return
            }
            await MainActor.run {
                self.camera.statusMessage = "这张照片打不开。Couldn't open that still."
            }
        }
    }

    func openDevelop(image: UIImage, originalWasRaw: Bool, lensZoom: Double = 1) {
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
            status: status,
            lensZoom: lensZoom
        )
    }

    /// Opens the last developed still, or the bundled sample when nothing has been captured.
    func openProcess() {
        if let base = StillArchive.loadBasePreview() {
            present(
                base: base,
                recipe: StillRecipe(exposureEV: 0, style: .off, originalWasRaw: false),
                isSample: false,
                status: lastSavedNote,
                originalImage: UIImage(cgImage: base)
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
        let job = await MainActor.run { () -> ExportJob? in
            if session.isExporting { return nil }
            session.isExporting = true
            return ExportJob(
                base: session.base,
                ev: session.exposureEV,
                style: session.style,
                isSample: session.isSample,
                originalWasRaw: session.originalWasRaw,
                dng: session.sourceDNG,
                metadata: session.sourceMetadata,
                aspect: session.framedAspect,
                look: session.colorLook,
                halo: session.halo,
                zoom: session.lensZoom,
                neutral: session.isNeutral,
                originalPixels: session.originalImage?.cgImage,
                styleTitle: session.style.title
            )
        }
        guard let job else { return }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 16_000_000)
        let exported = await Task.detached(priority: .userInitiated) { () -> ExportBody in
            // background-export: full-res render and HEIF encode stay off the main thread.
            let rendered: CGImage?
            if job.neutral {
                rendered = job.originalPixels ?? job.base
            } else {
                // The edit base is the framed camera still. A fresh DNG develop replaces that tone.
                rendered = StillPipeline.render(
                    job.base,
                    exposureEV: job.ev,
                    style: job.style,
                    look: job.look,
                    halo: job.halo,
                    lensZoom: 1,
                    maxSide: nil
                )
            }
            guard let rendered, let encoded = StillPipeline.encodeDeveloped(rendered, metadata: job.metadata) else {
                return .renderFailed
            }
            let stamp = Self.fileStamp()
            guard let url = try? StillArchive.write(data: encoded.data, stamp: stamp, ext: encoded.ext) else {
                return .writeFailed
            }
            return .ready(ExportFile(
                data: encoded.data,
                ext: encoded.ext,
                uti: encoded.uti,
                width: rendered.width,
                height: rendered.height,
                url: url,
                stamp: stamp
            ))
        }.value
        let saved: ExportFile
        switch exported {
        case .renderFailed:
            await MainActor.run {
                session.isExporting = false
                session.status = "没有导出处理图。Couldn't render the still."
            }
            return
        case .writeFailed:
            await MainActor.run {
                session.isExporting = false
                session.status = "处理图没有留在 App 内。"
            }
            return
        case .ready(let ready):
            saved = ready
        }
        let sourceName = job.dng == nil ? "系统成片" : "DNG"
        let bytes = saved.data.count
        let info = "\(sourceName) · \(saved.width)×\(saved.height) · HEIF \(RawDevelop.exportQuality) · \(bytes) bytes"
        Logger(subsystem: "com.zeid.phi", category: "develop").info("\(info, privacy: .public)")
        let stamp = saved.stamp
        let filename = "PHI-\(job.styleTitle)-\(stamp).\(saved.ext)"
        let url = saved.url
        let file = LibraryRecord.File(
            path: url.lastPathComponent,
            typeIdentifier: saved.uti,
            filename: filename,
            alternate: false
        )
        let localShot = PhiLocalShots.Shot(
            id: stamp,
            files: [file],
            hasRaw: false,
            savedToPhotos: false,
            photosIdentifier: nil,
            saveFailed: nil,
            aspect: job.aspect.rawValue,
            lensZoom: nil
        )
        PhiLocalShots.remember(localShot)
        let payload = LibraryPayload(
            data: saved.data,
            fileURL: url,
            typeIdentifier: saved.uti,
            filename: filename,
            alternate: false
        )
        await MainActor.run {
            session.developInfo = info
            self.developRetryID = stamp
            self.albumRevision += 1
            self.canRetryPhotoSave = true
        }
        let note: String
        if job.isSample {
            note = "已把样张的处理图存入相册。Saved the sample develop."
        } else if job.originalWasRaw {
            note = "已另存处理图。RAW 原片没有改动。Saved a develop. The RAW file was left as captured."
        } else {
            note = "已另存处理图，没有覆盖拍摄原片。Saved a separate develop."
        }
        await saveDevelopedToPhotos(payload, localShotID: stamp, successNote: note, session: session)
    }

    /// Editor 重试. A failed develop is saved again; otherwise the last original capture is.
    func retryFailedSave() {
        if let id = developRetryID {
            retryLocalShot(id: id)
            return
        }
        retryPhotoSave()
    }

    private struct ExportFile {
        var data: Data
        var ext: String
        var uti: String
        var width: Int
        var height: Int
        var url: URL
        var stamp: String
    }

    private enum ExportBody {
        case renderFailed
        case writeFailed
        case ready(ExportFile)
    }

    private struct ExportJob {
        var base: CGImage
        var ev: Double
        var style: GrainStyle
        var isSample: Bool
        var originalWasRaw: Bool
        var dng: Data?
        var metadata: [String: Any]?
        var aspect: PhotoAspect
        var look: ColorLook
        var halo: HaloLevel
        var zoom: Double
        var neutral: Bool
        var originalPixels: CGImage?
        var styleTitle: String
    }

    private func saveDevelopedToPhotos(
        _ payload: LibraryPayload,
        localShotID: String,
        successNote: String,
        session: ProcessSession
    ) async {
        do {
            let identifier = try await PhotoLibrary.save(
                payloads: [payload],
                fileInAlbum: true,
                location: session.captureLocation
            )
            if let identifier {
                PhiShotIndex.append(localIdentifier: identifier, hasRaw: false, aspect: session.framedAspect.rawValue)
                PhiLocalShots.markSaved(id: localShotID, photosIdentifier: identifier)
            }
            await MainActor.run {
                self.albumRevision += 1
                self.developRetryID = nil
                self.canRetryPhotoSave = false
                self.lastSavedNote = successNote
                session.isExporting = false
                session.status = successNote
                if self.camera.statusMessage?.contains("相册") == true {
                    self.camera.statusMessage = nil
                }
            }
        } catch let error as PhotoSaveError {
            let line = error.debugLine
            Logger(subsystem: "com.zeid.phi", category: "photos").error("develop \(line, privacy: .public)")
            PhiLocalShots.markFailed(id: localShotID)
            await MainActor.run {
                self.albumRevision += 1
                self.developRetryID = localShotID
                self.canRetryPhotoSave = true
                session.isExporting = false
                session.status = "未能写入相册（\(error.codeLine)）。处理图留在 App 内。"
                session.developInfo = line
                self.camera.statusMessage = "未能写入相册（\(error.codeLine)）。照片留在 App 内。"
            }
        } catch {
            let ns = error as NSError
            let line = "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
            Logger(subsystem: "com.zeid.phi", category: "photos").error("develop \(line, privacy: .public)")
            PhiLocalShots.markFailed(id: localShotID)
            await MainActor.run {
                self.albumRevision += 1
                self.developRetryID = localShotID
                self.canRetryPhotoSave = true
                session.isExporting = false
                session.status = "未能写入相册（\(ns.domain) \(ns.code)）。处理图留在 App 内。"
                session.developInfo = line
                self.camera.statusMessage = "未能写入相册（\(ns.domain) \(ns.code)）。照片留在 App 内。"
            }
        }
    }

    func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        shutterTick += 1
        camera.statusMessage = nil
        resetPending()
        let format = processMode
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
        let name = (path as NSString).lastPathComponent
        return LibraryRecord(files: [
            LibraryRecord.File(path: name, typeIdentifier: uti, filename: name, alternate: false)
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
        // The embedded preview is enough for the shutter thumbnail. The full-frame image
        // representation decodes the whole still, which on a 48MP RAW is a second bitmap.
        if pending.preview == nil, let preview = photo.previewCGImageRepresentation() {
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
        // The still is finished. Putting the 50mm crop back any earlier reconfigures the session
        // while this capture is still in flight.
        DispatchQueue.main.async {
            self.camera.noteCaptureFinished()
            self.finish(snapshot)
        }
    }

    private func finish(_ snapshot: PendingCapture) {
        let format = processMode
        let keepCompanion = saveHEIF
        let hasRaw = snapshot.raw != nil
        let hasProcessed = snapshot.processed != nil
        guard hasRaw || hasProcessed else {
            isCapturing = false
            camera.statusMessage = snapshot.error ?? "没有得到照片数据。No photo data."
            return
        }

        let aspect = photoAspect
        let lensZoom = camera.framingZoom()
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
            // Keep Apple's original HEIF/JPEG bytes. Develop runs later, from the stored DNG, when the user taps 编辑.
            let stamp = StillArchive.stamp()
            let processedBox = originalProcessed.map { CapturedContainer.inspect($0) }
            let rawBox = rawData.map { CapturedContainer.inspect($0) }
            let photosLog = Logger(subsystem: "com.zeid.phi", category: "photos")
            if let processedBox {
                let companion = keepCompanion ? "HEIF on" : "HEIF off, primary kept"
                photosLog.info("capture primary \(processedBox.logLine, privacy: .public) \(companion, privacy: .public)")
            } else {
                photosLog.error("capture produced no processed HEIF/JPEG")
            }
            if let rawBox {
                photosLog.info("capture raw \(rawBox.logLine, privacy: .public)")
            }
            var files: [LibraryRecord.File] = []
            var payloads: [LibraryPayload] = []
            if let processedBox, processedBox.isDecodableImage, processedBox.isRawContainer == false,
               let url = try? StillArchive.write(data: processedBox.data, stamp: stamp, ext: processedBox.filenameExtension) {
                let file = LibraryRecord.File(
                    path: url.lastPathComponent,
                    typeIdentifier: processedBox.typeIdentifier,
                    filename: url.lastPathComponent,
                    alternate: false
                )
                files.append(file)
                payloads.append(LibraryPayload(
                    data: processedBox.data,
                    fileURL: url,
                    typeIdentifier: processedBox.typeIdentifier,
                    filename: file.filename,
                    alternate: false
                ))
            }
            if saveRaw, let rawBox, rawBox.isRawContainer,
               let url = try? StillArchive.write(data: rawBox.data, stamp: stamp, ext: "dng") {
                let alternate = files.isEmpty == false
                let file = LibraryRecord.File(
                    path: url.lastPathComponent,
                    typeIdentifier: rawUTI,
                    filename: url.lastPathComponent,
                    alternate: alternate
                )
                files.append(file)
                payloads.append(LibraryPayload(
                    data: rawBox.data,
                    fileURL: url,
                    typeIdentifier: rawBox.typeIdentifier,
                    filename: file.filename,
                    alternate: alternate
                ))
            }
            let keptRaw = files.contains { $0.filename.lowercased().hasSuffix(".dng") }
            let thumbImage = preview.flatMap { image -> UIImage? in
                let capped = Self.downsampledPreview(image, maxSide: 960)
                guard let cg = StillPipeline.normalizedCGImage(from: capped) else { return capped }
                return UIImage(cgImage: aspect.cropped(LensCrop.cropped(cg, zoom: lensZoom)))
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
                    aspect: aspect.rawValue,
                    lensZoom: lensZoom > 1.01 ? lensZoom : nil
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
                        lensZoom: lensZoom,
                        thumb: thumb,
                        localShotID: stamp
                    )
                }
            }
        }
    }

    /// Shrink a shutter preview before the 2× crop. Drawing a full-frame still here keeps a second bitmap alive
    /// while the session switches back to the viewfinder zoom.
    private static func downsampledPreview(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let longest = max(cg.width, cg.height)
        guard CGFloat(longest) > maxSide, longest > 0 else { return image }
        let ratio = maxSide / CGFloat(longest)
        let width = max(1, Int((CGFloat(cg.width) * ratio).rounded(.down)))
        let height = max(1, Int((CGFloat(cg.height) * ratio).rounded(.down)))
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return image }
        return UIImage(cgImage: scaled)
    }

    private func saveToPhotos(
        _ payloads: [LibraryPayload],
        skippedRaw: Bool,
        croppedAspect: Bool,
        location: CLLocation? = nil,
        aspect: PhotoAspect = .threeByFour,
        lensZoom: Double = 1,
        thumb: UIImage? = nil,
        localShotID: String = ""
    ) async {
        do {
            let identifier = try await PhotoLibrary.save(payloads: payloads, fileInAlbum: true, location: location)
            if let identifier {
                let hasRaw = payloads.contains { $0.alternate || $0.filename.lowercased().hasSuffix(".dng") }
                PhiShotIndex.append(
                    localIdentifier: identifier,
                    hasRaw: hasRaw,
                    aspect: aspect.rawValue,
                    lensZoom: lensZoom > 1.01 ? lensZoom : nil
                )
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
                if self.developRetryID == localShotID {
                    self.developRetryID = nil
                }
                self.processSession?.isExporting = false
                UserDefaults.standard.set(true, forKey: StillArchive.lastSavedKey)
                if self.camera.statusMessage?.contains("相册") == true {
                    self.camera.statusMessage = nil
                }
                if self.processSession?.isSample == false {
                    self.processSession?.status = "已保存新照片，原片保留"
                    self.processSession?.developInfo = note
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
        lensZoom: Double = 1,
        location: CLLocation? = nil,
        originalImage: UIImage? = nil,
        originalData: Data? = nil
    ) {
        let source = originalImage ?? UIImage(cgImage: base)
        let framed = AlbumImage.framed(source, aspect: aspect, zoom: lensZoom)
        let pixels = framed.cgImage ?? base
        let session = ProcessSession(
            base: pixels,
            exposureEV: 0,
            style: .off,
            isSample: isSample,
            originalWasRaw: recipe.originalWasRaw,
            status: status,
            sourceDNG: sourceDNG,
            sourceMetadata: sourceMetadata,
            framedAspect: aspect,
            lensZoom: 1,
            captureLocation: location,
            colorLook: .none,
            halo: .off,
            originalImage: framed,
            originalData: originalData
        )
        if isSample == false {
            session.onPreview = { [weak self] image in
                guard let self else { return }
                self.previewPublish += 1
                let generation = self.previewPublish
                Task.detached(priority: .utility) { [weak self] in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    let current = await MainActor.run { self?.previewPublish == generation }
                    guard current == true else { return }
                    let thumb = StillArchive.thumbnail(from: image)
                    let jpeg = thumb.jpegData(compressionQuality: 0.82)
                    if let jpeg {
                        try? jpeg.write(to: StillArchive.thumbnailURL, options: .atomic)
                    }
                    await MainActor.run {
                        guard self?.previewPublish == generation else { return }
                        self?.thumbnail = thumb
                        self?.persist(session)
                    }
                }
            }
            if session.status == nil {
                session.status = recipe.originalWasRaw
                    ? "RAW 原片单独保存，这里只改处理图。The RAW file stays as captured."
                    : "导出时另存处理图，不覆盖刚拍的原片。"
            }
        }
        session.preview = session.originalImage ?? UIImage(cgImage: pixels)
        session.developInfo = "原片 · \(session.preview?.size.width ?? 0)x\(session.preview?.size.height ?? 0)"
        session.warmPreview()
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

private enum SettingsTiming {
    static let log = Logger(subsystem: "com.zeid.phi", category: "settings")
    static let signposter = OSSignposter(subsystem: "com.zeid.phi", category: "settings")

    static func measure(_ name: StaticString, label: String, _ body: () -> Void) {
        let state = signposter.beginInterval(name)
        let start = CFAbsoluteTimeGetCurrent()
        body()
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        signposter.endInterval(name, state)
        let line = String(format: "%@ %.2f ms", label, milliseconds)
        log.info("\(line, privacy: .public)")
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
