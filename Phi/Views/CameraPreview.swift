import AVFoundation
import SwiftUI
import UIKit

enum PreviewDrag {
    case began
    case changed(CGFloat)
    case ended
}

struct CameraPreview: UIViewRepresentable {
    var session: AVCaptureSession
    var device: AVCaptureDevice?
    var onTap: (CGPoint, CGPoint) -> Void
    var onDrag: (PreviewDrag) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.device = device
        view.onTap = onTap
        view.onDrag = onDrag
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
        if view.device !== device {
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

    var device: AVCaptureDevice? {
        didSet {
            guard device !== oldValue else { return }
            installCoordinator()
        }
    }

    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

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
        guard let coordinator else { return }
        apply(coordinator.videoRotationAngleForHorizonLevelPreview)
    }

    private func installCoordinator() {
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            self?.apply(coordinator.videoRotationAngleForHorizonLevelPreview)
        }
    }

    private func apply(_ angle: CGFloat) {
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
