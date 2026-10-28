import CoreImage
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Develops a still in 16-bit linear Display P3, then emits one 8-bit Display P3 image.
/// Preview and export both call `render` so they share one recipe. Grain is FINE or off.
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
        let pixel = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixel, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixel))
        }.cgImage
    }

    static func render(
        _ image: CGImage,
        exposureEV: Double,
        style: GrainStyle,
        look: ColorLook = .none,
        halo: Bool = false,
        maxSide: CGFloat?
    ) -> CGImage? {
        var input = CIImage(cgImage: image)
        let longest = max(input.extent.width, input.extent.height)
        if let maxSide, longest > maxSide, longest > 0 {
            let scale = maxSide / longest
            input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        // The file is display-encoded. Looks expect the linear working space.
        input = input.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.2])
        let bounded = Swift.min(2, Swift.max(-2, exposureEV))
        let exposed = input.applyingFilter("CIExposureAdjust", parameters: ["inputEV": bounded])
        let looked = ColorLooks.apply(exposed, look: look, halo: halo)
        let developed = grained(looked, style: style)
        return displayImage(developed)
    }

    static func grained(_ image: CIImage, style: GrainStyle) -> CIImage {
        applyGrain(to: image, style: style)
    }

    static func displayImage(_ image: CIImage) -> CGImage? {
        renderLock.lock()
        defer { renderLock.unlock() }
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1, extent.isInfinite == false else { return nil }
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

    private static func applyGrain(to image: CIImage, style: GrainStyle) -> CIImage {
        guard let profile = style.profile else { return image }
        let tile = GrainTiles.image(for: style)
        let tileWidth = max(tile.extent.width, 1)
        let target = max(image.extent.width * profile.tileFraction, tileWidth)
        let scale = target / tileWidth
        let scaled = tile.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let tiled = scaled
            .applyingFilter("CIAffineTile")
            .cropped(to: image.extent)
        let speckled = tiled.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: profile.chroma,
            kCIInputContrastKey: profile.contrast,
            kCIInputBrightnessKey: 0
        ])
        guard let overlay = CIFilter(name: "CIOverlayBlendMode") else { return image }
        overlay.setValue(speckled, forKey: kCIInputImageKey)
        overlay.setValue(image, forKey: kCIInputBackgroundImageKey)
        guard let overlaid = overlay.outputImage?.cropped(to: image.extent) else { return image }
        guard let dissolve = CIFilter(name: "CIDissolveTransition") else { return image }
        dissolve.setValue(image, forKey: kCIInputImageKey)
        dissolve.setValue(overlaid, forKey: kCIInputTargetImageKey)
        dissolve.setValue(min(1, max(0, profile.mix)), forKey: kCIInputTimeKey)
        return (dissolve.outputImage ?? image).cropped(to: image.extent)
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

enum GrainTiles {
    private static let lock = NSLock()
    private static var cache: [GrainStyle: CIImage] = [:]
    private static let side = 256

    static func image(for style: GrainStyle) -> CIImage {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[style] { return cached }
        let image = CIImage(cgImage: makeTile(style))
        cache[style] = image
        return image
    }

    private static func makeTile(_ style: GrainStyle) -> CGImage {
        let profile = style.profile
        let cell = max(profile?.cell ?? 1, 1)
        let chroma = (profile?.chroma ?? 0) > 0.12
        let bytes = side * side * 4
        var pixels = [UInt8](repeating: 255, count: bytes)
        for y in 0..<side {
            for x in 0..<side {
                let cx = x / cell
                let cy = y / cell
                let n = unitHash(x: cx, y: cy, seed: profile?.seed ?? 1)
                let centered = (n - 0.5) * 0.9
                let gray = UInt8(clamping: Int((0.5 + centered) * 255))
                var red = gray
                var blue = gray
                if chroma {
                    let shift = Int((unitHash(x: cx, y: cy, seed: (profile?.seed ?? 1) ^ 0xA5A5_5A5A) - 0.5) * 36)
                    red = UInt8(clamping: Int(gray) + shift)
                    blue = UInt8(clamping: Int(gray) - shift)
                }
                let index = (y * side + x) * 4
                pixels[index] = red
                pixels[index + 1] = gray
                pixels[index + 2] = blue
                pixels[index + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }
            return context.makeImage()
        }
        return image ?? grayFallback()
    }

    private static func unitHash(x: Int, y: Int, seed: UInt32) -> Double {
        var n = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263) &+ seed
        n = (n ^ (n >> 13)) &* 1274126177
        return Double(n & 0x00FF_FFFF) / Double(0x00FF_FFFF)
    }

    private static func grayFallback() -> CGImage {
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
