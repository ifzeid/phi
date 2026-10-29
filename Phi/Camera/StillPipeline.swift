import CoreImage
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Develops a still in 16-bit linear Display P3, then emits one 8-bit Display P3 image.
/// Preview and export both call `render` so they share one recipe. Grain is FINE or off.
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
    private static let context = CIContext(options: [
        CIContextOption.workingColorSpace: linearP3,
        CIContextOption.outputColorSpace: displayP3,
        CIContextOption.workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
        CIContextOption.cacheIntermediates: false
    ])

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
        var input = displayEncoded(image)
        let zoom = lensZoom > 1 ? lensZoom : 1
        input = LensCrop.cropped(input, zoom: zoom)
        let longest = max(input.extent.width, input.extent.height)
        if let maxSide, longest > maxSide, longest > 0 {
            let scale = maxSide / longest
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let bounded = Swift.min(2, Swift.max(-2, exposureEV))
        let exposed: CIImage
        if abs(bounded) < 0.0001 {
            exposed = input
        } else {
            exposed = input.applyingFilter("CIExposureAdjust", parameters: ["inputEV": bounded])
        }
        let looked = ColorLooks.apply(exposed, look: look, halo: halo)
        let developed = grained(looked, style: style)
        return displayImage(developed)
    }

    static func grained(_ image: CIImage, style: GrainStyle) -> CIImage {
        guard let profile = style.profile else { return image }
        return applyingGrain(image, profile: profile)
    }

    /// `glow` is the multiscale blur of `img * emphasis`, in source colour.
    /// Scales that glow so its mean luma matches the image, then `out = (1 - k) * img + k * glow`.
    static func applyingDiffusion(_ image: CIImage, glow: CIImage, scatter: CGFloat) -> CIImage {
        let bounds = image.extent.integral
        guard let base = linearPixels(image, bounds: bounds),
              let glowPixels = linearPixels(glow, bounds: bounds),
              base.count == glowPixels.count else { return image }
        var pixels = base
        let count = pixels.count / 4
        var imageSum = 0.0
        var glowSum = 0.0
        for index in 0..<count {
            let offset = index * 4
            imageSum += Double(GrainField.rec709(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2]))
            glowSum += Double(GrainField.rec709(
                red: glowPixels[offset],
                green: glowPixels[offset + 1],
                blue: glowPixels[offset + 2]
            ))
        }
        let scale: Float = glowSum > 1e-8 ? Float(imageSum / glowSum) : 1
        let k = Float(scatter)
        let kept = 1 - k
        for index in 0..<count {
            let offset = index * 4
            pixels[offset] = pixels[offset] * kept + k * scale * glowPixels[offset]
            pixels[offset + 1] = pixels[offset + 1] * kept + k * scale * glowPixels[offset + 1]
            pixels[offset + 2] = pixels[offset + 2] * kept + k * scale * glowPixels[offset + 2]
        }
        return Self.image(pixels, bounds: bounds)
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

    private static func applyingGrain(_ image: CIImage, profile: GrainProfile) -> CIImage {
        let bounds = image.extent.integral
        guard var pixels = linearPixels(image, bounds: bounds) else { return image }
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        let step = GrainField.step(width: width, tileFraction: profile.tileFraction)
        var noise = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                noise[y * width + x] = GrainField.signedUnit(
                    x: x,
                    y: y,
                    seed: profile.seed,
                    cell: profile.cell,
                    step: step
                )
            }
        }
        noise = GrainField.balanced(noise)
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
        return Self.image(pixels, bounds: bounds)
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

    private static func image(_ pixels: [Float], bounds: CGRect) -> CIImage {
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
