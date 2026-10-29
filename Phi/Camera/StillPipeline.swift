import CoreImage
import ImageIO
import Metal
import os
import UIKit
import UniformTypeIdentifiers

/// Develops a still in 16-bit linear Display P3, then emits one 8-bit Display P3 image.
/// Preview bakes a screen-sized linear plate; export calls `render` at full resolution.
/// Exposure is `2^EV` on that plate, then the highlight shoulder, then grade, glow, and grain.
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
            // Preview repeats the same graph with a new exposure. Keep intermediates.
            // The proxy is at most 1280 px, so the cache stays small.
            CIContextOption.cacheIntermediates: true,
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
        // HEIF is display-encoded. `exposeThenShoulder` decodes it once, then applies `2^ev` and the shoulder.
        let toned = RawDevelop.exposeThenShoulder(input, ev: exposureEV)
        return renderLinear(toned, exposureEV: 0, style: style, look: look, halo: halo)
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

/// Look, highlight glow, then grain. Exposure is already in `linear` (`expose` / `exposeThenShoulder`).
static func renderLinear(
    _ linear: CIImage,
    exposureEV: Double,
    style: GrainStyle,
    look: ColorLook,
    halo: HaloLevel
) -> CGImage? {
    // Callers pass 0. A non-zero value is still only `2^ev`, and it does not run the shoulder again.
    let exposed = applyingExposure(linear, ev: exposureEV)
    let graded = ColorLooks.graded(exposed, look: look)
    let glowed = applyHalo(graded, level: halo)
        let extent = glowed.extent.integral
        let count = extent.width * extent.height
        if let profile = style.profile, count > 6_000_000 {
            return displayGrained(glowed, profile: profile, ev: 0)
        }
        let grain = grained(glowed, style: style)
        return displayImage(grain)
    }

    /// Scene-linear samples. `baseline` is the DNG BaselineExposure tag, in stops. HEIF uses 0.
    /// `filmic` is the mode 0 toe and contrast. HEIF stays on the highlight shoulder only.
    struct LinearPlate {
        var pixels: [Float]
        var baseline: Float
        var extent: CGRect
        var filmic: Bool = false
    }

    /// One decode into extended-linear Display P3. The dial does not render this plate again.
    static func linearPlate(of image: CIImage, baseline: Float, filmic: Bool = false) -> LinearPlate? {
        let bounds = image.extent.integral
        guard let pixels = linearPixels(image, bounds: bounds) else { return nil }
        return LinearPlate(pixels: pixels, baseline: baseline, extent: bounds, filmic: filmic)
    }

    /// Lanczos to `maxSide` on the long edge. The RAW filter has already demosaiced at full resolution.
    static func scaledToSide(_ image: CIImage, maxSide: CGFloat) -> CIImage {
        let extent = image.extent.integral
        let longest = max(extent.width, extent.height)
        guard longest > maxSide, longest > 0, maxSide > 1 else { return image }
        let scale = maxSide / longest
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: image.extent)
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return image }
        return output.cropped(to: output.extent.integral)
    }

    /// `2^(trimmed baseline + ev)` on scene-linear RGB, then the mode 0 filmic or the highlight shoulder.
    /// Preview and export both call this. The multiply is on these samples.
    static func expose(_ plate: LinearPlate, ev: Double, shoulder: Bool = true) -> CIImage {
        var pixels = plate.pixels
        let gain = RawDevelop.sceneGain(baseline: plate.baseline, ev: ev)
        let count = pixels.count / 4
        var index = 0
        while index < count {
            let offset = index * 4
            let red = pixels[offset] * gain
            let green = pixels[offset + 1] * gain
            let blue = pixels[offset + 2] * gain
            if shoulder {
                if plate.filmic {
                    pixels[offset] = RawDevelop.toneMapValue(red)
                    pixels[offset + 1] = RawDevelop.toneMapValue(green)
                    pixels[offset + 2] = RawDevelop.toneMapValue(blue)
                } else {
                    pixels[offset] = RawDevelop.baseShoulderValue(red)
                    pixels[offset + 1] = RawDevelop.baseShoulderValue(green)
                    pixels[offset + 2] = RawDevelop.baseShoulderValue(blue)
                }
            } else {
                pixels[offset] = max(red, 0)
                pixels[offset + 1] = max(green, 0)
                pixels[offset + 2] = max(blue, 0)
            }
            index += 1
        }
        return bitmapImage(pixels, bounds: plate.extent)
    }

    /// `pow(2, ev)` in linear light, without the shoulder. The dial itself is `expose`.
    static func applyingExposure(_ source: CIImage, ev: Double) -> CIImage {
        let bounded = min(5.0, max(-5.0, ev))
        if abs(bounded) < 0.0001 { return source }
        guard let plate = linearPlate(of: source, baseline: 0) else { return source }
        return expose(plate, ev: bounded, shoulder: false)
    }

    /// Bake a lazy graph to a linear bitmap so a later exposure pass does not rerun it.
    static func materialize(_ source: CIImage) -> CIImage? {
        let bounds = source.extent.integral
        guard let pixels = linearPixels(source, bounds: bounds) else { return nil }
        return bitmapImage(pixels, bounds: bounds)
    }

    /// Preview and export both call this. Highlight energy is blurred and added; the rest of the frame is unchanged.
    static func applyHalo(_ base: CIImage, level: HaloLevel) -> CIImage {
        #if DEBUG
        _ = haloPipelineCheck
        #endif
        return renderHalo(base, level: level)
    }

    static func renderHalo(_ base: CIImage, level: HaloLevel) -> CIImage {
        guard level != .off, level.scatter > 0 else { return base }
        let extent = base.extent.integral
        guard extent.width > 2, extent.height > 2, extent.isInfinite == false else { return base }
        guard let pixels = linearPixels(base, bounds: extent) else { return base }
        let width = Int(extent.width)
        let height = Int(extent.height)
        // HaloOptics.pyramidBlur runs on highlight energy only. A CI gaussian was screening a floor over the sky.
        let bloomed = HaloOptics.bloom(pixels, width: width, height: height, scatter: Float(level.scatter), stride: 4)
        return bitmapImage(bloomed, bounds: extent)
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

    /// Encode a preview into a Metal texture. Callers present the command buffer.
    static func render(_ image: CIImage, to texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        renderLock.lock()
        defer { renderLock.unlock() }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        destination.colorSpace = displayP3
        destination.isFlipped = true
        _ = try context.startTask(toRender: image, to: destination)
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

    #if DEBUG
    /// Renders a synthetic bright sky through `renderHalo` (the preview and export path).
    private static let haloPipelineCheck: Void = {
        let notes = haloCIFailures()
        let log = Logger(subsystem: "com.zeid.phi", category: "develop")
        if notes.isEmpty {
            log.notice("HALO CI CHECK passed")
        } else {
            let line = notes.joined(separator: " | ")
            log.error("HALO CI CHECK FAILED \(line, privacy: .public)")
        }
    }()

    private static func haloCIFailures() -> [String] {
        let width = 128
        let height = 80
        let sky: (Float, Float, Float) = (0.3916, 0.5647, 0.7605)
        let wall: (Float, Float, Float) = (0.8388, 0.7913, 0.7011)
        let terra: (Float, Float, Float) = (0.4342, 0.1620, 0.0685)
        let shadow: (Float, Float, Float) = (0.0194, 0.0144, 0.0116)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let sample: (Float, Float, Float)
                if y < Int(Float(height) * 0.38) {
                    sample = sky
                } else if x > Int(Float(width) * 0.42), y < Int(Float(height) * 0.82) {
                    sample = wall
                } else if x < 18, y > Int(Float(height) * 0.70) {
                    sample = shadow
                } else {
                    sample = terra
                }
                pixels[offset] = sample.0
                pixels[offset + 1] = sample.1
                pixels[offset + 2] = sample.2
                pixels[offset + 3] = 1
            }
        }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let source = bitmapImage(pixels, bounds: extent)
        guard let plain = displayImage(source),
              let weakImage = displayImage(renderHalo(source, level: .weak)),
              let strongImage = displayImage(renderHalo(source, level: .strong)),
              let plainBytes = rgba8(plain),
              let weakBytes = rgba8(weakImage),
              let strongBytes = rgba8(strongImage) else {
            return ["halo CI render failed"]
        }
        var notes: [String] = []
        let plainClip = clipFraction(plainBytes)
        let strongClip = clipFraction(strongBytes)
        let weakClip = clipFraction(weakBytes)
        if strongClip - plainClip > 0.02 || weakClip - plainClip > 0.02 {
            notes.append(String(format: "clipped-area delta weak %.3f strong %.3f", weakClip - plainClip, strongClip - plainClip))
        }
        let plainMean = byteMean(plainBytes)
        let weakMean = byteMean(weakBytes)
        let strongMean = byteMean(strongBytes)
        let weakRise = weakMean - plainMean
        let strongRise = strongMean - plainMean
        if weakRise < 0.5 || weakRise > 4 {
            notes.append(String(format: "弱 mean rise %.2f levels", weakRise))
        }
        if strongRise < 1.5 || strongRise > 8 {
            notes.append(String(format: "强 mean rise %.2f levels", strongRise))
        }
        if strongRise < weakRise + 1 {
            notes.append(String(format: "弱 and 强 too close (%.2f vs %.2f)", weakRise, strongRise))
        }
        let weakShadow = darkestByteLift(plainBytes, weakBytes)
        let strongShadow = darkestByteLift(plainBytes, strongBytes)
        if weakShadow > 1.25 || strongShadow > 1.25 {
            notes.append(String(format: "darkest decile lift weak %.2f strong %.2f", weakShadow, strongShadow))
        }
        if notes.isEmpty == false {
            notes.append(String(format: "means plain %.2f weak %.2f strong %.2f", plainMean, weakMean, strongMean))
        }
        return notes
    }

    private static func rgba8(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: displayP3,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? bytes : nil
    }

    private static func clipFraction(_ bytes: [UInt8]) -> Float {
        let count = bytes.count / 4
        guard count > 0 else { return 0 }
        var clipped = 0
        for index in 0..<count {
            let offset = index * 4
            if bytes[offset] == 255 || bytes[offset + 1] == 255 || bytes[offset + 2] == 255 {
                clipped += 1
            }
        }
        return Float(clipped) / Float(count)
    }

    private static func darkestByteLift(_ before: [UInt8], _ after: [UInt8]) -> Float {
        let count = min(before.count, after.count) / 4
        guard count > 0 else { return 0 }
        var levels = [(Float, Float)]()
        levels.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * 4
            let source = 0.2126 * Float(before[offset]) + 0.7152 * Float(before[offset + 1]) + 0.0722 * Float(before[offset + 2])
            let result = 0.2126 * Float(after[offset]) + 0.7152 * Float(after[offset + 1]) + 0.0722 * Float(after[offset + 2])
            levels.append((source, result - source))
        }
        levels.sort { $0.0 < $1.0 }
        let take = max(1, count / 10)
        var sum = Float(0)
        for index in 0..<take {
            sum += levels[index].1
        }
        return sum / Float(take)
    }

    private static func byteMean(_ bytes: [UInt8]) -> Float {
        let count = bytes.count / 4
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let offset = index * 4
            let red = Float(bytes[offset])
            let green = Float(bytes[offset + 1])
            let blue = Float(bytes[offset + 2])
            sum += 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        return sum / Float(count)
    }
    #endif
}

