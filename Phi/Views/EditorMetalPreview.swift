import CoreImage
import Metal
import MetalKit
import SwiftUI

/// Draws the editor proxy with the shared Metal `CIContext`. Preview updates do not allocate a `CGImage`.
struct EditorMetalPreview: UIViewRepresentable {
    var frame: ProcessSession.LiveFrame?
    var onPresented: (Int) -> Void
    var onFirstPixels: (CGImage) -> Void

    func makeUIView(context: Context) -> EditorCanvas {
        let view = EditorCanvas(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = false
        view.isOpaque = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = view
        view.onPresented = onPresented
        view.onFirstPixels = onFirstPixels
        return view
    }

    func updateUIView(_ view: EditorCanvas, context: Context) {
        view.onPresented = onPresented
        view.onFirstPixels = onFirstPixels
        guard let frame else { return }
        if view.pendingTicket != frame.ticket {
            view.image = frame.image
            view.pendingTicket = frame.ticket
        }
        if view.drawnTicket != frame.ticket {
            view.setNeedsDisplay()
        }
    }
}

final class EditorCanvas: MTKView, MTKViewDelegate {
    var image: CIImage?
    var pendingTicket = -1
    var drawnTicket = -2
    var onPresented: ((Int) -> Void)?
    var onFirstPixels: ((CGImage) -> Void)?
    private var capturedFirst = false
    private let queue: MTLCommandQueue?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        queue = device?.makeCommandQueue()
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("EditorCanvas is created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if drawableSize.width > 1, image != nil, drawnTicket != pendingTicket {
            setNeedsDisplay()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.width > 1, image != nil, drawnTicket != pendingTicket {
            setNeedsDisplay()
        }
    }

    func draw(in view: MTKView) {
        guard drawableSize.width > 1, drawableSize.height > 1,
              let image, let drawable = currentDrawable,
              let commandBuffer = queue?.makeCommandBuffer() else { return }
        let ticket = pendingTicket
        let pixelSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let fitted = Self.aspectFit(image, in: pixelSize)
        do {
            try StillPipeline.render(fitted, to: drawable.texture, commandBuffer: commandBuffer)
        } catch is StillPipeline.ContextBusy {
            DispatchQueue.main.async { self.setNeedsDisplay() }
            return
        } catch {
            DispatchQueue.main.async { self.onPresented?(ticket) }
            return
        }
        if capturedFirst == false, onFirstPixels != nil {
            capturedFirst = true
            let copied = Self.keepFirstFrame(texture: drawable.texture, commandBuffer: commandBuffer) { image in
                self.onFirstPixels?(image)
            }
            if copied == false, let fallback = StillPipeline.displayImage(image) {
                let deliver = onFirstPixels
                DispatchQueue.main.async { deliver?(fallback) }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in
            DispatchQueue.main.async {
                self.drawnTicket = ticket
                self.onPresented?(ticket)
            }
        }
        commandBuffer.commit()
    }

    /// Center the photo in the drawable. `CIRenderDestination.isFlipped` matches Metal's origin.
    private static func aspectFit(_ image: CIImage, in pixelSize: CGSize) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1, pixelSize.width > 1, pixelSize.height > 1 else { return image }
        let scale = min(pixelSize.width / extent.width, pixelSize.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let dx = (pixelSize.width - scaledExtent.width) / 2 - scaledExtent.origin.x
        let dy = (pixelSize.height - scaledExtent.height) / 2 - scaledExtent.origin.y
        let placed = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let canvas = CGRect(origin: .zero, size: pixelSize)
        let black = CIImage(color: CIColor.black).cropped(to: canvas)
        return placed.composited(over: black)
    }

    /// Copy the drawable after the preview encode. This is the frame that was presented, not the source bitmap.
    @discardableResult
    private static func keepFirstFrame(
        texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        deliver: @escaping (CGImage) -> Void
    ) -> Bool {
        let width = texture.width
        let height = texture.height
        guard width > 1, height > 1 else { return false }
        let alignment = 256
        let rowBytes = ((width * 4 + alignment - 1) / alignment) * alignment
        guard let buffer = texture.device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * height
        )
        blit.endEncoding()
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        commandBuffer.addCompletedHandler { _ in
            let data = Data(bytes: buffer.contents(), count: rowBytes * height)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: rowBytes,
                    space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                  ) else { return }
            DispatchQueue.main.async {
                deliver(image)
            }
        }
        return true
    }
}
