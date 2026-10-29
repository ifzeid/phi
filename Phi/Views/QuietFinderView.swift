import AVFoundation
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

/// Positions measured from Figma 390×844. Wider phones keep the same insets.
private struct CaptureChromeLayout {
    var width: CGFloat
    var height: CGFloat
    var flashCenter: CGPoint
    var settingsCenter: CGPoint
    var gridCenter: CGPoint
    var pillCenter: CGPoint
    var photoFrame: CGRect
    var rulerFrame: CGRect
    var shutterCenter: CGPoint
    var thumbCenter: CGPoint
    var zoomCenter: CGPoint

    static func measure(width: CGFloat, height: CGFloat, island: CGFloat, home: CGFloat) -> CaptureChromeLayout {
        let settingsCenterY = max(CGFloat(22), island * 0.42)
        let flashCenterY = settingsCenterY + 8
        let gridCenterY = settingsCenterY + 44
        let pillTop = island + 8
        let pillCenterY = pillTop + 16
        let photoTop = pillTop + 38
        let photoHeight = width / PhotoAspect.finderWidthOverHeight
        var rulerTop = photoTop + photoHeight + 6
        let rulerHeight: CGFloat = 88
        let rowHeight: CGFloat = 88
        let shutterGap: CGFloat = 9
        var rowTop = rulerTop + rulerHeight + shutterGap
        let limit = height - home - 4
        if rowTop + rowHeight > limit {
            let overflow = rowTop + rowHeight - limit
            rulerTop -= min(overflow, CGFloat(6))
            rowTop -= overflow
        }
        let rowCenterY = rowTop + rowHeight / 2
        let rulerWidth = min(CGFloat(342), width - 48)
        let rulerX = (width - rulerWidth) / 2
        return CaptureChromeLayout(
            width: width,
            height: height,
            flashCenter: CGPoint(x: 40, y: flashCenterY),
            settingsCenter: CGPoint(x: width - 40, y: settingsCenterY),
            gridCenter: CGPoint(x: width - 40, y: gridCenterY),
            pillCenter: CGPoint(x: width / 2, y: pillCenterY),
            photoFrame: CGRect(x: 0, y: photoTop, width: width, height: photoHeight),
            rulerFrame: CGRect(x: rulerX, y: rulerTop, width: rulerWidth, height: rulerHeight),
            shutterCenter: CGPoint(x: width / 2, y: rowCenterY),
            thumbCenter: CGPoint(x: 50, y: rowCenterY),
            zoomCenter: CGPoint(x: width - 72, y: rowCenterY)
        )
    }
}

private enum MeterScale {
    case iso
    case shutter
}

