import CoreImage

/// Fixed develop looks. No brand names, no intensity controls.
/// Input and output are in the linear working space. 无 is identity: no base curve.
/// A selected look's cube runs in a temporary gamma so it is not crushed, then the image is linear again.
enum ColorLooks {
    static func apply(_ image: CIImage, look: ColorLook, halo: HaloLevel) -> CIImage {
        var current = image
        if look != .none {
            current = toPerceptual(current)
            switch look {
            case .none:
                break
            case .positive:
                current = grade(current, LookCubes.positive)
            case .negative:
                current = grade(current, LookCubes.negative)
            case .mono:
                current = grade(current, LookCubes.mono)
            case .ccd:
                current = ccd(current)
            }
            current = toLinear(current)
        }
        if halo != .off {
            current = highlightDiffusion(current, level: halo)
        }
        return current
    }

    private static func toPerceptual(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.4545])
    }

    private static func toLinear(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.2])
    }

    /// The cube is `LookRecipe.apply` in this same perceptual space. It is not a second grade.
    private static func grade(_ image: CIImage, _ cube: Data) -> CIImage {
        image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": NSNumber(value: LookRecipe.cubeDimension),
            "inputCubeData": cube
        ])
    }

    /// Fixed CCD still. Color, shoulder, and texture live here. `CIRAWFilter` noise reduction,
    /// sharpness, detail, and moiré stay at 0. The small sharpen below belongs only to this look.
    private static func ccd(_ image: CIImage) -> CIImage {
        let colored = grade(image, LookCubes.ccd)
        let crisp = sharpenedDownsample(colored)
        return shadowTexture(crisp)
    }

    /// About 8MP of softness on a full frame, then a small-radius edge. Previews already under 8MP only get a light pass.
    private static func sharpenedDownsample(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let width = extent.width
        let height = extent.height
        guard width > 2, height > 2 else { return image }
        let pixels = width * height
        let target: CGFloat = 8_000_000
        let factor = pixels > target ? CGFloat(sqrt(Double(target / pixels))) : 0.88
        guard let down = lanczos(image, factor), let up = lanczos(down, 1 / factor) else { return image }
        let placed = up.transformed(by: CGAffineTransform(
            translationX: extent.minX - up.extent.minX,
            y: extent.minY - up.extent.minY
        )).cropped(to: extent)
        return placed.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputRadiusKey: 0.65,
            kCIInputSharpnessKey: 0.38
        ])
    }

    private static func lanczos(_ image: CIImage, _ factor: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            return image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(factor, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return filter.outputImage
    }

    /// Weak chroma noise and a faint horizontal band, both held to the shadows.
    private static func shadowTexture(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let mask = shadowMask(image)
        let chroma = CCDTexture.chroma.applyingFilter("CIAffineTile").cropped(to: extent)
        let bands = CCDTexture.bands.applyingFilter("CIAffineTile").cropped(to: extent)
        let withChroma = maskedMix(image, overlay: chroma, mask: mask, amount: 0.08)
        return maskedMix(withChroma, overlay: bands, mask: mask, amount: 0.05)
    }

    private static func shadowMask(_ image: CIImage) -> CIImage {
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let gray = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": weights,
            "inputGVector": weights,
            "inputBVector": weights,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let scale = CGFloat(-1.0 / 0.30)
        return gray.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
    }

    private static func maskedMix(_ image: CIImage, overlay texture: CIImage, mask: CIImage, amount: Double) -> CIImage {
        guard let overlay = CIFilter(name: "CIOverlayBlendMode") else { return image }
        overlay.setValue(texture, forKey: kCIInputImageKey)
        overlay.setValue(image, forKey: kCIInputBackgroundImageKey)
        guard let overlaid = overlay.outputImage?.cropped(to: image.extent) else { return image }
        guard let dissolve = CIFilter(name: "CIDissolveTransition") else { return image }
        dissolve.setValue(image, forKey: kCIInputImageKey)
        dissolve.setValue(overlaid, forKey: kCIInputTargetImageKey)
        dissolve.setValue(amount, forKey: kCIInputTimeKey)
        guard let mixed = dissolve.outputImage?.cropped(to: image.extent) else { return image }
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        blend.setValue(mixed, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return (blend.outputImage ?? image).cropped(to: image.extent)
    }

    /// Physical highlight diffusion in linear light. A fraction of every tone, weighted toward
    /// highlights, is lifted out of the sharp image and returned as a tight bloom plus a wide veil.
    /// Glow colour is the source colour. Edges are clamped, so there is no vignette.
    /// `out = (1-k)*img + k*multiscaleGaussian(img * emphasis)`, then the glow is scaled so its
    /// mean luma matches the image. A flat field stays put. Runs after the look is linear again, before grain.
    private static func highlightDiffusion(_ image: CIImage, level: HaloLevel) -> CIImage {
        let extent = image.extent
        let longest = Swift.max(extent.width, extent.height)
        guard level != .off, longest > 2 else { return image }
        let weighted = image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": NSNumber(value: HaloWeight.dimension),
            "inputCubeData": HaloWeight.data
        ])
        let source = weighted.clampedToExtent()
        let tight = source.applyingGaussianBlur(sigma: longest * HaloOptics.tightRadius).cropped(to: extent)
        let wide = source.applyingGaussianBlur(sigma: longest * HaloOptics.wideRadius).cropped(to: extent)
        guard let scales = CIFilter(name: "CIDissolveTransition") else { return image }
        scales.setValue(tight, forKey: kCIInputImageKey)
        scales.setValue(wide, forKey: kCIInputTargetImageKey)
        scales.setValue(Double(1 - HaloOptics.tightMix), forKey: kCIInputTimeKey)
        let glow = (scales.outputImage ?? wide).cropped(to: extent)
        return StillPipeline.applyingDiffusion(image, glow: glow, scatter: level.scatter)
    }
}

