import AVFoundation
import CoreLocation
import ImageIO
import UIKit

enum PhiVersion {
    /// Shown in EXIF/TIFF Software. Uses the bundle short version, currently 0.1.0.
    static var software: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return "PHI \(version)"
    }
}

enum PhotoMetadata {
    /// Apple's file bytes, with GPS and Software merged in. Pixel data is not re-encoded.
    static func fileData(from photo: AVCapturePhoto, location: CLLocation?) -> (data: Data?, metadata: [String: Any]) {
        let metadata = merged(photo.metadata, location: location)
        let data = photo.fileDataRepresentation(withReplacementMetadata: metadata) ?? photo.fileDataRepresentation()
        return (data, metadata)
    }

    static func properties(of data: Data) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    }

    /// Properties for one final HEIF/JPEG write. Orientation is upright because the pixels were already turned.
    static func exportProperties(from metadata: [String: Any]?, quality: CGFloat) -> [CFString: Any] {
        var props: [String: Any] = metadata ?? [:]
        props[kCGImagePropertyOrientation as String] = 1
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
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
