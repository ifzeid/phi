import Foundation

/// One selectable field of view. Millimeters are 35mm-film equivalents from the
/// format's horizontal field of view, not a manufacturer lens name.
struct FocalStop: Identifiable, Equatable, Hashable {
    var id: String
    var millimeters: Int
    var zoomFactor: Double
    /// True when the zoom sits on 1× or a virtual-device switch-over, rather than a crop between those steps.
    var isOpticalStep: Bool
}

struct FocalLengthProbe {
    var horizontalFOVDegrees: Double
    var minZoom: Double
    var maxZoom: Double
    var switchOverZooms: [Double]
}

enum FocalLengthMath {
    /// `f = 18 / tan(horizontalFOV / 2)`, then multiplied by the video zoom factor.
    /// 18mm is half of the 36mm still-film gate. Returns nil when the inputs cannot describe a lens.
    static func equivalentMillimeters(horizontalFOVDegrees fov: Double, zoom: Double) -> Double? {
        guard fov > 8, fov < 170, zoom > 0 else { return nil }
        let base = 18.0 / tan((fov * .pi / 180) / 2)
        guard base.isFinite, base > 0 else { return nil }
        let result = base * zoom
        return result.isFinite ? result : nil
    }

    /// Prefer 24 / 35 / 50 when this camera can actually reach them (within 12%), and always keep 1×.
    /// Otherwise label the hardware zoom steps with their real equivalents.
    static func stops(for probe: FocalLengthProbe) -> [FocalStop] {
        guard let base = equivalentMillimeters(horizontalFOVDegrees: probe.horizontalFOVDegrees, zoom: 1) else {
            return []
        }
        let minZ = probe.minZoom
        let maxZ = max(probe.maxZoom, minZ)
        guard maxZ >= minZ else { return [] }

        func millimeters(for zoom: Double) -> Int? {
            guard let value = equivalentMillimeters(horizontalFOVDegrees: probe.horizontalFOVDegrees, zoom: zoom) else {
                return nil
            }
            return Int(value.rounded())
        }

        let opticalZooms = ([minZ, 1.0] + probe.switchOverZooms).map { min(max($0, minZ), maxZ) }
        func isOptical(_ zoom: Double) -> Bool {
            opticalZooms.contains { abs($0 - zoom) < 0.06 }
        }

        var chosen: [FocalStop] = []
        func add(zoom rawZoom: Double, optical: Bool, requireTarget: Double?) {
            let zoom = min(max(rawZoom, minZ), maxZ)
            guard let actual = millimeters(for: zoom) else { return }
            if let target = requireTarget, Double(abs(actual - Int(target))) / target > 0.12 { return }
            if chosen.contains(where: { abs($0.zoomFactor - zoom) < 0.05 || abs($0.millimeters - actual) <= 2 }) { return }
            chosen.append(stop(millimeters: actual, zoom: zoom, optical: optical))
        }

        for target in [24.0, 35.0, 50.0] {
            let desired = target / base
            guard desired >= minZ - 0.02, desired <= maxZ + 0.02 else { continue }
            add(zoom: desired, optical: isOptical(desired), requireTarget: target)
        }
        add(zoom: 1, optical: true, requireTarget: nil)

        if chosen.count >= 2 {
            let ranked = chosen.sorted { lhs, rhs in
                distanceToClassic(lhs.millimeters) < distanceToClassic(rhs.millimeters)
            }
            var picked = Array(ranked.prefix(3))
            if let native = chosen.first(where: { abs($0.zoomFactor - 1) < 0.05 }),
               picked.contains(where: { $0.id == native.id }) == false {
                if picked.count == 3 { picked.removeLast() }
                picked.append(native)
            }
            return picked.sorted { $0.zoomFactor < $1.zoomFactor }
        }

        var hardware: [FocalStop] = []
        for zoom in Set(opticalZooms.map { ($0 * 100).rounded() / 100 }).sorted() {
            guard let actual = millimeters(for: zoom) else { continue }
            if hardware.contains(where: { abs($0.millimeters - actual) <= 2 }) { continue }
            hardware.append(stop(millimeters: actual, zoom: zoom, optical: true))
        }
        hardware.sort { $0.zoomFactor < $1.zoomFactor }
        if hardware.count <= 3 { return hardware }
        return [hardware[0], hardware[hardware.count / 2], hardware[hardware.count - 1]]
    }

    private static func distanceToClassic(_ millimeters: Int) -> Int {
        [24, 35, 50].map { abs($0 - millimeters) }.min() ?? millimeters
    }

    /// The working default is the stop nearest 35mm when that is close; otherwise the stop nearest 1×.
    static func preferred(_ stops: [FocalStop]) -> FocalStop? {
        if let near = stops.min(by: { abs($0.millimeters - 35) < abs($1.millimeters - 35) }),
           abs(near.millimeters - 35) <= 8 {
            return near
        }
        return stops.min { abs($0.zoomFactor - 1) < abs($1.zoomFactor - 1) }
    }

    private static func stop(millimeters: Int, zoom: Double, optical: Bool) -> FocalStop {
        FocalStop(
            id: "\(millimeters)-\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), zoom))",
            millimeters: millimeters,
            zoomFactor: zoom,
            isOpticalStep: optical
        )
    }
}
