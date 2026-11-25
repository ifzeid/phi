import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Full-resolution still used for export. Prefers the original file bytes over a preview cache.
enum ExportSource {
    static func loadImage(url: URL?, data: Data?) -> (image: CGImage, fileData: Data?)? {
        if let url {
            if let loaded = try? Data(contentsOf: url), let image = decode(loaded) {
                return (image, loaded)
            }
        }
        if let data, let image = decode(data) {
            return (image, data)
        }
        return nil
    }

    static func decode(_ data: Data) -> CGImage? {
        guard data.isEmpty == false,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// EXIF / TIFF orientation of a still file. Missing tags are treated as upright (1).
    static func exifOrientation(of data: Data?) -> CGImagePropertyOrientation {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return .up }
        let raw = props[kCGImagePropertyOrientation] as? UInt32
            ?? (props[kCGImagePropertyOrientation] as? Int).map(UInt32.init)
        guard let raw, let orientation = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return orientation
    }

    /// Full-res display pixels for a *developed* (non-DNG) export: bake EXIF orientation, then apply
    /// aspect and display zoom once. The encoded file is written with orientation 1 to match these pixels.
    /// Neutral exports should copy `fileData` instead of re-encoding this bitmap.
    /// `fallback` is only used when the disk/original bytes cannot be decoded; it is assumed already upright.
    static func preparedDisplayPixels(
        url: URL?,
        data: Data?,
        fallback: CGImage?,
        aspect: PhotoAspect,
        zoom: Double
    ) -> CGImage? {
        if let loaded = loadImage(url: url, data: data) {
            let orientation = exifOrientation(of: loaded.fileData)
            return ImageFraming.framedPixels(
                loaded.image,
                orientation: orientation,
                aspect: aspect,
                zoom: zoom
            )
        }
        guard let fallback else { return nil }
        return ImageFraming.framedPixels(fallback, orientation: .up, aspect: aspect, zoom: zoom)
    }

    static func filePayload(_ data: Data, url: URL?) -> (data: Data, ext: String, uti: String) {
        let ext = url?.pathExtension.lowercased() ?? ""
        switch ext {
        case "heic":
            return (data, "heic", UTType.heic.identifier)
        case "heif":
            return (data, "heif", UTType.heic.identifier)
        case "jpg", "jpeg":
            return (data, "jpg", UTType.jpeg.identifier)
        case "png":
            return (data, "png", UTType.png.identifier)
        default:
            break
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 {
            return (data, "jpg", UTType.jpeg.identifier)
        }
        if data.count >= 16 {
            let ascii = String(data: data.subdata(in: 4..<12), encoding: .ascii) ?? ""
            if ascii.contains("ftyp") {
                return (data, "heic", UTType.heic.identifier)
            }
        }
        return (data, "img", UTType.image.identifier)
    }
}
