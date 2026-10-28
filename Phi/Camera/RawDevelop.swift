import CoreImage

/// Single-frame Bayer develop. Local tone mapping, noise reduction, and sharpening stay off.
/// The EV dial is `CIRAWFilter.exposure`. Apple's HEIF is not an input.
enum RawDevelop {
    static func image(
        dng: Data,
        exposureEV: Double,
        style: GrainStyle,
        aspect: PhotoAspect,
        maxSide: CGFloat?,
        draft: Bool
    ) -> CGImage? {
        guard let filtered = filteredImage(dng: dng, exposureEV: exposureEV, aspect: aspect, maxSide: maxSide, draft: draft) else {
            return nil
        }
        let grained = StillPipeline.grained(filtered, style: style)
        return StillPipeline.displayImage(grained)
    }

    private static func filteredImage(
        dng: Data,
        exposureEV: Double,
        aspect: PhotoAspect,
        maxSide: CGFloat?,
        draft: Bool
    ) -> CIImage? {
        guard let filter = CIRAWFilter(imageData: dng, identifierHint: nil) else { return nil }
        let bounded = Swift.min(2, Swift.max(-2, exposureEV))
        filter.exposure = Float(bounded)
        filter.localToneMapAmount = 0
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.sharpnessAmount = 0
        filter.boostAmount = 0
        filter.contrastAmount = 0
        filter.isDraftMode = draft
        if let maxSide {
            let native = filter.outputNativeSize
            let longest = max(native.width, native.height)
            if longest > maxSide, longest > 0 {
                filter.scaleFactor = Float(maxSide / longest)
            }
        }
        guard let output = filter.outputImage else { return nil }
        return aspect.cropped(output)
    }
}
