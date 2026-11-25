import AVFoundation
import CoreImage
import SwiftUI
import UIKit

enum PreviewDrag {
    case began
    case changed(CGFloat)
    case ended
}

/// Holds the live preview so the session queue can drop its rotation coordinator before a reconfigure.
/// The coordinator has to be created and released on the main thread.
final class PreviewAnchor {
    private weak var view: PreviewView?
    private var zeroOn = false
    /// Fired on the main thread when the preview rotation coordinator publishes a new angle.
    var onRotationChanged: ((CGFloat) -> Void)?

    func attach(_ view: PreviewView) {
        self.view = view
        view.onRotationChanged = { [weak self] angle in
            self?.onRotationChanged?(angle)
        }
        view.setZeroPreview(zeroOn)
    }

    /// Mode 0 covers the system preview with the zero-process tone. The layer underneath still receives taps.
    func setZeroPreview(_ on: Bool) {
        zeroOn = on
        let apply: () -> Void = { self.view?.setZeroPreview(on) }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func presentZero(_ image: CIImage) {
        DispatchQueue.main.async {
            self.view?.presentZero(image)
        }
    }

    func suspend() {
        view?.detachCoordinator()
    }

    /// Selected framing over the device's current framing. 1 except while a crop stop shoots RAW at zoom 1.
    /// Crops by sizing a hosted preview layer inside a clipped view — never `UIView.transform`,
    /// which relayouts the preview during RAW reconfigure and hung the 2× shutter (build 33).
    func setFinderScale(_ scale: CGFloat) {
        let apply = {
            guard let view = self.view else { return }
            view.transform = .identity
            view.setFinderCropScale(scale)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func resume(device: AVCaptureDevice?) {
        let apply = {
            self.view?.resumeCoordinator(device: device)
        }
        if Thread.isMainThread {
            _ = apply()
        } else {
            DispatchQueue.main.async { _ = apply() }
        }
    }
}

/// Skips preview updates when only the meter or exposure label changed.
struct StableCameraPreview: View, Equatable {
    var session: AVCaptureSession
    var device: AVCaptureDevice?
    var epoch: Int
    var anchor: PreviewAnchor
    var onTap: (CGPoint, CGPoint) -> Void
    var onDrag: (PreviewDrag) -> Void
    var onLongPress: () -> Void = {}

    static func == (lhs: StableCameraPreview, rhs: StableCameraPreview) -> Bool {
        lhs.device?.uniqueID == rhs.device?.uniqueID && lhs.session === rhs.session && lhs.epoch == rhs.epoch
    }

    var body: some View {
        CameraPreview(session: session, device: device, anchor: anchor, onTap: onTap, onDrag: onDrag, onLongPress: onLongPress)
    }
}

struct CameraPreview: UIViewRepresentable {
    var session: AVCaptureSession
    var device: AVCaptureDevice?
    var anchor: PreviewAnchor
    var onTap: (CGPoint, CGPoint) -> Void
    var onDrag: (PreviewDrag) -> Void
    var onLongPress: () -> Void = {}

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        anchor.attach(view)
        view.device = device
        view.onTap = onTap
        view.onDrag = onDrag
        view.onLongPress = onLongPress
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        anchor.attach(view)
        view.previewLayer.videoGravity = .resizeAspectFill
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
        // While a lens change is reconfiguring, leave the coordinator detached.
        if view.isCoordinatorPaused == false, view.coordinatorDevice !== device {
            view.device = device
        }
        view.onTap = onTap
        view.onDrag = onDrag
        view.onLongPress = onLongPress
    }
}

private final class SystemPreviewHost: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

final class PreviewView: UIView {
    private let previewHost = SystemPreviewHost()
    var previewLayer: AVCaptureVideoPreviewLayer { previewHost.previewLayer }
    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onDrag: ((PreviewDrag) -> Void)?
    var onLongPress: (() -> Void)?
    var onRotationChanged: ((CGFloat) -> Void)?
    private var finderCropScale: CGFloat = 1
    private var lastPublishedRotation: CGFloat?

    /// Device the preview coordinator was built for. Distinct from a mid-update assignment.
    private(set) var coordinatorDevice: AVCaptureDevice?
    private(set) var isCoordinatorPaused = false

    var device: AVCaptureDevice? {
        didSet {
            guard device !== oldValue else { return }
            installCoordinator()
        }
    }

    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private let zeroCanvas = FinderToneView()
    private var zeroWanted = false

    func detachCoordinator() {
        isCoordinatorPaused = true
        clearCoordinator()
    }

    func resumeCoordinator(device: AVCaptureDevice?) {
        isCoordinatorPaused = false
        previewLayer.videoGravity = .resizeAspectFill
        self.device = device
        installCoordinator()
    }

    private func clearCoordinator() {
        rotationObservation?.invalidate()
        rotationObservation = nil
        coordinator = nil
        coordinatorDevice = nil
    }

    func setZeroPreview(_ on: Bool) {
        guard on != zeroWanted || on == false else { return }
        zeroWanted = on
        // Stay hidden until a real toned frame is on screen; the system preview shows meanwhile.
        zeroCanvas.isHidden = true
        if on {
            zeroCanvas.resetFirstFrame()
            zeroCanvas.onFirstFrame = { [weak self] in
                guard let self, self.zeroWanted else { return }
                self.zeroCanvas.isHidden = false
            }
        } else {
            zeroCanvas.clear()
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    func presentZero(_ image: CIImage) {
        guard zeroWanted else { return }
        zeroCanvas.present(image)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        previewHost.isUserInteractionEnabled = false
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .clear
        zeroCanvas.isHidden = true
        zeroCanvas.isUserInteractionEnabled = false
        addSubview(previewHost)
        addSubview(zeroCanvas)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.4
        addGestureRecognizer(tap)
        addGestureRecognizer(pan)
        addGestureRecognizer(hold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewView is created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPreviewCrop()
        zeroCanvas.frame = bounds
        previewLayer.videoGravity = .resizeAspectFill
        guard let coordinator else { return }
        apply(coordinator.videoRotationAngleForHorizonLevelPreview)
    }

    func setFinderCropScale(_ scale: CGFloat) {
        transform = .identity
        let next = max(scale, 1)
        if abs(next - finderCropScale) < 0.001 { return }
        finderCropScale = next
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func layoutPreviewCrop() {
        // Mode 0 already center-crops inside FinderTone; keep the hosted layer 1:1 then.
        let scale = (zeroWanted || finderCropScale <= 1.01) ? 1 : finderCropScale
        if scale <= 1.01 {
            previewHost.frame = bounds
        } else {
            let width = bounds.width * scale
            let height = bounds.height * scale
            previewHost.frame = CGRect(
                x: bounds.midX - width / 2,
                y: bounds.midY - height / 2,
                width: width,
                height: height
            )
        }
    }

    private func installCoordinator() {
        clearCoordinator()
        guard isCoordinatorPaused == false, let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator
        coordinatorDevice = device
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            DispatchQueue.main.async {
                self?.apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            }
        }
    }

    private func apply(_ angle: CGFloat) {
        previewLayer.videoGravity = .resizeAspectFill
        guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        FinderTone.sharedRotation = angle
        if lastPublishedRotation == nil || abs((lastPublishedRotation ?? 0) - angle) > 0.5 {
            lastPublishedRotation = angle
            onRotationChanged?(angle)
        }
    }

    @objc private func handleHold(_ hold: UILongPressGestureRecognizer) {
        guard hold.state == .began else { return }
        onLongPress?()
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        let layerPoint = previewLayer.convert(point, from: layer)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onTap?(point, devicePoint)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            onDrag?(.began)
        case .changed:
            onDrag?(.changed(pan.translation(in: self).y))
        case .ended, .cancelled, .failed:
            onDrag?(.ended)
        default:
            break
        }
    }
}
