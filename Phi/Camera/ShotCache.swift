import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Small JPEGs written once at capture or develop. The album and the editor open these,
/// downsampled with ImageIO, and do not decode a full DNG or HEIF on the main thread.
enum ShotCache {
    static let gridSide: CGFloat = 360
    static var screenSide: CGFloat { EditorMatch.previewMaxSide }

    private static var root: URL {
        let base = StillArchive.directory.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func stem(forLibrary identifier: String) -> String {
        "lib-" + identifier.replacingOccurrences(of: "/", with: "_")
    }

    static func gridImage(stem: String) -> UIImage? {
        image(at: file(stem, kind: "grid"), maxSide: gridSide)
    }

    static func screenImage(stem: String) -> UIImage? {
        image(at: file(stem, kind: "screen"), maxSide: screenSide)
    }

    /// ImageIO thumbnail of a display still. A DNG is not a grid source. Existing files stay.
    static func storeIfNeeded(stem: String, fromFile url: URL) {
        let grid = file(stem, kind: "grid")
        let screen = file(stem, kind: "screen")
        if FileManager.default.fileExists(atPath: grid.path), FileManager.default.fileExists(atPath: screen.path) {
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return
        }
        if FileManager.default.fileExists(atPath: grid.path) == false, let cg = thumbnail(source, maxSide: gridSide) {
            writeJPEG(cg, to: grid, quality: 0.72)
        }
        if FileManager.default.fileExists(atPath: screen.path) == false, let cg = thumbnail(source, maxSide: screenSide) {
            writeJPEG(cg, to: screen, quality: 0.86)
        }
    }

    /// Replace both sizes. Mode 0 calls this after the develop, so the grid is not the Apple preview.
    static func store(stem: String, fromFile url: URL) {
        try? FileManager.default.removeItem(at: file(stem, kind: "grid"))
        try? FileManager.default.removeItem(at: file(stem, kind: "screen"))
        storeIfNeeded(stem: stem, fromFile: url)
    }

    static func store(stem: String, image: CGImage) {
        if let grid = scaled(image, maxSide: gridSide) {
            writeJPEG(grid, to: file(stem, kind: "grid"), quality: 0.72)
        }
        if let screen = scaled(image, maxSide: screenSide) {
            writeJPEG(screen, to: file(stem, kind: "screen"), quality: 0.86)
        }
    }

    static func remove(stem: String) {
        try? FileManager.default.removeItem(at: file(stem, kind: "grid"))
        try? FileManager.default.removeItem(at: file(stem, kind: "screen"))
    }

    private static func file(_ stem: String, kind: String) -> URL {
        let cleaned = stem.replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent("\(cleaned).\(kind).jpg")
    }

    private static func image(at url: URL, maxSide: CGFloat) -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        guard let cg = thumbnail(source, maxSide: maxSide) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func thumbnail(_ source: CGImageSource, maxSide: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func scaled(_ image: CGImage, maxSide: CGFloat) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let ratio = min(1, maxSide / CGFloat(longest))
        let width = max(1, Int((CGFloat(image.width) * ratio).rounded(.down)))
        let height = max(1, Int((CGFloat(image.height) * ratio).rounded(.down)))
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: url, options: .atomic)
    }
}
