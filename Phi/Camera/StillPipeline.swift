import CoreImage
import ImageIO
import Metal
import UIKit
import UniformTypeIdentifiers

/// Develops a still in 16-bit linear Display P3, then emits one 8-bit Display P3 image.
/// Preview bakes a screen-sized proxy; export calls `render` at full resolution.
/// Both use the same grade, highlight glow, grain, then exposure gain. Grain is FINE or off.
///
/// The context working space is extended linear Display P3, so a tagged display image is
/// decoded once on the way in and encoded once on the way out (`createCGImage` → Display P3).
/// That Display P3 CGImage is the profile ImageIO writes into the HEIF. Do not add a second
/// gamma, and do not blend a display-encoded tile in this working space: code 128 would be
/// decoded to about 0.21 and an overlay pivot of 0.5 would darken and recolor the frame.
enum StillPipeline {
    private static let renderLock = NSLock()
    static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB()
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    /// One Metal context for preview and export. Callers render off the main thread.
    private static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            CIContextOption.workingColorSpace: linearP3,
            CIContextOption.outputColorSpace: displayP3,
            CIContextOption.workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            CIContextOption.cacheIntermediates: false,
            CIContextOption.useSoftwareRenderer: false
        ]
        let device: MTLDevice? = MTLCreateSystemDefaultDevice()
        if let device {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    static func normalizedCGImage(from image: UIImage) -> CGImage? {
        let scale = image.scale == 0 ? 1 : image.scale
        let width = max(1, (image.size.width * scale).rounded())
        let height = max(1, (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        // Renderer output is a named display space, kept upright.
        // `displayEncoded` tags a nameless bitmap as Display P3 without resampling.
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }.cgImage
    }

    static func render(
        _ image: CGImage,
        exposureEV: Double,
        style: GrainStyle,
        look: ColorLook = .none,
        halo: HaloLevel = .off,
        lensZoom: Double = 1,
        maxSide: CGFloat?
    ) -> CGImage? {
        guard let input = prepared(image, zoom: lensZoom, maxSide: maxSide) else { return nil }
        return renderLinear(input, exposureEV: exposureEV, style: style, look: look, halo: halo)
    }

    /// Crop and optional long-side scale. The result is still a lazy graph; preview bakes it once.
    static func prepared(_ image: CGImage, zoom: Double, maxSide: CGFloat?) -> CIImage? {
        var input = displayEncoded(image)
        let zoomed = zoom > 1 ? zoom : 1
        input = LensCrop.cropped(input, zoom: zoomed)
        let longest = max(input.extent.width, input.extent.height)
        if let maxSide, longest > maxSide, longest > 0 {
            let scale = maxSide / longest
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = input.extent.integral
        guard extent.width > 1, extent.height > 1, extent.isInfinite == false else { return nil }
        return input.cropped(to: extent)
    }

    /// Look, highlight glow, then grain, then the exposure dial as a linear gain.
    /// The dial is last so a preview can cache the developed proxy and only multiply.
    static func renderLinear(
        _ linear: CIImage,
        exposureEV: Double,
        style: GrainStyle,
        look: ColorLook,
        halo: HaloLevel
    ) -> CGImage? {
        let graded = ColorLooks.graded(linear, look: look)
        let glowed = ColorLooks.withHalo(graded, level: halo)
        let extent = glowed.extent.integral
        let count = extent.width * extent.height
        if let profile = style.profile, count > 6_000_000 {
            return displayGrained(glowed, profile: profile, ev: exposureEV)
        }
        let grain = grained(glowed, style: style)
        return displayImage(applyingExposure(grain, ev: exposureEV))
    }

    /// `pow(2, ev)` in linear light. The dial runs from −5 to +5.
    static func applyingExposure(_ source: CIImage, ev: Double) -> CIImage {
        let bounded = min(5.0, max(-5.0, ev))
        if abs(bounded) < 0.0001 { return source }
        return source.applyingFilter("CIExposureAdjust", parameters: ["inputEV": bounded])
    }

    /// Bake a lazy graph to a linear bitmap so a later exposure pass does not rerun it.
    static func materialize(_ source: CIImage) -> CIImage? {
        let bounds = source.extent.integral
        guard let pixels = linearPixels(source, bounds: bounds) else { return nil }
        return bitmapImage(pixels, bounds: bounds)
    }

    /// `out = base + scatter * glow`. Glow is not scaled to the image mean.
    static func addGlow(_ base: CIImage, glow: CIImage, scatter: CGFloat) -> CIImage {
        let amount = min(CGFloat(1.5), max(CGFloat(0), scatter))
        guard amount > 0 else { return base }
        let scaled = glow.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        guard let add = CIFilter(name: "CIAdditionCompositing") else { return base }
        add.setValue(scaled, forKey: kCIInputImageKey)
        add.setValue(base, forKey: kCIInputBackgroundImageKey)
        return (add.outputImage ?? base).cropped(to: base.extent)
    }

    /// Gaussian at `sigma`, evaluated on a reduced image and scaled back.
    /// A full-frame sigma of hundreds of pixels never hits the full-res kernel.
    static func pyramidBlur(_ source: CIImage, sigma: CGFloat, extent: CGRect) -> CIImage {
        guard sigma > 0.35, extent.width > 2, extent.height > 2 else { return source.cropped(to: extent) }
        let targetSigma: CGFloat = 6
        let longest = max(extent.width, extent.height)
        var scale: CGFloat = sigma > targetSigma ? targetSigma / sigma : 1
        if longest > 0, longest * scale < 8 {
            scale = min(1, 8 / longest)
        }
        scale = min(1, max(scale, 1 / 64))
        let reduced = max(sigma * scale, 0.5)
        let shift = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let shrink = CGAffineTransform(scaleX: scale, y: scale)
        let down = shift.concatenating(shrink)
        let smallW = max(CGFloat(2), (extent.width * scale).rounded(.up))
        let smallH = max(CGFloat(2), (extent.height * scale).rounded(.up))
        let small = CGRect(x: 0, y: 0, width: smallW, height: smallH)
        let shrunk = source.transformed(by: down).cropped(to: small)
        let pad = reduced * 3 + 2
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: small.insetBy(dx: -pad, dy: -pad))
        let blurred = shrunk.composited(over: black)
            .applyingGaussianBlur(sigma: reduced)
            .cropped(to: small)
        let lifted = blurred.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        let fix = CGAffineTransform(
            translationX: extent.minX - lifted.extent.minX,
            y: extent.minY - lifted.extent.minY
        )
        return lifted.transformed(by: fix).cropped(to: extent)
    }

    static func grained(_ image: CIImage, style: GrainStyle) -> CIImage {
        guard let profile = style.profile else { return image }
        return applyingGrain(image, profile: profile)
    }

    /// Mean Rec.709 luma of a linear image. Used only to decide a global night lift.
    static func meanLinearLuma(_ image: CIImage) -> Float? {
        let extent = image.extent
        guard extent.width > 2, extent.height > 2, extent.isInfinite == false else { return nil }
        guard let average = CIFilter(name: "CIAreaAverage") else { return nil }
        average.setValue(image, forKey: kCIInputImageKey)
        average.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let pixel = average.outputImage else { return nil }
        var bitmap = [Float](repeating: 0, count: 4)
        renderLock.lock()
        bitmap.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                pixel,
                toBitmap: base,
                rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBAf,
                colorSpace: linearP3
            )
        }
        renderLock.unlock()
        let luma = GrainField.rec709(red: bitmap[0], green: bitmap[1], blue: bitmap[2])
        return luma.isFinite ? luma : nil
    }

    static func displayImage(_ image: CIImage) -> CGImage? {
        renderLock.lock()
        defer { renderLock.unlock() }
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1, extent.isInfinite == false else { return nil }
        // Display P3 on the CGImage is what ImageIO writes into the HEIF. There is no separate ICC property key on this SDK.
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: displayP3)
    }

    static func encodeDeveloped(_ image: CGImage, metadata: [String: Any]? = nil) -> (data: Data, ext: String, uti: String)? {
        if let heic = encode(image, type: UTType.heic, quality: RawDevelop.exportQuality, metadata: metadata) {
            return (heic, "heic", UTType.heic.identifier)
        }
        if let jpeg = encode(image, type: UTType.jpeg, quality: RawDevelop.exportQuality, metadata: metadata) {
            return (jpeg, "jpg", UTType.jpeg.identifier)
        }
        return nil
    }

    /// A calibrated display profile is kept. Device RGB is tagged Display P3 so the linear
    /// working space decodes it once. Pixels are display-encoded; this does not mark them linear.
    private static func displayEncoded(_ image: CGImage) -> CIImage {
        if let space = image.colorSpace, space.name != nil {
            return CIImage(cgImage: image)
        }
        return CIImage(cgImage: image, options: [CIImageOption.colorSpace: displayP3])
    }

    private static func applyingGrain(_ source: CIImage, profile: GrainProfile) -> CIImage {
        let bounds = source.extent.integral
        guard var pixels = linearPixels(source, bounds: bounds) else { return source }
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        paintGrain(
            &pixels,
            width: width,
            height: height,
            originX: 0,
            originY: 0,
            fieldWidth: width,
            profile: profile,
            calibration: nil
        )
        return bitmapImage(pixels, bounds: bounds)
    }

    /// Full-frame grain without a single float buffer the size of a 48MP still.
    /// Noise mean and peak match `GrainField.balanced` over the whole frame, so strips do not seam.
    private static func displayGrained(_ source: CIImage, profile: GrainProfile, ev: Double) -> CGImage? {
        let bounds = source.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 1, height > 1 else { return nil }
        let calibration = noiseCalibration(width: width, height: height, profile: profile)
        guard let canvas = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: displayP3,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        canvas.interpolationQuality = .none
        let rowsPerStrip = 160
        var row = 0
        while row < height {
            let rows = min(rowsPerStrip, height - row)
            let rect = CGRect(
                x: bounds.minX,
                y: bounds.minY + CGFloat(row),
                width: CGFloat(width),
                height: CGFloat(rows)
            )
            let strip = source.cropped(to: rect)
            guard var pixels = linearPixels(strip, bounds: rect) else { return nil }
            paintGrain(
                &pixels,
                width: width,
                height: rows,
                originX: 0,
                originY: row,
                fieldWidth: width,
                profile: profile,
                calibration: calibration
            )
            let baked = bitmapImage(pixels, bounds: rect)
            guard let piece = displayImage(applyingExposure(baked, ev: ev)) else { return nil }
            canvas.draw(piece, in: CGRect(x: 0, y: CGFloat(row), width: CGFloat(width), height: CGFloat(rows)))
            row += rows
        }
        return canvas.makeImage()
    }

    private static func noiseCalibration(width: Int, height: Int, profile: GrainProfile) -> (mean: Float, scale: Float) {
        let step = GrainField.step(width: width, tileFraction: profile.tileFraction)
        var sum = 0.0
        let count = max(width * height, 1)
        for y in 0..<height {
            for x in 0..<width {
                sum += Double(GrainField.signedUnit(x: x, y: y, seed: profile.seed, cell: profile.cell, step: step))
            }
        }
        let mean = Float(sum / Double(count))
        var peak: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let sample = GrainField.signedUnit(x: x, y: y, seed: profile.seed, cell: profile.cell, step: step) - mean
                peak = max(peak, abs(sample))
            }
        }
        let scale: Float = peak > 1 ? 1 / peak : 1
        return (mean, scale)
    }

    private static func paintGrain(
        _ pixels: inout [Float],
        width: Int,
        height: Int,
        originX: Int,
        originY: Int,
        fieldWidth: Int,
        profile: GrainProfile,
        calibration: (mean: Float, scale: Float)?
    ) {
        let step = GrainField.step(width: fieldWidth, tileFraction: profile.tileFraction)
        var noise = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                noise[y * width + x] = GrainField.signedUnit(
                    x: originX + x,
                    y: originY + y,
                    seed: profile.seed,
                    cell: profile.cell,
                    step: step
                )
            }
        }
        if let calibration {
            for index in noise.indices {
                noise[index] = (noise[index] - calibration.mean) * calibration.scale
            }
        } else {
            noise = GrainField.balanced(noise)
        }
        let amplitude = Float(profile.amplitude)
        for index in noise.indices {
            let offset = index * 4
            let red = pixels[offset]
            let green = pixels[offset + 1]
            let blue = pixels[offset + 2]
            // Display P3 uses the IEC 61966-2-1 transfer. Noise is zero-mean in that space so the
            // 8-bit HEIF mean does not shift when the encode curve bends a linear deviation.
            let redD = GrainField.encoded(red)
            let greenD = GrainField.encoded(green)
            let blueD = GrainField.encoded(blue)
            let y = GrainField.rec709(red: redD, green: greenD, blue: blueD)
            let peak = max(redD, max(greenD, blueD))
            // Brightest channel, not just luma, so a later 8-bit clamp cannot eat only the positive half.
            let high: Float = peak > 0.0001 ? y * (1 - peak) / peak : 0
            let room = min(y, max(high, 0))
            let delta = noise[index] * min(amplitude, max(room, 0))
            let factor: Float = y > 0.0001 ? (y + delta) / y : 1
            pixels[offset] = GrainField.decoded(redD * factor)
            pixels[offset + 1] = GrainField.decoded(greenD * factor)
            pixels[offset + 2] = GrainField.decoded(blueD * factor)
        }
    }

    private static func linearPixels(_ image: CIImage, bounds: CGRect) -> [Float]? {
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 1, height > 1, bounds.isInfinite == false else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let rowBytes = width * MemoryLayout<Float>.size * 4
        renderLock.lock()
        let wrote = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            context.render(
                image,
                toBitmap: base,
                rowBytes: rowBytes,
                bounds: bounds,
                format: .RGBAf,
                colorSpace: linearP3
            )
            return true
        }
        renderLock.unlock()
        return wrote ? pixels : nil
    }

    static func gradePixels(_ source: CIImage, recipe: LookRecipe) -> CIImage {
        let bounds = source.extent.integral
        guard var pixels = linearPixels(source, bounds: bounds) else { return source }
        let count = pixels.count / 4
        for index in 0..<count {
            let offset = index * 4
            let red = GrainField.encoded(pixels[offset])
            let green = GrainField.encoded(pixels[offset + 1])
            let blue = GrainField.encoded(pixels[offset + 2])
            let mapped = recipe.apply(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue))
            pixels[offset] = GrainField.decoded(Float(mapped.0))
            pixels[offset + 1] = GrainField.decoded(Float(mapped.1))
            pixels[offset + 2] = GrainField.decoded(Float(mapped.2))
        }
        return bitmapImage(pixels, bounds: bounds)
    }

    private static func bitmapImage(_ pixels: [Float], bounds: CGRect) -> CIImage {
        let width = Int(bounds.width)
        let rowBytes = width * MemoryLayout<Float>.size * 4
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let bitmap = CIImage(
            bitmapData: data,
            bytesPerRow: rowBytes,
            size: CGSize(width: bounds.width, height: bounds.height),
            format: .RGBAf,
            colorSpace: linearP3
        )
        return bitmap.transformed(by: CGAffineTransform(translationX: bounds.origin.x, y: bounds.origin.y))
    }

    private static func encode(_ image: CGImage, type: UTType, quality: CGFloat, metadata: [String: Any]?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = PhotoMetadata.exportProperties(from: metadata, quality: quality)
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Screen-sized develop cache. The proxy, the grade, and the highlight blur are baked once.
/// Dragging exposure only multiplies that bitmap. Full resolution is `StillPipeline.render`.
final class PreviewCache {
    private var proxyID: ObjectIdentifier?
    private var proxyZoom = 0.0
    private var proxySide = 0
    private var proxyDNG = -1
    private var proxyAspect: PhotoAspect?
    private var proxy: CIImage?

    private var gradedLook: ColorLook?
    private var graded: CIImage?
    private var glowLook: ColorLook?
    private var glow: CIImage?
    private var bakedLook: ColorLook?
    private var bakedHalo: HaloLevel?
    private var bakedStyle: GrainStyle?
    private var baked: CIImage?

    func cgImage(
        source: CGImage,
        dng: Data?,
        aspect: PhotoAspect,
        exposureEV: Double,
        style: GrainStyle,
        look: ColorLook,
        halo: HaloLevel,
        lensZoom: Double,
        maxSide: CGFloat
    ) -> CGImage? {
        guard let base = linearBase(source: source, dng: dng, aspect: aspect, zoom: lensZoom, maxSide: maxSide) else {
            return nil
        }
        let developed = develop(base, look: look, halo: halo, style: style)
        return StillPipeline.displayImage(StillPipeline.applyingExposure(developed, ev: exposureEV))
    }

    private func linearBase(
        source: CGImage,
        dng: Data?,
        aspect: PhotoAspect,
        zoom: Double,
        maxSide: CGFloat
    ) -> CIImage? {
        let side = Int(maxSide.rounded())
        let dngCount = dng?.count ?? 0
        let identity = ObjectIdentifier(source)
        if proxyID == identity,
           proxyZoom == zoom,
           proxySide == side,
           proxyDNG == dngCount,
           proxyAspect == aspect,
           let proxy {
            return proxy
        }
        let prepared: CIImage?
        if let dng {
            prepared = RawDevelop.linearBase(
                dng: dng,
                aspect: aspect,
                lensZoom: zoom,
                maxSide: maxSide,
                draft: false
            )
        } else {
            prepared = StillPipeline.prepared(source, zoom: zoom, maxSide: maxSide)
        }
        guard let prepared else { return nil }
        let bakedProxy = StillPipeline.materialize(prepared) ?? prepared
        proxy = bakedProxy
        proxyID = identity
        proxyZoom = zoom
        proxySide = side
        proxyDNG = dngCount
        proxyAspect = aspect
        graded = nil
        gradedLook = nil
        glow = nil
        glowLook = nil
        baked = nil
        return bakedProxy
    }

    private func develop(_ base: CIImage, look: ColorLook, halo: HaloLevel, style: GrainStyle) -> CIImage {
        if graded == nil || gradedLook != look {
            if look == .none {
                graded = base
            } else {
                let graph = ColorLooks.graded(base, look: look)
                graded = StillPipeline.materialize(graph) ?? graph
            }
            gradedLook = look
            glow = nil
            glowLook = nil
            baked = nil
        }
        guard let graded else { return base }
        if halo != .off, glow == nil || glowLook != look {
            let field = ColorLooks.unscaledGlow(graded)
            glow = StillPipeline.materialize(field) ?? field
            glowLook = look
            baked = nil
        }
        if let baked, bakedLook == look, bakedHalo == halo, bakedStyle == style {
            return baked
        }
        if halo == .off, style == .off {
            baked = graded
            bakedLook = look
            bakedHalo = halo
            bakedStyle = style
            return graded
        }
        var current = graded
        if halo != .off, let glow {
            current = StillPipeline.addGlow(current, glow: glow, scatter: halo.scatter)
        }
        if style != .off {
            current = StillPipeline.grained(current, style: style)
        } else {
            current = StillPipeline.materialize(current) ?? current
        }
        baked = current
        bakedLook = look
        bakedHalo = halo
        bakedStyle = style
        return current
    }
}

/// Luminance grain. The deviation is zero-mean in Display P3 code values.
/// `Tests/look_calibration_test.py` mirrors this math.
enum GrainField {
    static let tileSide = 256

    static func rec709(red: Float, green: Float, blue: Float) -> Float {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// Display P3 opto-electronic transfer (IEC 61966-2-1), extended above 1. Inverse of `decoded`.
    static func encoded(_ linear: Float) -> Float {
        if linear <= 0.0031308 { return 12.92 * linear }
        return 1.055 * pow(linear, 1 / Float(2.4)) - 0.055
    }

    /// Display P3 electro-optical transfer (IEC 61966-2-1), extended above 1.
    static func decoded(_ display: Float) -> Float {
        if display <= 0.04045 { return display / 12.92 }
        return pow((display + 0.055) / 1.055, Float(2.4))
    }

    /// How many source pixels share one hash cell. One 256px tile covers `tileFraction` of the width.
    static func step(width: Int, tileFraction: Double) -> Int {
        let raw = Double(max(width, 1)) * tileFraction / Double(tileSide)
        let whole = Int(raw)
        let step = raw - Double(whole) >= 0.5 ? whole + 1 : whole
        return max(step, 1)
    }

    static func signedUnit(x: Int, y: Int, seed: UInt32, cell: Int, step: Int) -> Float {
        let safeStep = max(step, 1)
        let safeCell = max(cell, 1)
        let unit = unitHash(x: (x / safeStep) / safeCell, y: (y / safeStep) / safeCell, seed: seed)
        return Float((unit - 0.5) * 2)
    }

    /// Subtracts the mean, then if anything falls outside [-1, 1] scales it back. Mean stays 0.
    static func balanced(_ noise: [Float]) -> [Float] {
        guard noise.isEmpty == false else { return noise }
        var sum = 0.0
        for sample in noise {
            sum += Double(sample)
        }
        let mean = Float(sum / Double(noise.count))
        var balanced = noise
        var peak: Float = 0
        for index in balanced.indices {
            balanced[index] -= mean
            peak = max(peak, abs(balanced[index]))
        }
        if peak > 1 {
            let scale = 1 / peak
            for index in balanced.indices {
                balanced[index] *= scale
            }
        }
        return balanced
    }

    static func unitHash(x: Int, y: Int, seed: UInt32) -> Double {
        var n = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263) &+ seed
        n = (n ^ (n >> 13)) &* 1274126177
        return Double(n & 0x00FF_FFFF) / Double(0x00FF_FFFF)
    }
}
