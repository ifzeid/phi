import CoreImage
import os

/// Fixed develop looks. No brand names, no intensity controls.
/// Input and output are in the linear working space. 无 is identity: no base curve.
/// A look's cube is authored in display-encoded P3. `CIColorCubeWithColorSpace` converts
/// into that space, applies the lattice, and converts back. A plain `CIColorCube` in the
/// extended-linear working space leaves the lattice unused, so the look is a no-op.
enum ColorLooks {
    static func apply(_ image: CIImage, look: ColorLook, halo: HaloLevel) -> CIImage {
        withHalo(graded(image, look: look), level: halo)
    }

    static func graded(_ image: CIImage, look: ColorLook) -> CIImage {
        switch look {
        case .none:
            return image
        case .positive:
            return applyCube(image, recipe: .positive, data: LookCubes.positive)
        case .negative:
            return applyCube(image, recipe: .negative, data: LookCubes.negative)
        case .mono:
            return applyCube(image, recipe: .mono, data: LookCubes.mono)
        case .ccd:
            return ccd(image)
        }
    }

    static func withHalo(_ image: CIImage, level: HaloLevel) -> CIImage {
        StillPipeline.applyHalo(image, level: level)
    }

    private static func toPerceptual(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.4545])
    }

    private static func toLinear(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.2])
    }

    /// Display-P3 lattice. Falls back to `LookRecipe.apply` on pixels if the GPU cube does not grade.
    private static func applyCube(_ image: CIImage, recipe: LookRecipe, data: Data) -> CIImage {
        if gpuCubeBroken {
            return StillPipeline.gradePixels(image, recipe: recipe)
        }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": NSNumber(value: LookRecipe.cubeDimension),
            "inputCubeData": data,
            "inputColorSpace": StillPipeline.displayP3
        ])
    }

    /// True when a saturated red is still saturated after the mono cube.
    private static let gpuCubeBroken: Bool = {
        let broken = probeCube()
        if broken {
            Logger(subsystem: "com.zeid.phi", category: "develop")
                .error("color cube did not grade; applying the recipe on pixels")
        }
        return broken
    }()

    private static func probeCube() -> Bool {
        let width = 4
        let height = 4
        let space = StillPipeline.displayP3
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        let fill = CGColor(colorSpace: space, components: [0.84, 0.10, 0.08, 1])
            ?? CGColor(srgbRed: 0.84, green: 0.10, blue: 0.08, alpha: 1)
        ctx.setFillColor(fill)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage(), let source = rgba(cg) else { return true }
        guard source.0 > source.1 + 40 else { return true }
        let input = CIImage(cgImage: cg, options: [CIImageOption.colorSpace: space])
        let graded = input.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": NSNumber(value: LookRecipe.cubeDimension),
            "inputCubeData": LookCubes.mono,
            "inputColorSpace": space
        ])
        guard let out = StillPipeline.displayImage(graded), let pixel = rgba(out) else { return true }
        let spread = max(pixel.0, pixel.1, pixel.2) - min(pixel.0, pixel.1, pixel.2)
        return spread > 10
    }

    private static func rgba(_ image: CGImage) -> (Int, Int, Int)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drew = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: StillPipeline.displayP3,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drew else { return nil }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// Fixed CCD still. Color, shoulder, and texture live here. `CIRAWFilter` noise reduction,
    /// sharpness, detail, and moiré stay at 0. The small sharpen below belongs only to this look.
    private static func ccd(_ image: CIImage) -> CIImage {
        let colored = applyCube(image, recipe: .ccd, data: LookCubes.ccd)
        // Texture samples were built for perceptual code values. The cube itself is already
        // back in linear light, so this round trip does not wrap the grade.
        let perceptual = toPerceptual(colored)
        return toLinear(shadowTexture(sharpenedDownsample(perceptual)))
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

}

