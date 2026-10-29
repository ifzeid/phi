import CoreGraphics
import Foundation

/// One step on the shutter-side zoom button.
/// 0.5× / 1× / 2× / 4× stand in for the stops the finder already had, about 14 / 25 / 50 / 108.
enum CaptureZoom: Double, CaseIterable, Equatable {
    case half = 0.5
    case one = 1
    case two = 2
    case four = 4

    var title: String {
        switch self {
        case .half: return "0.5×"
        case .one: return "1×"
        case .two: return "2×"
        case .four: return "4×"
        }
    }

    /// 0.5× is the only label wider than the 20 pt mark.
    var titleSize: CGFloat {
        switch self {
        case .half: return 16
        case .one, .two, .four: return 20
        }
    }
}

/// Maps the cycle onto the device's existing focal stops. Levels the camera does not have are left out.
enum ZoomCycle {
    struct Pair: Equatable {
        var zoom: CaptureZoom
        var stop: FocalStop
    }

    static func pairs(in stops: [FocalStop]) -> [Pair] {
        var pool = stops
        func take(where match: (FocalStop) -> Bool) -> FocalStop? {
            guard let index = pool.firstIndex(where: match) else { return nil }
            return pool.remove(at: index)
        }

        var found: [Pair] = []
        let wide = take { stop in
            let native = stop.isOpticalStep && abs(stop.zoomFactor - 1) < 0.05
            let aroundMain = stop.millimeters >= 18 && stop.millimeters <= 35
            return native && aroundMain
        }
        if let wide {
            found.append(Pair(zoom: .one, stop: wide))
        }
        let wideMM = wide?.millimeters ?? 25

        if let ultra = take(where: { $0.isOpticalStep && $0.millimeters < wideMM - 4 }) {
            found.append(Pair(zoom: .half, stop: ultra))
        }
        if let crop = take(where: { stop in
            if stop.isOpticalStep == false { return true }
            let target = wideMM * 2
            return abs(stop.millimeters - target) <= max(8, target / 5)
        }) {
            found.append(Pair(zoom: .two, stop: crop))
        }
        if let tele = take(where: { $0.isOpticalStep && $0.millimeters > wideMM * 2 + 8 }) {
            found.append(Pair(zoom: .four, stop: tele))
        }
        return found.sorted { $0.zoom.rawValue < $1.zoom.rawValue }
    }

    static func zoom(matching stopID: String?, in stops: [FocalStop]) -> CaptureZoom? {
        guard let stopID else { return nil }
        return pairs(in: stops).first { $0.stop.id == stopID }?.zoom
    }

    static func next(after current: CaptureZoom, in stops: [FocalStop]) -> Pair? {
        let list = pairs(in: stops)
        guard list.isEmpty == false else { return nil }
        let index = list.firstIndex { $0.zoom == current } ?? -1
        return list[(index + 1) % list.count]
    }
}