/// Screen-sized develop cache. The plate is scene-linear and is decoded once.
/// Each long side and each look keeps its own bake. Full resolution is `StillPipeline.render`.
final class PreviewCache {
    private let lock = NSLock()
    private var sourceID: ObjectIdentifier?
    private var sourceZoom = 0.0
    private var sourceDNG = -1
    private var sourceAspect: PhotoAspect?
    private var plates: [Int: StillPipeline.LinearPlate] = [:]
    private var grades: [String: CIImage] = [:]

    /// Drag and idle proxies, and every look cube, so the first edit does not compile them.
    func prewarm(source: CGImage, dng: Data?, aspect: PhotoAspect, zoom: Double, sides: [CGFloat]) {
        lock.lock()
        defer { lock.unlock() }
        for side in sides {
            guard let plate = plate(source: source, dng: dng, aspect: aspect, zoom: zoom, maxSide: side) else { continue }
            let base = StillPipeline.expose(plate, ev: 0)
            for look in ColorLook.allCases {
                _ = grade(base, look: look, halo: .off, style: .off, exposureEV: 0)
            }
        }
    }

    func previewImage(
        source: CGImage,
        dng: Data?,
        aspect: PhotoAspect,
        exposureEV: Double,
        style: GrainStyle,
        look: ColorLook,
        halo: HaloLevel,
        lensZoom: Double,
        maxSide: CGFloat
    ) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let plate = plate(source: source, dng: dng, aspect: aspect, zoom: lensZoom, maxSide: maxSide) else {
            return nil
        }
        let base = StillPipeline.expose(plate, ev: exposureEV)
        return grade(base, look: look, halo: halo, style: style, exposureEV: exposureEV)
    }

    /// DNG: sensor linear, with the file's baseline exposure stored beside the samples.
    /// HEIF: one decode from the display transfer. Neither plate has the dial or the shoulder.
    private func plate(
        source: CGImage,
        dng: Data?,
        aspect: PhotoAspect,
        zoom: Double,
        maxSide: CGFloat
    ) -> StillPipeline.LinearPlate? {
        let side = Int(maxSide.rounded())
        let dngCount = dng?.count ?? 0
        let identity = ObjectIdentifier(source)
        if sourceID != identity || sourceAspect != aspect || abs(sourceZoom - zoom) > 0.001 || sourceDNG != dngCount {
            plates.removeAll()
            grades.removeAll()
            sourceID = identity
            sourceAspect = aspect
            sourceZoom = zoom
            sourceDNG = dngCount
        }
        if let cached = plates[side] { return cached }
        var loaded: StillPipeline.LinearPlate?
        if let dng {
            loaded = RawDevelop.scenePlate(
                dng: dng,
                aspect: aspect,
                lensZoom: zoom,
                maxSide: maxSide,
                draft: false
            )
        } else if let prepared = StillPipeline.prepared(source, zoom: zoom, maxSide: maxSide) {
            loaded = StillPipeline.linearPlate(of: prepared, baseline: 0)
        } else {
            loaded = nil
        }
        guard let loaded else { return nil }
        plates[side] = loaded
        return loaded
    }

    private func grade(_ base: CIImage, look: ColorLook, halo: HaloLevel, style: GrainStyle, exposureEV: Double) -> CIImage {
        if look == .none, halo == .off, style == .off {
            return base
        }
        let width = Int(base.extent.integral.width.rounded())
        let height = Int(base.extent.integral.height.rounded())
        let bakedLook = look
        let bakedHalo = halo
        let bakedStyle = style
        let evTag = Int((exposureEV * 10).rounded())
        let key = "\(width)x\(height)|\(evTag)|\(bakedLook.rawValue)|\(bakedHalo.rawValue)|\(bakedStyle.rawValue)"
        if let cached = grades[key], bakedHalo == halo, bakedLook == look, bakedStyle == style {
            return cached
        }
        let graded: CIImage
        if look == .none {
            graded = base
        } else {
            let graph = ColorLooks.graded(base, look: look)
            graded = StillPipeline.materialize(graph) ?? graph
        }
        var current = graded
        if halo != .off {
            current = StillPipeline.applyHalo(current, level: halo)
        }
        if style != .off {
            current = StillPipeline.grained(current, style: style)
            current = StillPipeline.materialize(current) ?? current
        }
        grades[key] = current
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
