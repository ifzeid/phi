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
    @State private var statusTicket = 0
    @State private var openRuler: CaptureRuler?
    @State private var flashMenu = false

    private var camera: CameraSession { capture.camera }

    var body: some View {
        ZStack {
            CameraColor.background.ignoresSafeArea()
            if showsFinder {
                finder
            } else {
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
        }
        .modifier(HiddenSystemChrome())
        .modifier(UnderIsland())
        .onAppear {
            #if DEBUG
            if PHIUITest.screen == .flash {
                flashMenu = true
            }
            if PHIUITest.screen == .capture || PHIUITest.screen == .flash {
                return
            }
            #endif
            camera.refreshAuthorization()
        }
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
            DispatchQueue.main.async {
                switch pending {
                case .library(let localIdentifier):
                    capture.openLibraryShot(localIdentifier: localIdentifier)
                case .local(let id):
                    capture.openLocalShot(id: id)
                }
            }
        }) {
            AlbumBrowser(
                revision: capture.albumRevision,
                onClose: { showAlbum = false },
                onEditLibrary: { asset in
                    pendingDevelop = .library(asset.localIdentifier)
                    showAlbum = false
                },
                onEditLocal: { id in
                    pendingDevelop = .local(id)
                    showAlbum = false
                },
                onRetryLocal: { capture.retryLocalShot(id: $0) }
            )
        }
        .sheet(isPresented: $showSettings) {
            FinderSettingsSheet(
                mode: capture.processMode,
                onMode: { capture.setProcessMode($0) },
                saveHEIF: capture.saveHEIF,
                onSaveHEIF: { capture.setSaveHEIF($0) },
                codec: capture.processedCodec,
                onCodec: { capture.setProcessedCodec($0) },
                aspect: capture.photoAspect,
                onAspect: { capture.setPhotoAspect($0) },
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
                onRetryOriginal: { capture.retryFailedSave() },
                onClose: { capture.dismissProcess() }
            )
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: capture.shutterTick)
    }

    private var finder: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                viewfinder
                    .frame(width: geo.size.width)
                parameterSlot
                    .frame(height: 62)
                exposureRow
                    .frame(height: 44)
                controlRow
                    .frame(height: 80)
                    .padding(.horizontal, 28)
                captionRow
                    .frame(height: 28)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .overlay(alignment: .topLeading) {
            if flashMenu {
                FlashChoiceMenu(
                    selection: camera.flashMode,
                    enabled: camera.flashAvailable,
                    reason: camera.flashAvailable ? nil : "这枚镜头或当前格式不能用闪光灯。",
                    onSelect: { mode in
                        camera.setFlash(mode)
                        flashMenu = false
                    }
                )
                .padding(.leading, 18)
                .padding(.top, 48)
                .zIndex(8)
            }
        }
    }

    private var showsFinder: Bool {
        #if DEBUG
        if PHIUITest.screen == .capture || PHIUITest.screen == .flash { return true }
        #endif
        return false
    }

    /// Mode and aspect, plus the millimeters of the camera that is actually running.
    private var finderLabel: String {
        guard camera.activeLensMillimeters > 0, camera.formatLabel != "—" else { return camera.formatLabel }
        return "\(camera.formatLabel) · \(camera.activeLensMillimeters)"
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            PhiGlyphButton(glyph: flashGlyph, label: flashLabel) {
                flashMenu.toggle()
            }
            Spacer(minLength: 4)
            modePill
            Spacer(minLength: 4)
            PhiGlyphButton(glyph: showGrid ? .gridOn : .gridOff, label: showGrid ? "隐藏九宫格" : "显示九宫格") {
                showGrid.toggle()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    private var flashGlyph: PhiGlyph {
        switch camera.flashMode {
        case .on: .flashOn
        case .auto: .flashAuto
        default: .flashOff
        }
    }

    private var viewfinder: some View {
        PhotoCanvas(widthOverHeight: capture.photoAspect.widthOverHeight) {
            stage
        }
    }

    private var livePreview: some View {
        let onTap: (CGPoint, CGPoint) -> Void = { viewPoint, devicePoint in
            openRuler = nil
            flashMenu = false
            focusPoint = viewPoint
            camera.focus(at: devicePoint)
        }
        let onDrag: (PreviewDrag) -> Void = { event in
            handleDrag(event)
        }
        let onLongPress: () -> Void = {
            camera.setFocusLocked(camera.focusLocked == false)
        }
        let preview = StableCameraPreview(
            session: camera.session,
            device: camera.videoDevice,
            epoch: camera.previewEpoch,
            anchor: camera.previewAnchor,
            onTap: onTap,
            onDrag: onDrag,
            onLongPress: onLongPress
        ).equatable()
        return preview
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                #if DEBUG
                if PHIUITest.screen == .capture || PHIUITest.screen == .flash, let sample = PHIUITest.sample {
                    Image(uiImage: sample)
                        .resizable()
                        .scaledToFill()
                }
                #endif
            }
    }

    private var stagePlaceholder: some View {
        VStack(spacing: 18) {
            Text(camera.statusMessage ?? "正在打开相机\nOpening the camera")
                .font(CameraFont.interface(15, weight: .medium))
                .foregroundStyle(CameraColor.textSecondary)
                .multilineTextAlignment(.center)
            if capture.hasDevelopBase == false, camera.statusMessage != nil {
                Button("编辑样张", action: capture.openSample)
                    .buttonStyle(QuietButtonStyle())
                    .padding(.horizontal, 28)
            }
        }
        .padding(24)
    }

    private var stageStatusText: String? {
        if camera.isConfigured == false { return nil }
        return camera.statusMessage ?? (camera.isRunning ? nil : "正在打开相机")
    }

    private var uiTestCapture: Bool {
        #if DEBUG
        return PHIUITest.screen == .capture || PHIUITest.screen == .flash
        #else
        return false
        #endif
    }

    private var stageStatus: some View {
        let dismiss: () -> Void = { camera.statusMessage = nil }
        return Group {
            if uiTestCapture {
                EmptyView()
            } else if let message = stageStatusText {
                Button(action: dismiss) {
                    Text(message)
                        .font(CameraFont.interface(13, weight: .medium))
                        .foregroundStyle(CameraColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityHint("点一下关掉提示")
            }
        }
    }

    private var stage: some View {
        let onStatus: (String?, String?) -> Void = { _, message in
            guard let message else { return }
            scheduleStatusDismiss(message)
        }
        let onShutter: (Int, Int) -> Void = { _, _ in
            flashOpacity = 0.85
            withAnimation(.easeOut(duration: 0.28)) {
                flashOpacity = 0
            }
        }
        return ZStack {
            CameraColor.surface
            #if DEBUG
            if uiTestCapture, let sample = PHIUITest.sample {
                Image(uiImage: sample)
                    .resizable()
                    .scaledToFill()
            } else if camera.isConfigured {
                livePreview
            } else {
                stagePlaceholder
            }
            #else
            if camera.isConfigured {
                livePreview
            } else {
                stagePlaceholder
            }
            #endif
        }
        .clipped()
        .overlay { gridOverlay }
        .overlay { stageStatus }
        .overlay { flashOverlay }
        .overlay { focusOverlay }
        .onChange(of: camera.statusMessage, onStatus)
        .onChange(of: capture.shutterTick, onShutter)
    }

    private var gridOverlay: some View {
        Group {
            if showGrid {
                CompositionGrid()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var flashOverlay: some View {
        Color.white
            .opacity(flashOpacity)
            .allowsHitTesting(false)
    }

    private var focusOverlay: some View {
        GeometryReader { proxy in
            let point = focusPoint ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            if camera.isConfigured {
                FocusBracket(locked: camera.focusLocked)
                    .position(point)
                    .animation(.easeOut(duration: 0.18), value: point.x)
                    .animation(.easeOut(duration: 0.18), value: point.y)
            }
        }
    }

    private var modePill: some View {
        Button {
            showSettings = true
            openRuler = nil
            flashMenu = false
        } label: {
            Text(finderLabel)
                .font(CameraFont.parameter(13))
                .foregroundStyle(CameraColor.textPrimary)
                .lineLimit(1)
                .frame(width: 150, height: 32)
                .background(CameraColor.scrim, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("拍摄设置 \(finderLabel)")
    }

    private var parameterSlot: some View {
        Group {
            if let openRuler {
                activeRuler(openRuler)
                    .padding(.horizontal, 24)
            } else {
                lensBar
            }
        }
    }

    private var shownStops: [FocalStop] {
        #if DEBUG
        if camera.focalStops.isEmpty, PHIUITest.screen != nil {
            return PHIUITest.lensStops
        }
        #endif
        return camera.focalStops
    }

    private var lensBar: some View {
        HStack(spacing: 8) {
            ForEach(shownStops) { stop in
                let selected = stop.id == camera.selectedStopID || (camera.selectedStopID == nil && stop.millimeters == 25)
                Button {
                    guard camera.focalStops.isEmpty == false else { return }
                    camera.select(stop: stop)
                } label: {
                    Text("\(stop.millimeters)")
                        .font(CameraFont.interface(13, weight: .medium))
                        .foregroundStyle(selected ? CameraColor.accent : CameraColor.textPrimary)
                        .frame(width: 48, height: 32)
                        .background(selected ? CameraColor.surface : CameraColor.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(stop.millimeters) 毫米")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 240, height: 40)
        .background(CameraColor.scrim, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private func activeRuler(_ ruler: CaptureRuler) -> some View {
        switch ruler {
        case .ev:
            SharedRuler(
                labels: evLabels,
                index: exposureIndex,
                onChange: { index in
                    let span = camera.exposureRange.upperBound - camera.exposureRange.lowerBound
                    guard exposureCount > 1, span > 0 else { return }
                    let value = camera.exposureRange.lowerBound + (Double(index) / Double(exposureCount - 1)) * span
                    camera.setExposureEV(value)
                },
                onCommit: { camera.commitExposureEV() }
            )
        case .iso:
            SharedRuler(
                labels: camera.isoChoices.map { isoLabel($0) },
                index: isoIndex,
                onChange: { index in
                    guard camera.isoChoices.indices.contains(index) else { return }
                    camera.setManualISO(camera.isoChoices[index])
                },
                onCommit: {}
            )
        case .shutter:
            SharedRuler(
                labels: camera.shutterChoices.map { MeterFormat.shutterFraction($0) },
                index: shutterIndex,
                onChange: { index in
                    guard camera.shutterChoices.indices.contains(index) else { return }
                    camera.setManualShutter(camera.shutterChoices[index])
                },
                onCommit: {}
            )
        }
    }

    private var evLabels: [String] {
        guard exposureCount > 0 else { return ["0"] }
        let span = camera.exposureRange.upperBound - camera.exposureRange.lowerBound
        return (0..<exposureCount).map { index in
            let value = span > 0 && exposureCount > 1
                ? camera.exposureRange.lowerBound + (Double(index) / Double(exposureCount - 1)) * span
                : 0
            return ExposureFormat.signedDecimal(value)
        }
    }

    private var exposureRow: some View {
        HStack(spacing: 8) {
            SelectPill(title: camera.autoExposure ? "A 自动" : "M 手动", selected: true, width: 88) {
                _ = camera.setAutoExposure(camera.autoExposure == false)
                openRuler = nil
            }
            Spacer(minLength: 8)
            if camera.autoExposure {
                SelectPill(title: "\(ExposureFormat.signedDecimal(camera.exposureEV)) EV", selected: openRuler == .ev, width: 94, height: 36) {
                    toggleRuler(.ev)
                }
            } else {
                SelectPill(title: "ISO \(isoBadge)", selected: openRuler == .iso, width: 108) {
                    toggleRuler(.iso)
                }
                SelectPill(title: shutterBadge, selected: openRuler == .shutter, width: 108) {
                    toggleRuler(.shutter)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func toggleRuler(_ ruler: CaptureRuler) {
        flashMenu = false
        openRuler = openRuler == ruler ? nil : ruler
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
                PhiGlyphButton(glyph: .settings, label: "拍摄设置") {
                    showSettings = true
                }
            }
            WhiteShutterButton(isReady: camera.isRunning, isCapturing: capture.isCapturing) {
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
            Spacer()
            Text(camera.shutterText)
            Spacer()
            Text(camera.whiteBalanceText)
        }
        .font(CameraFont.parameter(11))
        .foregroundStyle(CameraColor.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, 24)
    }

    private var exposureCount: Int {
        let span = camera.exposureRange.upperBound - camera.exposureRange.lowerBound
        return max(Int((span / 0.1).rounded()) + 1, 1)
    }

    private var exposureIndex: Int {
        let span = camera.exposureRange.upperBound - camera.exposureRange.lowerBound
        guard span > 0 else { return 0 }
        let fraction = (camera.exposureEV - camera.exposureRange.lowerBound) / span
        return min(max(Int((fraction * Double(exposureCount - 1)).rounded()), 0), exposureCount - 1)
    }

    private var isoIndex: Int {
        ExposureStops.nearestIndex(to: camera.manualISOValue, in: camera.isoChoices)
    }

    private var shutterIndex: Int {
        ExposureStops.nearestIndex(to: camera.manualShutterSeconds, in: camera.shutterChoices)
    }

    private var isoBadge: String {
        guard camera.manualISOValue > 0 else { return "—" }
        return isoLabel(camera.manualISOValue)
    }

    private var shutterBadge: String {
        MeterFormat.shutterFraction(camera.manualShutterSeconds)
    }

    private func isoLabel(_ value: Float) -> String {
        if value >= 100 { return "\(Int(value.rounded()))" }
        return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func scheduleStatusDismiss(_ message: String) {
        guard camera.isConfigured else { return }
        if message.contains("正在打开") || message.contains("Opening") { return }
        statusTicket += 1
        let ticket = statusTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard statusTicket == ticket, camera.statusMessage == message else { return }
            camera.statusMessage = nil
        }
    }

    private func handleDrag(_ event: PreviewDrag) {
        guard camera.autoExposure else { return }
        switch event {
        case .began:
            dragBaseEV = camera.exposureEV
            openRuler = .ev
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

    private var flashLabel: String {
        switch camera.flashMode {
        case .on: "闪光灯打开"
        case .auto: "闪光灯自动"
        default: "闪光灯关闭"
        }
    }

    private func fittedSize(in bounds: CGSize, ratio: CGFloat) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
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

private enum CaptureRuler: Equatable {
    case ev
    case iso
    case shutter
}

private enum PendingDevelop {
    case library(String)
    case local(String)
}
