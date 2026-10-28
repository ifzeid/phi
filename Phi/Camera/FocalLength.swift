import Foundation

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
