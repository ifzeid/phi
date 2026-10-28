import SwiftUI
import UIKit

/// Rule-of-thirds lines. Stroke stays thin so it reads on both bright and dark frames.
private struct CompositionGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let thirdX = size.width / 3
            let thirdY = size.height / 3
            path.move(to: CGPoint(x: thirdX, y: 0))
            path.addLine(to: CGPoint(x: thirdX, y: size.height))
            path.move(to: CGPoint(x: thirdX * 2, y: 0))
            path.addLine(to: CGPoint(x: thirdX * 2, y: size.height))
            path.move(to: CGPoint(x: 0, y: thirdY))
            path.addLine(to: CGPoint(x: size.width, y: thirdY))
            path.move(to: CGPoint(x: 0, y: thirdY * 2))
            path.addLine(to: CGPoint(x: size.width, y: thirdY * 2))
            context.stroke(
                path,
                with: .color(CameraColor.textPrimary.opacity(0.42)),
                style: StrokeStyle(lineWidth: 0.6, lineCap: .round)
            )
        }
    }
}

struct QuietFinderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var capture = CaptureService()
    @AppStorage("phi.showGrid") private var showGrid = false
    @State private var showSettings = false
    @State private var showAlbum = false
    @State private var pendingDevelop: PendingDevelop?
    @State private var dragBaseEV: Double = 0
    @State private var rulerOpacity: Double = 0
    @State private var focusPoint: CGPoint?
    @State private var flashOpacity: Double = 0

    private var camera: CameraSession { capture.camera }

    var body: some View {
        ZStack {
            CameraColor.background.ignoresSafeArea()
            switch camera.gate {
            case .unknown:
                CameraColor.background
            case .needsPermission:
                CameraGateView(denied: false) { camera.requestAccess() }
            case .denied:
                CameraGateView(denied: true, onPrimary: openSettings)
            case .authorized:
                finder
            }
        }
        .onAppear { camera.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            guard camera.gate == .authorized else { return }
            if phase == .active {
                camera.start()
            } else {
                camera.stop()
            }
        }
        .fullScreenCover(isPresented: $showAlbum, onDismiss: {
            guard let pending = pendingDevelop else { return }
            pendingDevelop = nil
            capture.openDevelop(image: pending.image, originalWasRaw: pending.raw)
        }) {
            AlbumBrowser(
                onClose: { showAlbum = false },
                onProcess: { image, raw in
                    pendingDevelop = PendingDevelop(image: image, raw: raw)
                    showAlbum = false
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            FinderSettingsSheet(
                format: capture.captureFormat,
                onFormat: { capture.setCaptureFormat($0) },
                aspect: capture.photoAspect,
                onAspect: { capture.setPhotoAspect($0) },
                iso: camera.manualISOValue,
                isoChoices: camera.isoChoices,
                shutter: camera.manualShutterSeconds,
                shutterChoices: camera.shutterChoices,
                manualSupported: camera.manualExposureSupported,
                onISO: { camera.setManualISO($0) },
                onShutter: { camera.setManualShutter($0) },
                onClose: { showSettings = false }
            )
        }
        .fullScreenCover(item: $capture.processSession, onDismiss: { capture.dismissProcess() }) { session in
            ProcessStillView(
                session: session,
                canRetryOriginal: capture.canRetryPhotoSave,
                onExport: {
                    Task { await capture.exportDeveloped(session) }
                    return
                },
                onRetryOriginal: { capture.retryPhotoSave() },
                onClose: { capture.dismissProcess() }
            )
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: capture.shutterTick)
    }

    private var finder: some View {
        let caption: CGFloat = 44
        let controls: CGFloat = 80
        let bottomPad: CGFloat = 8
        return VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 8)
                .padding(.top, 4)
            viewfinder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            metaRow
                .frame(height: 44)
                .padding(.horizontal, 16)
            controlRow
                .frame(height: controls)
                .padding(.horizontal, 24)
            captionRow
                .frame(height: caption)
        }
        .padding(.bottom, bottomPad)
    }

    private var topBar: some View {
        ZStack {
            Text(camera.formatLabel)
                .font(CameraFont.parameter(13, medium: true))
                .foregroundStyle(camera.formatLabel == "—" ? CameraColor.textSecondary : CameraColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel("拍摄格式 \(camera.formatLabel)")
            HStack {
                IconHitButton(
                    symbol: .flash,
                    active: camera.flashMode != .off,
                    badge: camera.flashMode == .auto ? "A" : nil,
                    label: flashLabel,
                    action: { camera.cycleFlash() }
                )
                Spacer()
                IconHitButton(
                    symbol: .grid,
                    active: showGrid,
                    label: showGrid ? "隐藏九宫格" : "显示九宫格",
                    action: { showGrid.toggle() }
                )
            }
        }
        .frame(height: 44)
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            let fitted = fittedSize(in: geo.size)
            ZStack {
                CameraColor.background
                stage
                    .frame(width: fitted.width, height: fitted.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var stage: some View {
        ZStack {
            CameraColor.surface
            if camera.isConfigured {
                CameraPreview(
                    session: camera.session,
                    device: camera.videoDevice,
                    anchor: camera.previewAnchor
                ) { viewPoint, devicePoint in
                    focusPoint = viewPoint
                    camera.focus(at: devicePoint)
                } onDrag: { event in
                    handleDrag(event)
                }
            } else {
                VStack(spacing: 18) {
                    Text(camera.statusMessage ?? "正在打开相机\nOpening the camera")
                        .font(CameraFont.interface(15, weight: .medium))
                        .foregroundStyle(CameraColor.textSecondary)
                        .multilineTextAlignment(.center)
                    if capture.hasDevelopBase == false, camera.statusMessage != nil {
                        Button("处理样张") { capture.openSample() }
                            .buttonStyle(QuietButtonStyle())
                            .padding(.horizontal, 28)
                    }
                }
                .padding(24)
            }
        }
        .clipped()
        .overlay {
            if showGrid {
                CompositionGrid()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if camera.isConfigured, let message = camera.statusMessage ?? (camera.isRunning ? nil : "正在打开相机") {
                Text(message)
                    .font(CameraFont.interface(13, weight: .medium))
                    .foregroundStyle(CameraColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            Color.white
                .opacity(flashOpacity)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Text(counterText)
                .font(CameraFont.parameter(12, medium: true))
                .foregroundStyle(CameraColor.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(12)
                .accessibilityLabel("已拍摄 \(capture.captureCount) 张")
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if camera.focalStops.isEmpty == false {
                FocalLengthPicker(stops: camera.focalStops, selectedID: camera.selectedStopID) { stop in
                    camera.select(stop: stop)
                }
                .padding(.bottom, 14)
            }
        }
        .overlay(alignment: .trailing) {
            ExposureDragScale(value: camera.exposureEV, range: camera.exposureRange)
                .padding(.trailing, 10)
                .padding(.bottom, 56)
                .opacity(rulerOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(rulerOpacity < 0.2)
        }
        .overlay {
            GeometryReader { proxy in
                let point = focusPoint ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                if camera.isConfigured {
                    FocusReticle()
                        .position(point)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.18), value: point.x)
                        .animation(.easeOut(duration: 0.18), value: point.y)
                }
            }
        }
        .onChange(of: capture.shutterTick) { _, _ in
            flashOpacity = 0.85
            withAnimation(.easeOut(duration: 0.28)) {
                flashOpacity = 0
            }
        }
    }

    private var metaRow: some View {
        HStack {
            Spacer()
            Text("\(ExposureFormat.signedDecimal(camera.exposureEV)) EV")
                .font(CameraFont.parameter(13, medium: true))
                .foregroundStyle(CameraColor.accent)
        }
        .accessibilityLabel("曝光 \(ExposureFormat.signedDecimal(camera.exposureEV)) EV")
    }

    private var controlRow: some View {
        ZStack {
            HStack {
                Button {
                    if capture.thumbnail == nil && capture.hasDevelopBase == false {
                        capture.openSample()
                    } else {
                        showAlbum = true
                    }
                } label: {
                    thumbnail
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(capture.thumbnail == nil && capture.hasDevelopBase == false ? "打开样张" : "打开相册")
                Spacer()
                IconHitButton(
                    symbol: .controls,
                    label: "拍摄设置",
                    action: { showSettings = true }
                )
            }
            ShutterButton(isReady: camera.isRunning, isCapturing: capture.isCapturing) {
                capture.capture()
            }
        }
    }

    private var thumbnail: some View {
        Group {
            if let image = capture.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(CameraColor.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(CameraColor.border, lineWidth: 1)
                    }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var captionRow: some View {
        HStack {
            Text(camera.isoText)
                .frame(width: 88, alignment: .leading)
            Spacer()
            Text(camera.shutterText)
            Spacer()
            Text(camera.whiteBalanceText)
                .frame(width: 88, alignment: .trailing)
        }
        .font(CameraFont.parameter(12))
        .foregroundStyle(CameraColor.textSecondary)
        .padding(.horizontal, 8)
    }

    private func handleDrag(_ event: PreviewDrag) {
        switch event {
        case .began:
            dragBaseEV = camera.exposureEV
            withAnimation(.easeOut(duration: 0.12)) {
                rulerOpacity = 1
            }
        case .changed(let translationY):
            let steps = Int((-translationY / 22).rounded())
            camera.setExposureEV(dragBaseEV + Double(steps) * 0.1)
        case .ended:
            camera.commitExposureEV()
            withAnimation(.easeOut(duration: 0.7).delay(0.12)) {
                rulerOpacity = 0
            }
        }
    }

    private var counterText: String {
        capture.captureCount > 999 ? "\(capture.captureCount)" : String(format: "%03d", capture.captureCount)
    }

    private var flashLabel: String {
        switch camera.flashMode {
        case .on: "闪光灯打开"
        case .auto: "闪光灯自动"
        default: "闪光灯关闭"
        }
    }

    private func fittedSize(in bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let ratio = capture.photoAspect.widthOverHeight
        guard ratio > 0 else { return bounds }
        let heightFromWidth = bounds.width / ratio
        if heightFromWidth <= bounds.height {
            return CGSize(width: bounds.width, height: heightFromWidth)
        }
        return CGSize(width: bounds.height * ratio, height: bounds.height)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct PendingDevelop {
    var image: UIImage
    var raw: Bool
}

/// Vertical exposure scale. Drawn only while a viewfinder drag is in progress.
private struct ExposureDragScale: View {
    var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(ExposureFormat.signedDecimal(value))
                .font(CameraFont.parameter(13, medium: true))
                .foregroundStyle(CameraColor.accent)
                .frame(width: 44, alignment: .trailing)
            Canvas { context, size in
                let span = range.upperBound - range.lowerBound
                let inset: CGFloat = 8
                let usable = max(size.height - inset * 2, 1)
                func yPosition(_ sample: Double) -> CGFloat {
                    guard span > 0 else { return size.height / 2 }
                    let fraction = (range.upperBound - sample) / span
                    return inset + CGFloat(fraction) * usable
                }
                var spine = Path()
                spine.move(to: CGPoint(x: 18, y: inset))
                spine.addLine(to: CGPoint(x: 18, y: size.height - inset))
                context.stroke(spine, with: .color(CameraColor.textPrimary.opacity(0.45)), lineWidth: 1)

                let steps = max(Int((span / 0.5).rounded()), 1)
                for index in 0...steps {
                    let sample = range.lowerBound + (span * Double(index) / Double(steps))
                    let y = yPosition(sample)
                    let major = abs(sample.rounded() - sample) < 0.05
                    var tick = Path()
                    let length: CGFloat = major ? 10 : 5
                    tick.move(to: CGPoint(x: 18, y: y))
                    tick.addLine(to: CGPoint(x: 18 - length, y: y))
                    context.stroke(
                        tick,
                        with: .color(major ? CameraColor.textPrimary.opacity(0.8) : CameraColor.border),
                        lineWidth: 1
                    )
                }

                let needleY = yPosition(value)
                var needle = Path()
                needle.addEllipse(in: CGRect(x: 14, y: needleY - 4, width: 8, height: 8))
                context.fill(needle, with: .color(CameraColor.accent))
            }
            .frame(width: 28, height: 168)
        }
        .shadow(color: .black.opacity(0.55), radius: 2, y: 0)
        .accessibilityLabel("曝光补偿")
        .accessibilityValue("\(ExposureFormat.signedDecimal(value)) EV")
    }
}