/// Scatter fractions and radii for 光晕. Weak and strong are two steps, not a slider.
/// `Tests/look_calibration_test.py` mirrors `emphasis` and the additive mix.
enum HaloOptics {
    static let weakScatter: CGFloat = 0.42
    static let strongScatter: CGFloat = 1.05
    /// Share of the blurred highlight in the tight, medium, and wide pyramid passes.
    static let tightWeight: CGFloat = 0.45
    static let mediumWeight: CGFloat = 0.40
    static let wideWeight: CGFloat = 0.15
    /// Radii as a fraction of the long side. The wide step stays local; it is not a frame veil.
    static let tightRadius: CGFloat = 0.015
    static let mediumRadius: CGFloat = 0.035
    static let wideRadius: CGFloat = 0.055
    /// Soft knee on display luma. Below 0.8 of display white, nothing is extracted.
    /// Scene-linear values above 1 encode past this end and enter fully.
    static let knee: Float = 0.80
    static let highlightEnd: Float = 0.96

    /// `displayLuma` is the encoded Rec.709 of the linear pixel. Below `knee` the gain is 0.
    static func emphasis(_ displayLuma: Float) -> Float {
        let y = min(max(displayLuma, Float(0)), Float(1))
        if y <= knee { return 0 }
        if y >= highlightEnd { return 1 }
        let t = (y - knee) / (highlightEnd - knee)
        return t * t * (3 - 2 * t)
    }

    /// Same weight on every channel, so the extracted light keeps the source hue.
    static func highlightGain(red: Float, green: Float, blue: Float) -> Float {
        let luma = GrainField.rec709(red: red, green: green, blue: blue)
        if luma <= 0 { return 0 }
        return emphasis(GrainField.encoded(luma))
    }

    /// `base + scatter * glow`. A zero or dust-level glow returns `base` unchanged. Values already at 1 stay put.
    static func addBloom(base: Float, glow: Float, scatter: Float) -> Float {
        let extra = scatter * glow
        // Below this, display code moves by less than 1/255, so the pixel stays bit-identical.
        if extra <= 0.0001 { return base }
        if base >= 1 { return base }
        let sum = base + extra
        if sum >= 1 { return 1 }
        return sum
    }

    /// Pure-function check used by the debug assertion. Same knee, radii, and rolloff as the filter.
    static func spatialFailures() -> [String] {
        let width = 72
        let height = 40
        var notes: [String] = []
        var weakGain: Float = 0
        var strongGain: Float = 0
        for (scatter, name) in [(weakScatter, "弱"), (strongScatter, "强")] {
            let flat = [Float](repeating: 0.45, count: width * height * 3)
            let flatOut = referenceDiffuse(flat, width: width, height: height, scatter: Float(scatter))
            var worst: Float = 0
            for index in flat.indices {
                worst = max(worst, abs(flatOut[index] - flat[index]) / 0.45)
            }
            if worst > 0.005 {
                notes.append("\(name) gray below knee moved \(worst)")
            }
            let x0 = width / 2 - 4
            let y0 = height / 2 - 4
            var scene = [Float](repeating: 0.02, count: width * height * 3)
            for y in y0..<(y0 + 8) {
                for x in x0..<(x0 + 8) {
                    let index = (y * width + x) * 3
                    scene[index] = 1
                    scene[index + 1] = 1
                    scene[index + 2] = 1
                }
            }
            let diffused = referenceDiffuse(scene, width: width, height: height, scatter: Float(scatter))
            let shadowLift = darkestDisplayLift(before: scene, after: diffused)
            if shadowLift > 1 {
                notes.append("\(name) darkest decile lifted \(shadowLift)")
            }
            var far: Float = 0
            for y in 0..<6 {
                for x in 0..<6 {
                    let index = (y * width + x) * 3
                    far = max(far, abs(diffused[index] - scene[index]) / max(scene[index], 0.0001))
                }
            }
            if far > 0.005 {
                notes.append("\(name) far dark moved \(far)")
            }
            let neighbor = ((y0 + 4) * width + (x0 - 1)) * 3
            let gain = (diffused[neighbor] + diffused[neighbor + 1] + diffused[neighbor + 2]) / 3 - 0.02
            if name == "弱" { weakGain = gain } else { strongGain = gain }
            if gain < 0.01 {
                notes.append("\(name) neighbor did not gain glow \(gain)")
            }
            let center = ((y0 + 4) * width + (x0 + 4)) * 3
            let lifted = diffused[center] - scene[center]
            if lifted > 0.004 {
                notes.append("\(name) bright source was lifted \(lifted)")
            }
        }
        if strongGain <= weakGain {
            notes.append("强 glow \(strongGain) is not above 弱 \(weakGain)")
        }
        let x0 = width / 2 - 4
        let y0 = height / 2 - 4
        var warm = [Float](repeating: 0.03, count: width * height * 3)
        for y in y0..<(y0 + 8) {
            for x in x0..<(x0 + 8) {
                let index = (y * width + x) * 3
                warm[index] = 1
                warm[index + 1] = 0.72
                warm[index + 2] = 0.38
            }
        }
        let warmOut = referenceDiffuse(warm, width: width, height: height, scatter: Float(strongScatter))
        let beside = ((y0 + 4) * width + (x0 - 1)) * 3
        let dRed = warmOut[beside] - warm[beside]
        let dBlue = warmOut[beside + 2] - warm[beside + 2]
        if dRed <= dBlue {
            notes.append("warm glow did not keep source hue")
        }
        notes.append(contentsOf: nightSkyFailures())
        notes.append(contentsOf: brightSkyFailures())
        return notes
    }

