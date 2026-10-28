import CoreImage

/// Fixed develop looks. No brand names, no intensity controls.
/// Input and output are in the linear working space. Curves run in a temporary gamma so they are not crushed.
enum ColorLooks {
    static func apply(_ image: CIImage, look: ColorLook, halo: Bool, includeBase: Bool = true) -> CIImage {
        var current = toPerceptual(image)
        if includeBase {
            current = baseFilm(current)
        }
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
        if halo {
            current = highlightDiffusion(current)
        }
        return current
    }

    private static func toPerceptual(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.4545])
    }

    /// Global film curve. The toe lifts shadows instead of crushing them. No local tone mapping.
    private static func baseFilm(_ image: CIImage) -> CIImage {
        let curved = tone(image, points: [
            (0.00, 0.02),
            (0.12, 0.18),
            (0.40, 0.44),
            (0.72, 0.76),
            (1.00, 0.98)
        ])
        return curved.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.12,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: 1.04
        ])
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

    /// Ricoh-style highlight diffusion. Linear light, source color, no vignette and no tint.
    /// Runs after the look is back in linear light, and before grain.
    private static func highlightDiffusion(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let longest = Swift.max(extent.width, extent.height)
        guard longest > 2 else { return image }
        let highlights = tone(image, points: [
            (0.00, 0.00),
            (0.80, 0.00),
            (0.88, 0.35),
            (0.94, 0.72),
            (1.00, 1.00)
        ])
        let clamped = highlights.clampedToExtent()
        let wide = clamped.applyingGaussianBlur(sigma: longest * 0.028).cropped(to: extent)
        let tight = clamped.applyingGaussianBlur(sigma: longest * 0.016).cropped(to: extent)
        guard let scales = CIFilter(name: "CIDissolveTransition") else { return image }
        scales.setValue(tight, forKey: kCIInputImageKey)
        scales.setValue(wide, forKey: kCIInputTargetImageKey)
        scales.setValue(0.5, forKey: kCIInputTimeKey)
        let glow = (scales.outputImage ?? wide).cropped(to: extent)
        guard let screen = CIFilter(name: "CIScreenBlendMode") else { return image }
        screen.setValue(glow, forKey: kCIInputImageKey)
        screen.setValue(image, forKey: kCIInputBackgroundImageKey)
        guard let bloomed = screen.outputImage?.cropped(to: extent) else { return image }
        guard let mix = CIFilter(name: "CIDissolveTransition") else { return image }
        mix.setValue(image, forKey: kCIInputImageKey)
        mix.setValue(bloomed, forKey: kCIInputTargetImageKey)
        mix.setValue(0.30, forKey: kCIInputTimeKey)
        let mixed = (mix.outputImage ?? image).cropped(to: extent)
        return mixed.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: 0.95
        ])
    }

    private static func tone(_ image: CIImage, points: [(CGFloat, CGFloat)]) -> CIImage {
        var parameters: [String: Any] = [:]
        for (index, point) in points.enumerated() {
            parameters["inputPoint\(index)"] = CIVector(x: point.0, y: point.1)
        }
        return image.applyingFilter("CIToneCurve", parameters: parameters)
    }
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
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let cg = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmap
            ) else { return nil }
            return context.makeImage()
        }
        return CIImage(cgImage: cg ?? fallback())
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
