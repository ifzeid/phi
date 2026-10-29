import CoreLocation
import os
import UIKit

/// One developed still. When `sourceDNG` is set, exposure and grain re-develop that Bayer file.
/// Otherwise exposure is applied to `base`. Preview and export share the recipe.
final class ProcessSession: ObservableObject, Identifiable {
    let id = UUID()
    let base: CGImage
    let isSample: Bool
    let originalWasRaw: Bool
    let sourceDNG: Data?
    let sourceMetadata: [String: Any]?
    let framedAspect: PhotoAspect
    /// 1 is the full sensor. A crop stop such as 2× keeps the center of the full-frame DNG.
    let lensZoom: Double
    let captureLocation: CLLocation?
    /// The file the user opened. Neutral edits show this, not a new render.
    let originalImage: UIImage?
    let originalData: Data?
    @Published var exposureEV: Double
    @Published var style: GrainStyle
    @Published var colorLook: ColorLook
    @Published var halo: HaloLevel
    @Published var preview: UIImage?
    @Published var isExporting = false
    @Published var status: String?
    @Published var developInfo: String

    var onPreview: ((UIImage) -> Void)?

    private var renderTicket = 0
    private var rendering = false
    private let previewCache = PreviewCache()
    private var oriented: CGImage?

    init(
        base: CGImage,
        exposureEV: Double,
        style: GrainStyle,
        isSample: Bool,
        originalWasRaw: Bool,
        status: String? = nil,
        sourceDNG: Data? = nil,
        sourceMetadata: [String: Any]? = nil,
        framedAspect: PhotoAspect = .threeByFour,
        lensZoom: Double = 1,
        captureLocation: CLLocation? = nil,
        colorLook: ColorLook = .none,
        halo: HaloLevel = .off,
        originalImage: UIImage? = nil,
        originalData: Data? = nil
    ) {
        self.base = base
        self.exposureEV = exposureEV
        self.style = style
        self.isSample = isSample
        self.originalWasRaw = originalWasRaw
        self.status = status
        self.sourceDNG = sourceDNG
        self.sourceMetadata = sourceMetadata
        self.framedAspect = framedAspect
        self.lensZoom = lensZoom > 1 ? lensZoom : 1
        self.captureLocation = captureLocation
        self.colorLook = colorLook
        self.halo = halo
        self.originalImage = originalImage
        self.originalData = originalData
        self.developInfo = sourceDNG == nil ? "来源 系统成片" : "来源 DNG"
        if let originalImage {
            self.preview = originalImage
        }
        _ = DevelopEffectCheck.confirm
    }

    var isNeutral: Bool {
        exposureEV == 0 && style == .off && colorLook == .none && halo == .off
    }

    func setExposure(_ value: Double) {
        exposureEV = (min(5, max(-5, value)) * 10).rounded() / 10
        schedule()
    }

    func setStyle(_ next: GrainStyle) {
        guard next != style else { return }
        style = next
        schedule()
    }

    func setColorLook(_ next: ColorLook) {
        guard next != colorLook else { return }
        colorLook = next
        schedule()
    }

    func setHalo(_ level: HaloLevel) {
        guard level != halo else { return }
        halo = level
        schedule()
    }

    func schedule() {
        renderTicket += 1
        if isNeutral {
            showOriginal()
            return
        }
        if rendering { return }
        rendering = true
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.pump()
        }
    }

    private func showOriginal() {
        if let originalImage {
            preview = originalImage
            developInfo = "原片 · \(originalImage.size.width)x\(originalImage.size.height)"
        } else {
            preview = UIImage(cgImage: base)
            developInfo = "原片 · \(base.width)×\(base.height)"
        }
    }

    private struct DevelopRequest {
        var ticket: Int
        var neutral: Bool
        var exposureEV: Double
        var style: GrainStyle
        var look: ColorLook
        var halo: HaloLevel
        var zoom: Double
        var maxSide: CGFloat
        var base: CGImage
        var original: UIImage?
        var dng: Data?
        var aspect: PhotoAspect
    }

    private func makeSnapshot() -> DevelopRequest {
        DevelopRequest(
            ticket: renderTicket,
            neutral: isNeutral,
            exposureEV: exposureEV,
            style: style,
            look: colorLook,
            halo: halo,
            zoom: lensZoom,
            maxSide: Self.previewSide,
            base: base,
            original: originalImage,
            dng: sourceDNG,
            aspect: framedAspect
        )
    }

    /// Latest request wins. Exposure hits the baked proxy; look, 光晕, and grain rebuild it.
    private func pump() async {
        while true {
            let snap = await MainActor.run { self.makeSnapshot() }
            if snap.neutral {
                await MainActor.run {
                    self.showOriginal()
                    self.rendering = false
                }
                return
            }
            let source = upright(snap.original, fallback: snap.base)
            let rendered = previewCache.cgImage(
                source: source,
                dng: snap.dng,
                aspect: snap.aspect,
                exposureEV: snap.exposureEV,
                style: snap.style,
                look: snap.look,
                halo: snap.halo,
                lensZoom: snap.zoom,
                maxSide: snap.maxSide
            )
            let stale = await MainActor.run { () -> Bool in
                guard self.renderTicket == snap.ticket else { return true }
                if let rendered {
                    let image = UIImage(cgImage: rendered)
                    let label = snap.dng == nil ? "source HEIF" : "source DNG"
                    self.developInfo = "\(label) · \(rendered.width)×\(rendered.height) · \(RawDevelop.lastReport)"
                    Logger(subsystem: "com.zeid.phi", category: "develop").info("\(self.developInfo, privacy: .public)")
                    self.preview = image
                    self.onPreview?(image)
                }
                self.rendering = false
                return false
            }
            if stale == false { return }
        }
    }

    private func upright(_ original: UIImage?, fallback: CGImage) -> CGImage {
        if let oriented { return oriented }
        let resolved: CGImage
        if let original, original.imageOrientation != .up,
           let drawn = StillPipeline.normalizedCGImage(from: original) {
            resolved = drawn
        } else {
            resolved = fallback
        }
        oriented = resolved
        return resolved
    }

    /// Screen pixels, not the 1600px draft scale. Full export still uses scale 1.
    static var previewSide: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let screen = scene?.screen
        let bounds = screen?.bounds ?? CGRect(x: 0, y: 0, width: 402, height: 874)
        let scale = screen?.scale ?? 3
        return max(bounds.width, bounds.height) * max(scale, 1)
    }

    static func syntheticPreview() -> ProcessSession {
        let context = CGContext(
            data: nil,
            width: 800,
            height: 1066,
            bitsPerComponent: 8,
            bytesPerRow: 800 * 4,
            space: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for y in 0..<1066 {
            let t = CGFloat(y) / 1066
            context.setFillColor(CGColor(srgbRed: 0.35 + 0.2 * t, green: 0.28 + 0.12 * t, blue: 0.22, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: 800, height: 1))
        }
        let image = context.makeImage()!
        let session = ProcessSession(base: image, exposureEV: 0, style: .off, isSample: true, originalWasRaw: false, status: "预览渐变，不是照片。")
        session.schedule()
        return session
    }
}
