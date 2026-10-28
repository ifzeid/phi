import AVFoundation
import CoreImage
import CoreLocation
import ImageIO
import UniformTypeIdentifiers

enum ImageOrientation {
    static func exif(of data: Data) -> Int {
        guard let props = PhotoMetadata.properties(of: data),
              let value = props[kCGImagePropertyOrientation as String] as? Int else { return 1 }
        return value
    }

    /// Turns EXIF orientation into upright pixels. Callers then write orientation 1, not both and not neither.
    static func upright(_ image: CIImage, exif: Int) -> CIImage {
        guard let orientation = CGImagePropertyOrientation(rawValue: UInt32(exif)), orientation != .up else {
            return image
        }
        return image.oriented(orientation)
    }
}

enum PhiVersion {
    /// Shown in EXIF/TIFF Software. Uses the bundle short version, currently 0.1.0.
    static var software: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return "PHI \(version)"
    }
}

enum PhotoMetadata {
    /// Apple's container bytes, unchanged.
    /// Rewriting a HEIF (gain map and all) with ImageIO makes Photos reject the RAW pair as invalidResource (3300).
    /// GPS is stored on the Photos asset. The dictionary is kept for a later PHI develop.
    static func fileData(from photo: AVCapturePhoto, location: CLLocation?) -> (data: Data?, metadata: [String: Any]) {
        let metadata = merged(photo.metadata, location: location)
        return (photo.fileDataRepresentation(), metadata)
    }

    static func properties(of data: Data) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    }

    /// Properties for one final HEIF/JPEG write. Orientation is upright because the pixels were already turned.
    static func exportProperties(from metadata: [String: Any]?, quality: CGFloat) -> [CFString: Any] {
        var props: [String: Any] = [:]
        if let metadata {
            if let gps = metadata[kCGImagePropertyGPSDictionary as String] {
                props[kCGImagePropertyGPSDictionary as String] = gps
            }
            if let exif = metadata[kCGImagePropertyExifDictionary as String] {
                props[kCGImagePropertyExifDictionary as String] = exif
            }
        }
        props[kCGImagePropertyOrientation as String] = 1
        if let profile = CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() {
            props[kCGImagePropertyICCProfile as String] = profile
        }
        var tiff = metadata?[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFSoftware as String] = PhiVersion.software
        props[kCGImagePropertyTIFFDictionary as String] = tiff
        props[kCGImageDestinationLossyCompressionQuality as String] = quality
        var bridged: [CFString: Any] = [:]
        for (key, value) in props {
            bridged[key as CFString] = value
        }
        return bridged
    }

    private static func merged(_ metadata: [String: Any], location: CLLocation?) -> [String: Any] {
        var props = metadata
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFSoftware as String] = PhiVersion.software
        props[kCGImagePropertyTIFFDictionary as String] = tiff
        if let location {
            props[kCGImagePropertyGPSDictionary as String] = gpsDictionary(from: location)
        }
        return props
    }

    private static func gpsDictionary(from location: CLLocation) -> [String: Any] {
        var gps: [String: Any] = [:]
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        gps[kCGImagePropertyGPSLatitude as String] = abs(latitude)
        gps[kCGImagePropertyGPSLatitudeRef as String] = latitude >= 0 ? "N" : "S"
        gps[kCGImagePropertyGPSLongitude as String] = abs(longitude)
        gps[kCGImagePropertyGPSLongitudeRef as String] = longitude >= 0 ? "E" : "W"
        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = location.altitude >= 0 ? 0 : 1
        }
        if location.horizontalAccuracy >= 0 {
            gps[kCGImagePropertyGPSHPositioningError as String] = location.horizontalAccuracy
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss"
        gps[kCGImagePropertyGPSTimeStamp as String] = formatter.string(from: location.timestamp)
        formatter.dateFormat = "yyyy:MM:dd"
        gps[kCGImagePropertyGPSDateStamp as String] = formatter.string(from: location.timestamp)
        return gps
    }
}

/// One captured container, described from its bytes. Photos uses this UTI and these pixel sizes.
struct CapturedContainer {
    var data: Data
    var typeIdentifier: String
    var filenameExtension: String
    var pixelWidth: Int
    var pixelHeight: Int
    var orientation: Int

    var isDecodableImage: Bool {
        guard data.count > 64 else { return false }
        if pixelWidth > 1, pixelHeight > 1 { return true }
        return filenameExtension == "heic" || filenameExtension == "jpg"
    }

    var isRawContainer: Bool {
        typeIdentifier == "com.adobe.raw-image" || filenameExtension == "dng"
    }

    /// 5...8 are the mirrored and rotated tags. They swap the stored axes.
    var orientedWidth: Int { (5...8).contains(orientation) ? pixelHeight : pixelWidth }
    var orientedHeight: Int { (5...8).contains(orientation) ? pixelWidth : pixelHeight }

    var logLine: String {
        "\(typeIdentifier) \(data.count) bytes \(pixelWidth)x\(pixelHeight) orient \(orientation)"
    }

    /// Same capture when the stored pixels match, or the oriented pixels match.
    func matchesPixels(of other: CapturedContainer) -> Bool {
        if pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight { return true }
        return orientedWidth == other.orientedWidth && orientedHeight == other.orientedHeight && orientedWidth > 1
    }

    static func inspect(_ data: Data) -> CapturedContainer {
        let kind = kind(of: data)
        var width = 0
        var height = 0
        var orientation = 1
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        }
        return CapturedContainer(
            data: data,
            typeIdentifier: kind.uti,
            filenameExtension: kind.ext,
            pixelWidth: width,
            pixelHeight: height,
            orientation: orientation
        )
    }

    private static func kind(of data: Data) -> (uti: String, ext: String) {
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            return (UTType.jpeg.identifier, "jpg")
        }
        if let brand = ftypBrand(data), heifBrands.contains(brand) {
            return (UTType.heic.identifier, "heic")
        }
        if data.count >= 4 {
            let tiffLE = data[0] == 0x49 && data[1] == 0x49 && data[2] == 0x2A && data[3] == 0x00
            let tiffBE = data[0] == 0x4D && data[1] == 0x4D && data[2] == 0x00 && data[3] == 0x2A
            if tiffLE || tiffBE {
                return ("com.adobe.raw-image", "dng")
            }
        }
        return ("public.data", "dat")
    }

    private static let heifBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "heim", "heis", "avci"]

    /// Major brand at byte 8 of an ISO BMFF file. `ftyp` sits at byte 4.
    private static func ftypBrand(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let ftyp = data.subdata(in: 4..<8)
        guard String(data: ftyp, encoding: .ascii) == "ftyp" else { return nil }
        let brand = data.subdata(in: 8..<12)
        return String(data: brand, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters)
    }
}
