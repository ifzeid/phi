import CoreImage
import Foundation

/// What a shutter press writes into Photos. The processed file is HEIC when the device offers HEVC, otherwise JPEG.
enum CaptureFormat: String, CaseIterable, Identifiable {
    /// Processed still plus Bayer RAW, as one paired library asset. Zeid's usual setting.
    case jpegAndRaw
    case raw
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpegAndRaw: "JPEG+RAW"
        case .raw: "RAW"
        case .jpeg: "JPEG"
        }
    }

    /// Ask the camera for Bayer when this stop can deliver it.
    var wantsRaw: Bool { self != .jpeg }

    static let storageKey = "phi.captureFormat"

    static func stored(_ raw: String?) -> CaptureFormat {
        guard let raw, let format = CaptureFormat(rawValue: raw) else { return .jpegAndRaw }
        return format
    }

    /// Top-bar readout. `rawDelivered` is false on a crop stop that cannot shoot Bayer.
    static func label(preference: CaptureFormat, rawDelivered: Bool, codec: String, aspect: String) -> String {
        let head: String
        switch preference {
        case .jpeg:
            head = codec
        case .raw:
            head = rawDelivered ? "RAW" : codec
        case .jpegAndRaw:
            head = rawDelivered ? "RAW+\(codec)" : codec
        }
        guard aspect != "—" else { return head }
        return "\(head) · \(aspect)"
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

    /// Bayer RAW stays the full sensor frame, so only 3:4 keeps it.
    var allowsRaw: Bool { self == .threeByFour }

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
