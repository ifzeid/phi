import CoreImage
import os

/// Bayer develop. Noise reduction, sharpness, detail, and moiré stay at 0 after scale,
/// because scale can restore defaults. The 无 look does not grade the file. Other looks are the
/// `LookRecipe` cubes. Only the CCD look resamples and sharpens.
/// ProRAW files are already multi-frame, demosaiced, and denoised by Apple; the same zeros still apply.
/// EV 0 is the DNG BaselineExposure tag, applied once as `2^baseline`, then a gentle filmic curve.
/// The dial is the same multiply (`2^(baseline + ev)`) before that curve. The filter does not add a second gain.
/// Demosaic stays full resolution and draft stays off. Apple's HEIF is not an input.
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
        guard let plate = scenePlate(
            dng: dng,
            aspect: aspect,
            lensZoom: lensZoom,
            maxSide: maxSide,
            draft: draft
        ) else {
            return nil
        }
        let toned = StillPipeline.expose(plate, ev: exposureEV)
        return StillPipeline.renderLinear(
            toned,
            exposureEV: 0,
            style: style,
            look: look,
            halo: halo
        )
    }

    /// Sensor-linear samples. `baseline` is the DNG tag, applied later as one multiply with the dial.
    static func scenePlate(
        dng: Data,
        aspect: PhotoAspect,
        lensZoom: Double,
        maxSide: CGFloat?,
        draft: Bool
    ) -> StillPipeline.LinearPlate? {
        guard let developed = developedFrame(
            dng: dng,
            lensZoom: lensZoom,
            maxSide: maxSide,
            draft: draft
        ) else { return nil }
        var cropped = aspect.cropped(developed.image)
        if let maxSide {
            // Full-res demosaic, then a sharp downsample. Scaling inside CIRAWFilter softens the Bayer grid.
            cropped = StillPipeline.scaledToSide(cropped, maxSide: maxSide)
        }
        return StillPipeline.linearPlate(of: cropped, baseline: developed.baseline, filmic: true)
    }

    /// `pow(2, ev)` while the data is still scene-linear, then the highlight shoulder.
    /// HEIF input is decoded once inside `linearPlate`. Preview and export both end in `StillPipeline.expose`.
    static func exposeThenShoulder(_ scene: CIImage, ev: Double) -> CIImage {
        guard let plate = StillPipeline.linearPlate(of: scene, baseline: 0) else { return scene }
        return StillPipeline.expose(plate, ev: ev)
    }

    /// Filter output, scene lift, and lens crop. No second orientation pass, and no aspect crop.
    private static func developedFrame(
        dng: Data,
        lensZoom: Double,
        maxSide: CGFloat?,
        draft: Bool
    ) -> (image: CIImage, baseline: Float)? {
        guard let filter = CIRAWFilter(imageData: dng, identifierHint: nil) else { return nil }
        _ = draft
        _ = maxSide
        filter.isDraftModeEnabled = false
        let asShotTemperature = filter.neutralTemperature
        let asShotTint = filter.neutralTint
        let asShotSharpness = filter.sharpnessAmount
        let zoom = lensZoom > 1 ? lensZoom : 1
        let native = filter.nativeSize
        // Full-resolution demosaic. A scaleFactor below 1 is a softer Bayer reconstruction.
        filter.scaleFactor = 1
        let baseline = silenceProcessing(filter)
        filter.sharpnessAmount = min(max(asShotSharpness, Float(0)), Float(0.35))
        // Other inputs reset the as-shot neutral. Put it back last so beams stay neutral.
        filter.neutralTemperature = asShotTemperature
        filter.neutralTint = asShotTint
        guard let output = filter.outputImage else { return nil }
        Self.lastReport = report(filter, native: native, output: output.extent, baseline: baseline)
        Logger(subsystem: "com.zeid.phi", category: "develop").info("baselineExposure \(baseline) as-shot WB \(asShotTemperature) tint \(asShotTint), full-res demosaic, filmic after 2^EV")
        // `outputImage` is already upright: a 4032×3024 buffer tagged orientation 6 comes out 3024×4032.
        // Applying that EXIF tag again turns the portrait frame sideways.
        let framed = LensCrop.cropped(output, zoom: zoom)
        Logger(subsystem: "com.zeid.phi", category: "develop").info("source DNG native \(Int(native.width))x\(Int(native.height)) scale \(filter.scaleFactor) zoom \(zoom)")
        return (framed, baseline)
    }

    /// Landscape sensor buffer tagged orientation 6. `CIRAWFilter` already turns that into a portrait image.
    static func portraitOrientationFailures() -> [String] {
        let sensorWidth = 64
        let sensorHeight = 48
        let dng = PortraitProbeDNG.data(width: sensorWidth, height: sensorHeight)
        let tagged = PortraitProbeDNG.orientationTag(in: dng) ?? ImageOrientation.exif(of: dng)
        guard tagged == 6 else {
            return ["portrait probe DNG is missing orientation 6"]
        }
        guard let framed = developedFrame(dng: dng, lensZoom: 1, maxSide: nil, draft: false)?.image else {
            return ["portrait-orientation DNG did not develop"]
        }
        let size = framed.extent.integral.size
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        if height <= width {
            return ["portrait DNG developed \(width)x\(height)"]
        }
        return []
    }

    /// Applied after draft mode and scaleFactor so those changes cannot put noise reduction back.
    /// The tag is returned and applied once, later, as `2^baseline`. The filter must not also apply it:
    /// its exposure, boost, and gamut map sit on a curve that refits after a second gain.
    @discardableResult
    private static func silenceProcessing(_ filter: CIRAWFilter) -> Float {
        let baseline = filter.baselineExposure
        filter.baselineExposure = 0
        filter.exposure = 0
        filter.shadowBias = 0
        filter.boostAmount = 0
        filter.localToneMapAmount = 0
        // Keep highlights inside Display P3 so a clipped channel does not turn a beam cyan.
        filter.isGamutMappingEnabled = true
        // Leave headroom above 1 so the filmic shoulder, not an SDR lift, rolls off the lights.
        filter.extendedDynamicRangeAmount = 1
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.moireReductionAmount = 0
        filter.detailAmount = 0
        filter.contrastAmount = 0
        filter.isLensCorrectionEnabled = false
        if filter.inputKeys.contains("inputBoostShadowAmount") {
            filter.setValue(0.0, forKey: "inputBoostShadowAmount")
        }
        return baseline
    }

    private static func report(_ filter: CIRAWFilter, native: CGSize, output: CGRect, baseline: Float) -> String {
        let line = "native \(Int(native.width))x\(Int(native.height)) out \(Int(output.width))x\(Int(output.height)) scale \(filter.scaleFactor) draft \(filter.isDraftModeEnabled) exp \(filter.exposure) base \(baseline) nr \(filter.luminanceNoiseReductionAmount)/\(filter.colorNoiseReductionAmount) sharp \(filter.sharpnessAmount) detail \(filter.detailAmount) moire \(filter.moireReductionAmount) ltm \(filter.localToneMapAmount) lens \(filter.isLensCorrectionEnabled)"
        Logger(subsystem: "com.zeid.phi", category: "develop").info("\(line, privacy: .public)")
        return line
    }

    /// `2^(baseline + ev)` before any tone curve. HEIF passes a baseline of 0.
    static func sceneGain(baseline: Float, ev: Double) -> Float {
        let stops = Double(baseline) + min(5, max(-5, ev))
        return Float(pow(2, stops))
    }

    /// Gentle filmic for mode 0. A toe pulls night sky toward black, a small S adds contrast, then the highlight shoulder.
    /// The same curve on each channel, so a neutral beam stays neutral. EV 0 already includes BaselineExposure.
    static func toneMapValue(_ linear: Float) -> Float {
        let x = max(linear, 0)
        let toeEnd: Float = 0.045
        let toed: Float
        if x <= 0 {
            toed = 0
        } else if x >= toeEnd {
            toed = x
        } else {
            let t = x / toeEnd
            toed = toeEnd * t * t
        }
        let pivot: Float = 0.18
        let contrast: Float = 1.2
        let contrasted = toed <= 0 ? Float(0) : pivot * pow(toed / pivot, contrast)
        return baseShoulderValue(contrasted)
    }

    /// Global shoulder. Midtones below the knee stay put, so a sunset is not lifted into a pale frame.
    /// Highlights roll toward 1 and are not locally tone-mapped.
    static func baseShoulderValue(_ linear: Float) -> Float {
        let knee: Float = 0.62
        let softness: Float = 0.55
        let x = max(linear, 0)
        if x <= knee { return x }
        let span = x - knee
        return min(knee + (1 - knee) * (span / (span + softness)), 1)
    }

    static func baseToneFailures() -> [String] {
        var notes: [String] = []
        if baseShoulderValue(0.4) != 0.4 {
            notes.append("base shoulder moved a midtone")
        }
        let high = baseShoulderValue(2)
        if high >= 1 || high <= baseShoulderValue(0.62) {
            notes.append("base shoulder did not keep a highlight")
        }
        if toneMapValue(0) != 0 {
            notes.append("filmic lifted black")
        }
        if toneMapValue(0.01) > 0.004 {
            notes.append("filmic left a night sky gray")
        }
        let mid = toneMapValue(0.18)
        if abs(mid - 0.18) > 0.02 {
            notes.append("filmic moved mid gray")
        }
        var previous = Float(0)
        for sample in [Float(0), 0.01, 0.04, 0.18, 0.45, 1, 2] {
            let tone = toneMapValue(sample)
            if tone + 0.0001 < previous {
                notes.append("filmic is not monotonic")
                break
            }
            previous = tone
        }
        if toneMapValue(0.85 * Float(pow(2, 0.9))) >= 0.985 {
            notes.append("filmic clipped a white wall at +0.9")
        }
        let gain = sceneGain(baseline: 0.5, ev: -2)
        if abs(gain - Float(pow(2, 0.5 - 2))) > 0.0001 {
            notes.append("scene gain is not 2^(baseline+EV)")
        }
        return notes
    }

    /// Synthetic chart plus a white-wall sample. Mean luma falls as EV falls. Mid-gray tracks `2^EV` under the knee.
    static func exposureMetricFailures() -> [String] {
        var notes = wallShoulderFailures()
        let scene = exposureProbe()
        let stops: [Double] = [2, 0.9, 0, -0.7, -1, -2]
        var rows: [(Double, Float, Float, Float, Float, Float)] = []
        for ev in stops {
            let toned = exposeThenShoulder(scene, ev: ev)
            guard let image = StillPipeline.displayImage(toned), let stats = probeStats(image, ev: ev) else {
                return notes + ["exposure probe did not render"]
            }
            let line = String(
                format: "EDITOR EV METRICS ev=%+.1f mean=%.3f p1=%.3f p99=%.3f sat=%.3f linearMid=%.4f",
                ev, stats.mean, stats.p1, stats.p99, stats.sat, stats.linearMid
            )
            print(line)
            Logger(subsystem: "com.zeid.phi", category: "uitest").notice("\(line, privacy: .public)")
            rows.append((ev, stats.mean, stats.p1, stats.p99, stats.sat, stats.linearMid))
        }
        guard let zero = rows.first(where: { abs($0.0) < 0.001 }) else { return notes + ["exposure probe did not render"] }
        for index in 1..<rows.count where rows[index].1 >= rows[index - 1].1 - 0.002 {
            notes.append(String(
                format: "EV %+.1f mean luma %.3f is not below EV %+.1f %.3f",
                rows[index].0, rows[index].1, rows[index - 1].0, rows[index - 1].1
            ))
        }
        for row in rows {
            if row.0 <= 0.001, row.2 > zero.2 + 0.004 {
                notes.append(String(format: "EV %+.1f black p1 rose from %.3f to %.3f", row.0, zero.2, row.2))
            }
            if row.0 < -0.05, row.4 + 0.03 < zero.4 {
                notes.append(String(format: "EV %+.1f saturation dropped from %.3f to %.3f", row.0, zero.4, row.4))
            }
            let expected = Float(pow(2, row.0))
            let underKnee = Float(0.18) * expected <= 0.60
            if underKnee, zero.5 > 0.001, abs(row.0) > 0.05 {
                let ratio = row.5 / zero.5
                let error = abs(ratio - expected) / expected
                if error > 0.12 {
                    notes.append(String(
                        format: "EV %+.1f linear midtone ratio %.3f is not 2^EV (%.3f)",
                        row.0, ratio, expected
                    ))
                }
            }
        }
        return notes
    }

    /// A wall that is comfortable at EV 0 must darken at −0.7 and must not clip at +0.9.
    private static func wallShoulderFailures() -> [String] {
        let wall: Float = 0.85
        let neutral = baseShoulderValue(wall)
        let dropped = baseShoulderValue(wall * Float(pow(2, -0.7)))
        let lifted = baseShoulderValue(wall * Float(pow(2, 0.9)))
        let line = String(
            format: "EDITOR EV METRICS wall ev0=%.3f ev-0.7=%.3f ev+0.9=%.3f",
            neutral, dropped, lifted
        )
        print(line)
        Logger(subsystem: "com.zeid.phi", category: "uitest").notice("\(line, privacy: .public)")
        var notes: [String] = []
        if dropped >= neutral {
            notes.append(String(format: "EV -0.7 wall %.3f is not darker than %.3f", dropped, neutral))
        }
        if lifted <= neutral {
            notes.append(String(format: "EV +0.9 wall %.3f is not brighter than %.3f", lifted, neutral))
        }
        if lifted >= 0.985 {
            notes.append(String(format: "EV +0.9 clipped a white wall to %.3f", lifted))
        }
        return notes
    }

    private static func exposureProbe() -> CIImage {
        func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ rect: CGRect) -> CIImage {
            let space = StillPipeline.linearP3
            let color = CIColor(red: red, green: green, blue: blue, alpha: 1, colorSpace: space)
                ?? CIColor(red: red, green: green, blue: blue)
            return CIImage(color: color).cropped(to: rect)
        }
        let black = solid(0, 0, 0, CGRect(x: 0, y: 0, width: 32, height: 8))
        let gray = solid(0.18, 0.18, 0.18, CGRect(x: 0, y: 8, width: 32, height: 8))
        let red = solid(0.45, 0.08, 0.08, CGRect(x: 0, y: 16, width: 32, height: 8))
        let hot = solid(1.6, 0.9, 0.3, CGRect(x: 0, y: 24, width: 32, height: 8))
        return hot.composited(over: red.composited(over: gray.composited(over: black)))
    }

    private static func probeStats(_ image: CGImage, ev: Double) -> (mean: Float, p1: Float, p99: Float, sat: Float, linearMid: Float)? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = StillPipeline.displayP3
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew, width > 0, height > 0 else { return nil }
        var luma = [Float]()
        luma.reserveCapacity(width * height)
        var satSum = Float(0)
        var satCount = 0
        var midSum = Float(0)
        var midCount = 0
        for index in 0..<(width * height) {
            let offset = index * 4
            let red = Float(bytes[offset]) / 255
            let green = Float(bytes[offset + 1]) / 255
            let blue = Float(bytes[offset + 2]) / 255
            let y = GrainField.rec709(red: red, green: green, blue: blue)
            luma.append(y)
            let peak = max(red, max(green, blue))
            let floor = min(red, min(green, blue))
            if peak > 0.08 {
                satSum += (peak - floor) / peak
                satCount += 1
            }
            if peak - floor < 0.04, y > 0.05 {
                let linear = GrainField.rec709(
                    red: GrainField.decoded(red),
                    green: GrainField.decoded(green),
                    blue: GrainField.decoded(blue)
                )
                midSum += linear
                midCount += 1
            }
        }
        luma.sort()
        let p1 = luma[max(0, luma.count / 100)]
        let p99 = luma[min(luma.count - 1, luma.count * 99 / 100)]
        let mean = luma.reduce(0, +) / Float(luma.count)
        let sat = satCount > 0 ? satSum / Float(satCount) : 0
        let linearMid = midCount > 0 ? midSum / Float(midCount) : 0
        _ = ev
        return (mean, p1, p99, sat, linearMid)
    }
}

