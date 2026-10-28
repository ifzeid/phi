import CoreImage
import os

/// Single-frame Bayer develop. Noise reduction stays off after scale, because scale can restore defaults.
/// A little sharpness and detail stay on. The film curve lives in `ColorLooks`, not in `contrastAmount`.
/// The EV dial is `CIRAWFilter.exposure`. Apple's HEIF is not an input.
enum RawDevelop {
    static let exportQuality: CGFloat = 0.98

    static func image(
        dng: Data,
        exposureEV: Double,
        style: GrainStyle,
        look: ColorLook,
        halo: Bool,
        aspect: PhotoAspect,
        lensZoom: Double = 1,
        maxSide: CGFloat?,
        draft: Bool
    ) -> CGImage? {
        guard let filtered = filteredImage(
            dng: dng,
            exposureEV: exposureEV,
            aspect: aspect,
            lensZoom: lensZoom,
            maxSide: maxSide,
            draft: draft
        ) else {
            return nil
        }
        let looked = ColorLooks.apply(filtered, look: look, halo: halo, includeBase: true)
        let grained = StillPipeline.grained(looked, style: style)
        return StillPipeline.displayImage(grained)
    }

    private static func filteredImage(
        dng: Data,
        exposureEV: Double,
        aspect: PhotoAspect,
        lensZoom: Double,
        maxSide: CGFloat?,
        draft: Bool
    ) -> CIImage? {
        guard let filter = CIRAWFilter(imageData: dng, identifierHint: nil) else { return nil }
        filter.isDraftModeEnabled = draft
        let asShotTemperature = filter.neutralTemperature
        let asShotTint = filter.neutralTint
        let zoom = lensZoom > 1 ? lensZoom : 1
        let native = filter.nativeSize
        if let maxSide {
            let native = filter.nativeSize
            let longest = Swift.max(native.width, native.height)
            let needed = maxSide * zoom
            if longest > needed, longest > 0 {
                filter.scaleFactor = Float(needed / longest)
            } else {
                filter.scaleFactor = 1
            }
        } else {
            filter.scaleFactor = 1
        }
        filter.neutralTemperature = asShotTemperature
        filter.neutralTint = asShotTint
        silenceProcessing(filter, exposureEV: exposureEV)
        guard let output = filter.outputImage else { return nil }
        let oriented = ImageOrientation.upright(output, exif: ImageOrientation.exif(of: dng))
        let framed = LensCrop.cropped(oriented, zoom: zoom)
        Logger(subsystem: "com.zeid.phi", category: "develop").info("source DNG native \(Int(native.width))x\(Int(native.height)) scale \(filter.scaleFactor) zoom \(zoom)")
        return aspect.cropped(framed)
    }

    /// Applied after draft mode and scaleFactor so those changes cannot put noise reduction back.
    private static func silenceProcessing(_ filter: CIRAWFilter, exposureEV: Double) {
        let bounded = Swift.min(2, Swift.max(-2, exposureEV))
        filter.exposure = Float(bounded)
        filter.localToneMapAmount = 0
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.moireReductionAmount = 0
        filter.sharpnessAmount = 0
        filter.detailAmount = 0
        filter.boostAmount = 0
        filter.contrastAmount = 0
    }
}
