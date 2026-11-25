import SwiftUI
import UIKit

/// Post-capture develop surface. Exposure here changes the rendered still, not the camera meter.
/// Grain is a named look. The original RAW file is never rewritten.
private enum EditorTab: String, CaseIterable, Identifiable {
    case exposure = "曝光"
    case style = "风格"
    case effects = "效果"
    var id: String { rawValue }
}

struct ProcessStillView: View {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var session: ProcessSession
    @ObservedObject private var finderLaunch = FinderLaunchRouter.shared
    var canRetryOriginal: Bool
    var onExport: () -> Void
    var onRetryOriginal: () -> Void
    var onClose: () -> Void

    @State private var tab: EditorTab = ProcessStillView.initialTab
    @State private var holdingOriginal = false
    @State private var confirmDiscard = ProcessStillView.initialDiscard
    @State private var baseEV = 0.0
    @State private var baseLook: ColorLook = .none
    @State private var baseHalo: HaloLevel = .off
    @State private var baseGrain: GrainStyle = .off
    @State private var capturedBaseline = false

    private let toolHeight: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            let width: CGFloat = geo.size.width
            let height: CGFloat = geo.size.height
            let island: CGFloat = geo.safeAreaInsets.top > 1 ? geo.safeAreaInsets.top : ScreenEdge.windowTop
            let home: CGFloat = max(geo.safeAreaInsets.bottom > 1 ? geo.safeAreaInsets.bottom : ScreenEdge.windowBottom, 21)
            // Same measure as the finder so the image content rect and top-button baseline match.
            let layout = CaptureChromeLayout.measure(width: width, height: height, island: island, home: home, scale: displayScale)
            let content = layout.contentFrame(for: session.framedAspect)
            let tools = editorToolHeights(below: layout.photoFrame.maxY, height: height, home: home)
            ZStack(alignment: .topLeading) {
                CameraColor.background
                    .frame(width: width, height: height)

                editorImage
                    .frame(width: content.width, height: content.height)
                    .position(x: content.midX, y: content.midY)

                editorCloseButton
                    .position(x: 12 + 24, y: layout.topButtonCenterY)

                Text(savedCopy ? "编辑后的照片" : "编辑照片")
                    .font(CameraFont.interface(14, weight: .medium))
                    .foregroundStyle(CameraColor.textPrimary)
                    .position(x: layout.aspectCenter.x, y: layout.topButtonCenterY)
                    .allowsHitTesting(false)

                editorCompareButton
                    .position(x: layout.settingsCenter.x, y: layout.topButtonCenterY)

                VStack(spacing: 0) {
                    tabBar
                        .frame(height: tools.tab)
                    tool
                        .frame(height: tools.tool)
                    actions
                        .frame(height: tools.actions)
                }
                .padding(.bottom, 12)
                .frame(width: width, height: tools.tab + tools.tool + tools.actions + 12, alignment: .bottom)
                .position(x: width / 2, y: height - home - (tools.tab + tools.tool + tools.actions + 12) / 2)
            }
            .frame(width: width, height: height)
            .overlay(alignment: .top) {
                // Only the designed success toast (Figma 358:2297). Processing is the button label
                // “保存中…”. Failure stays on this page with 重试 — no toast node exists in the file.
                if editorPrompt == .success {
                    AppNoticeBanner(kind: .success, scale: displayScale)
                        .padding(.horizontal, 16)
                        .padding(.top, island + 6)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .modifier(HiddenSystemChrome())
        .overlay {
            if confirmDiscard {
                CeramicDiscardCard(
                    onDiscard: {
                        confirmDiscard = false
                        onClose()
                    },
                    onStay: { confirmDiscard = false }
                )
                .ignoresSafeArea()
            }
        }
        .onAppear {
            captureBaseline()
        }
        .onChange(of: finderLaunch.generation) { _, _ in
            // Dirty → existing discard card (cancel stays here). Clean → onClose back to the finder.
            requestClose()
        }
        .onChange(of: session.savedEdits) { _, _ in
            rebaselineAfterSave()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PHIUITest.discardSave)) { _ in onExport() }
        .onReceive(NotificationCenter.default.publisher(for: PHIUITest.discardProbe)) { note in
            PHIUITest.noteDiscardState(dirty: dirty, step: note.object as? String ?? "probe")
        }
        #endif
    }

    private static var initialTab: EditorTab {
        #if DEBUG
        if let name = PHIUITest.editorTab {
            switch name {
            case .exposure: return .exposure
            case .style: return .style
            case .effects: return .effects
            }
        }
        if PHIUITest.screen == .style { return .style }
        #endif
        return .exposure
    }

