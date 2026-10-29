import CoreImage
import os

/// Bayer develop. Noise reduction, sharpness, detail, and moiré stay at 0 after scale,
/// because scale can restore defaults. The 无 look does not grade the file. Other looks are the
/// `LookRecipe` cubes. Only the CCD look resamples and sharpens.
/// ProRAW files are already multi-frame, demosaiced, and denoised by Apple; the same zeros still apply.
/// The EV dial is `CIRAWFilter.exposure`. Apple's HEIF is not an input.
enum RawDevelop {
    static let exportQuality: CGFloat = 0.98
    /// Last develop, for the on-screen line and the log. Not a user setting.
    static var lastReport = ""

    static func image(
        dng: Data,
        exposureEV: Double,
        style: GrainStyle,
        look: ColorLook,
        halo: HaloLevel,
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
        let looked = ColorLooks.apply(filtered, look: look, halo: halo)
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
        let baseline = silenceProcessing(filter, exposureEV: exposureEV)
        guard var output = filter.outputImage else { return nil }
        Self.lastReport = report(filter, native: native, output: output.extent, baseline: baseline)
        let lifted = sceneExposureLift(output)
        output = lifted.image
        Logger(subsystem: "com.zeid.phi", category: "develop").info("baselineExposure \(baseline) sceneLift \(lifted.extraEV)")
        let oriented = ImageOrientation.upright(output, exif: ImageOrientation.exif(of: dng))
        let framed = LensCrop.cropped(oriented, zoom: zoom)
        Logger(subsystem: "com.zeid.phi", category: "develop").info("source DNG native \(Int(native.width))x\(Int(native.height)) scale \(filter.scaleFactor) zoom \(zoom)")
        return aspect.cropped(framed)
    }

    /// Applied after draft mode and scaleFactor so those changes cannot put noise reduction back.
    /// `exposure` replaces the file's baseline, so the dial is added to `baselineExposure`.
    @discardableResult
    private static func silenceProcessing(_ filter: CIRAWFilter, exposureEV: Double) -> Float {
        let bounded = Swift.min(5, Swift.max(-5, exposureEV))
        let baseline = filter.baselineExposure
        filter.exposure = baseline + Float(bounded)
        filter.localToneMapAmount = 0
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.moireReductionAmount = 0
        filter.sharpnessAmount = 0
        filter.detailAmount = 0
        filter.boostAmount = 0
        filter.contrastAmount = 0
        filter.isLensCorrectionEnabled = false
        return baseline
    }

    private static func report(_ filter: CIRAWFilter, native: CGSize, output: CGRect, baseline: Float) -> String {
        let line = "native \(Int(native.width))x\(Int(native.height)) out \(Int(output.width))x\(Int(output.height)) scale \(filter.scaleFactor) draft \(filter.isDraftModeEnabled) exp \(filter.exposure) base \(baseline) nr \(filter.luminanceNoiseReductionAmount)/\(filter.colorNoiseReductionAmount) sharp \(filter.sharpnessAmount) detail \(filter.detailAmount) moire \(filter.moireReductionAmount) ltm \(filter.localToneMapAmount) lens \(filter.isLensCorrectionEnabled)"
        Logger(subsystem: "com.zeid.phi", category: "develop").info("\(line, privacy: .public)")
        return line
    }

    /// One global EV when the frame is still dark after baseline exposure. No local tone map.
    private static func sceneExposureLift(_ image: CIImage) -> (image: CIImage, extraEV: Float) {
        guard let mean = StillPipeline.meanLinearLuma(image), mean > 0.001, mean < 0.08 else {
            return (image, 0)
        }
        let needed = log2(Float(0.12) / mean)
        let extra = min(Float(1.5), max(Float(0), needed))
        guard extra >= 0.15 else { return (image, 0) }
        let lifted = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": extra])
        return (lifted, extra)
    }
}