    /// Black sky and two hot lamps. Pixels outside the blur stay identical; the rim around a lamp rises.
    private static func nightSkyFailures() -> [String] {
        let width = 96
        let height = 64
        var scene = [Float](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            let offset = index * 3
            scene[offset] = 0.008
            scene[offset + 1] = 0.009
            scene[offset + 2] = 0.012
        }
        let lamps = [(24, 18), (70, 40)]
        for lamp in lamps {
            for dy in -1...1 {
                for dx in -1...1 {
                    let x = lamp.0 + dx
                    let y = lamp.1 + dy
                    let offset = (y * width + x) * 3
                    scene[offset] = 2.8
                    scene[offset + 1] = 2.1
                    scene[offset + 2] = 1.4
                }
            }
        }
        let diffused = referenceDiffuse(scene, width: width, height: height, scatter: Float(weakScatter))
        var notes: [String] = []
        let corner = abs(diffused[0] - scene[0]) + abs(diffused[1] - scene[1]) + abs(diffused[2] - scene[2])
        if corner > 0.000001 {
            notes.append("night sky far from lamps moved \(corner)")
        }
        let beside = (18 * width + 20) * 3
        let gain = GrainField.rec709(
            red: diffused[beside] - scene[beside],
            green: diffused[beside + 1] - scene[beside + 1],
            blue: diffused[beside + 2] - scene[beside + 2]
        )
        if gain < 0.01 {
            notes.append("night lamp rim did not gain bloom \(gain)")
        }
        let redGain = diffused[beside] - scene[beside]
        let blueGain = diffused[beside + 2] - scene[beside + 2]
        if redGain <= blueGain {
            notes.append("night lamp bloom did not keep the warm hue")
        }
        return notes
    }

