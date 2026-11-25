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
                with: .color(CameraColor.gridLine),
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
            context.stroke(Path(crop), with: .color(Color.white.opacity(0.9)), lineWidth: 1)
        }
    }
}

private enum MeterScale {
    case iso
    case shutter
}

struct QuietFinderView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var capture = CaptureService()
    @ObservedObject private var finderLaunch = FinderLaunchRouter.shared
    @AppStorage("phi.showGrid") private var showGrid = false
    @State private var showRawMenu = {
        #if DEBUG
        return PHIUITest.showRawMenu
        #else
        return false
        #endif
    }()
    @State private var settingsPage: SettingsPage? = {
        #if DEBUG
        return PHIUITest.settingsCard
        #else
        return nil
        #endif
    }()
    @State private var showAlbum = false
    @State private var pendingDevelop: PendingDevelop?
    @State private var flashOpacity: Double = 0
    @State private var statusTicket = 0
    @State private var meterScale: MeterScale = .iso
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
            consumeFinderLaunch()
            PerfTrace.noteFirstFrame()
            #if DEBUG
            if PHIUITest.perf, PHIUITest.openEditorBasename == nil {
                Task { await PHIUITest.runPerf { capture.openLocalShot(id: $0) } }
            }
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
            if PHIUITest.showRawMenu {
                showRawMenu = true
            }
            if PHIUITest.settingsTour {
                Task { await runSettingsTour() }
            }
            if ProcessInfo.processInfo.arguments.contains("-PHIUITestFinderCycle") || ProcessInfo.processInfo.environment["PHI_FINDER_CYCLE"] != nil {
                Task { await runFinderCycle() }
            }
            if uiTestCapture {
                return
            }
            if PHIUITest.manual {
                _ = camera.setAutoExposure(false)
            }
            #endif
            camera.refreshAuthorization()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                consumeFinderLaunch()
            }
            guard camera.gate == .authorized else { return }
            if phase == .active {
                camera.start()
            } else {
                camera.stop()
            }
        }
        .onChange(of: finderLaunch.generation) { _, _ in
            consumeFinderLaunch()
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
            let layout = CaptureChromeLayout.measure(width: width, height: height, island: island, home: home, scale: displayScale)
            let surroundCorner = 16 + layout.finderBorderWidth
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: surroundCorner, style: .continuous)
                    .fill(CameraColor.surround)
                    .frame(width: layout.surroundFrame.width, height: layout.surroundFrame.height)
                    .position(x: layout.surroundFrame.midX, y: layout.surroundFrame.midY)

                viewfinder
                    .frame(width: layout.photoFrame.width, height: layout.photoFrame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onAppear { viewfinderSize = CGSize(width: layout.photoFrame.width, height: layout.photoFrame.height) }
                    .onChange(of: layout.photoFrame.height) { _, _ in
                        viewfinderSize = CGSize(width: layout.photoFrame.width, height: layout.photoFrame.height)
                    }
                    .position(x: layout.photoFrame.midX, y: layout.photoFrame.midY)

                settingsButton
                    .position(layout.settingsCenter)
                rawMenu
                    .position(layout.rawCenter)

                if showRawMenu {
                    #if DEBUG
                    let keepOpen = PHIUITest.showRawMenu
                    #else
                    let keepOpen = false
                    #endif
                    if keepOpen == false {
                        Color.black.opacity(0.001)
                            .frame(width: width, height: height)
                            .onTapGesture { showRawMenu = false }
                            .accessibilityHidden(true)
                    }
                    rawMenuPanel
                        .zIndex(8)
                        .position(x: 12 + 119, y: layout.rawCenter.y + 18 + 8 + 70)
                }

                styleBadge
                    .position(layout.styleBadgeCenter)

                // Always on screen and never moves. The settings card floats over it.
                captureRuler(height: layout.rulerFrame.height)
                    .frame(width: layout.rulerFrame.width, height: layout.rulerFrame.height)
                    .clipped()
                    .position(x: layout.rulerFrame.midX, y: layout.rulerFrame.midY)
                    .allowsHitTesting(settingsPage == nil)

                if settingsPage != nil {
                    Color.black.opacity(0.001)
                        .frame(width: width, height: height)
                        .onTapGesture { closeSettings() }
                        .accessibilityHidden(true)
                }

                bottomRow(layout)

                if let page = settingsPage {
                    let card = layout.cardFrame(for: page)
                    settingsCard
                        .frame(width: card.width, height: card.height)
                        .position(x: card.midX, y: card.midY)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: settingsPage)
            .frame(width: width, height: height)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    /// Fixed in place. An open settings card or sub-card overlays it (Zeid: no lift, unlike Figma 163:1207).
    @ViewBuilder
    private func bottomRow(_ layout: CaptureChromeLayout) -> some View {
        let rowY = layout.rowCenterY
        Group {
            thumbnailButton
                .position(x: layout.thumbCenter.x, y: rowY)
            WhiteShutterButton(isReady: camera.isRunning || uiTestCapture, isCapturing: capture.isCapturing, size: layout.shutterSize) {
                capture.capture()
            }
            .position(x: layout.shutterCenter.x, y: rowY)
            ZoomCycleButton(title: activeZoom.title, titleSize: activeZoom.titleSize) {
                cycleZoom()
            }
            .position(x: layout.zoomCenter.x, y: rowY)
        }
        .allowsHitTesting(settingsPage == nil)
    }

    private var settingsCard: some View {
        FinderSettingsCard(
            page: Binding(
                get: { settingsPage ?? .main },
                set: { settingsPage = $0 }
            ),
            mode: capture.processMode,
            onMode: { capture.setProcessMode($0) },
            saveHEIF: capture.saveHEIF,
            onSaveHEIF: { capture.setSaveHEIF($0) },
            codec: capture.processedCodec,
            onCodec: { capture.setProcessedCodec($0) },
            aspect: activeAspect,
            onAspect: { capture.setPhotoAspect($0) },
            flash: shownFlash,
            flashGlyph: flashGlyph,
            flashEnabled: camera.flashAvailable || uiTestCapture,
            onFlash: { camera.setFlash($0) },
            look: capture.captureLook,
            onLook: { capture.setCaptureLook($0) },
            showGrid: $showGrid,
            onClose: closeSettings,
            exposureRuler: { autoRulerCompact }
        )
    }

    private func closeSettings() {
        settingsPage = nil
    }

    /// Apply a pending “打开取景” request. Does not fire the shutter or reset the camera session.
    private func consumeFinderLaunch() {
        guard finderLaunch.takePending() else { return }
        let surface = FinderLaunchPlanner.Surface(
            editorOpen: capture.processSession != nil,
            editorDirty: false,
            albumOpen: showAlbum,
            settingsOpen: settingsPage != nil,
            rawMenuOpen: showRawMenu
        )
        for action in FinderLaunchPlanner.actions(for: surface) {
            switch action {
            case .alreadyOnFinder, .confirmDiscard, .dismissEditor:
                break
            case .closeOverlays(let settings, let rawMenu):
                if settings { settingsPage = nil }
                if rawMenu { showRawMenu = false }
            case .dismissAlbum:
                pendingDevelop = nil
                showAlbum = false
            }
        }
    }

    private var styleBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(CameraColor.accent)
                .frame(width: 4, height: 4)
            Text(capture.captureLook.badgeTitle)
                .font(CameraFont.parameter(12))
                .foregroundStyle(CameraColor.textSecondary)
                .lineLimit(1)
        }
        .frame(height: 20)
        .allowsHitTesting(false)
        .accessibilityLabel("风格 \(capture.captureLook.title)")
    }

    private var rawMenu: some View {
        Button {
            settingsPage = nil
            showRawMenu.toggle()
        } label: {
            Text(capture.processMode.finderWord)
                .font(CameraFont.parameter(13))
                .foregroundStyle(CameraColor.textPrimary)
                .lineLimit(1)
                .frame(width: 56, height: 36)
                .background(CameraColor.surface, in: Capsule())
                .shadow(color: CameraColor.dropShadow, radius: 3, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("处理方式 \(capture.processMode.finderWord)")
        .accessibilityAddTraits(showRawMenu ? .isSelected : [])
    }

    /// Ceramic White stand-in for Figma's System Menu / RAW (336:2527), 238×140, 40 pt rows.
    private var rawMenuPanel: some View {
        VStack(spacing: 0) {
            ForEach(ProcessMode.allCases, id: \.self) { mode in
                Button {
                    capture.setProcessMode(mode)
                    showRawMenu = false
                } label: {
                    HStack(spacing: 8) {
                        Text(mode.menuTitle)
                            .font(CameraFont.fixed(15, weight: .regular))
                            .foregroundStyle(CameraColor.textPrimary)
                        Spacer(minLength: 8)
                        if mode == capture.processMode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(CameraColor.textPrimary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(width: 238, height: 40, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.menuTitle)
                .accessibilityAddTraits(mode == capture.processMode ? .isSelected : [])
            }
        }
        .padding(.vertical, 10)
        .frame(width: 238, height: 140, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(CameraColor.surface.opacity(0.94))
                .shadow(color: Color.black.opacity(0.12), radius: 24, y: 10)
        }
    }

    private var aspectMenu: some View {
        Menu {
            ForEach(PhotoAspect.menuOrder, id: \.self) { aspect in
                Button {
                    capture.setPhotoAspect(aspect)
                } label: {
                    if aspect == activeAspect {
                        Label(aspect.chromeTitle, systemImage: "checkmark")
                    } else {
                        Text(aspect.chromeTitle)
                    }
                }
            }
        } label: {
            Text(activeAspect.chromeTitle)
                .font(CameraFont.parameter(13))
                .foregroundStyle(CameraColor.textPrimary)
                .lineLimit(1)
                .frame(width: 72, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .environment(\.colorScheme, .light)
        .accessibilityLabel("画幅 \(activeAspect.chromeTitle)")
    }

    #if DEBUG
    /// `-PHIUITestSettings`: opens the card, then each sub-card in turn, for Simulator screenshots.
    private func runSettingsTour() async {
        try? await Task.sleep(for: .seconds(2))
        showRawMenu = false
        let pages: [SettingsPage] = [.main, .process, .aspect, .flash, .output, .exposure, .style, .grid]
        for page in pages {
            settingsPage = page
            PHIUITest.logSettings("SETTINGS CARD \(page.rawValue) \(page.title)")
            try? await Task.sleep(for: .seconds(PHIUITest.settingsDwell))
        }
        settingsPage = nil
        PHIUITest.logSettings("SETTINGS CARD done")
    }
    #endif

    private var showsFinder: Bool {
        #if DEBUG
        if PHIUITest.capturesSample { return true }
        #endif
        return false
    }

    private var showsManual: Bool {
        if wantsManual { return true }
        return camera.autoExposure == false
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
        Button {
            showRawMenu = false
            settingsPage = settingsPage == nil ? .main : nil
        } label: {
            Image(systemName: "ellipsis")
                .font(CameraFont.fixed(15, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
                .frame(width: 48, height: 36)
                .background(CameraColor.surface, in: Capsule())
                .shadow(color: CameraColor.dropShadow, radius: 3, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("拍摄设置")
    }

    private var thumbnailButton: some View {
        Button {
            if capture.thumbnail == nil && capture.hasDevelopBase == false {
                capture.openSample()
            } else {
                PerfTrace.beginAlbum()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    showAlbum = true
                }
            }
        } label: {
            thumbnail
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(capture.thumbnail == nil && capture.hasDevelopBase == false ? "打开样张" : "打开相册")
    }

    private var fixtureThumbnail: UIImage? {
        #if DEBUG
        if PHIUITest.capturesSample { return PHIUITest.sample }
        #endif
        return nil
    }

    private var thumbnail: some View {
        Group {
            if let image = fixtureThumbnail ?? capture.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(CameraColor.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(CameraColor.border, lineWidth: 1)
                    }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: CameraColor.dropShadow, radius: 3, y: 2)
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
        // Viewfinder drag-to-expose is removed for now. Exposure lives on the ruler.
        let onDrag: (PreviewDrag) -> Void = { _ in }
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
            // The finder scale (crop stop during a RAW capture) must not spill past the frame.
            .clipped()
            .overlay {
                #if DEBUG
                if PHIUITest.capturesSample, let sample = PHIUITest.sample {
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
        return PHIUITest.capturesSample
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
    private func captureRuler(height: CGFloat) -> some View {
        if showsManual == false {
            autoRuler(height: height)
        } else if meterScale == .shutter {
            shutterRuler(height: height)
        } else {
            isoRuler(height: height)
        }
    }

    private func autoRuler(height: CGFloat) -> some View {
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
            fineStep: 0.2,
            majorEvery: 1,
            hapticEvery: 1,
            gridStep: 0.1,
            zeroMark: true,
            height: height,
            emphasizeNearestLabel: false,
            label: evTickLabel,
            snap: snapEV,
            onChange: { next in
                camera.setExposureEV(next)
            },
            onCommit: {
                camera.commitExposureEV()
            },
            onReset: resetEV
        )
    }

    /// Ruler inside the 曝光 sub-card (Figma 326×70, no tick captions).
    private var autoRulerCompact: some View {
        CalibratedRuler(
            leading: "A / EV",
            valueText: ExposureFormat.signedDecimal(camera.exposureEV),
            trailing: "EV",
            onLeading: nil,
            onTrailing: nil,
            value: camera.exposureEV,
            lower: evLower,
            upper: evUpper,
            pointsPerUnit: 100,
            fineStep: 0.2,
            majorEvery: 1,
            hapticEvery: 1,
            gridStep: 0.1,
            zeroMark: true,
            showsLabels: false,
            height: 70,
            emphasizeNearestLabel: false,
            label: evTickLabel,
            snap: snapEV,
            onChange: { camera.setExposureEV($0) },
            onCommit: { camera.commitExposureEV() },
            onReset: resetEV
        )
    }

    private func resetEV() {
        if showsManual { return }
        camera.setExposureEV(0)
        camera.commitExposureEV()
    }

    private func isoRuler(height: CGFloat) -> some View {
        CalibratedRuler(
            leading: "M / ISO",
            valueText: isoNumber(shownISO),
            trailing: shutterReadout(shownShutter),
            onLeading: toggleMeterMode,
            onTrailing: {
                meterScale = .shutter
            },
            value: isoCoordinate(shownISO),
            lower: isoCoordinate(isoStops.first ?? 50),
            upper: isoCoordinate(isoStops.last ?? 800),
            pointsPerUnit: 72,
            fineStep: 1.0 / 6.0,
            majorEvery: 1,
            zeroMark: false,
            height: height,
            emphasizeNearestLabel: true,
            label: isoTickLabel,
            snap: snapISOCoordinate,
            onChange: { coordinate in
                camera.setManualISO(nearestISO(to: coordinate))
            },
            onCommit: {}
        )
    }

    private func shutterRuler(height: CGFloat) -> some View {
        CalibratedRuler(
            leading: "M / ISO",
            valueText: MeterFormat.shutterFraction(shownShutter),
            trailing: "ISO \(isoNumber(shownISO))",
            onLeading: toggleMeterMode,
            onTrailing: {
                meterScale = .iso
            },
            value: shutterCoordinate,
            lower: 0,
            upper: Double(max(shutterStops.count - 1, 0)),
            pointsPerUnit: 72,
            fineStep: 1.0 / 6.0,
            majorEvery: 1,
            zeroMark: false,
            height: height,
            emphasizeNearestLabel: true,
            label: shutterTickLabel,
            snap: snapShutterCoordinate,
            onChange: { coordinate in
                let index = Int(coordinate.rounded())
                guard shutterStops.indices.contains(index) else { return }
                camera.setManualShutter(shutterStops[index])
            },
            onCommit: {}
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

    #if DEBUG
    /// Device check: step through every zoom stop, then optionally shoot once at 2×.
    /// `-PHIUITestFinderCycle` (add `-PHIUITestShootAt2` to capture). Logs FINDER CYCLE lines next to FINDER SCALE.
    private func runFinderCycle() async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for step in 0..<5 {
            await MainActor.run { cycleZoom() }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            NSLog("FINDER CYCLE step=%d zoom=%@", step, String(describing: activeZoom))
            if ProcessInfo.processInfo.environment["PHI_FINDER_CYCLE"] == "shootall" {
                NSLog("FINDER CYCLE shutter at %@ busy=%d", String(describing: activeZoom), capture.isCapturing ? 1 : 0)
                await MainActor.run { capture.capture() }
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                NSLog("FINDER CYCLE after capture %@ busy=%d", String(describing: activeZoom), capture.isCapturing ? 1 : 0)
                if step == 3 { return }
                continue
            }
            if activeZoom == .two, ProcessInfo.processInfo.arguments.contains("-PHIUITestShootAt2") || ProcessInfo.processInfo.environment["PHI_FINDER_CYCLE"] == "shoot2" {
                NSLog("FINDER CYCLE shutter at 2x")
                await MainActor.run { capture.capture() }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                NSLog("FINDER CYCLE after capture")
                return
            }
        }
    }
    #endif

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
    }

    private var evLower: Double {
        if camera.isConfigured { return max(camera.exposureRange.lowerBound, -5) }
        return -5
    }

    private var evUpper: Double {
        if camera.isConfigured { return min(camera.exposureRange.upperBound, 5) }
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
                    .shadow(color: CameraColor.dropShadow, radius: 4, y: 2)
                    .frame(width: 48, height: 48)
                Text(title)
                    .font(CameraFont.parameterSemibold(titleSize))
                    .foregroundStyle(CameraColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("倍率 \(title)")
    }
}

private enum PendingDevelop {
    case library(String)
    case local(String)
}
