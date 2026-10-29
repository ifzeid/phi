import CoreImage
import os

/// Bayer develop. Noise reduction, sharpness, detail, and moiré stay at 0 after scale,
/// because scale can restore defaults. The 无 look does not grade the file. Other looks are the
/// `LookRecipe` cubes. Only the CCD look resamples and sharpens.
/// ProRAW files are already multi-frame, demosaiced, and denoised by Apple; the same zeros still apply.
/// The EV dial is a linear gain after the look, matching the HEIF preview cache.
/// `CIRAWFilter.exposure` stays at the file baseline. Apple's HEIF is not an input.
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
        guard let filtered = linearBase(
            dng: dng,
            aspect: aspect,
            lensZoom: lensZoom,
            maxSide: maxSide,
            draft: draft
        ) else {
            return nil
        }
        return StillPipeline.renderLinear(
            filtered,
            exposureEV: exposureEV,
            style: style,
            look: look,
            halo: halo
        )
    }

    /// Proxy-scale or full-size linear develop at baseline exposure. The dial is applied later.
    static func linearBase(
        dng: Data,
        aspect: PhotoAspect,
        lensZoom: Double,
        maxSide: CGFloat?,
        draft: Bool
    ) -> CIImage? {
        filteredImage(
            dng: dng,
            exposureEV: 0,
            aspect: aspect,
            lensZoom: lensZoom,
            maxSide: maxSide,
            draft: draft
        )
    }

    private static func filteredImage(
        dng: Data,
        exposureEV: Double,
        aspect: PhotoAspect,
        lensZoom: Double,
        maxSide: CGFloat?,
        draft: Bool
    ) -> CIImage? {
        guard let framed = developedFrame(
            dng: dng,
            exposureEV: exposureEV,
            lensZoom: lensZoom,
            maxSide: maxSide,
            draft: draft
        ) else { return nil }
        return aspect.cropped(framed)
    }

    /// Filter output, scene lift, and lens crop. No second orientation pass, and no aspect crop.
    private static func developedFrame(
        dng: Data,
        exposureEV: Double,
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
        output = baseShoulder(output)
        Logger(subsystem: "com.zeid.phi", category: "develop").info("baselineExposure \(baseline) shoulder knee 0.62")
        // `outputImage` is already upright: a 4032×3024 buffer tagged orientation 6 comes out 3024×4032.
        // Applying that EXIF tag again turns the portrait frame sideways.
        let framed = LensCrop.cropped(output, zoom: zoom)
        Logger(subsystem: "com.zeid.phi", category: "develop").info("source DNG native \(Int(native.width))x\(Int(native.height)) scale \(filter.scaleFactor) zoom \(zoom)")
        return framed
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
        guard let framed = developedFrame(dng: dng, exposureEV: 0, lensZoom: 1, maxSide: nil, draft: false) else {
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
    /// `exposure` replaces the file's baseline. Callers pass 0 here; the dial is a gain after the look.
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
        return notes
    }

    private static let shoulderKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 phiShoulder(__sample s) {
            float knee = 0.62;
            float softness = 0.55;
            vec3 x = max(s.rgb, vec3(0.0));
            vec3 span = max(x - vec3(knee), vec3(0.0));
            vec3 compressed = vec3(knee) + vec3(1.0 - knee) * (span / (span + vec3(softness)));
            vec3 y = mix(x, min(compressed, vec3(1.0)), step(vec3(knee), x));
            return vec4(y, s.a);
        }
        """)

    private static func baseShoulder(_ image: CIImage) -> CIImage {
        guard let kernel = shoulderKernel, let output = kernel.apply(extent: image.extent, arguments: [image]) else {
            return image
        }
        return output
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
