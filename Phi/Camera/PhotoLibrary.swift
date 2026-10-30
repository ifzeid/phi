import CoreLocation
import Foundation
import ImageIO
import os
import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoSaveError: Error {
    case notAuthorized
    case failed(domain: String, code: Int, message: String)

    var debugLine: String {
        switch self {
        case .notAuthorized:
            return "Photos not authorized"
        case .failed(let domain, let code, let message):
            return "\(domain) \(code) \(message)"
        }
    }

    /// Domain and code only, for the viewfinder toast.
    var codeLine: String {
        switch self {
        case .notAuthorized:
            return "未授权"
        case .failed(let domain, let code, _):
            return "\(domain) \(code)"
        }
    }
}

/// Local identifiers of assets PHI has written. The album browser reads these back after the user allows library access.
enum PhiShotIndex {
    private static var fileURL: URL {
        StillArchive.directory.appendingPathComponent("phi-assets.json")
    }

    struct Entry: Codable, Equatable {
        var localIdentifier: String
        var hasRaw: Bool
        var aspect: String?
        /// Center-crop zoom for a focal-length crop stop. Nil or 1 is the full frame.
        var lensZoom: Double?
        /// `ProcessMode.rawValue`. Nil on rows written before mode 0 had its own develop.
        var processMode: String?
        /// Finder EV compensation in stops. Nil on older rows. Editor 0 is this capture, not a second copy of it.
        var captureEV: Double?

        private enum CodingKeys: String, CodingKey {
            case localIdentifier, hasRaw, aspect, lensZoom, processMode, captureEV
        }

