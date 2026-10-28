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

/// Dims everything outside the chosen crop. The 3:4 frame itself does not move.
private struct CropWindow: View {
    var crop: CGRect

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            guard crop.width > 1, crop.height > 1 else { return }
            let fillsFrame = abs(crop.width - bounds.width) < 1 && abs(crop.height - bounds.height) < 1
            guard fillsFrame == false else { return }
            var dim = Path()
            dim.addRect(bounds)
            dim.addRect(crop)
            context.fill(dim, with: .color(Color.black.opacity(0.55)), style: FillStyle(eoFill: true))
            context.stroke(Path(crop), with: .color(CameraColor.textPrimary.opacity(0.9)), lineWidth: 1)
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
    @State private var viewfinderSize = CGSize(width: 402, height: 536)

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
                        .modifier(UnderIsland())
                case .denied:
                    CameraGateView(denied: true, onPrimary: openSettings)
                        .modifier(UnderIsland())
                case .authorized:
                    finder
                }
            }
        }
        .modifier(HiddenSystemChrome())
        .onAppear {
            #if DEBUG
            if let aspect = PHIUITest.aspect {
                capture.setPhotoAspect(aspect)
            }
            if PHIUITest.showGrid {
                showGrid = true
            }
            if PHIUITest.showEVRuler {
                openRuler = .ev
            }
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
            let width: CGFloat = geo.size.width
            let height: CGFloat = geo.size.height
            let island: CGFloat = geo.safeAreaInsets.top > 1 ? geo.safeAreaInsets.top : ScreenEdge.windowTop
            let home: CGFloat = max(geo.safeAreaInsets.bottom > 1 ? geo.safeAreaInsets.bottom : ScreenEdge.windowBottom, 21)
            let iconTop: CGFloat = island / 2 - 22
            let pillTop: CGFloat = island + 8
            let photoTop: CGFloat = pillTop + 38
            // Lens 40, gap 6, exposure 44, gap 3, shutter 80, gap 3, readout 22.
            let cluster: CGFloat = 198
            let clusterTop: CGFloat = height - home - cluster
            let photoHeight: CGFloat = width / PhotoAspect.finderWidthOverHeight
            let flashCenterX: CGFloat = 40
            let gridCenterX: CGFloat = width - 40
            let pillCenterY: CGFloat = pillTop + 16
            let menuCenterX: CGFloat = 103
            let menuCenterY: CGFloat = iconTop + 139
            ZStack(alignment: .topLeading) {
                viewfinder
                    .frame(width: width, height: photoHeight)
                    .onAppear { viewfinderSize = CGSize(width: width, height: photoHeight) }
                    .onChange(of: photoHeight) { _, _ in
                        viewfinderSize = CGSize(width: width, height: photoHeight)
                    }
                    .overlay(alignment: .bottom) {
                        if let openRuler {
                            activeRuler(openRuler)
                                .padding(.horizontal, 24)
                                .frame(height: 62)
                                .allowsHitTesting(true)
                        }
                    }
                    .position(x: width / 2, y: photoTop + photoHeight / 2)

                flashButton
                    .position(x: flashCenterX, y: iconTop + 22)
                gridButton
                    .position(x: gridCenterX, y: iconTop + 22)
                modePill
                    .position(x: width / 2, y: pillCenterY)

                VStack(spacing: 0) {
                    lensBar
                        .frame(height: 40)
                    Color.clear.frame(height: 6)
                    exposureRow
                        .frame(height: 44)
                    Color.clear.frame(height: 3)
                    controlRow
                        .frame(height: 80)
                        .padding(.horizontal, 28)
                    Color.clear.frame(height: 3)
                    captionRow
                        .frame(height: 22)
                }
                .frame(width: width)
                .position(x: width / 2, y: clusterTop + cluster / 2)

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
                    .position(x: menuCenterX, y: menuCenterY)
                    .zIndex(8)
                }
            }
            .frame(width: width, height: height)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
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

    private var flashButton: some View {
        PhiGlyphButton(glyph: flashGlyph, label: flashLabel) {
            flashMenu.toggle()
        }
    }

    private var gridButton: some View {
        PhiGlyphButton(glyph: showGrid ? .gridOn : .gridOff, label: showGrid ? "隐藏九宫格" : "显示九宫格") {
            showGrid.toggle()
        }
    }

    private var flashGlyph: PhiGlyph {
        switch camera.flashMode {
        case .on: .flashOn
        case .auto: .flashAuto
        default: .flashOff
        }
    }

    private var viewfinder: some View {
        PhotoCanvas(widthOverHeight: PhotoAspect.finderWidthOverHeight) {
            stage
        }
    }

    private var livePreview: some View {
        let onTap: (CGPoint, CGPoint) -> Void = { viewPoint, _ in
            openRuler = nil
            flashMenu = false
            let size = viewfinderSize
            let crop = activeAspect.cropWindow(in: size)
            let limit = crop.insetBy(dx: 38, dy: 38)
            let clamped = CGPoint(
                x: min(max(viewPoint.x, limit.minX), max(limit.minX, limit.maxX)),
                y: min(max(viewPoint.y, limit.minY), max(limit.minY, limit.maxY))
            )
            focusPoint = clamped
            let device = CGPoint(
                x: size.width > 1 ? clamped.x / size.width : 0.5,
                y: size.height > 1 ? clamped.y / size.height : 0.5
            )
            camera.focus(at: device)
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
        .overlay { cropOverlay }
        .overlay { stageStatus }
        .overlay { flashOverlay }
        .overlay { focusOverlay }
        .onChange(of: camera.statusMessage, onStatus)
        .onChange(of: capture.shutterTick, onShutter)
        .onChange(of: capture.photoAspect) { _, _ in
            focusPoint = nil
        }
    }

    private var activeAspect: PhotoAspect {
        #if DEBUG
        if let aspect = PHIUITest.aspect { return aspect }
        #endif
        return capture.photoAspect
    }

    private var cropOverlay: some View {
        GeometryReader { proxy in
            let crop = activeAspect.cropWindow(in: proxy.size)
            CropWindow(crop: crop)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
            if showGrid {
                CompositionGrid()
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }

    private var flashOverlay: some View {
        Color.white
            .opacity(flashOpacity)
            .allowsHitTesting(false)
    }

    private var focusOverlay: some View {
        GeometryReader { proxy in
            let crop = activeAspect.cropWindow(in: proxy.size)
            let limit = crop.insetBy(dx: 38, dy: 38)
            let center = CGPoint(x: crop.midX, y: crop.midY)
            let raw = focusPoint ?? center
            let point = CGPoint(
                x: min(max(raw.x, limit.minX), limit.maxX),
                y: min(max(raw.y, limit.minY), limit.maxY)
            )
            if camera.isConfigured || uiTestCapture {
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
        }
        .buttonStyle(PillPlateStyle(fill: CameraColor.scrim, width: 150, height: 32))
        .accessibilityLabel("拍摄设置 \(finderLabel)")
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
                        .font(CameraFont.fixed(13, weight: .medium))
                        .foregroundStyle(selected ? CameraColor.accent : CameraColor.textPrimary)
                }
                .buttonStyle(PillPlateStyle(
                    fill: selected ? CameraColor.surface : CameraColor.background,
                    width: 48,
                    height: 32
                ))
                .accessibilityLabel("\(stop.millimeters) 毫米")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 240, height: 40)
        .background {
            Capsule().fill(CameraColor.scrim)
        }
        .overlay {
            Capsule().strokeBorder(CameraColor.border, lineWidth: 1)
        }
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
            SelectPill(title: camera.autoExposure ? "A 自动" : "M 手动", selected: true, width: 88, height: 36, plate: CameraColor.surface) {
                _ = camera.setAutoExposure(camera.autoExposure == false)
                openRuler = nil
            }
            Spacer(minLength: 8)
            if camera.autoExposure {
                SelectPill(title: "\(ExposureFormat.signedDecimal(camera.exposureEV)) EV", selected: openRuler == .ev, width: 94, height: 36, plate: CameraColor.surface) {
                    toggleRuler(.ev)
                }
            } else {
                SelectPill(title: "ISO \(isoBadge)", selected: openRuler == .iso, width: 108, height: 36, plate: CameraColor.surface) {
                    toggleRuler(.iso)
                }
                SelectPill(title: shutterBadge, selected: openRuler == .shutter, width: 108, height: 36, plate: CameraColor.surface) {
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
