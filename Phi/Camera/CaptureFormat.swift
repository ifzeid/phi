import CoreImage
import Foundation

/// How a shutter press is developed. The viewfinder shows `mark`. Settings show `fullName`.
enum ProcessMode: String, CaseIterable, Identifiable {
    /// Single-frame Bayer RAW, developed in the app.
    case bayer
    /// Apple ProRAW. Already multi-frame, demosaiced, and denoised by Apple before the file exists.
    case proRaw
    /// Apple's processed HEIF or JPEG. No RAW request.
    case standard

    var id: String { rawValue }

    /// Short mark for the viewfinder. Not a product name.
    var mark: String {
        switch self {
        case .bayer: "0"
        case .proRaw: "Φ"
        case .standard: "1"
        }
    }

    /// Name under the setting. Do not call the Bayer path by a marketing name.
    var fullName: String {
        switch self {
        case .bayer: "Bayer RAW"
        case .proRaw: "ProRAW"
        case .standard: "Apple 处理"
        }
    }

    var wantsRaw: Bool { self != .standard }
    var wantsProRaw: Bool { self == .proRaw }

    static let storageKey = "phi.processMode"
    static let legacyFormatKey = "phi.captureFormat"
    static let saveHEIFKey = "phi.saveHEIF"

    struct Preference {
        var mode: ProcessMode
        var saveHEIF: Bool
    }

    /// Reads the new keys, or maps the old JPEG+RAW / RAW / JPEG setting once.
    static func load() -> Preference {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: storageKey), let mode = mode(fromStored: raw) {
            let save = defaults.object(forKey: saveHEIFKey) as? Bool ?? true
            return Preference(mode: mode, saveHEIF: mode == .standard ? true : save)
        }
        let old = defaults.string(forKey: legacyFormatKey)
        let preference: Preference
        switch old {
        case "raw":
            preference = Preference(mode: .bayer, saveHEIF: false)
        case "jpeg":
            preference = Preference(mode: .standard, saveHEIF: true)
        default:
            preference = Preference(mode: .bayer, saveHEIF: true)
        }
        defaults.set(preference.mode.rawValue, forKey: storageKey)
        defaults.set(preference.saveHEIF, forKey: saveHEIFKey)
        return preference
    }

    /// Stored value stays `standard`. The old on-screen word `标准` still loads as mode 1.
    private static func mode(fromStored raw: String) -> ProcessMode? {
        if raw == "标准" { return .standard }
        return ProcessMode(rawValue: raw)
    }

    static func label(mode: ProcessMode, aspect: String) -> String {
        guard aspect != "—" else { return mode.mark }
        return "\(mode.mark) · \(aspect)"
    }
}

/// Container for the Apple processed still. Capture falls back to JPEG when HEVC is missing.
enum ProcessedCodec: String, CaseIterable, Identifiable {
    case heic
    case jpeg

    var id: String { rawValue }
    var title: String { self == .heic ? "HEIC" : "JPEG" }

    static let storageKey = "phi.processedCodec"

    static func stored(_ raw: String?) -> ProcessedCodec {
        guard let raw, let codec = ProcessedCodec(rawValue: raw) else { return .heic }
        return codec
    }
}

/// Portrait crop. 3:4 is the full sensor. The others are a center crop of that frame.
enum PhotoAspect: String, CaseIterable, Identifiable {
    case square
    case threeByFour
    case twoByThree
    case nineBySixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: "1:1"
        case .threeByFour: "3:4"
        case .twoByThree: "2:3"
        case .nineBySixteen: "9:16"
        }
    }

    /// Width ÷ height while the phone is held in portrait.
    var widthOverHeight: CGFloat {
        switch self {
        case .square: 1
        case .threeByFour: 3.0 / 4.0
        case .twoByThree: 2.0 / 3.0
        case .nineBySixteen: 9.0 / 16.0
        }
    }

    /// Aspect is a center crop recorded for develop. It does not turn RAW off.
    var allowsRaw: Bool { true }

    static let storageKey = "phi.photoAspect"

    static func stored(_ raw: String?) -> PhotoAspect {
        guard let raw, let aspect = PhotoAspect(rawValue: raw) else { return .threeByFour }
        return aspect
    }

    /// Center crop. A no-op when the image is already this ratio.
    func cropped(_ image: CGImage) -> CGImage {
        let pixelWidth = CGFloat(image.width)
        let pixelHeight = CGFloat(image.height)
        guard pixelWidth > 1, pixelHeight > 1 else { return image }
        let current = pixelWidth / pixelHeight
        let target = widthOverHeight
        guard abs(current - target) > 0.008 else { return image }
        let rect: CGRect
        if target < current {
            let cropWidth = pixelHeight * target
            let originX = (pixelWidth - cropWidth) / 2
            rect = CGRect(x: originX, y: 0, width: cropWidth, height: pixelHeight)
        } else {
            let cropHeight = pixelWidth / target
            let originY = (pixelHeight - cropHeight) / 2
            rect = CGRect(x: 0, y: originY, width: pixelWidth, height: cropHeight)
        }
        let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        let integral = rect.integral.intersection(bounds)
        guard integral.width > 1, integral.height > 1, let cropped = image.cropping(to: integral) else { return image }
        return cropped
    }

    /// Same center crop in CIImage space. Extent origin is included so a non-zero origin still crops the middle.
    func cropped(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1, extent.isInfinite == false else { return image }
        let current = extent.width / extent.height
        let target = widthOverHeight
        guard abs(current - target) > 0.008 else { return image }
        let rect: CGRect
        if target < current {
            let cropWidth = extent.height * target
            let originX = extent.origin.x + (extent.width - cropWidth) / 2
            rect = CGRect(x: originX, y: extent.origin.y, width: cropWidth, height: extent.height)
        } else {
            let cropHeight = extent.width / target
            let originY = extent.origin.y + (extent.height - cropHeight) / 2
            rect = CGRect(x: extent.origin.x, y: originY, width: extent.width, height: cropHeight)
        }
        return image.cropped(to: rect.integral)
    }
}