/// Tiny Bayer DNG: landscape samples, TIFF orientation 6. Develop must come out portrait.
private enum PortraitProbeDNG {
    static func data(width: Int, height: Int) -> Data {
        let entryCount = 23
        let ifdEnd = 8 + 2 + entryCount * 12 + 4
        var extra = Data()
        func offset() -> Int { ifdEnd + extra.count }
        func appendU16(_ value: Int, to data: inout Data) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        func appendU32(_ value: Int, to data: inout Data) {
            appendU16(value & 0xFFFF, to: &data)
            appendU16((value >> 16) & 0xFFFF, to: &data)
        }
        func appendRational(_ numerator: Int, _ denominator: Int, to data: inout Data) {
            appendU32(numerator, to: &data)
            appendU32(denominator, to: &data)
        }

        let matrixOffset = offset()
        let matrix = [
            4125, 10000, 3576, 10000, 1804, 10000,
            2127, 10000, 7152, 10000, 722, 10000,
            193, 10000, 1192, 10000, 9503, 10000
        ]
        var pair = 0
        while pair < matrix.count {
            appendRational(matrix[pair], matrix[pair + 1], to: &extra)
            pair += 2
        }
        let neutralOffset = offset()
        appendRational(1, 1, to: &extra)
        appendRational(1, 1, to: &extra)
        appendRational(1, 1, to: &extra)
        let blackOffset = offset()
        appendRational(0, 1, to: &extra)
        let stripOffset = offset()
        for y in 0..<height {
            for x in 0..<width {
                let red = y % 2 == 0 && x % 2 == 0
                let blue = y % 2 == 1 && x % 2 == 1
                let sample = red ? 8000 : (blue ? 3000 : 5000)
                appendU16(sample, to: &extra)
            }
        }
        let stripBytes = width * height * 2
        let entries: [(Int, Int, Int, Int)] = [
            (254, 4, 1, 0),
            (256, 4, 1, width),
            (257, 4, 1, height),
            (258, 3, 1, 16),
            (259, 3, 1, 1),
            (262, 3, 1, 32803),
            (273, 4, 1, stripOffset),
            (274, 3, 1, 6),
            (277, 3, 1, 1),
            (278, 4, 1, height),
            (279, 4, 1, stripBytes),
            (284, 3, 1, 1),
            (33421, 3, 2, 0x0002_0002),
            (33422, 1, 4, 0x0201_0100),
            (50706, 1, 4, 0x0000_0401),
            (50707, 1, 4, 0x0000_0101),
            (50708, 2, 4, 0x0049_4850),
            (50710, 1, 3, 0x0002_0100),
            (50713, 5, 1, blackOffset),
            (50717, 4, 1, 65535),
            (50721, 10, 9, matrixOffset),
            (50728, 5, 3, neutralOffset),
            (50778, 3, 1, 21)
        ]
        var file = Data()
        file.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
        appendU32(8, to: &file)
        appendU16(entries.count, to: &file)
        for item in entries {
            appendU16(item.0, to: &file)
            appendU16(item.1, to: &file)
            appendU32(item.2, to: &file)
            appendU32(item.3, to: &file)
        }
        appendU32(0, to: &file)
        file.append(extra)
        return file
    }

    /// TIFF orientation tag 274. ImageIO sometimes nests this under the TIFF dictionary.
    static func orientationTag(in data: Data) -> Int? {
        guard data.count > 8, data[0] == 0x49, data[1] == 0x49, data[2] == 0x2A else { return nil }
        let start = int32(data, 4)
        guard start + 2 <= data.count else { return nil }
        let count = int16(data, start)
        var cursor = start + 2
        for _ in 0..<count {
            guard cursor + 12 <= data.count else { return nil }
            let tag = int16(data, cursor)
            if tag == 274 {
                return int16(data, cursor + 8)
            }
            cursor += 12
        }
        return nil
    }

    private static func int16(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private static func int32(_ data: Data, _ offset: Int) -> Int {
        int16(data, offset) | (int16(data, offset + 2) << 16)
    }
}