    private static var initialDiscard: Bool {
        #if DEBUG
        return PHIUITest.screen == .discard
        #else
        return false
        #endif
    }

    /// Compress editor tools to fit under the shared photo slot; never move or stretch the photo.
    private func editorToolHeights(below photoMaxY: CGFloat, height: CGFloat, home: CGFloat) -> (tab: CGFloat, tool: CGFloat, actions: CGFloat) {
        let budget = height - home - 12 - photoMaxY
        var tab: CGFloat = 48
        var tool: CGFloat = toolHeight
        var actions: CGFloat = 48
        var deficit = max(0, (tab + tool + actions) - max(budget, 0))
        let toolCut = min(deficit, max(0, tool - 56))
        tool -= toolCut
        deficit -= toolCut
        let tabCut = min(deficit, max(0, tab - 36))
        tab -= tabCut
        deficit -= tabCut
        let actCut = min(deficit, max(0, actions - 44))
        actions -= actCut
        return (tab, tool, actions)
    }

    /// 48×36 ceramic capsule, same row geometry as the finder RAW / settings pills.
    private var editorCloseButton: some View {
        Button(action: requestClose) {
            PhiGlyphImage(glyph: .close)
                .foregroundStyle(CameraColor.textPrimary)
                .frame(width: 48, height: CaptureChromeLayout.topButtonHeight)
                .background(CameraColor.surface, in: Capsule())
                .shadow(color: CameraColor.dropShadow, radius: 3, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("离开编辑")
    }

    private var editorCompareButton: some View {
        PhiGlyphImage(glyph: .compare)
            .foregroundStyle(CameraColor.textPrimary)
            .frame(width: 48, height: CaptureChromeLayout.topButtonHeight)
            .background(CameraColor.surface, in: Capsule())
            .shadow(color: CameraColor.dropShadow, radius: 3, y: 2)
            .contentShape(Capsule())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in holdingOriginal = true }
                    .onEnded { _ in holdingOriginal = false }
            )
            .accessibilityLabel("按住对比原片")
    }

