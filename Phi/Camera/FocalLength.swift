import Foundation
import UIKit

/// One real lens, or the wide camera's 2× crop. Millimeters come from that camera's field of view.
struct FocalStop: Identifiable, Equatable, Hashable {
    var id: String
    var millimeters: Int
    /// Zoom factor on `deviceID`, not on a virtual multi-camera.
    var zoomFactor: Double
    /// False for the wide camera's 2× crop.
    var isOpticalStep: Bool
    var deviceID: String
}

struct LensSample {
    var id: String
    var millimeters: Int
    var isWide: Bool
    var allowsTwoXCrop: Bool
}

enum FocalLengthMath {
    /// `f = 18 / tan(horizontalFOV / 2)` at the format's native zoom.
    /// 18mm is half of the 36mm still-film gate.
    static func equivalentMillimeters(horizontalFOVDegrees fov: Double, zoom: Double = 1) -> Double? {
        guard fov > 8, fov < 170, zoom > 0 else { return nil }
        let base = 18.0 / tan((fov * .pi / 180) / 2)
        guard base.isFinite, base > 0 else { return nil }
        let result = base * zoom
        return result.isFinite ? result : nil
    }

    /// One stop per physical camera, plus a 2× crop of the wide camera when it is not already a separate lens.
    static func stops(from lenses: [LensSample]) -> [FocalStop] {
        var stops: [FocalStop] = []
        for lens in lenses where lens.millimeters > 0 {
            if stops.contains(where: { $0.deviceID == lens.id && abs($0.zoomFactor - 1) < 0.01 }) { continue }
            stops.append(FocalStop(
                id: lens.id,
                millimeters: lens.millimeters,
                zoomFactor: 1,
                isOpticalStep: true,
                deviceID: lens.id
            ))
        }
        if let wide = lenses.first(where: { $0.isWide && $0.allowsTwoXCrop }) {
            let crop = Int((Double(wide.millimeters) * 2).rounded())
            let alreadyThere = stops.contains { abs($0.millimeters - crop) <= max(3, crop / 12) }
            if !alreadyThere, crop > wide.millimeters {
                stops.append(FocalStop(
                    id: "\(wide.id)#2x",
                    millimeters: crop,
                    zoomFactor: 2,
                    isOpticalStep: false,
                    deviceID: wide.id
                ))
            }
        }
        return stops.sorted { lhs, rhs in
            if lhs.millimeters == rhs.millimeters { return lhs.zoomFactor < rhs.zoomFactor }
            return lhs.millimeters < rhs.millimeters
        }
    }

    /// Main wide camera at 1×. Not the nearest number to 35.
    static func defaultStop(_ stops: [FocalStop], wideDeviceID: String?) -> FocalStop? {
        if let wideDeviceID, let native = stops.first(where: { $0.deviceID == wideDeviceID && abs($0.zoomFactor - 1) < 0.01 }) {
            return native
        }
        return stops.first { abs($0.zoomFactor - 1) < 0.01 && $0.isOpticalStep } ?? stops.first
    }
}

/// Center crop for a focal-length stop that is a zoom into a physical camera.
/// `zoom` of 1 keeps the frame. `zoom` of 2 keeps the middle half of each side, at the pixels that region already has.
enum LensCrop {
    static func cropped(_ image: CIImage, zoom: Double) -> CIImage {
        guard zoom > 1.01 else { return image }
        let extent = image.extent.integral
        guard extent.width > 2, extent.height > 2, extent.isInfinite == false else { return image }
        let cropWidth = extent.width / zoom
        let cropHeight = extent.height / zoom
        let rect = CGRect(
            x: extent.origin.x + (extent.width - cropWidth) / 2,
            y: extent.origin.y + (extent.height - cropHeight) / 2,
            width: cropWidth,
            height: cropHeight
        ).integral
        guard rect.width > 1, rect.height > 1 else { return image }
        return image.cropped(to: rect)
    }

    static func cropped(_ image: CGImage, zoom: Double) -> CGImage {
        guard zoom > 1.01 else { return image }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 2, height > 2 else { return image }
        let cropWidth = width / zoom
        let cropHeight = height / zoom
        let rect = CGRect(
            x: (width - cropWidth) / 2,
            y: (height - cropHeight) / 2,
            width: cropWidth,
            height: cropHeight
        ).integral
        guard rect.width > 1, rect.height > 1, let cropped = image.cropping(to: rect) else { return image }
        return cropped
    }

    static func cropped(_ image: UIImage, zoom: Double) -> UIImage {
        guard zoom > 1.01, let cg = image.cgImage else { return image }
        return UIImage(cgImage: LensCrop.cropped(cg, zoom: zoom), scale: image.scale, orientation: image.imageOrientation)
    }
}

/// Zoom factors for one virtual multi-camera. Constituents are widest field of view first.
struct VirtualZoomDevice {
    var minimum: Double
    var maximum: Double
    var switchOvers: [Double]
    var constituentIDs: [String]
}

enum VirtualZoomMath {
    /// Zoom on the virtual device that frames `millimeters`.
    /// 1× is the wide camera. Nil when that physical camera is not a constituent, or the factor is outside the zoom range.
    static func factor(
        deviceID: String,
        millimeters: Int,
        optical: Bool,
        wideMillimeters: Int,
        device: VirtualZoomDevice
    ) -> Double? {
        guard wideMillimeters > 0, millimeters > 0 else { return nil }
        guard let index = device.constituentIDs.firstIndex(of: deviceID) else { return nil }
        guard device.maximum >= device.minimum, device.minimum > 0 else { return nil }
        let desired = Double(millimeters) / Double(wideMillimeters)
        guard desired.isFinite else { return nil }
        let lowerBound = device.minimum
        let upperBound = device.maximum

        // Virtual multi-cam: zoom 1 is the wide camera, including when an ultrawide sits below 1.
        if optical, abs(desired - 1) < 0.12 {
            guard lowerBound <= 1, upperBound >= 1 else { return nil }
            return 1
        }
        if desired < lowerBound - 0.15 || desired > upperBound + 0.15 {
            return nil
        }

        let switches = device.switchOvers
        if optical, desired > 1 {
            let entry = index > 0 && (index - 1) < switches.count ? switches[index - 1] : lowerBound
            var zoom = Swift.max(desired, entry)
            if index > 0, zoom <= entry + 0.0001 {
                zoom = entry + 0.02
            }
            guard zoom <= upperBound + 0.02 else { return nil }
            return Swift.min(upperBound, Swift.max(lowerBound, zoom))
        }

        var zoom = Swift.min(upperBound, Swift.max(lowerBound, desired))
        if optical, index == 0, let handoff = switches.first, zoom >= handoff {
            zoom = handoff - 0.01
        }
        guard zoom.isFinite, zoom + 0.001 >= lowerBound, zoom <= upperBound + 0.001 else { return nil }
        return Swift.min(upperBound, Swift.max(lowerBound, zoom))
    }
}