/// Scatter fractions and radii for 光晕. Weak and strong match a diffusion filter's two steps, not a slider.
enum HaloOptics {
    static let weakScatter: CGFloat = 0.18
    static let strongScatter: CGFloat = 0.36
    /// Share of the scattered light that stays in the tight bloom. The rest is the wide veil.
    static let tightMix: CGFloat = 0.38
    /// Radii as a fraction of the long side.
    static let tightRadius: CGFloat = 0.02
    static let wideRadius: CGFloat = 0.18
    /// Every tone scatters at least this much. The rest of the weight rises toward highlights.
    static let emphasisFloor: CGFloat = 0.16

    static func emphasis(_ luma: Float) -> Float {
        let y = min(max(luma, Float(0)), Float(1))
        let t = smooth(0.04, 1, y)
        let shaped = t * t
        let floor = Float(emphasisFloor)
        return floor + (1 - floor) * shaped
    }

    private static func smooth(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let span = edge1 - edge0
        if span == 0 { return value < edge0 ? 0 : 1 }
        let t = min(max((value - edge0) / span, Float(0)), Float(1))
        return t * t * (3 - 2 * t)
    }
}

enum HaloLevel: String, CaseIterable, Identifiable, Codable {
    case off
    case weak
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关"
        case .weak: "弱"
        case .strong: "强"
        }
    }

    var scatter: CGFloat {
        switch self {
        case .off: 0
        case .weak: HaloOptics.weakScatter
        case .strong: HaloOptics.strongScatter
        }
    }
}

/// `rgb * emphasis(luma)` in linear light. The same factor on every channel, so a neutral stays neutral.
private enum HaloWeight {
    static let dimension = 17
    static let data: Data = {
        let size = dimension
        var samples = [Float](repeating: 0, count: size * size * size * 4)
        let last = Float(size - 1)
        var offset = 0
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let r = Float(red) / last
                    let g = Float(green) / last
                    let b = Float(blue) / last
                    let gain = HaloOptics.emphasis(GrainField.rec709(red: r, green: g, blue: b))
                    samples[offset] = r * gain
                    samples[offset + 1] = g * gain
                    samples[offset + 2] = b * gain
                    samples[offset + 3] = 1
                    offset += 4
                }
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }()
}

enum ColorLook: String, CaseIterable, Identifiable, Codable {
    case none
    case positive
    case negative
    case mono
    case ccd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "无"
        case .positive: "正片"
        case .negative: "负片"
        case .mono: "黑白"
        case .ccd: "CCD"
        }
    }
}

private enum LookCubes {
    static let positive = LookRecipe.positive.cubeData()
    static let negative = LookRecipe.negative.cubeData()
    static let mono = LookRecipe.mono.cubeData()
    static let ccd = LookRecipe.ccd.cubeData()
}

/// Baked once. Chroma is a weak color speckle. Bands are a few levels of horizontal magenta and green.
private enum CCDTexture {
    static let chroma: CIImage = image(width: 128, height: 128) { x, y in
        let n = unit(x, y, 0xC0D1)
        let shift = (n - 0.5) * 16
        return (128 + shift, 128, 128 - shift)
    }

    static let bands: CIImage = image(width: 8, height: 512) { _, y in
        let wave = sin(Double(y) * 0.82) * 0.65 + sin(Double(y) * 0.19) * 0.35
        let delta = wave * 4.5
        let red = 128 + (delta > 0 ? delta : delta * 0.25)
        let green = 128 + (delta < 0 ? -delta : -delta * 0.2)
        let blue = 128 + (delta > 0 ? delta * 0.65 : 0)
        return (red, green, blue)
    }

    private static func image(width: Int, height: Int, pixel: (Int, Int) -> (Double, Double, Double)) -> CIImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sample = pixel(x, y)
                let index = (y * width + x) * 4
                pixels[index] = byte(sample.0)
                pixels[index + 1] = byte(sample.1)
                pixels[index + 2] = byte(sample.2)
            }
        }
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let cg = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress else { return nil }
            let linear = CGColorSpace(name: CGColorSpace.linearDisplayP3)
            let device = CGColorSpaceCreateDeviceRGB()
            let context = (linear.flatMap { space in
                CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: bitmap
                )
            }) ?? CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: device,
                bitmapInfo: bitmap
            )
            return context?.makeImage()
        }
        // Code 128 is the overlay pivot in the manual-gamma grade. Tag extended-linear so Core Image
        // does not run a display decode (128 would become ~0.21 and the overlay would darken shadows).
        return CIImage(cgImage: cg ?? fallback(), options: [CIImageOption.colorSpace: StillPipeline.linearP3])
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(clamping: Int(value.rounded()))
    }

    private static func unit(_ x: Int, _ y: Int, _ seed: UInt32) -> Double {
        var n = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263) &+ seed
        n = (n ^ (n >> 13)) &* 1274126177
        return Double(n & 0x00FF_FFFF) / Double(0x00FF_FFFF)
    }

    private static func fallback() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }
}
