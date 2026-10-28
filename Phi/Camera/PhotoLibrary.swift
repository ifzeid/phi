import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoSaveError: Error {
    case notAuthorized
}

/// Local identifiers of assets PHI has written. The album browser reads these back after the user allows library access.
enum PhiShotIndex {
    private static var fileURL: URL {
        StillArchive.directory.appendingPathComponent("phi-assets.json")
    }

    struct Entry: Codable, Equatable {
        var localIdentifier: String
        var hasRaw: Bool
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func append(localIdentifier: String, hasRaw: Bool) {
        var entries = load()
        entries.removeAll { $0.localIdentifier == localIdentifier }
        entries.append(Entry(localIdentifier: localIdentifier, hasRaw: hasRaw))
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// One file inside a Photos asset. A JPEG+RAW pair uses `.photo` for the processed still and `.alternatePhoto` for the DNG.
struct LibraryPayload {
    var data: Data
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
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)) else { return nil }
            items.append(LibraryPayload(
                data: data,
                typeIdentifier: file.typeIdentifier,
                filename: file.filename,
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
    static func save(data: Data, typeIdentifier: String, filename: String) async throws -> String? {
        try await save(payloads: [
            LibraryPayload(data: data, typeIdentifier: typeIdentifier, filename: filename, alternate: false)
        ], fileInAlbum: false)
    }

    /// One library asset. Pass the processed still first (`alternate == false`) and the DNG as `alternate`.
    /// Returns the new asset's local identifier. Album filing happens only when read access was already granted, so a shutter press does not raise a second permission prompt.
    @discardableResult
    static func save(payloads: [LibraryPayload], fileInAlbum: Bool = false) async throws -> String? {
        guard payloads.isEmpty == false else { return nil }
        guard await canAddPhotos() else { throw PhotoSaveError.notAuthorized }

        let album: PHAssetCollection?
        if fileInAlbum, canReadLibrary(readWriteStatus()) {
            album = try? await ensureAlbum()
        } else {
            album = nil
        }
        let box = IdentifierBox()
        let items = payloads
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for item in items {
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = item.typeIdentifier
                options.originalFilename = item.filename
                let kind: PHAssetResourceType = item.alternate ? .alternatePhoto : .photo
                request.addResource(with: kind, data: item.data, options: options)
            }
            if let placeholder = request.placeholderForCreatedAsset {
                box.localIdentifier = placeholder.localIdentifier
                if let album, let change = PHAssetCollectionChangeRequest(for: album) {
                    change.addAssets([placeholder] as NSArray)
                }
            }
        }
        return box.localIdentifier
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

private final class IdentifierBox: @unchecked Sendable {
    var localIdentifier: String?
}

enum StillArchive {
    static let countKey = "phi.captureCount"
    static let lastPathKey = "phi.lastStillPath"
    static let lastUTIKey = "phi.lastStillUTI"
    static let lastSavedKey = "phi.lastStillSavedToPhotos"
    static let grainStyleKey = "phi.grainStyle"
    static let lastBundleKey = "phi.lastStillBundle"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stills", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
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
        for stem in ordered.dropFirst(3) {
            for url in stems[stem] ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
