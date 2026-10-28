import CoreLocation
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
    let captureLocation: CLLocation?
    @Published var exposureEV: Double
    @Published var style: GrainStyle
    @Published var preview: UIImage?
    @Published var isExporting = false
    @Published var status: String?

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
        captureLocation: CLLocation? = nil
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
        self.captureLocation = captureLocation
    }

    func setExposure(_ value: Double) {
        exposureEV = (min(2, max(-2, value)) * 10).rounded() / 10
        schedule()
    }

    func setStyle(_ next: GrainStyle) {
        guard next != style else { return }
        style = next
        schedule()
    }

    func schedule() {
        token += 1
        let current = token
        let base = base
        let ev = exposureEV
        let style = style
        let dng = sourceDNG
        let aspect = framedAspect
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 45_000_000)
            guard current == self.token else { return }
            let rendered = await Task.detached(priority: .userInitiated) {
                if let dng {
                    return RawDevelop.image(dng: dng, exposureEV: ev, style: style, aspect: aspect, maxSide: 1600, draft: false)
                }
                return StillPipeline.render(base, exposureEV: ev, style: style, maxSide: 1600)
            }.value
            guard current == self.token, let rendered else { return }
            let image = UIImage(cgImage: rendered)
            self.preview = image
            self.onPreview?(image)
        }
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