    /// Same courtyard frame as `daylight_scene()` in Tests/look_calibration_test.py.
    /// A near-white linear wall (0.94) encodes around 0.97, so it is not clipped yet, but strong
    /// screen fill uses the rest of the headroom and lands on 1. That probe marked about 84% of
    /// the frame as newly clipped. These daylight colors are the ones the look test measures.
    private static func brightSkyFailures() -> [String] {
        let width = 128
        let height = 80
        let scene = daylightScene(width: width, height: height)
        let weak = referenceDiffuse(scene, width: width, height: height, scatter: Float(weakScatter))
        let strong = referenceDiffuse(scene, width: width, height: height, scatter: Float(strongScatter))
        let before = clipFraction(scene)
        var notes: [String] = []
        let weakRise = meanDisplayLevel(weak) - meanDisplayLevel(scene)
        let strongRise = meanDisplayLevel(strong) - meanDisplayLevel(scene)
        if weakRise < Float(0.8) || weakRise > Float(3) {
            notes.append("bright sky 弱 mean rise \(weakRise) levels is outside 0.8–3")
        }
        if strongRise < Float(2.2) || strongRise > Float(6) {
            notes.append("bright sky 强 mean rise \(strongRise) levels is outside 2.2–6")
        }
        if strongRise < weakRise + Float(1.2) {
            notes.append("bright sky 强 mean rise \(strongRise) is not clearly above 弱 \(weakRise)")
        }
        let pair: [(String, [Float])] = [("弱", weak), ("强", strong)]
        for (name, diffused) in pair {
            let after = clipFraction(diffused)
            if after - before > Float(0.02) {
                notes.append("bright sky \(name) clipped-area delta \(after - before)")
            }
            let shadow = shadowRectangleLift(before: scene, after: diffused, width: width, height: height)
            if shadow > Float(1) {
                notes.append("bright sky \(name) far shadow lifted \(shadow) levels")
            }
        }
        let wallX = Int(Float(width) * 0.42) + 1
        let yStart = Int(Float(height) * 0.45)
        let yEnd = Int(Float(height) * 0.70)
        if yEnd > yStart, wallX >= 3 {
            var band = Float(0)
            var weakBand = Float(0)
            let rows = yEnd - yStart
            for y in yStart..<yEnd {
                let index = y * width + (wallX - 3)
                band += displayLevel(strong, index: index) - displayLevel(scene, index: index)
                weakBand += displayLevel(weak, index: index) - displayLevel(scene, index: index)
            }
            let bandGain = band / Float(rows)
            if bandGain < Float(8) {
                notes.append("bright sky halo beside the wall is not visible (\(bandGain) levels)")
            }
            if weakBand / Float(rows) > bandGain * Float(0.75) {
                notes.append("bright sky 弱 bloom beside the wall is not clearly quieter than 强")
            }
        }
        var far = Float(0)
        let corner = min(8, width * height)
        for index in 0..<corner {
            far = max(far, abs(displayLevel(strong, index: index) - displayLevel(scene, index: index)))
        }
        if far > Float(1.5) {
            notes.append("bright sky far corner moved \(far) levels")
        }
        return notes
    }

    /// Sky, white wall, terracotta, and a far shadow. Layout matches `daylight_scene()`.
    private static func daylightScene(width: Int, height: Int) -> [Float] {
        let sky: (Float, Float, Float) = (0.3916, 0.5647, 0.7605)
        let wall: (Float, Float, Float) = (0.8388, 0.7913, 0.7011)
        let terra: (Float, Float, Float) = (0.4342, 0.1620, 0.0685)
        let shadow: (Float, Float, Float) = (0.0194, 0.0144, 0.0116)
        var scene = [Float](repeating: 0, count: width * height * 3)
        let skyLimit = Int(Float(height) * 0.38)
        let wallX = Int(Float(width) * 0.42)
        let wallLimit = Int(Float(height) * 0.82)
        let shadowLimit = Int(Float(height) * 0.70)
        for y in 0..<height {
            for x in 0..<width {
                let sample: (Float, Float, Float)
                if y < skyLimit {
                    sample = sky
                } else if x > wallX, y < wallLimit {
                    sample = wall
                } else if x < 18, y > shadowLimit {
                    sample = shadow
                } else {
                    sample = terra
                }
                let offset = (y * width + x) * 3
                scene[offset] = sample.0
                scene[offset + 1] = sample.1
                scene[offset + 2] = sample.2
            }
        }
        return scene
    }