        init(localIdentifier: String, hasRaw: Bool, aspect: String?, lensZoom: Double?, processMode: String? = nil, captureEV: Double? = nil) {
            self.localIdentifier = localIdentifier
            self.hasRaw = hasRaw
            self.aspect = aspect
            self.lensZoom = lensZoom
            self.processMode = processMode
            self.captureEV = captureEV
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            localIdentifier = try container.decode(String.self, forKey: .localIdentifier)
            hasRaw = try container.decode(Bool.self, forKey: .hasRaw)
            aspect = try container.decodeIfPresent(String.self, forKey: .aspect)
            lensZoom = try container.decodeIfPresent(Double.self, forKey: .lensZoom)
            processMode = try container.decodeIfPresent(String.self, forKey: .processMode)
            captureEV = try container.decodeIfPresent(Double.self, forKey: .captureEV)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(localIdentifier, forKey: .localIdentifier)
            try container.encode(hasRaw, forKey: .hasRaw)
            try container.encodeIfPresent(aspect, forKey: .aspect)
            try container.encodeIfPresent(lensZoom, forKey: .lensZoom)
            try container.encodeIfPresent(processMode, forKey: .processMode)
            try container.encodeIfPresent(captureEV, forKey: .captureEV)
        }
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func append(localIdentifier: String, hasRaw: Bool, aspect: String?, lensZoom: Double? = nil, processMode: String? = nil, captureEV: Double? = nil) {
        var entries = load()
        entries.removeAll { $0.localIdentifier == localIdentifier }
        entries.append(Entry(
            localIdentifier: localIdentifier,
            hasRaw: hasRaw,
            aspect: aspect,
            lensZoom: lensZoom,
            processMode: processMode,
            captureEV: captureEV
        ))
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func remove(localIdentifiers: [String]) {
        guard localIdentifiers.isEmpty == false else { return }
        let dropping = Set(localIdentifiers)
        let entries = load().filter { dropping.contains($0.localIdentifier) == false }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func aspect(for localIdentifier: String) -> PhotoAspect? {
        guard let raw = load().first(where: { $0.localIdentifier == localIdentifier })?.aspect else { return nil }
        return PhotoAspect(rawValue: raw)
    }

    static func lensZoom(for localIdentifier: String) -> Double {
        guard let entry = load().first(where: { $0.localIdentifier == localIdentifier }) else { return 1 }
        if entry.processMode == ProcessMode.bayer.rawValue { return 1 }
        let stored = entry.lensZoom ?? 1
        return stored > 1 ? stored : 1
    }

    /// Crop used when developing the DNG again. The Photos primary is already cropped, so display zoom stays 1.
    static func captureZoom(for localIdentifier: String) -> Double {
        // Shots saved by build 30 lack the zoom in this index; the local shot record still has it.
        let stored = load().first(where: { $0.localIdentifier == localIdentifier })?.lensZoom
            ?? PhiLocalShots.load().first(where: { $0.photosIdentifier == localIdentifier })?.lensZoom
            ?? 1
        return stored > 1 ? stored : 1
    }

    static func processMode(for localIdentifier: String) -> ProcessMode? {
        guard let raw = load().first(where: { $0.localIdentifier == localIdentifier })?.processMode else { return nil }
        return ProcessMode(rawValue: raw)
    }
}

/// Shots kept in the app container. The in-app album shows these even when Photos rejects the asset.
enum PhiLocalShots {
    struct Shot: Codable, Identifiable, Equatable {
        var id: String
        var files: [LibraryRecord.File]
        var hasRaw: Bool
        var savedToPhotos: Bool
        var photosIdentifier: String?
        /// Set after Photos rejects the asset. Absent while the write is still in flight.
        var saveFailed: Bool?
        /// `PhotoAspect.rawValue` at capture. Older records omit it.
        var aspect: String?
        /// Center-crop zoom. Older records omit it. Mode 0 re-develop uses this; the saved HEIF is already cropped.
        var lensZoom: Double?
        /// `ProcessMode.rawValue`. Older records omit it.
        var processMode: String?
        /// Finder EV in stops. Editor 0 is the captured frame; meter total is `captureEV + editorEV`.
        var captureEV: Double?

        private enum CodingKeys: String, CodingKey {
            case id, files, hasRaw, savedToPhotos, photosIdentifier, saveFailed, aspect, lensZoom, processMode, captureEV
        }

        init(
            id: String,
            files: [LibraryRecord.File],
            hasRaw: Bool,
            savedToPhotos: Bool,
            photosIdentifier: String?,
            saveFailed: Bool?,
            aspect: String?,
            lensZoom: Double?,
            processMode: String? = nil,
            captureEV: Double? = nil
        ) {
            self.id = id
            self.files = files
            self.hasRaw = hasRaw
            self.savedToPhotos = savedToPhotos
            self.photosIdentifier = photosIdentifier
            self.saveFailed = saveFailed
            self.aspect = aspect
            self.lensZoom = lensZoom
            self.processMode = processMode
            self.captureEV = captureEV
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            files = try container.decode([LibraryRecord.File].self, forKey: .files)
            hasRaw = try container.decode(Bool.self, forKey: .hasRaw)
            savedToPhotos = try container.decode(Bool.self, forKey: .savedToPhotos)
            photosIdentifier = try container.decodeIfPresent(String.self, forKey: .photosIdentifier)
            saveFailed = try container.decodeIfPresent(Bool.self, forKey: .saveFailed)
            aspect = try container.decodeIfPresent(String.self, forKey: .aspect)
            lensZoom = try container.decodeIfPresent(Double.self, forKey: .lensZoom)
            processMode = try container.decodeIfPresent(String.self, forKey: .processMode)
            captureEV = try container.decodeIfPresent(Double.self, forKey: .captureEV)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(files, forKey: .files)
            try container.encode(hasRaw, forKey: .hasRaw)
            try container.encode(savedToPhotos, forKey: .savedToPhotos)
            try container.encodeIfPresent(photosIdentifier, forKey: .photosIdentifier)
            try container.encodeIfPresent(saveFailed, forKey: .saveFailed)
            try container.encodeIfPresent(aspect, forKey: .aspect)
            try container.encodeIfPresent(lensZoom, forKey: .lensZoom)
            try container.encodeIfPresent(processMode, forKey: .processMode)
            try container.encodeIfPresent(captureEV, forKey: .captureEV)
        }
    }

    private static var fileURL: URL {
        StillArchive.directory.appendingPathComponent("phi-local-shots.json")
    }

    static func load() -> [Shot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var shots = (try? JSONDecoder().decode([Shot].self, from: data)) ?? []
        var changed = false
        for index in shots.indices {
            for fileIndex in shots[index].files.indices {
                let stored = shots[index].files[fileIndex].path
                guard let url = StillArchive.resolve(stored) else { continue }
                let name = url.lastPathComponent
                let inSupport = url.path.hasPrefix(StillArchive.directory.path)
                if inSupport, stored != name {
                    shots[index].files[fileIndex].path = name
                    changed = true
                }
            }
        }
        if changed { write(shots) }
        return shots
    }

    static func forget(id: String) {
        remove(ids: [id])
    }

    /// Deletes the files and the index rows for shots that never made it into Photos, or whose files are already gone.
    static func remove(ids: [String]) {
        let dropping = Set(ids)
        guard dropping.isEmpty == false else { return }
        let shots = load()
        for shot in shots where dropping.contains(shot.id) {
            ShotCache.remove(stem: shot.id)
            for file in shot.files {
                if let url = StillArchive.resolve(file.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        write(shots.filter { dropping.contains($0.id) == false })
    }

    static func remember(_ shot: Shot) {
        var shots = load().filter { $0.id != shot.id }
        shots.append(shot)
        write(shots)
    }

    private static func write(_ shots: [Shot]) {
        guard let data = try? JSONEncoder().encode(shots) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func markSaved(id: String, photosIdentifier: String) {
        var shots = load()
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[index].savedToPhotos = true
        shots[index].photosIdentifier = photosIdentifier
        shots[index].saveFailed = false
        write(shots)
    }

    static func markFailed(id: String) {
        var shots = load()
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[index].saveFailed = true
        write(shots)
    }

    /// Album and editor still. Mode 0 prefers the DNG develop. Apple's HEIF is named `.apple.` and is only the fallback.
    static func displayFile(of shot: Shot) -> LibraryRecord.File? {
        let visible = shot.files.filter { isAppleFallback($0) == false && isRawFile($0) == false }
        return visible.first { $0.alternate == false }
            ?? visible.first
            ?? shot.files.first { isRawFile($0) == false }
            ?? shot.files.first
    }

    /// Crop zoom for showing `displayFile`. A finished mode 0 HEIF already contains the crop.
    static func displayZoom(of shot: Shot) -> Double {
        let developed = shot.files.contains { isAppleFallback($0) == false && isRawFile($0) == false }
        if shot.processMode == ProcessMode.bayer.rawValue, developed {
            return 1
        }
        let zoom = shot.lensZoom ?? 1
        return zoom > 1 ? zoom : 1
    }

    static func isAppleFallback(_ file: LibraryRecord.File) -> Bool {
        file.filename.lowercased().contains(".apple.")
    }

    private static func isRawFile(_ file: LibraryRecord.File) -> Bool {
        file.filename.lowercased().hasSuffix(".dng")
    }

    static func unsaved() -> [Shot] {
        load().filter { $0.savedToPhotos == false }.reversed()
    }

    static func unsavedNames() -> Set<String> {
        Set(unsaved().flatMap { shot in
            shot.files.map { ($0.path as NSString).lastPathComponent }
        })
    }

    static func shot(id: String) -> Shot? {
        load().first { $0.id == id }
    }
}

/// One file inside a Photos asset. A JPEG+RAW pair uses `.photo` for the processed still and `.alternatePhoto` for the DNG.
/// Photos rejects a DNG passed as `data` for `.alternatePhoto` (PHPhotosErrorDomain 3300). A file URL is accepted.
struct LibraryPayload {
    var data: Data
    var fileURL: URL? = nil
    var typeIdentifier: String
    var filename: String
    var alternate: Bool
}

struct LibraryRecord: Codable, Equatable {
    struct File: Codable, Equatable {
        var path: String
        var typeIdentifier: String
        var filename: String
        var alternate: Bool
    }

    var files: [File]

    func payloads() -> [LibraryPayload]? {
        var items: [LibraryPayload] = []
        for file in files {
            guard let url = StillArchive.resolve(file.path),
                  let data = try? Data(contentsOf: url) else { return nil }
            items.append(LibraryPayload(
                data: data,
                fileURL: url,
                typeIdentifier: file.typeIdentifier,
                filename: file.filename.isEmpty ? url.lastPathComponent : file.filename,
                alternate: file.alternate
            ))
        }
        return items
    }
}

enum PhotoLibrary {
    static let albumTitle = "PHI"

    static func addOnlyStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    static func requestAddOnly() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    static func readWriteStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestReadWrite() async -> PHAuthorizationStatus {
        let current = readWriteStatus()
        if current == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return current
    }

    static func canReadLibrary(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    @discardableResult
    static func save(data: Data, typeIdentifier: String, filename: String, location: CLLocation? = nil) async throws -> String? {
        try await save(payloads: [
            LibraryPayload(data: data, typeIdentifier: typeIdentifier, filename: filename, alternate: false)
        ], fileInAlbum: false, location: location)
    }

    /// One library asset. Pass the processed still first (`alternate == false`) and the DNG as `alternate`.
    /// Returns the new asset's local identifier. Album filing happens only when read access was already granted, so a shutter press does not raise a second permission prompt.
    @discardableResult
    static func save(payloads: [LibraryPayload], fileInAlbum: Bool = false, location: CLLocation? = nil) async throws -> String? {
        guard payloads.isEmpty == false else { return nil }
        guard await canAddPhotos() else { throw PhotoSaveError.notAuthorized }

        let album: PHAssetCollection?
        if fileInAlbum, canReadLibrary(readWriteStatus()) {
            album = try? await ensureAlbum()
        } else {
            album = nil
        }
        let box = IdentifierBox()
        let items = normalizedForPhotos(payloads)
        guard let primary = items.first(where: { $0.alternate == false }) else {
            throw PhotoSaveError.failed(domain: "com.zeid.phi", code: 1, message: "没有可用的 HEIF/JPEG 主图")
        }
        let shotLocation = location
        let log = Logger(subsystem: "com.zeid.phi", category: "photos")
        for item in items {
            let container = CapturedContainer.inspect(item.data)
            let kind = item.alternate ? "alternatePhoto" : "photo"
            let via = item.fileURL == nil ? "data" : "file"
            log.info("resource \(kind, privacy: .public) via \(via, privacy: .public) \(container.logLine, privacy: .public) file \(item.filename, privacy: .public)")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.location = shotLocation
                for item in items {
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = item.typeIdentifier
                    options.originalFilename = item.filename
                    let kind: PHAssetResourceType = item.alternate ? .alternatePhoto : .photo
                    if let url = item.fileURL {
                        options.shouldMoveFile = false
                        request.addResource(with: kind, fileURL: url, options: options)
                    } else {
                        request.addResource(with: kind, data: item.data, options: options)
                    }
                }
                if let placeholder = request.placeholderForCreatedAsset {
                    box.localIdentifier = placeholder.localIdentifier
                    if let album, let change = PHAssetCollectionChangeRequest(for: album) {
                        change.addAssets([placeholder] as NSArray)
                    }
                }
            }
        } catch let error as NSError {
            let primaryLine = CapturedContainer.inspect(primary.data).logLine
            log.error("Photos rejected \(primaryLine, privacy: .public) \(error.domain, privacy: .public) \(error.code)")
            throw PhotoSaveError.failed(domain: error.domain, code: error.code, message: error.localizedDescription)
        }
        return box.localIdentifier
    }

    /// Primary `.photo` is Apple's HEIF or JPEG. The DNG is `.alternatePhoto` only beside that primary.
    /// invalidResource (3300) here is Photos refusing the DNG when `addResource` is given bytes. The file on disk is the resource that succeeds.
    private static func normalizedForPhotos(_ payloads: [LibraryPayload]) -> [LibraryPayload] {
        let inspected = payloads.map { item in
            (item, CapturedContainer.inspect(item.data))
        }
        let primary = inspected.first { $0.1.isRawContainer == false && $0.1.isDecodableImage && ($0.1.filenameExtension == "heic" || $0.1.filenameExtension == "jpg") }
            ?? inspected.first { $0.1.isRawContainer == false && $0.1.isDecodableImage }
        guard let primary else { return [] }
        var results = [libraryPayload(primary.0, container: primary.1, alternate: false)]
        if let raw = inspected.first(where: { $0.1.isRawContainer && $0.1.data.count > 64 }) {
            if raw.1.matchesPixels(of: primary.1) == false, primary.1.pixelWidth > 0, raw.1.pixelWidth > 0 {
                Logger(subsystem: "com.zeid.phi", category: "photos").error(
                    "DNG \(raw.1.pixelWidth)x\(raw.1.pixelHeight) does not match primary \(primary.1.pixelWidth)x\(primary.1.pixelHeight)"
                )
            }
            results.append(libraryPayload(raw.0, container: raw.1, alternate: true))
        }
        return results
    }

    private static func libraryPayload(_ item: LibraryPayload, container: CapturedContainer, alternate: Bool) -> LibraryPayload {
        let ext = container.filenameExtension
        let stem = (item.filename as NSString).deletingPathExtension
        let filename = stem.isEmpty ? "PHI.\(ext)" : "\(stem).\(ext)"
        return LibraryPayload(
            data: item.data,
            fileURL: item.fileURL,
            typeIdentifier: container.typeIdentifier,
            filename: filename,
            alternate: alternate
        )
    }

    /// Creates the PHI album when missing. Requires read/write or limited access.
    static func ensureAlbum() async throws -> PHAssetCollection? {
        if let existing = phiAlbum() { return existing }
        let box = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            box.localIdentifier = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        if let localIdentifier = box.localIdentifier,
           let created = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [localIdentifier], options: nil).firstObject {
            return created
        }
        return phiAlbum()
    }

    static func phiAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumTitle)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject
    }

    /// Puts previously saved identifiers into the PHI album. Assets already in the album are left alone.
    static func fileIntoAlbum(_ identifiers: [String], album: PHAssetCollection) async {
        guard identifiers.isEmpty == false else { return }
        let incoming = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        let already = PHAsset.fetchAssets(in: album, options: nil)
        var present = Set<String>()
        already.enumerateObjects { asset, _, _ in
            present.insert(asset.localIdentifier)
        }
        var missing: [PHAsset] = []
        incoming.enumerateObjects { asset, _, _ in
            if present.contains(asset.localIdentifier) == false {
                missing.append(asset)
            }
        }
        guard missing.isEmpty == false else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(missing as NSArray)
        }
    }

    static func loadAlternateData(for asset: PHAsset) async -> Data? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: PhiRawAsset.isRaw) else { return nil }
        return await loadResource(resource)
    }

