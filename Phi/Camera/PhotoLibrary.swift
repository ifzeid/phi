import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoSaveError: Error {
    case notAuthorized
}

enum PhotoLibrary {
    static func addOnlyStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    static func requestAddOnly() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    static func save(data: Data, typeIdentifier: String, filename: String) async throws {
        let status = addOnlyStatus()
        let granted: PHAuthorizationStatus
        if status == .notDetermined {
            granted = await requestAddOnly()
        } else {
            granted = status
        }
        guard granted == .authorized || granted == .limited else { throw PhotoSaveError.notAuthorized }

        let payload = data
        let type = typeIdentifier
        let name = filename
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = type
            options.originalFilename = name
            request.addResource(with: .photo, data: payload, options: options)
        }
    }
}

enum StillArchive {
    static let countKey = "phi.captureCount"
    static let lastPathKey = "phi.lastStillPath"
    static let lastUTIKey = "phi.lastStillUTI"
    static let lastSavedKey = "phi.lastStillSavedToPhotos"
    static let grainStyleKey = "phi.grainStyle"

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

    static func write(data: Data, ext: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("PHI-\(formatter.string(from: Date())).\(ext)")
        try data.write(to: url, options: .atomic)
        prune()
        return url
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
        let stills = files
            .filter { $0.lastPathComponent.hasPrefix("PHI-") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for url in stills.dropFirst(3) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
