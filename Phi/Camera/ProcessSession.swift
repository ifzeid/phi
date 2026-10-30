import CoreImage
import CoreLocation
import os
import UIKit

/// One developed still. Neutral shows the framed camera HEIF. Edits are gains on that still, at preview size until export.
final class ProcessSession: ObservableObject, Identifiable {
    let id = UUID()
    let base: CGImage
    let isSample: Bool
    let originalWasRaw: Bool
    private(set) var sourceDNG: Data?
    private(set) var sourceMetadata: [String: Any]?
    let framedAspect: PhotoAspect
    /// 1 is the full sensor. A crop stop such as 2× keeps the center of the full-frame DNG.
    let lensZoom: Double
    /// Mode 0. Preview and non-neutral export develop `sourceDNG` instead of Apple's HEIF.
    let rendersFromDNG: Bool
    let captureLocation: CLLocation?
    /// The file the user opened. Neutral edits show this, not a new render.
    let originalImage: UIImage?
    let originalData: Data?
    /// Stops relative to the captured frame. 0 reproduces the viewfinder, including finder EV compensation,
    /// because that bias is already in the sensor data and is not applied again. The meter-relative total
    /// is `captureEV + exposureEV`. The album thumbnail is this develop at 0, the capture look.
    @Published var exposureEV: Double
    @Published var style: GrainStyle
    @Published var colorLook: ColorLook
    @Published var halo: HaloLevel
    @Published var preview: UIImage?
    /// What the Metal preview draws. Ticket 0 is the framed HEIF, before any edit.
    @Published var liveFrame: LiveFrame?
    @Published var isExporting = false
    /// 0...1 while a full-res export is on the background queue.
    @Published var exportProgress: Double = 0
    @Published var status: String?
    @Published var developInfo: String

    var onPreview: ((UIImage) -> Void)?
    /// First pixels are on screen. Plate builds wait for this so open stays on the cached JPEG.
    var onFirstPresented: (() -> Void)?
    #if DEBUG
    var onFirstDrawn: ((CGImage) -> Void)?
    #endif

    struct LiveFrame {
        var ticket: Int
        var image: CIImage
    }

