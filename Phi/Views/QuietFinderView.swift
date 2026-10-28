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

private enum DragParameter {
    case ev
    case iso
    case shutter

    var accessibilityName: String {
        switch self {
        case .ev: "曝光补偿"
        case .iso: "ISO"
        case .shutter: "快门"
        }
    }
}

struct QuietFinderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var capture = CaptureService()
    @AppStorage("phi.showGrid") private var showGrid = false
    @State private var dragParameter: DragParameter = .ev
    @State private var dragBaseEV: Double = 0
    @State private var dragBaseISO: Float = 100
    @State private var dragBaseShutter: Double = 1.0 / 125
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
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
                CameraPreview(session: camera.session, device: camera.videoDevice) { viewPoint, devicePoint in
                    focusPoint = viewPoint
                    focusToken += 1
                    camera.focus(at: devicePoint)
                } onDrag: { event in
                    handleDrag(event)
                }
                .id(camera.activeDeviceID)
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
            VStack(spacing: 10) {
                dragTargets
                if camera.focalStops.isEmpty == false {
                    FocalLengthPicker(stops: camera.focalStops, selectedID: camera.selectedStopID) { stop in
                        camera.select(stop: stop)
                    }
                }
            }
            .padding(.bottom, 14)
        }
        .overlay {
            if let focusPoint {
                PhiIcon(symbol: .focus, color: CameraColor.textPrimary)
                    .scaleEffect(2.6)
                    .frame(width: 72, height: 72)
                    .position(focusPoint)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: capture.shutterTick) { _, _ in
            flashOpacity = 0.85
            withAnimation(.easeOut(duration: 0.28)) {
                flashOpacity = 0
            }
        }
        .task(id: focusToken) {
            guard focusToken > 0 else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            focusPoint = nil
        }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                GrainStylePicker(selection: capture.grainStyle) { capture.setGrainStyle($0) }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            Text(activeValueText)
                .font(CameraFont.parameter(13, medium: true))
                .foregroundStyle(CameraColor.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel(activeValueText)
        }
    }

    private var controlRow: some View {
        ZStack {
            HStack {
                Button {
                    capture.openProcess()
                } label: {
                    thumbnail
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(capture.hasDevelopBase ? "最近一张，进入处理" : "打开样张")
                Spacer()
                Color.clear
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
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

    private var dragTargets: some View {
        HStack(spacing: 8) {
            dragChip(.ev, title: "\(ExposureFormat.signedDecimal(camera.exposureEV)) EV")
            dragChip(.iso, title: isoChip)
            dragChip(.shutter, title: shutterChip)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.88), in: Capsule())
    }

    private func dragChip(_ parameter: DragParameter, title: String) -> some View {
        let selected = dragParameter == parameter
        return Button {
            dragParameter = parameter
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(CameraFont.parameter(12, medium: selected))
                    .foregroundStyle(selected ? CameraColor.accent : CameraColor.textPrimary)
                    .lineLimit(1)
                Rectangle()
                    .fill(selected ? CameraColor.accent : Color.clear)
                    .frame(width: 14, height: 1.5)
            }
            .frame(minWidth: 64, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(parameter.accessibilityName)
        .accessibilityHint("在取景画面上上下拖动")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var isoChip: String {
        let value = camera.manualISOValue
        return value >= 100 ? "\(Int(value.rounded()))" : String(format: "%.0f", value)
    }

    private var shutterChip: String {
        MeterFormat.shutter(seconds: camera.manualShutterSeconds).replacingOccurrences(of: " S", with: "")
    }

    private var activeValueText: String {
        switch dragParameter {
        case .ev:
            "\(ExposureFormat.signedDecimal(camera.exposureEV)) EV"
        case .iso:
            "ISO \(isoChip)"
        case .shutter:
            MeterFormat.shutter(seconds: camera.manualShutterSeconds)
        }
    }

    private func handleDrag(_ event: PreviewDrag) {
        switch event {
        case .began:
            dragBaseEV = camera.exposureEV
            dragBaseISO = camera.manualISOValue
            dragBaseShutter = camera.manualShutterSeconds
        case .changed(let translationY):
            let steps = Int((-translationY / 22).rounded())
            switch dragParameter {
            case .ev:
                camera.setExposureEV(dragBaseEV + Double(steps) * 0.1)
            case .iso:
                nudgeISO(steps)
            case .shutter:
                nudgeShutter(steps)
            }
        case .ended:
            if dragParameter == .ev {
                camera.commitExposureEV()
            }
        }
    }

    private func nudgeISO(_ steps: Int) {
        let choices = camera.isoChoices
        guard choices.isEmpty == false else {
            camera.setManualISO(dragBaseISO)
            return
        }
        let start = ExposureStops.nearestIndex(to: dragBaseISO, in: choices)
        let index = min(max(start + steps, 0), choices.count - 1)
        camera.setManualISO(choices[index])
    }

    private func nudgeShutter(_ steps: Int) {
        let choices = camera.shutterChoices
        guard choices.isEmpty == false else {
            camera.setManualShutter(dragBaseShutter)
            return
        }
        let start = ExposureStops.nearestIndex(to: dragBaseShutter, in: choices)
        let index = min(max(start + steps, 0), choices.count - 1)
        camera.setManualShutter(choices[index])
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
        let heightFromWidth = bounds.width * 4 / 3
        if heightFromWidth <= bounds.height {
            return CGSize(width: bounds.width, height: heightFromWidth)
        }
        return CGSize(width: bounds.height * 3 / 4, height: bounds.height)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