    private static func loadResource(_ resource: PHAssetResource) async -> Data? {
        await withCheckedContinuation { continuation in
            let buffer = NSMutableData()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            let resumed = ResourceResume()
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                buffer.append(chunk)
            } completionHandler: { error in
                if error != nil {
                    resumed.resume(continuation, with: nil)
                } else {
                    resumed.resume(continuation, with: buffer as Data)
                }
            }
        }
    }

    /// Newest first. Indexed captures, plus anything already sitting in the PHI album.
    static func loadShots() -> [PHAsset] {
        let indexed = PhiShotIndex.load()
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: indexed.map(\.localIdentifier), options: nil)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
        }
        var shots = indexed.reversed().compactMap { byID[$0.localIdentifier] }
        guard let album = phiAlbum() else { return shots }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
            if byID[asset.localIdentifier] == nil {
                shots.append(asset)
                byID[asset.localIdentifier] = asset
            }
        }
        return shots
    }

    private static func canAddPhotos() async -> Bool {
        if canReadLibrary(readWriteStatus()) { return true }
        let add = addOnlyStatus()
        if add == .authorized || add == .limited { return true }
        if add == .notDetermined {
            let granted = await requestAddOnly()
            return granted == .authorized || granted == .limited
        }
        return false
    }
}

enum PhiRawAsset {
    /// This SDK has no `PHAssetMediaSubtype.photoRAW`. A still is RAW when a resource is DNG/RAW.
    static func contains(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains(where: isRaw)
    }

