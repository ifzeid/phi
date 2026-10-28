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
    @Published var halo: Bool
    @Published var preview: UIImage?
    @Published var isExporting = false
    @Published var status: String?
    @Published var developInfo: String

    var onPreview: ((UIImage) -> Void)?

    private var token = 0

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
        halo: Bool = false,
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
    }

    var isNeutral: Bool {
        exposureEV == 0 && style == .off && colorLook == .none && halo == false
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

    func setHalo(_ enabled: Bool) {
        guard enabled != halo else { return }
        halo = enabled
        schedule()
    }

    func schedule() {
        if isNeutral {
            token += 1
            if let originalImage {
                preview = originalImage
                developInfo = "原片 · \(originalImage.size.width)x\(originalImage.size.height)"
            } else {
                preview = UIImage(cgImage: base)
                developInfo = "原片 · \(base.width)×\(base.height)"
            }
            return
        }
        token += 1
        let current = token
        let upright = originalImage.flatMap { StillPipeline.normalizedCGImage(from: $0) } ?? base
        let base = upright
        let ev = exposureEV
        let style = style
        let dng = sourceDNG
        let aspect = framedAspect
        let zoom = lensZoom
        let look = colorLook
        let haloOn = halo
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 45_000_000)
            guard current == self.token else { return }
            let rendered = await Task.detached(priority: .userInitiated) {
                if let dng {
                    return RawDevelop.image(
                        dng: dng,
                        exposureEV: ev,
                        style: style,
                        look: look,
                        halo: haloOn,
                        aspect: aspect,
                        lensZoom: zoom,
                        maxSide: Self.previewSide,
                        draft: false
                    )
                }
                return StillPipeline.render(
                    base,
                    exposureEV: ev,
                    style: style,
                    look: look,
                    halo: haloOn,
                    lensZoom: zoom,
                    maxSide: Self.previewSide
                )
            }.value
            guard current == self.token, let rendered else { return }
            let image = UIImage(cgImage: rendered)
            let source = dng == nil ? "source HEIF" : "source DNG"
            let report = RawDevelop.lastReport
            self.developInfo = "\(source) · \(rendered.width)×\(rendered.height) · \(report)"
            Logger(subsystem: "com.zeid.phi", category: "develop").info("\(self.developInfo, privacy: .public)")
            self.preview = image
            self.onPreview?(image)
        }
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
            space: CGColorSpaceCreateDeviceRGB(),
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
