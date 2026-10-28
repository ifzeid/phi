import AVFoundation
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

    func attach(_ view: PreviewView) {
        self.view = view
    }

    func suspend() {
        view?.detachCoordinator()
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

    static func == (lhs: StableCameraPreview, rhs: StableCameraPreview) -> Bool {
        lhs.device?.uniqueID == rhs.device?.uniqueID && lhs.session === rhs.session && lhs.epoch == rhs.epoch
    }

    var body: some View {
        CameraPreview(session: session, device: device, anchor: anchor, onTap: onTap, onDrag: onDrag)
    }
}

struct CameraPreview: UIViewRepresentable {
    var session: AVCaptureSession
    var device: AVCaptureDevice?
    var anchor: PreviewAnchor
    var onTap: (CGPoint, CGPoint) -> Void
    var onDrag: (PreviewDrag) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        anchor.attach(view)
        view.device = device
        view.onTap = onTap
        view.onDrag = onDrag
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
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onDrag: ((PreviewDrag) -> Void)?

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

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewView is created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        previewLayer.videoGravity = .resizeAspectFill
        guard let coordinator else { return }
        apply(coordinator.videoRotationAngleForHorizonLevelPreview)
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
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
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
