import SwiftUI
import UIKit

struct QuietFinderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var capture = CaptureService()
    @State private var showExposure = false
    @State private var showLastStill = false
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
        .sheet(isPresented: $showLastStill) {
            LastStillView(
                image: capture.thumbnail,
                note: capture.lastSavedNote,
                canRetry: capture.canRetryPhotoSave,
                onRetry: { capture.retryPhotoSave() },
                onClose: { showLastStill = false }
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
                .frame(height: 36)
                .opacity(showExposure ? 0 : 1)
                .padding(.horizontal, 20)
            controlRow
                .frame(height: controls)
                .padding(.horizontal, 24)
            captionRow
                .frame(height: caption)
        }
        .padding(.bottom, bottomPad)
        .overlay(alignment: .bottom) {
            if showExposure {
                ExposureSheet(
                    ev: camera.exposureEV,
                    range: camera.exposureRange,
                    autoExposure: camera.autoExposure,
                    onEV: { camera.setExposureEV($0) },
                    onCommit: { camera.commitExposureEV() },
                        onAuto: { enabled in
                            _ = camera.setAutoExposure(enabled)
                        },
                    onClose: { setExposure(false) }
                )
                .padding(.bottom, caption + controls + bottomPad + 8)
                .transition(.opacity)
            }
        }
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
                    symbol: .focus,
                    active: camera.focusLocked,
                    label: camera.focusLocked ? "对焦已锁定" : "连续对焦",
                    action: { camera.setFocusLocked(!camera.focusLocked) }
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
            if camera.isConfigured && camera.isRunning {
                CameraPreview(session: camera.session, device: camera.videoDevice) { viewPoint, devicePoint in
                    focusPoint = viewPoint
                    focusToken += 1
                    camera.focus(at: devicePoint)
                }
            } else {
                Text(camera.statusMessage ?? "正在打开相机\nOpening the camera")
                    .font(CameraFont.interface(15, weight: .medium))
                    .foregroundStyle(CameraColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .clipped()
        .overlay {
            if camera.isConfigured && camera.isRunning, let message = camera.statusMessage {
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
            if !showExposure, camera.focalStops.isEmpty == false {
                FocalLengthPicker(stops: camera.focalStops, selectedID: camera.selectedStopID) { stop in
                    camera.select(stop: stop)
                }
                .padding(.bottom, 16)
            }
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
        HStack {
            Text("NATURAL")
                .font(CameraFont.interface(11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(CameraColor.textSecondary)
                .accessibilityLabel("自然色彩，未套用胶片或 LUT")
            Spacer()
            Text("\(ExposureFormat.signedDecimal(camera.exposureEV)) EV")
                .font(CameraFont.parameter(13, medium: true))
                .foregroundStyle(CameraColor.accent)
        }
    }

    private var controlRow: some View {
        ZStack {
            HStack {
                Button {
                    showLastStill = true
                } label: {
                    thumbnail
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(capture.thumbnail == nil ? "还没有照片" : "最近一张照片")
                Spacer()
                IconHitButton(
                    symbol: .controls,
                    active: showExposure,
                    label: showExposure ? "关闭曝光" : "曝光",
                    action: { setExposure(!showExposure) }
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
        Group {
            if showExposure {
                ZStack {
                    HStack {
                        Text(camera.isoText)
                            .frame(width: 88, alignment: .leading)
                        Spacer()
                        Text(camera.whiteBalanceText)
                            .frame(width: 88, alignment: .trailing)
                    }
                    Text(camera.shutterText)
                }
                .font(CameraFont.parameter(12))
                .foregroundStyle(CameraColor.textSecondary)
            } else {
                HStack(spacing: 18) {
                    modeButton("PHOTO", selected: camera.autoExposure) {
                        _ = camera.setAutoExposure(true)
                    }
                    modeButton("MANUAL", selected: !camera.autoExposure) {
                        if camera.setAutoExposure(false) {
                            setExposure(true)
                        }
                    }
                }
            }
        }
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title)
                    .font(CameraFont.interface(11, weight: selected ? .semibold : .regular))
                    .tracking(1.1)
                    .foregroundStyle(selected ? CameraColor.accent : CameraColor.textSecondary)
                Rectangle()
                    .fill(selected ? CameraColor.accent : Color.clear)
                    .frame(width: 16, height: 1.5)
            }
            .frame(minWidth: 72, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    private func setExposure(_ open: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            showExposure = open
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