    @ViewBuilder
    private var editorImage: some View {
        PhotoCanvas(widthOverHeight: session.framedAspect.widthOverHeight) {
            ZStack {
                CameraColor.background
                EditorMetalPreview(frame: session.liveFrame, onPresented: { ticket in
                    session.notePresented(ticket: ticket)
                }, onFirstPixels: { image in
                    #if DEBUG
                    session.deliverFirstPixels(image)
                    #endif
                })
                if holdingOriginal {
                    Image(uiImage: session.originalImage ?? UIImage(cgImage: session.base))
                        .resizable()
                        .scaledToFit()
                }
            }
            // 16 pt is the photo's own corner in Figma, not a decorative surround.
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PHIShowDevelopInfo") {
            Text(session.developInfo)
                .font(CameraFont.parameter(11))
                .foregroundStyle(CameraColor.textSecondary)
                .lineLimit(2)
                .padding(.horizontal, 20)
        }
        #endif
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(EditorTab.allCases.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Spacer(minLength: 0)
                }
                textTab(item)
            }
        }
        .padding(.horizontal, 24)
    }

    private func textTab(_ item: EditorTab) -> some View {
        let selected = tab == item
        return Button {
            tab = item
        } label: {
            ZStack {
                Text(item.rawValue)
                    .font(CameraFont.fixed(14, weight: .medium))
                    .foregroundStyle(selected ? CameraColor.textPrimary : CameraColor.textSecondary)
                Circle()
                    .fill(selected ? CameraColor.accent : Color.clear)
                    .frame(width: 4, height: 4)
                    .offset(y: 16)
            }
            .frame(width: 104, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var tool: some View {
        switch tab {
        case .exposure:
            exposureTool
        case .style:
            styleTool
        case .effects:
            effectsTool
        }
    }

    private var exposureTool: some View {
        CalibratedRuler(
            leading: "曝光",
            valueText: ExposureFormat.signedDecimal(session.exposureEV),
            trailing: "EV",
            leadingMono: false,
            onLeading: nil,
            onTrailing: nil,
            value: session.exposureEV,
            lower: -5,
            upper: 5,
            pointsPerUnit: 100,
            fineStep: 0.2,
            majorEvery: 1,
            hapticEvery: 1,
            gridStep: 0.1,
            zeroMark: true,
            emphasizeNearestLabel: false,
            label: editTickLabel,
            snap: snapEditEV,
            onChange: { next in
                session.setExposure(next, interactive: true)
            },
            onCommit: {
                session.refinePreview()
            },
            onReset: {
                session.setExposure(0, interactive: false)
                session.refinePreview()
            }
        )
        .frame(maxWidth: 342)
        .frame(maxWidth: .infinity)
    }

    private var styleTool: some View {
        HStack(spacing: 7.5) {
            ForEach(ColorLook.allCases) { look in
                let selected = session.colorLook == look
                Button {
                    session.setColorLook(look)
                } label: {
                    Text(look.title)
                        .font(CameraFont.fixed(14, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? CameraColor.textPrimary : CameraColor.textSecondary)
                        .lineLimit(1)
                        .frame(width: 64, height: 44)
                        .background {
                            if selected {
                                Capsule().fill(CameraColor.surface)
                            }
                        }
                        .frame(width: 64, height: 86)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(look.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: 90)
    }

    private var effectsTool: some View {
        HStack(spacing: 14) {
            effectKey(
                title: "光晕",
                value: session.halo.title,
                active: session.halo != .off,
                accessibility: session.halo == .off ? "光晕 关" : "光晕 开"
            ) {
                session.setHalo(session.halo == .off ? .on : .off)
            }
            effectKey(
                title: "颗粒",
                value: session.style.title,
                active: session.style != .off,
                accessibility: session.style == .off ? "颗粒 关" : "颗粒 细颗粒"
            ) {
                session.setStyle(session.style == .off ? .fine : .off)
            }
        }
        .padding(.horizontal, 19)
    }

    private func effectKey(title: String, value: String, active: Bool, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(active ? CameraColor.accent : CameraColor.border)
                        .frame(width: 6, height: 6)
                    Text(title)
                        .font(CameraFont.fixed(14, weight: .medium))
                        .foregroundStyle(CameraColor.textPrimary)
                }
                Spacer(minLength: 8)
                Text(value)
                    .font(CameraFont.fixed(12, weight: .regular))
                    .foregroundStyle(active ? CameraColor.accent : CameraColor.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(CameraColor.surface, in: Capsule())
            .shadow(color: Color(red: 46.0 / 255, green: 59.0 / 255, blue: 51.0 / 255).opacity(0.10), radius: 4, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Editor bottom icons (Figma 336:2050 / 336:2051): 44 pt white circle, no stroke,
    /// shadow #2E3B33 9% / radius 6 / y 2. Not the settings tile stroke treatment.
    private func editorPlateIcon(glyph: PhiGlyph, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PhiGlyphImage(glyph: glyph)
                .foregroundStyle(CameraColor.textPrimary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(CameraColor.surface))
                .shadow(color: Color(red: 46.0 / 255, green: 59.0 / 255, blue: 51.0 / 255).opacity(0.09), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Figma Editor actions 336:2049: close and reset sit on white 44 pt plates;
    /// center “另存照片” is a 140×48 ink capsule (336:2052), not 148 and not a stroke tile.
    private var actions: some View {
        HStack(spacing: 0) {
            editorPlateIcon(glyph: .close, label: "离开编辑", action: requestClose)
            Spacer(minLength: 0)
            if showsRetry {
                Button(action: onRetryOriginal) {
                    Text("重试")
                        .font(CameraFont.fixed(13, weight: .medium))
                        .foregroundStyle(CameraColor.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
            }
            Button(action: onExport) {
                Text(isProcessing ? "保存中…" : "另存照片")
                    .font(CameraFont.fixed(14, weight: .medium))
                    .foregroundStyle(CameraColor.surface)
                    .lineLimit(1)
            }
            .buttonStyle(PillPlateStyle(fill: CameraColor.textPrimary, width: 140, height: 48))
            .shadow(color: Color(red: 46.0 / 255, green: 59.0 / 255, blue: 51.0 / 255).opacity(0.14), radius: 12, y: 4)
            .disabled(isProcessing || session.preview == nil)
            Spacer(minLength: 0)
            editorPlateIcon(glyph: .reset, label: "还原调整", action: resetAdjustments)
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
    }

    private var showsRetry: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PHIUITestSaveFailed") { return true }
        #endif
        return canRetryOriginal && saveFailed
    }

    /// '重试' appears only after this edit's photo-library save failed.
    private var saveFailed: Bool {
        savedCopy == false && displayedSave == .failed
    }

    private var isProcessing: Bool {
        #if DEBUG
        if PHIUITest.saving { return true }
        #endif
        return session.isExporting
    }

    /// Processing wins over a previous success or failure so the two notices never overlap.
    private var editorPrompt: EditorPrompt? {
        EditorPrompt.current(isExporting: isProcessing, save: displayedSave)
    }

    private var displayedSave: PhotoLibrarySaveState {
        #if DEBUG
        if PHIUITest.savedCopy { return .savedCopy }
        if ProcessInfo.processInfo.arguments.contains("-PHIUITestSaveFailed") { return .failed }
        #endif
        return session.photoLibrarySave
    }

    private var savedCopy: Bool {
        if isProcessing { return false }
        return displayedSave == .savedCopy
    }

    private func editTickLabel(_ tick: Double) -> String {
        ExposureFormat.tick(Int(tick.rounded()))
    }

    private func snapEditEV(_ raw: Double) -> Double {
        let clamped = min(5.0, max(-5.0, raw))
        return (clamped * 10).rounded() / 10
    }

    private var dirty: Bool {
        guard capturedBaseline else { return false }
        return session.exposureEV != baseEV
            || session.colorLook != baseLook
            || session.halo != baseHalo
            || session.style != baseGrain
    }

    private func captureBaseline() {
        guard capturedBaseline == false else { return }
        baseEV = session.exposureEV
        baseLook = session.colorLook
        baseHalo = session.halo
        baseGrain = session.style
        capturedBaseline = true
    }

    /// The saved photo is the new reference: closing with no further change leaves without asking.
    private func rebaselineAfterSave() {
        baseEV = session.exposureEV
        baseLook = session.colorLook
        baseHalo = session.halo
        baseGrain = session.style
        capturedBaseline = true
        #if DEBUG
        PHIUITest.noteDiscardState(dirty: dirty, step: "saved")
        #endif
    }

    private func requestClose() {
        #if DEBUG
        PHIUITest.noteDiscardState(dirty: dirty, step: "close")
        #endif
        if dirty {
            confirmDiscard = true
        } else {
            onClose()
        }
    }

    private func resetAdjustments() {
        session.setExposure(0)
        session.setColorLook(.none)
        session.setHalo(.off)
        session.setStyle(.off)
    }

}

struct ColorLookPicker: View {
    var selection: ColorLook
    var onSelect: (ColorLook) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ColorLook.allCases) { look in
                let selected = look == selection
                Button {
                    onSelect(look)
                } label: {
                    VStack(spacing: 5) {
                        Text(look.title)
                            .font(CameraFont.parameter(12, medium: selected))
                            .foregroundStyle(selected ? CameraColor.textPrimary : CameraColor.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Rectangle()
                            .fill(selected ? CameraColor.textPrimary : Color.clear)
                            .frame(width: 14, height: 1.5)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(look.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct HaloToggle: View {
    var level: HaloLevel
    var onChange: (HaloLevel) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HaloLevel.allCases) { step in
                option(step.title, selected: level == step) { onChange(step) }
            }
        }
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title)
                    .font(CameraFont.parameter(12, medium: selected))
                    .foregroundStyle(selected ? CameraColor.accent : CameraColor.textSecondary)
                Rectangle()
                    .fill(selected ? CameraColor.accent : Color.clear)
                    .frame(width: 14, height: 1.5)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}


/// Ceramic White discard card (Figma 336:2169). Same dirty-check behavior as the previous system alert.
private struct CeramicDiscardCard: View {
    @Environment(\.displayScale) private var displayScale
    var onDiscard: () -> Void
    var onStay: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: onStay)
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("放弃这次调整？")
                        .font(CameraFont.interface(17, weight: .semibold))
                        .foregroundStyle(CameraColor.textPrimary)
                    Text("未保存的调整将丢失，原片不会改变。")
                        .font(CameraFont.interface(15))
                        .foregroundStyle(CameraColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onDiscard) {
                    Text("放弃调整")
                        .font(CameraFont.interface(17, weight: .medium))
                        .foregroundStyle(CameraColor.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(CameraColor.destructiveWash, in: Capsule())
                }
                .buttonStyle(.plain)
                Button(action: onStay) {
                    Text("继续编辑")
                        .font(CameraFont.interface(17, weight: .medium))
                        .foregroundStyle(CameraColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(CameraColor.quietWash, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(width: 300)
            .flowGlass(cornerRadius: FlowGlassToken.discardCorner, scale: displayScale)
            .shadow(color: CameraColor.dropShadow, radius: 20, y: 10)
        }
        .accessibilityAddTraits(.isModal)
    }
}