    private var renderTicket = 0
    private var rendering = false
    private var exposureDrag = false
    private var presentedTicket = -1
    private var warmTask: Task<Void, Never>?
    #if DEBUG
    private var presentWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    #endif
    #if DEBUG
    private var renderStarted: [Int: CFAbsoluteTime] = [:]
    #endif
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
        originalData: Data? = nil,
        rendersFromDNG: Bool = false
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
        self.rendersFromDNG = rendersFromDNG
        self.developInfo = sourceDNG == nil ? "来源 系统成片" : "来源 DNG"
        if let originalImage {
            self.preview = originalImage
        }
        let display = originalImage?.cgImage ?? base
        self.liveFrame = LiveFrame(ticket: 0, image: CIImage(cgImage: display))
        // Debug-only self-check takes seconds; keep it off the main thread so the editor opens at once.
        DispatchQueue.global(qos: .utility).async {
            _ = DevelopEffectCheck.confirm
        }
        if rendersFromDNG, sourceDNG != nil {
            // The saved file above is the placeholder for the first frame; the develop replaces it.
            schedule()
        }
    }

    var isNeutral: Bool {
        exposureEV == 0 && style == .off && colorLook == .none && halo == .off
    }

    /// Mode 0 with a DNG shows PHI's own zero-processing develop at every EV, 0 included, so the dial
    /// moves smoothly through the detent. The saved file is only a placeholder until that develop lands,
    /// and the settled frame without a DNG.
    var showsSavedFile: Bool {
        isNeutral && (rendersFromDNG == false || sourceDNG == nil)
    }

    func setExposure(_ value: Double) {
        setExposure(value, interactive: false)
    }

    /// `interactive` uses the 800 px proxy. The idle refine after the finger lifts uses 1280.
    func setExposure(_ value: Double, interactive: Bool) {
        exposureDrag = interactive
        exposureEV = (min(5, max(-5, value)) * 10).rounded() / 10
        schedule()
    }

    /// After a dial drag, replace the small proxy with the idle one.
    func refinePreview() {
        guard exposureDrag else { return }
        exposureDrag = false
        guard showsSavedFile == false else { return }
        schedule()
    }

    func setStyle(_ next: GrainStyle) {
        guard next != style else { return }
        exposureDrag = false
        style = next
        schedule()
    }

    func setColorLook(_ next: ColorLook) {
        guard next != colorLook else { return }
        exposureDrag = false
        colorLook = next
        schedule()
    }

    func setHalo(_ level: HaloLevel) {
        guard level != halo else { return }
        exposureDrag = false
        halo = level
        schedule()
    }

    func schedule() {
        renderTicket += 1
        #if DEBUG
        renderStarted[renderTicket] = CFAbsoluteTimeGetCurrent()
        #endif
        if showsSavedFile {
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
        let display = originalImage?.cgImage ?? base
        liveFrame = LiveFrame(ticket: renderTicket, image: CIImage(cgImage: display))
    }

    private struct DevelopRequest {
        var ticket: Int
        var neutral: Bool
        var exposureEV: Double
        var style: GrainStyle
        var look: ColorLook
        var halo: HaloLevel
        var interactive: Bool
        var maxSide: CGFloat
        var base: CGImage
        var original: UIImage?
        var aspect: PhotoAspect
    }

    private func makeSnapshot() -> DevelopRequest {
        DevelopRequest(
            ticket: renderTicket,
            neutral: showsSavedFile,
            exposureEV: exposureEV,
            style: style,
            look: colorLook,
            halo: halo,
            interactive: exposureDrag,
            maxSide: exposureDrag ? EditorMatch.dragSide : EditorMatch.previewMaxSide,
            base: base,
            original: originalImage,
            aspect: framedAspect
        )
    }

    /// Latest request wins. The camera still is already cropped; exposure hits the baked proxy.
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
            let rendered = previewCache.previewImage(
                source: source,
                dng: self.rendersFromDNG ? self.sourceDNG : nil,
                aspect: snap.aspect,
                exposureEV: snap.exposureEV,
                style: snap.style,
                look: snap.look,
                halo: snap.halo,
                lensZoom: self.rendersFromDNG ? self.lensZoom : 1,
                maxSide: snap.maxSide
            )
            let stale = await MainActor.run { () -> Bool in
                guard self.renderTicket == snap.ticket else { return true }
                if let rendered {
                    let side = Int(rendered.extent.integral.width.rounded())
                    let other = Int(rendered.extent.integral.height.rounded())
                    self.developInfo = "HEIF · \(side)×\(other)"
                    Logger(subsystem: "com.zeid.phi", category: "develop").info("\(self.developInfo, privacy: .public)")
                    self.liveFrame = LiveFrame(ticket: snap.ticket, image: rendered)
                    if snap.interactive == false {
                        self.publishThumbnail(rendered)
                    }
                }
                self.rendering = false
                return false
            }
            if stale == false { return }
        }
    }

    /// DNG bytes arrived after the cached JPEG was already on screen. The plate build stays off the main thread.
    func installSource(dng: Data, metadata: [String: Any]?) {
        sourceDNG = dng
        sourceMetadata = metadata
        developInfo = "来源 DNG"
        warmPreview()
        if showsSavedFile == false {
            schedule()
        }
    }

    func setExportProgress(_ value: Double) {
        exportProgress = min(1, max(0, value))
    }

    /// Called from the Metal view once that ticket's drawable has been presented.
    func notePresented(ticket: Int) {
        presentedTicket = max(presentedTicket, ticket)
        finishFirstFrame()
        #if DEBUG
        logRenderLatency(ticket: ticket)
        let ready = presentWaiters.filter { $0.0 <= ticket }
        presentWaiters.removeAll { $0.0 <= ticket }
        ready.forEach { $0.1.resume() }
        #endif
    }

    func deliverFirstPixels(_ image: CGImage) {
        finishFirstFrame()
        #if DEBUG
        onFirstDrawn?(image)
        onFirstDrawn = nil
        #endif
    }

    private func finishFirstFrame() {
        let callback = onFirstPresented
        onFirstPresented = nil
        callback?()
    }

    #if DEBUG
    func waitUntilWarm() async {
        await warmTask?.value
    }

    /// Applies one edit and waits until the Metal view presents it. Returns milliseconds.
    func measureEdit(_ body: @escaping (ProcessSession) -> Void) async -> Double {
        let started = CFAbsoluteTimeGetCurrent()
        let ticket = await MainActor.run { () -> Int in
            body(self)
            return self.renderTicket
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                if self.presentedTicket >= ticket {
                    continuation.resume()
                } else {
                    self.presentWaiters.append((ticket, continuation))
                }
            }
        }
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    func resetLatencySamples() {
        latencySamples.removeAll()
    }

    private(set) var latencySamples: [Double] = []
    #endif

    private func publishThumbnail(_ image: CIImage) {
        let picture = image
        let callback = onPreview
        Task.detached(priority: .utility) { [weak self] in
            guard let cg = StillPipeline.displayImage(picture) else { return }
            let ui = UIImage(cgImage: cg)
            await MainActor.run {
                self?.preview = ui
                callback?(ui)
            }
        }
    }

    #if DEBUG
    private func logRenderLatency(ticket: Int) {
        guard let start = renderStarted.removeValue(forKey: ticket) else { return }
        renderStarted = renderStarted.filter { $0.key > ticket }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        latencySamples.append(ms)
        let line = String(format: "EDITOR RENDER LATENCY %.1f ms", ms)
        print(line)
        Logger(subsystem: "com.zeid.phi", category: "uitest").notice("\(line, privacy: .public)")
    }
    #endif

    /// Bake the 800 px and 1280 px proxies, and every look cube, before the first edit.
    /// A full-res plate follows on a utility queue so save does not demosaic a second time.
    func warmPreview() {
        warmTask?.cancel()
        let source = upright(originalImage, fallback: base)
        let aspect = framedAspect
        let cache = previewCache
        let dng = rendersFromDNG ? sourceDNG : nil
        let zoom = rendersFromDNG ? lensZoom : 1
        warmTask = Task.detached(priority: .userInitiated) {
            cache.prewarm(
                source: source,
                dng: dng,
                aspect: aspect,
                zoom: zoom,
                sides: [EditorMatch.dragSide, EditorMatch.previewMaxSide]
            )
            guard Task.isCancelled == false, let dng else { return }
            _ = RawDevelop.scenePlate(
                dng: dng,
                aspect: aspect,
                lensZoom: zoom,
                maxSide: nil,
                draft: false
            )
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

    /// Interactive proxy. Full resolution is only the export render.
    static var previewSide: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let screen = scene?.screen
        let bounds = screen?.bounds ?? CGRect(x: 0, y: 0, width: 402, height: 874)
        let scale = screen?.scale ?? 3
        let pixels = max(bounds.width, bounds.height) * max(scale, 1)
        return min(EditorMatch.previewMaxSide, max(640, pixels))
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

/// Neutral edit frame versus the album still, and a proof that the dial changes the proxy.
enum EditorMatch {
    static let dragSide: CGFloat = 800
    static let previewMaxSide: CGFloat = 1280

    static func failures() -> [String] {
        guard let source = checkerImage() else { return ["editor checker image failed"] }
        let wrapped = UIImage(cgImage: source)
        guard let album = AlbumImage.framed(wrapped, aspect: .threeByFour, zoom: 2).cgImage,
              let editor = AlbumImage.framed(wrapped, aspect: .threeByFour, zoom: 2).cgImage else {
            return ["editor frame missing"]
        }
        var notes: [String] = []
        if album.width != editor.width || album.height != editor.height {
            notes.append("editor frame \(editor.width)x\(editor.height) is not the album frame \(album.width)x\(album.height)")
        }
        let ratio = CGFloat(editor.width) / CGFloat(max(editor.height, 1))
        if abs(ratio - PhotoAspect.threeByFour.widthOverHeight) > 0.03 {
            notes.append("editor frame aspect \(ratio)")
        }
        if editor.width >= source.width || editor.height >= source.height {
            notes.append("2× frame did not crop")
        }
        if let diff = meanAbsDiff(album, editor), diff > 0.5 {
            notes.append("album and editor frames differ by \(diff)")
        }
        if let neutral = StillPipeline.render(
            editor,
            exposureEV: 0,
            style: .off,
            look: .none,
            halo: .off,
            lensZoom: 1,
            maxSide: nil
        ) {
            if neutral.width != editor.width || neutral.height != editor.height {
                notes.append("neutral render \(neutral.width)x\(neutral.height) does not match \(editor.width)x\(editor.height)")
            } else if let diff = meanAbsDiff(editor, neutral), diff > 8 {
                notes.append("neutral render differs from the saved still by \(diff)")
            }
        } else {
            notes.append("neutral render failed")
        }
        guard let proxy = StillPipeline.render(editor, exposureEV: 0, style: .off, lensZoom: 1, maxSide: 96),
              let lifted = StillPipeline.render(editor, exposureEV: 1, style: .off, lensZoom: 1, maxSide: 96) else {
            notes.append("preview proxy failed")
            return notes
        }
        if max(proxy.width, proxy.height) > 96 {
            notes.append("preview proxy is \(max(proxy.width, proxy.height)) px")
        }
        if meanLuma(lifted) < meanLuma(proxy) + 8 {
            notes.append("exposure dial did not brighten the proxy")
        }
        if ProcessSession.previewSide > previewMaxSide {
            notes.append("preview side \(ProcessSession.previewSide) is above \(previewMaxSide)")
        }
        return notes
    }

    /// Mean absolute channel difference after drawing both images into the editor frame's size.
    static func logNeutralDiff(heif: CGImage, editor: CGImage) {
        let fitted = fittedSize(width: editor.width, height: editor.height, longSide: 256)
        guard fitted.width > 1, fitted.height > 1,
              let left = draw(heif, size: fitted),
              let right = draw(editor, size: fitted),
              let diff = meanAbsDiff(left, right) else {
            print("EDITOR NEUTRAL DIFF failed")
            return
        }
        let line = String(format: "EDITOR NEUTRAL DIFF %.3f", diff)
        print(line)
        Logger(subsystem: "com.zeid.phi", category: "uitest").notice("\(line, privacy: .public)")
    }

    private static func fittedSize(width: Int, height: Int, longSide: Int) -> CGSize {
        let longest = max(width, height)
        guard longest > longSide, longest > 0 else {
            return CGSize(width: CGFloat(width), height: CGFloat(height))
        }
        let scale = CGFloat(longSide) / CGFloat(longest)
        let fittedWidth = max(CGFloat(1), (CGFloat(width) * scale).rounded(.down))
        let fittedHeight = max(CGFloat(1), (CGFloat(height) * scale).rounded(.down))
        return CGSize(width: fittedWidth, height: fittedHeight)
    }

    private static func draw(_ image: CGImage, size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width.rounded(.down)))
        let height = max(1, Int(size.height.rounded(.down)))
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func checkerImage() -> CGImage? {
        let width = 320
        let height = 240
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for y in 0..<height {
            let t = CGFloat(y) / CGFloat(height)
            let fill = CGColor(colorSpace: space, components: [0.85, 0.35 + 0.2 * t, 0.12, 1])
                ?? CGColor(srgbRed: 0.85, green: 0.35 + 0.2 * t, blue: 0.12, alpha: 1)
            context.setFillColor(fill)
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return context.makeImage()
    }

    private static func meanAbsDiff(_ left: CGImage, _ right: CGImage) -> Float? {
        guard left.width == right.width, left.height == right.height, left.width > 0 else { return nil }
        guard let a = rgba(left), let b = rgba(right), a.count == b.count, a.isEmpty == false else { return nil }
        var sum = Float(0)
        let pixels = a.count / 4
        for index in 0..<pixels {
            let offset = index * 4
            sum += abs(Float(a[offset]) - Float(b[offset]))
            sum += abs(Float(a[offset + 1]) - Float(b[offset + 1]))
            sum += abs(Float(a[offset + 2]) - Float(b[offset + 2]))
        }
        return sum / Float(pixels * 3)
    }

    /// Display-encoded Rec.709 luma in 0...1. The editor EV sweep logs this.
    static func displayMeanLuma(_ image: CGImage) -> Float {
        meanLuma(image) / 255
    }

    private static func meanLuma(_ image: CGImage) -> Float {
        guard let bytes = rgba(image), bytes.isEmpty == false else { return 0 }
        var sum = Float(0)
        let pixels = bytes.count / 4
        for index in 0..<pixels {
            let offset = index * 4
            sum += 0.2126 * Float(bytes[offset]) + 0.7152 * Float(bytes[offset + 1]) + 0.0722 * Float(bytes[offset + 2])
        }
        return sum / Float(pixels)
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
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
        return drew ? bytes : nil
    }
}
