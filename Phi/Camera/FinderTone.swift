import AVFoundation
import CoreImage
import Metal
import MetalKit
import UIKit

/// Mode 0 viewfinder. The system preview is Apple's bright video; this redraws the same frames
/// with `RawDevelop.toneMapValue` (toe, linear middle, shoulder) so the finder matches the still.
final class FinderTone: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Portrait angle until the preview coordinator publishes the real one.
    static var sharedRotation: CGFloat = 90

    let output = AVCaptureVideoDataOutput()
    var onFrame: ((CIImage) -> Void)?
    var isEnabled = false

    private let queue = DispatchQueue(label: "com.zeid.phi.finder-tone")
    private let lock = NSLock()
    private var busy = false
    private var installed = false
    private var appliedRotation: CGFloat = -1

    func install(on session: AVCaptureSession) {
        guard installed == false else { return }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        installed = true
        alignRotation()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isEnabled, busy == false else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        if busy {
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        alignRotation()
        let source = CIImage(cvPixelBuffer: buffer)
        let toned = Self.toned(source)
        onFrame?(toned)
        lock.lock()
        busy = false
        lock.unlock()
    }

    private func alignRotation() {
        let angle = Self.sharedRotation
        guard abs(angle - appliedRotation) > 0.5, let connection = output.connection(with: .video) else { return }
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        appliedRotation = angle
    }

    /// Display-referred preview frames arrive in the linear working space, then this matches the still curve.
    private static func toned(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        let longest = max(extent.width, extent.height)
        let scaled: CIImage
        if longest > 960, longest > 0 {
            let factor = 960 / longest
            scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        } else {
            scaled = image
        }
        guard let kernel = toneKernel, let output = kernel.apply(extent: scaled.extent, arguments: [scaled]) else {
            return scaled
        }
        return output
    }

    /// Same toe (0.045), identity through the middle, and shoulder (knee 0.62, softness 0.55) as `toneMapValue`.
    private static let toneKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 phiZeroPreview(__sample s) {
            vec3 x = max(s.rgb, vec3(0.0));
            float toe = 0.045;
            vec3 t = min(x / toe, vec3(1.0));
            vec3 crushed = toe * t * t;
            vec3 toed = mix(crushed, x, step(vec3(toe), x));
            float knee = 0.62;
            float softness = 0.55;
            vec3 span = max(toed - vec3(knee), vec3(0.0));
            vec3 compressed = vec3(knee) + vec3(1.0 - knee) * (span / (span + vec3(softness)));
            vec3 y = mix(toed, min(compressed, vec3(1.0)), step(vec3(knee), toed));
            return vec4(y, 1.0);
        }
        """)
}

/// Covers the system preview in mode 0. Touches pass through to the preview layer.
final class FinderToneView: MTKView, MTKViewDelegate {
    private var image: CIImage?
    private let commandQueue: MTLCommandQueue?
    private var drawing = false

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let metal = device ?? MTLCreateSystemDefaultDevice()
        commandQueue = metal?.makeCommandQueue()
        super.init(frame: frameRect, device: metal)
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        isOpaque = true
        delegate = self
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("FinderToneView is created in code")
    }

    func present(_ image: CIImage) {
        self.image = image
        setNeedsDisplay()
    }

    func clear() {
        image = nil
    }

    func draw(in view: MTKView) {
        guard drawing == false, let image, let drawable = currentDrawable, drawableSize.width > 1,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        drawing = true
        let fitted = Self.aspectFill(image, in: CGSize(width: drawable.texture.width, height: drawable.texture.height))
        do {
            try StillPipeline.render(fitted, to: drawable.texture, commandBuffer: commandBuffer)
        } catch {
            drawing = false
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.drawing = false
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private static func aspectFill(_ image: CIImage, in pixelSize: CGSize) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1, pixelSize.width > 1, pixelSize.height > 1 else { return image }
        let scale = max(pixelSize.width / extent.width, pixelSize.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let dx = (pixelSize.width - scaledExtent.width) / 2 - scaledExtent.origin.x
        let dy = (pixelSize.height - scaledExtent.height) / 2 - scaledExtent.origin.y
        let placed = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let canvas = CGRect(origin: .zero, size: pixelSize)
        let black = CIImage(color: CIColor.black).cropped(to: canvas)
        return placed.cropped(to: canvas).composited(over: black)
    }
}
