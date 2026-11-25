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
    @ObservedObject var session: ProcessSession
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
            let bottomPad: CGFloat = 12
            let controls: CGFloat = 48 + toolHeight + 52
            let available: CGFloat = geo.size.height - 52 - controls - bottomPad
            let ideal: CGFloat = geo.size.width / PhotoAspect.finderWidthOverHeight
            let photoHeight: CGFloat = min(ideal, max(160, available))
            VStack(spacing: 0) {
                titleBar
                editorImage
                    .frame(height: photoHeight, alignment: .top)
                    .clipped()
                Spacer(minLength: 0)
                tabBar
                    .frame(height: 48)
                tool
                    .frame(height: toolHeight)
                actions
                    .frame(height: 52)
            }
            .padding(.bottom, bottomPad)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(CameraColor.background)
            .overlay {
                if session.isExporting {
                    VStack(spacing: 10) {
                        ProgressView(value: session.exportProgress)
                            .tint(CameraColor.accent)
                            .frame(width: 180)
                        Text("正在保存")
                            .font(CameraFont.interface(13, weight: .medium))
                            .foregroundStyle(CameraColor.textPrimary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .preferredColorScheme(.light)
        .modifier(HiddenSystemChrome())
        .modifier(UnderIsland())
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

    private var titleBar: some View {
        HStack(spacing: 20) {
            NativeCloseButton(label: "离开编辑") { requestClose() }
            Text(savedCopy ? "编辑后的照片" : "编辑照片")
                .font(CameraFont.interface(14, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
            Spacer()
            PhiGlyphButton(glyph: .compare, label: "按住对比原片") {}
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in holdingOriginal = true }
                        .onEnded { _ in holdingOriginal = false }
                )
        }
        .padding(.leading, 13)
        .padding(.trailing, 15)
        .frame(height: 52)
    }

    @ViewBuilder
    private var editorImage: some View {
        PhotoCanvas(widthOverHeight: PhotoAspect.finderWidthOverHeight) {
            ZStack {
                CameraColor.surround
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
                if savedCopy {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                            Text("已保存副本 · 原片保留")
                                .font(CameraFont.fixed(12, weight: .medium))
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.72), in: Capsule())
                        .padding(.bottom, 16)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(8)
            .background(CameraColor.surround, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    private var toast: some View {
        Group {
            if savedCopy {
                Text("已保存副本 · 原片保留")
                    .font(CameraFont.interface(12))
                    .foregroundStyle(CameraColor.textPrimary)
                    .frame(width: 260, height: 44)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            PhiGlyphButton(glyph: .close, label: "离开编辑") { requestClose() }
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
                .padding(.trailing, 20)
            }
            Button(action: onExport) {
                Text(session.isExporting ? "保存中…" : "另存照片")
                    .font(CameraFont.fixed(14, weight: .medium))
                    .foregroundStyle(CameraColor.surface)
                    .lineLimit(1)
            }
            .buttonStyle(PillPlateStyle(fill: CameraColor.textPrimary, width: 148, height: 48))
            .disabled(session.isExporting || session.preview == nil)
            Spacer(minLength: 0)
            PhiGlyphButton(glyph: .reset, label: "还原调整") { resetAdjustments() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: 52)
    }

    private var showsRetry: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PHIUITestSaveFailed") { return true }
        #endif
        return canRetryOriginal && saveFailed
    }

    /// '重试' appears only after this edit's photo-library save failed.
    private var saveFailed: Bool {
        savedCopy == false && session.photoLibrarySave == .failed
    }

    private var savedCopy: Bool {
        #if DEBUG
        if PHIUITest.savedCopy { return true }
        #endif
        return session.photoLibrarySave == .savedCopy
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
            .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: CameraColor.dropShadow, radius: 20, y: 10)
        }
        .accessibilityAddTraits(.isModal)
    }
}
