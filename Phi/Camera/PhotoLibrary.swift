import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoSaveError: Error {
    case notAuthorized
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
    static func addOnlyStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    static func requestAddOnly() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    static func save(data: Data, typeIdentifier: String, filename: String) async throws {
        try await save(payloads: [
            LibraryPayload(data: data, typeIdentifier: typeIdentifier, filename: filename, alternate: false)
        ])
    }

    /// One library asset. Pass the processed still first (`alternate == false`) and the DNG as `alternate` so Photos pairs them the way a RAW+JPEG capture does.
    static func save(payloads: [LibraryPayload]) async throws {
        guard payloads.isEmpty == false else { return }
        let status = addOnlyStatus()
        let granted: PHAuthorizationStatus
        if status == .notDetermined {
            granted = await requestAddOnly()
        } else {
            granted = status
        }
        guard granted == .authorized || granted == .limited else { throw PhotoSaveError.notAuthorized }

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
        }
    }
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