struct QuietFinderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var capture = CaptureService()
    @AppStorage("phi.showGrid") private var showGrid = false
    @State private var showSettings = false
    @State private var showAlbum = false
    @State private var pendingDevelop: PendingDevelop?
    @State private var dragBaseEV: Double = 0
    @State private var flashOpacity: Double = 0
    @State private var statusTicket = 0
    @State private var meterScale: MeterScale = .iso
    @State private var rulerOpacity: Double = {
        #if DEBUG
        return (PHIUITest.showEVRuler || PHIUITest.manual) ? 1 : 0
        #else
        return 0
        #endif
    }()
    @State private var rulerTicket = 0
    @State private var wantsManual: Bool = {
        #if DEBUG
        return PHIUITest.manual
        #else
        return false
        #endif
    }()
    @State private var zoomChoice: CaptureZoom = {
        #if DEBUG
        return PHIUITest.zoom ?? .one
        #else
        return .one
        #endif
    }()
    @State private var zoomTick = 0
    @State private var viewfinderSize = CGSize(width: 390, height: 520)

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
            PHIUITest.importPairsIfRequested()
            if let name = PHIUITest.openEditorOnce() {
                capture.openLocalShot(id: name)
            }
            if let aspect = PHIUITest.aspect {
                capture.setPhotoAspect(aspect)
            }
            if PHIUITest.showGrid {
                showGrid = true
            }
            if PHIUITest.screen == .capture || PHIUITest.screen == .flash {
                return
            }
            if PHIUITest.manual {
                _ = camera.setAutoExposure(false)
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
        .onChange(of: camera.autoExposure) { _, isAuto in
            #if DEBUG
            if PHIUITest.manual { return }
            #endif
            wantsManual = isAuto == false
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
        .sensoryFeedback(.selection, trigger: zoomTick)
    }

    private var finder: some View {
        GeometryReader { geo in
            let width: CGFloat = geo.size.width
            let height: CGFloat = geo.size.height
            let island: CGFloat = geo.safeAreaInsets.top > 1 ? geo.safeAreaInsets.top : ScreenEdge.windowTop
            let home: CGFloat = max(geo.safeAreaInsets.bottom > 1 ? geo.safeAreaInsets.bottom : ScreenEdge.windowBottom, 21)
            let layout = CaptureChromeLayout.measure(width: width, height: height, island: island, home: home)
            ZStack(alignment: .topLeading) {
                viewfinder
                    .frame(width: layout.photoFrame.width, height: layout.photoFrame.height)
                    .onAppear { viewfinderSize = CGSize(width: layout.photoFrame.width, height: layout.photoFrame.height) }
                    .onChange(of: layout.photoFrame.height) { _, _ in
                        viewfinderSize = CGSize(width: layout.photoFrame.width, height: layout.photoFrame.height)
                    }
                    .position(x: layout.photoFrame.midX, y: layout.photoFrame.midY)

                flashControl
                    .position(layout.flashCenter)
                settingsButton
                    .position(layout.settingsCenter)
                gridButton
                    .position(layout.gridCenter)
                modePill
                    .position(layout.pillCenter)

                captureRuler
                    .opacity(rulerOpacity)
                    .allowsHitTesting(rulerOpacity > 0.04)
                    .accessibilityHidden(rulerOpacity < 0.04)
                    .frame(width: layout.rulerFrame.width, height: layout.rulerFrame.height)
                    .position(x: layout.rulerFrame.midX, y: layout.rulerFrame.midY)

                thumbnailButton
                    .position(layout.thumbCenter)
                WhiteShutterButton(isReady: camera.isRunning || uiTestCapture, isCapturing: capture.isCapturing) {
                    capture.capture()
                }
                .position(layout.shutterCenter)
                ZoomCycleButton(title: activeZoom.title, titleSize: activeZoom.titleSize) {
                    cycleZoom()
                }
                .position(layout.zoomCenter)
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

    private var showsManual: Bool {
        if wantsManual { return true }
        return camera.autoExposure == false
    }

    private var finderLabel: String {
        "\(capture.processMode.finderWord) · \(activeAspect.title)"
    }

    private var shownFlash: AVCaptureDevice.FlashMode {
        #if DEBUG
        if PHIUITest.screen == .flash { return .auto }
        #endif
        return camera.flashMode
    }

    private var flashGlyph: PhiGlyph {
        switch shownFlash {
        case .on: .flashOn
        case .auto: .flashAuto
        default: .flashOff
        }
    }

    private var flashControl: some View {
        FlashSystemMenu(
            mode: shownFlash,
            glyph: flashGlyph,
            enabled: camera.flashAvailable || uiTestCapture,
            reason: camera.flashAvailable ? nil : "这枚镜头或当前格式不能用闪光灯。",
            openOnAppear: {
                #if DEBUG
                return PHIUITest.screen == .flash
                #else
                return false
                #endif
            }(),
            onSelect: { mode in
                camera.setFlash(mode)
            }
        )
        .frame(width: 44, height: 44)
    }

    private var settingsButton: some View {
        PhiGlyphButton(glyph: .settings, label: "拍摄设置") {
            showSettings = true
        }
    }

    private var gridButton: some View {
        PhiGlyphButton(glyph: showGrid ? .gridOn : .gridOff, label: showGrid ? "隐藏九宫格" : "显示九宫格") {
            showGrid.toggle()
        }
    }

    private var modePill: some View {
        Button {
            showSettings = true
        } label: {
            Text(finderLabel)
                .font(CameraFont.parameter(13))
                .foregroundStyle(CameraColor.textPrimary)
                .lineLimit(1)
                .frame(width: 150, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("拍摄设置 \(finderLabel)")
    }

    private var thumbnailButton: some View {
        Button {
            if capture.thumbnail == nil && capture.hasDevelopBase == false {
                capture.openSample()
            } else {
                showAlbum = true
            }
        } label: {
            thumbnail
                .frame(width: 44, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(capture.thumbnail == nil && capture.hasDevelopBase == false ? "打开样张" : "打开相册")
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
        .frame(width: 44, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var viewfinder: some View {
        PhotoCanvas(widthOverHeight: PhotoAspect.finderWidthOverHeight) {
            stage
        }
    }

    private var livePreview: some View {
        let onTap: (CGPoint, CGPoint) -> Void = { viewPoint, _ in
            let size = viewfinderSize
            let crop = activeAspect.cropWindow(in: size)
            let limit = crop.insetBy(dx: 38, dy: 38)
            let clamped = CGPoint(
                x: min(max(viewPoint.x, limit.minX), max(limit.minX, limit.maxX)),
                y: min(max(viewPoint.y, limit.minY), max(limit.minY, limit.maxY))
            )
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
            let cellWidth = crop.width / 3
            let cellHeight = crop.height / 3
            let cell = CGRect(
                x: crop.minX + cellWidth,
                y: crop.minY + cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            if camera.isConfigured || uiTestCapture {
                FocusBracket(locked: camera.focusLocked)
                    .frame(width: cell.width, height: cell.height)
                    .position(x: cell.midX, y: cell.midY)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var captureRuler: some View {
        if showsManual == false {
            autoRuler
        } else if meterScale == .shutter {
            shutterRuler
        } else {
            isoRuler
        }
    }

    private var autoRuler: some View {
        CalibratedRuler(
            leading: "A / EV",
            valueText: ExposureFormat.signedDecimal(camera.exposureEV),
            trailing: "EV",
            onLeading: toggleMeterMode,
            onTrailing: nil,
            value: camera.exposureEV,
            lower: evLower,
            upper: evUpper,
            pointsPerUnit: 100,
            fineStep: 0.5,
            majorEvery: 1,
            hapticEvery: 1,
            zeroMark: true,
            emphasizeNearestLabel: false,
            label: evTickLabel,
            snap: snapEV,
            onChange: { next in
                noteRulerActivity()
                camera.setExposureEV(next)
            },
            onCommit: {
                noteRulerActivity()
                camera.commitExposureEV()
            }
        )
    }

    private var isoRuler: some View {
        CalibratedRuler(
            leading: "M / ISO",
            valueText: isoNumber(shownISO),
            trailing: shutterReadout(shownShutter),
            onLeading: toggleMeterMode,
            onTrailing: {
                meterScale = .shutter
                noteRulerActivity()
            },
            value: isoCoordinate(shownISO),
            lower: isoCoordinate(isoStops.first ?? 50),
            upper: isoCoordinate(isoStops.last ?? 800),
            pointsPerUnit: 72,
            fineStep: 1.0 / 6.0,
            majorEvery: 1,
            zeroMark: false,
            emphasizeNearestLabel: true,
            label: isoTickLabel,
            snap: snapISOCoordinate,
            onChange: { coordinate in
                noteRulerActivity()
                camera.setManualISO(nearestISO(to: coordinate))
            },
            onCommit: { noteRulerActivity() }
        )
    }

    private var shutterRuler: some View {
        CalibratedRuler(
            leading: "M / ISO",
            valueText: MeterFormat.shutterFraction(shownShutter),
            trailing: "ISO \(isoNumber(shownISO))",
            onLeading: toggleMeterMode,
            onTrailing: {
                meterScale = .iso
                noteRulerActivity()
            },
            value: shutterCoordinate,
            lower: 0,
            upper: Double(max(shutterStops.count - 1, 0)),
            pointsPerUnit: 72,
            fineStep: 1.0 / 6.0,
            majorEvery: 1,
            zeroMark: false,
            emphasizeNearestLabel: true,
            label: shutterTickLabel,
            snap: snapShutterCoordinate,
            onChange: { coordinate in
                noteRulerActivity()
                let index = Int(coordinate.rounded())
                guard shutterStops.indices.contains(index) else { return }
                camera.setManualShutter(shutterStops[index])
            },
            onCommit: { noteRulerActivity() }
        )
    }

    private var shownStops: [FocalStop] {
        #if DEBUG
        if camera.focalStops.isEmpty, PHIUITest.screen != nil {
            return PHIUITest.lensStops
        }
        #endif
        return camera.focalStops
    }

    private var activeZoom: CaptureZoom {
        if camera.focalStops.isEmpty == false,
           let matched = ZoomCycle.zoom(matching: camera.selectedStopID, in: camera.focalStops) {
            return matched
        }
        return zoomChoice
    }

    private func cycleZoom() {
        guard let next = ZoomCycle.next(after: activeZoom, in: shownStops) else { return }
        zoomChoice = next.zoom
        zoomTick += 1
        if camera.focalStops.contains(where: { $0.id == next.stop.id }) {
            camera.select(stop: next.stop)
        }
    }

    private func toggleMeterMode() {
        let enableAuto = showsManual
        wantsManual = enableAuto == false
        _ = camera.setAutoExposure(enableAuto)
        if enableAuto == false {
            meterScale = .iso
        }
        noteRulerActivity()
    }

    /// The ruler keeps its frame while hidden, so the shutter row does not move.
    /// A viewfinder swipe or a meter change shows it, then it fades after a few idle seconds.
    private func noteRulerActivity() {
        #if DEBUG
        if PHIUITest.showEVRuler || PHIUITest.manual {
            rulerOpacity = 1
            return
        }
        #endif
        rulerTicket += 1
        let ticket = rulerTicket
        if rulerOpacity < 0.99 {
            withAnimation(.easeOut(duration: 0.15)) {
                rulerOpacity = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard rulerTicket == ticket else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                rulerOpacity = 0
            }
        }
    }

    private var evLower: Double {
        if camera.isConfigured { return camera.exposureRange.lowerBound }
        return -5
    }

    private var evUpper: Double {
        if camera.isConfigured { return camera.exposureRange.upperBound }
        return 5
    }

    private func evTickLabel(_ tick: Double) -> String {
        ExposureFormat.tick(Int(tick.rounded()))
    }

    private func snapEV(_ raw: Double) -> Double {
        let clamped = min(max(raw, evLower), evUpper)
        return (clamped * 10).rounded() / 10
    }

    private var isoStops: [Float] {
        if camera.isoChoices.isEmpty == false { return camera.isoChoices }
        return [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 3200]
    }

    private var shutterStops: [Double] {
        if camera.shutterChoices.isEmpty == false { return camera.shutterChoices }
        return ExposureStops.shutters(secondsMin: 1.0 / 8000, secondsMax: 1)
    }

    private var shownISO: Float {
        #if DEBUG
        if PHIUITest.manual, camera.isConfigured == false { return 200 }
        #endif
        if camera.manualISOValue > 1 { return camera.manualISOValue }
        return 200
    }

    private var shownShutter: Double {
        #if DEBUG
        if PHIUITest.manual, camera.isConfigured == false { return 1.0 / 250 }
        #endif
        if camera.manualShutterSeconds > 0 { return camera.manualShutterSeconds }
        return 1.0 / 250
    }

    private func isoCoordinate(_ iso: Float) -> Double {
        guard iso > 0 else { return 0 }
        return log2(Double(iso) / 50)
    }

    private func isoTickLabel(_ tick: Double) -> String {
        let iso = 50.0 * pow(2, tick)
        return isoNumber(Float(iso))
    }

    private func nearestISO(to coordinate: Double) -> Float {
        let iso = 50.0 * pow(2, coordinate)
        return isoStops.min(by: { lhs, rhs in
            abs(Double(lhs) - iso) < abs(Double(rhs) - iso)
        }) ?? Float(iso)
    }

    private func snapISOCoordinate(_ raw: Double) -> Double {
        isoCoordinate(nearestISO(to: raw))
    }

    private var shutterCoordinate: Double {
        Double(ExposureStops.nearestIndex(to: shownShutter, in: shutterStops))
    }

    private func shutterTickLabel(_ tick: Double) -> String {
        let index = Int(tick.rounded())
        guard shutterStops.indices.contains(index) else { return "" }
        return MeterFormat.shutterFraction(shutterStops[index])
    }

    private func snapShutterCoordinate(_ raw: Double) -> Double {
        let last = Double(max(shutterStops.count - 1, 0))
        return min(max(raw.rounded(), 0), last)
    }

    private func isoNumber(_ value: Float) -> String {
        guard value > 0 else { return "—" }
        if value >= 100 { return "\(Int(value.rounded()))" }
        return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func shutterReadout(_ seconds: Double) -> String {
        let fraction = MeterFormat.shutterFraction(seconds)
        return "\(fraction) s"
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
        noteRulerActivity()
        guard showsManual == false else { return }
        switch event {
        case .began:
            dragBaseEV = camera.exposureEV
        case .changed(let translationY):
            let steps = Int((-translationY / 22).rounded())
            camera.setExposureEV(dragBaseEV + Double(steps) * 0.1)
        case .ended:
            camera.commitExposureEV()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct ZoomCycleButton: View {
    var title: String
    var titleSize: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(CameraColor.surface)
                    .overlay {
                        Circle().stroke(CameraColor.border, lineWidth: 1)
                    }
                    .frame(width: 56, height: 56)
                Text(title)
                    .font(CameraFont.parameter(titleSize))
                    .foregroundStyle(CameraColor.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 96, height: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("倍率 \(title)")
    }
}

private enum PendingDevelop {
    case library(String)
    case local(String)
}
