import CoreGraphics
import Foundation

/// Design coordinates of the 88 pt mechanical ruler (Figma 124:628), scaled to a live height.
/// Tests assert every mark stays inside `height`; the view must use these values, not a fixed 88 canvas.
enum CalibratedRulerMetrics {
    static let designHeight: CGFloat = 88

    struct Marks: Equatable {
        var height: CGFloat
        var scale: CGFloat
        var headerHeight: CGFloat
        var headerTextHeight: CGFloat
        var headerPaddingTop: CGFloat
        var tickY: CGFloat
        var tickMajor: CGFloat
        var tickHalf: CGFloat
        var tickFine: CGFloat
        var needleY: CGFloat
        var needleWidth: CGFloat
        var needleHeight: CGFloat
        var labelY: CGFloat
        var zeroDotY: CGFloat
        var zeroDotSize: CGFloat

        var needleMaxY: CGFloat { needleY + needleHeight }
        var tickMajorMaxY: CGFloat { tickY + tickMajor }
        var labelMaxY: CGFloat { labelY + headerTextHeight / 2 }
    }

    static func marks(for height: CGFloat) -> Marks {
        let h = max(height, 1)
        let s = h / designHeight
        return Marks(
            height: h,
            scale: s,
            headerHeight: 40 * s,
            headerTextHeight: 24 * s,
            headerPaddingTop: 8 * s,
            tickY: 42 * s,
            tickMajor: 12 * s,
            tickHalf: 9 * s,
            tickFine: 6 * s,
            needleY: 39 * s,
            needleWidth: 2,
            needleHeight: 22 * s,
            labelY: 70 * s,
            zeroDotY: 35 * s,
            zeroDotSize: 3 * s
        )
    }
}