    private static func clipFraction(_ pixels: [Float]) -> Float {
        let count = pixels.count / 3
        guard count > 0 else { return 0 }
        var clipped = 0
        for index in 0..<count {
            let offset = index * 3
            let peak = max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2]))
            if GrainField.encoded(peak) >= 254.5 / 255 {
                clipped += 1
            }
        }
        return Float(clipped) / Float(count)
    }

    /// Display-code level, matching `display_code` in the look test: encode each channel, then Rec.709.
    private static func displayLevel(_ pixels: [Float], index: Int) -> Float {
        let offset = index * 3
        let red = GrainField.encoded(min(max(pixels[offset], Float(0)), Float(1)))
        let green = GrainField.encoded(min(max(pixels[offset + 1], Float(0)), Float(1)))
        let blue = GrainField.encoded(min(max(pixels[offset + 2], Float(0)), Float(1)))
        return 255 * GrainField.rec709(red: red, green: green, blue: blue)
    }

    private static func meanDisplayLevel(_ pixels: [Float]) -> Float {
        let count = pixels.count / 3
        guard count > 0 else { return 0 }
        var sum = Float(0)
        for index in 0..<count {
            sum += displayLevel(pixels, index: index)
        }
        return sum / Float(count)
    }

    /// The bottom-left shadow in `daylightScene`, away from the white wall.
    private static func shadowRectangleLift(before: [Float], after: [Float], width: Int, height: Int) -> Float {
        let y0 = Int(Float(height) * 0.70) + 1
        var sum = Float(0)
        var count = 0
        for y in y0..<height {
            for x in 0..<min(18, width) {
                let index = y * width + x
                sum += displayLevel(after, index: index) - displayLevel(before, index: index)
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return sum / Float(count)
    }

    /// Mean display-level change of the darkest tenth of the frame.
    private static func darkestDisplayLift(before: [Float], after: [Float]) -> Float {
        let count = before.count / 3
        guard count > 0, after.count == before.count else { return 0 }
        var levels = [(Float, Float)]()
        levels.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * 3
            let source = GrainField.rec709(red: before[offset], green: before[offset + 1], blue: before[offset + 2])
            let result = GrainField.rec709(red: after[offset], green: after[offset + 1], blue: after[offset + 2])
            let sourceLevel = GrainField.encoded(min(max(source, 0), 1)) * 255
            let resultLevel = GrainField.encoded(min(max(result, 0), 1)) * 255
            levels.append((sourceLevel, resultLevel - sourceLevel))
        }
        levels.sort { $0.0 < $1.0 }
        let take = max(1, count / 10)
        var sum = Float(0)
        for index in 0..<take {
            sum += levels[index].1
        }
        return sum / Float(take)
    }

    private static func referenceDiffuse(_ pixels: [Float], width: Int, height: Int, scatter: Float) -> [Float] {
        bloom(pixels, width: width, height: height, scatter: scatter, stride: 3)
    }

    /// Highlight energy only, blurred with a finite gaussian, then added. A zero glow leaves the pixel untouched.
    static func bloom(_ pixels: [Float], width: Int, height: Int, scatter: Float, stride: Int) -> [Float] {
        let count = width * height
        let factor = pyramidFactor(width: width, height: height)
        let smallW = max(1, (width + factor - 1) / factor)
        let smallH = max(1, (height + factor - 1) / factor)
        var energy = [Float](repeating: 0, count: smallW * smallH * 3)
        var coverage = [Int](repeating: 0, count: smallW * smallH)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * stride
                let red = pixels[offset]
                let green = pixels[offset + 1]
                let blue = pixels[offset + 2]
                let sx = min(smallW - 1, x / factor)
                let sy = min(smallH - 1, y / factor)
                let bin = sy * smallW + sx
                coverage[bin] += 1
                let gain = highlightGain(red: red, green: green, blue: blue)
                if gain == 0 { continue }
                let dest = bin * 3
                energy[dest] += red * gain
                energy[dest + 1] += green * gain
                energy[dest + 2] += blue * gain
            }
        }
        for bin in coverage.indices where coverage[bin] > 0 {
            let scale = 1 / Float(coverage[bin])
            let dest = bin * 3
            energy[dest] *= scale
            energy[dest + 1] *= scale
            energy[dest + 2] *= scale
        }
        let glowSmall = pyramidBlur(
            energy,
            width: smallW,
            height: smallH,
            fullWidth: width,
            fullHeight: height
        )
        let glow = factor == 1 ? glowSmall : upsample(glowSmall, smallW: smallW, smallH: smallH, width: width, height: height)
        var output = pixels
        for index in 0..<count {
            let offset = index * stride
            let red = pixels[offset]
            let green = pixels[offset + 1]
            let blue = pixels[offset + 2]
            // The lamp stays as exposed. Only the surrounding pixels receive its blurred energy.
            if highlightGain(red: red, green: green, blue: blue) > 0 { continue }
            let source = index * 3
            output[offset] = addBloom(base: red, glow: glow[source], scatter: scatter)
            output[offset + 1] = addBloom(base: green, glow: glow[source + 1], scatter: scatter)
            output[offset + 2] = addBloom(base: blue, glow: glow[source + 2], scatter: scatter)
        }
        return output
    }

    /// Box average down to a short side, then a finite gaussian. Zeros stay zero, so a black sky does not gain a floor.
    static func pyramidBlur(_ energy: [Float], width: Int, height: Int, fullWidth: Int, fullHeight: Int) -> [Float] {
        let longest = Float(max(fullWidth, fullHeight))
        let sigmaScale = Float(width) / Float(max(fullWidth, 1))
        let weightTotal = Float(tightWeight + mediumWeight + wideWeight)
        let shares = [
            Float(tightWeight) / weightTotal,
            Float(mediumWeight) / weightTotal,
            Float(wideWeight) / weightTotal
        ]
        let radii = [Float(tightRadius), Float(mediumRadius), Float(wideRadius)]
        let count = width * height
        var glow = [Float](repeating: 0, count: count * 3)
        for channel in 0..<3 {
            var plane = [Float](repeating: 0, count: count)
            for index in 0..<count {
                plane[index] = energy[index * 3 + channel]
            }
            for pass in 0..<3 {
                let sigma = longest * radii[pass] * sigmaScale
                let blurred = referenceBlur(plane, width: width, height: height, sigma: sigma)
                let share = shares[pass]
                for index in 0..<count {
                    glow[index * 3 + channel] += share * blurred[index]
                }
            }
        }
        return glow
    }

    private static func pyramidFactor(width: Int, height: Int) -> Int {
        let longest = max(width, height)
        let limit = 160
        if longest <= limit { return 1 }
        return max(1, (longest + limit - 1) / limit)
    }

    private static func upsample(_ small: [Float], smallW: Int, smallH: Int, width: Int, height: Int) -> [Float] {
        var output = [Float](repeating: 0, count: width * height * 3)
        let scaleX = Float(smallW) / Float(width)
        let scaleY = Float(smallH) / Float(height)
        for y in 0..<height {
            for x in 0..<width {
                let fx = min(max((Float(x) + 0.5) * scaleX - 0.5, 0), Float(smallW - 1))
                let fy = min(max((Float(y) + 0.5) * scaleY - 0.5, 0), Float(smallH - 1))
                let x0 = Int(fx)
                let y0 = Int(fy)
                let x1 = min(x0 + 1, smallW - 1)
                let y1 = min(y0 + 1, smallH - 1)
                let tx = fx - Float(x0)
                let ty = fy - Float(y0)
                let dest = (y * width + x) * 3
                for channel in 0..<3 {
                    let a = small[(y0 * smallW + x0) * 3 + channel]
                    let b = small[(y0 * smallW + x1) * 3 + channel]
                    let c = small[(y1 * smallW + x0) * 3 + channel]
                    let d = small[(y1 * smallW + x1) * 3 + channel]
                    let top = a + (b - a) * tx
                    let bottom = c + (d - c) * tx
                    output[dest + channel] = top + (bottom - top) * ty
                }
            }
        }
        return output
    }

    private static func referenceBlur(_ plane: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let kernel = referenceKernel(sigma)
        let radius = kernel.count / 2
        var horizontal = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for offset in kernel.indices {
                    let sample = min(width - 1, max(0, x + offset - radius))
                    acc += kernel[offset] * plane[y * width + sample]
                }
                horizontal[y * width + x] = acc
            }
        }
        var output = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for offset in kernel.indices {
                    let sample = min(height - 1, max(0, y + offset - radius))
                    acc += kernel[offset] * horizontal[sample * width + x]
                }
                output[y * width + x] = acc
            }
        }
        return output
    }

    private static func referenceKernel(_ sigma: Float) -> [Float] {
        if sigma < 0.15 { return [1] }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var weights = [Float]()
        weights.reserveCapacity(radius * 2 + 1)
        var total: Float = 0
        for offset in -radius...radius {
            let ratio = Float(offset) / sigma
            let weight = exp(-0.5 * ratio * ratio)
            weights.append(weight)
            total += weight
        }
        guard total > 0 else { return [1] }
        return weights.map { $0 / total }
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

enum ColorLook: String, CaseIterable, Identifiable, Codable {
    case none
    case positive
    case negative
    case mono
    case ccd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "原始"
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

/// Debug check: each look and the highlight glow move pixels relative to 无.
/// A failing note is logged. It must not trap, or every editor screen dies in a debug build.
enum DevelopEffectCheck {
    static let confirm: Void = {
        #if DEBUG
        let notes = failures()
        let log = Logger(subsystem: "com.zeid.phi", category: "develop")
        if notes.isEmpty {
            log.notice("DEVELOP EFFECT CHECK passed")
        } else {
            let line = notes.joined(separator: " | ")
            log.error("DEVELOP EFFECT CHECK FAILED \(line, privacy: .public)")
        }
        #endif
    }()

    static func failures() -> [String] {
        var notes: [String] = []
        let red = (CGFloat(0.78), CGFloat(0.14), CGFloat(0.12))
        let recipes: [(String, LookRecipe)] = [
            ("正片", .positive),
            ("负片", .negative),
            ("黑白", .mono),
            ("CCD", .ccd)
        ]
        for (title, recipe) in recipes {
            let out = recipe.apply(red: red.0, green: red.1, blue: red.2)
            let delta = abs(out.0 - red.0) + abs(out.1 - red.1) + abs(out.2 - red.2)
            if delta < 0.04 {
                notes.append("\(title) did not move vs 无 (\(delta))")
            }
            if recipe.monochrome {
                let spread = max(out.0, out.1, out.2) - min(out.0, out.1, out.2)
                if spread > 0.004 {
                    notes.append("\(title) is not grey")
                }
            }
        }
        notes.append(contentsOf: haloRampFailures())
        let grain = GrainField.signedUnit(x: 3, y: 5, seed: 0xF1E0_4A11, cell: 1, step: 1)
        if abs(grain) < 0.001 {
            notes.append("grain hash is flat")
        }
        notes.append(contentsOf: HaloOptics.spatialFailures())
        notes.append(contentsOf: RawDevelop.portraitOrientationFailures())
        notes.append(contentsOf: RawDevelop.baseToneFailures())
        notes.append(contentsOf: RawDevelop.exposureMetricFailures())
        notes.append(contentsOf: EditorMatch.failures())
        return notes
    }

    /// The glow curve starts at the display knee, and the added bloom stays inside 0...1.
    private static func haloRampFailures() -> [String] {
        var notes: [String] = []
        let knee = HaloOptics.knee
        let below: [Float] = [0, 0.45, knee - 0.01, knee]
        for sample in below where HaloOptics.emphasis(sample) != 0 {
            notes.append("emphasis leaks below the knee")
            break
        }
        var previous = Float(0)
        var step = Float(0)
        let stepSize = Float(0.05)
        let rampLimit = Float(1.001)
        let unitSlack = Float(0.00001)
        while step <= rampLimit {
            let value = HaloOptics.emphasis(min(step, Float(1)))
            if value > Float(1) + unitSlack || value + unitSlack < previous {
                notes.append("emphasis is not a unit ramp")
                break
            }
            previous = value
            step += stepSize
        }
        if HaloOptics.emphasis(1) < 0.99 {
            notes.append("white does not fully scatter")
        }
        let bases: [Float] = [0, 0.25, 0.55, 0.9, 1]
        let glows: [Float] = [0, 0.4, 1, 2, 6]
        let scatters: [Float] = [0, Float(HaloOptics.weakScatter), Float(HaloOptics.strongScatter), 1.5]
        var bloomBroke = false
        let bloomSlack = Float(0.0001)
        for base in bases where bloomBroke == false {
            for glow in glows where bloomBroke == false {
                for scatter in scatters {
                    let added = HaloOptics.addBloom(base: base, glow: glow, scatter: scatter)
                    if added > Float(1) + bloomSlack || added + unitSlack < base {
                        notes.append("bloom add left the unit range")
                        bloomBroke = true
                        break
                    }
                    if glow == 0, added != base {
                        notes.append("zero glow changed a pixel")
                        bloomBroke = true
                        break
                    }
                }
            }
        }
        return notes
    }
}
