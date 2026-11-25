import CoreGraphics
import Foundation

/// Positions measured from Figma 390×844 (safe top 47). Everything hangs off the safe area
/// so the iPhone 17 Pro (safe top 62) keeps the same rhythm.
struct CaptureChromeLayout {
    var width: CGFloat
    var height: CGFloat
    var home: CGFloat
    var flashCenter: CGPoint
    var settingsCenter: CGPoint
    var gridCenter: CGPoint
    var rawCenter: CGPoint
    var aspectCenter: CGPoint
    var photoFrame: CGRect
    var rulerFrame: CGRect
    var rowCenterY: CGFloat
    var shutterCenter: CGPoint
    var shutterSize: CGSize
    var thumbCenter: CGPoint
    var zoomCenter: CGPoint
    var finderBorderWidth: CGFloat

    /// Clear gap between the 36-pt top button row and the *outer* edge of the finder surround.
    static let topButtonGap: CGFloat = 8

    /// Visual thickness of the capture finder surround: **4 pt** at every scale.
    /// On a @3x phone that is 12 device pixels; on @2x it is 8. A previous 4-pixel (4/scale pt)
    /// reading was too thin. `scale` is kept so call sites can stay explicit; it does not change the width.
    static func finderBorderWidth(scale: CGFloat) -> CGFloat {
        _ = scale
        return 4
    }

    static func measure(width: CGFloat, height: CGFloat, island: CGFloat, home: CGFloat, scale: CGFloat) -> CaptureChromeLayout {
        // Figma 336:1737 on a 390×844 frame: RAW/more at y 53, recessed finder, ruler, style, 148×64 shutter.
        let chromeTop = island + 6
        let chromeCenterY = chromeTop + 18
        let side: CGFloat = 16
        let border = finderBorderWidth(scale: scale)
        let photoTop = chromeTop + 36 + topButtonGap + border
        let photoWidth = width - side * 2
        let photoHeight = photoWidth / PhotoAspect.finderWidthOverHeight
        var photo = CGRect(x: side, y: photoTop, width: photoWidth, height: photoHeight)
        var rulerHeight: CGFloat = 88
        var shutterHeight: CGFloat = 64
        let badgeHeight: CGFloat = 20
        let limit = height - home - 3
        let minRulerHeight: CGFloat = 56
        let minShutterHeight: CGFloat = 44
        let minPhotoGap: CGFloat = 8

        func pack(_ frame: CGRect, ruler: CGFloat, shutter: CGFloat, gap: CGFloat) -> (rulerTop: CGFloat, badgeTop: CGFloat, rowTop: CGFloat, overflow: CGFloat) {
            let rulerTop = frame.maxY + gap
            let badgeTop = rulerTop + ruler - 4
            let rowTop = badgeTop + badgeHeight + 8
            let overflow = max(0, rowTop + shutter - limit)
            return (rulerTop, badgeTop, rowTop, overflow)
        }

        var packed = pack(photo, ruler: rulerHeight, shutter: shutterHeight, gap: 16)
        if packed.overflow > 0 {
            // Shift the block up, but never let the ruler invade the photo.
            let minRulerTop = photo.maxY + minPhotoGap
            let shift = min(packed.overflow, max(0, packed.rulerTop - minRulerTop))
            packed.rulerTop -= shift
            packed.badgeTop -= shift
            packed.rowTop -= shift
            packed.overflow = max(0, packed.rowTop + shutterHeight - limit)
        }
        if packed.overflow > 0 {
            let shutterCut = min(packed.overflow, max(0, shutterHeight - minShutterHeight))
            shutterHeight -= shutterCut
            packed.overflow -= shutterCut
        }
        if packed.overflow > 0 {
            let rulerCut = min(packed.overflow, max(0, rulerHeight - minRulerHeight))
            rulerHeight -= rulerCut
            packed.badgeTop -= rulerCut
            packed.rowTop -= rulerCut
            packed.overflow -= rulerCut
        }
        if packed.overflow > 0 {
            // Last resort on very short phones: shrink the 3:4 photo so the shutter stays on-screen.
            let minBelow = minPhotoGap + minRulerHeight + badgeHeight + 8 + minShutterHeight
            let maxPhotoHeight = limit - photoTop - minBelow
            if maxPhotoHeight > 120, photo.height > maxPhotoHeight {
                let newHeight = maxPhotoHeight
                let newWidth = newHeight * PhotoAspect.finderWidthOverHeight
                photo = CGRect(x: (width - newWidth) / 2, y: photoTop, width: newWidth, height: newHeight)
                rulerHeight = minRulerHeight
                shutterHeight = minShutterHeight
                packed = pack(photo, ruler: rulerHeight, shutter: shutterHeight, gap: minPhotoGap)
            }
        }
        let rulerTop = packed.rulerTop
        let rowTop = packed.rowTop
        let bottomCenterY = rowTop + shutterHeight / 2
        let rulerWidth = min(CGFloat(342), width - 48)
        let rulerX = (width - rulerWidth) / 2
        let shutterWidth = 148 * (shutterHeight / 64)
        return CaptureChromeLayout(
            width: width,
            height: height,
            home: home,
            flashCenter: CGPoint(x: 41, y: chromeCenterY),
            settingsCenter: CGPoint(x: width - 12 - 24, y: chromeCenterY),
            gridCenter: CGPoint(x: width - 12 - 24 - 52, y: chromeCenterY),
            rawCenter: CGPoint(x: 12 + 28, y: chromeCenterY),
            aspectCenter: CGPoint(x: width / 2, y: chromeCenterY),
            photoFrame: photo,
            rulerFrame: CGRect(x: rulerX, y: rulerTop, width: rulerWidth, height: rulerHeight),
            rowCenterY: bottomCenterY,
            shutterCenter: CGPoint(x: width / 2, y: bottomCenterY),
            shutterSize: CGSize(width: shutterWidth, height: shutterHeight),
            thumbCenter: CGPoint(x: 28 + 22, y: bottomCenterY),
            zoomCenter: CGPoint(x: width - 28 - 24, y: bottomCenterY),
            finderBorderWidth: border
        )
    }

    var surroundFrame: CGRect {
        photoFrame.insetBy(dx: -finderBorderWidth, dy: -finderBorderWidth)
    }

    /// Shared 36 pt top-chrome row height (capture RAW/settings, editor close/compare).
    static let topButtonHeight: CGFloat = 36

    var topButtonCenterY: CGFloat { settingsCenter.y }

    /// Image *content* rect in the same window coordinates as the finder.
    /// 3:4 fills `photoFrame`. Other aspects use the centered crop window inside it.
    /// The 4 pt capture surround sits outside this rect and is not part of the metric.
    func contentFrame(for aspect: PhotoAspect) -> CGRect {
        let window = aspect.cropWindow(in: photoFrame.size)
        return window.offsetBy(dx: photoFrame.minX, dy: photoFrame.minY)
    }

    var styleBadgeCenter: CGPoint {
        CGPoint(x: width / 2, y: rulerFrame.maxY + 6)
    }

    /// The settings card sits one point above the home inset, inset 12 pt each side.
    func cardFrame(for page: SettingsPage) -> CGRect {
        let bottom = height - home - 1
        let cardHeight = page.cardHeight
        return CGRect(x: 12, y: bottom - cardHeight, width: width - 24, height: cardHeight)
    }
}