    static func isRaw(_ resource: PHAssetResource) -> Bool {
        if isRawIdentifier(resource.uniformTypeIdentifier) { return true }
        let name = resource.originalFilename.lowercased()
        if name.hasSuffix(".dng") || name.hasSuffix(".raw") { return true }
        return false
    }

    private static func isRawIdentifier(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        if lowered == "com.adobe.raw-image" || lowered == "public.camera-raw-image" { return true }
        if let type = UTType(identifier) {
            if type.conforms(to: .rawImage) { return true }
        }
        return lowered.contains("raw-image") || lowered.contains("camera-raw")
    }
}

private final class IdentifierBox: @unchecked Sendable {
    var localIdentifier: String?
}

private final class ResourceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<Data?, Never>, with data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard didResume == false else { return }
        didResume = true
        continuation.resume(returning: data)
    }
}

enum DevelopCache {
    private static var directory: URL {
        let url = StillArchive.directory.appendingPathComponent("develop-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func store(_ image: UIImage, identifier: String) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: fileURL(identifier), options: .atomic)
    }

    static func image(for identifier: String) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL(identifier)) else { return nil }
        return UIImage(data: data)
    }

    private static func fileURL(_ identifier: String) -> URL {
        let safe = identifier.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(safe).jpg")
    }
}

enum StillArchive {
    static let countKey = "phi.captureCount"
    static let lastPathKey = "phi.lastStillPath"
    static let lastUTIKey = "phi.lastStillUTI"
    static let lastSavedKey = "phi.lastStillSavedToPhotos"
    static let lastBundleKey = "phi.lastStillBundle"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stills", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Index entries store a file name. Older builds stored an absolute container path, which breaks when the UUID changes.
    static func resolve(_ stored: String) -> URL? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let name = (trimmed as NSString).lastPathComponent
        guard name.isEmpty == false, name != "/" else { return nil }
        let local = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        guard trimmed != name, FileManager.default.fileExists(atPath: trimmed) else { return nil }
        if FileManager.default.fileExists(atPath: local.path) == false {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: trimmed), to: local)
        }
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return URL(fileURLWithPath: trimmed)
    }

    static var thumbnailURL: URL {
        directory.appendingPathComponent("last-thumb.jpg")
    }

    static var basePreviewURL: URL {
        directory.appendingPathComponent("last-base.jpg")
    }

    static var recipeURL: URL {
        directory.appendingPathComponent("last-recipe.json")
    }

    static func writeBasePreview(_ image: CGImage) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: basePreviewURL, options: .atomic)
    }

    static func loadBasePreview() -> CGImage? {
        guard let data = try? Data(contentsOf: basePreviewURL),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func writeRecipe(_ recipe: StillRecipe) {
        guard let data = try? JSONEncoder().encode(recipe) else { return }
        try? data.write(to: recipeURL, options: .atomic)
    }

    static func loadRecipe() -> StillRecipe? {
        guard let data = try? Data(contentsOf: recipeURL) else { return nil }
        return try? JSONDecoder().decode(StillRecipe.self, from: data)
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    static func write(data: Data, ext: String) throws -> URL {
        try write(data: data, stamp: stamp(), ext: ext)
    }

    static func write(data: Data, stamp: String, ext: String) throws -> URL {
        let url = directory.appendingPathComponent("PHI-\(stamp).\(ext)")
        try data.write(to: url, options: .atomic)
        prune()
        return url
    }

    static func storeLastRecord(_ record: LibraryRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: lastBundleKey)
    }

    static func loadLastRecord() -> LibraryRecord? {
        guard let data = UserDefaults.standard.data(forKey: lastBundleKey) else { return nil }
        return try? JSONDecoder().decode(LibraryRecord.self, from: data)
    }

    static func thumbnail(from image: UIImage) -> UIImage {
        let maxSide: CGFloat = 480
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return image }
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let stills = files.filter { $0.lastPathComponent.hasPrefix("PHI-") }
        let stems = Dictionary(grouping: stills, by: { $0.deletingPathExtension().lastPathComponent })
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let ordered = stems.keys.sorted { lhs, rhs in
            let left = stems[lhs]?.map(modified).max() ?? .distantPast
            let right = stems[rhs]?.map(modified).max() ?? .distantPast
            return left > right
        }
        for stem in ordered.dropFirst(12) {
            for url in stems[stem] ?? [] {
                if PhiLocalShots.unsavedNames().contains(url.lastPathComponent) { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
