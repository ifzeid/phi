import SwiftUI

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

    @State private var tab: EditorTab = .exposure
    @State private var holdingOriginal = false
    @State private var confirmDiscard = false
    @State private var baseEV = 0.0
    @State private var baseLook: ColorLook = .none
    @State private var baseHalo = false
    @State private var baseGrain: GrainStyle = .off
    @State private var capturedBaseline = false

    private let toolHeight: CGFloat = 168

    var body: some View {
        GeometryReader { geo in
            let bottomPad: CGFloat = 12
            let controls: CGFloat = 48 + toolHeight + 44 + 44
            let available: CGFloat = geo.size.height - 52 - controls - bottomPad
            let ideal: CGFloat = geo.size.width / PhotoAspect.finderWidthOverHeight
            let photoHeight: CGFloat = min(ideal, max(160, available))
            ZStack {
                CameraColor.background
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
                    toast
                        .frame(height: 44)
                    actions
                        .frame(height: 44)
                }
                .padding(.bottom, bottomPad)
                if confirmDiscard {
                    discardDialog
                }
            }
        }
        .preferredColorScheme(.dark)
        .modifier(HiddenSystemChrome())
        .modifier(UnderIsland())
        .onAppear {
            #if DEBUG
            switch PHIUITest.editorTab {
            case .exposure: tab = .exposure
            case .style: tab = .style
            case .effects: tab = .effects
            case nil: break
            }
            #endif
            captureBaseline()
        }
    }

    private var titleBar: some View {
        HStack {
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
        .padding(.horizontal, 8)
        .frame(height: 52)
    }

    @ViewBuilder
    private var editorImage: some View {
        PhotoCanvas(widthOverHeight: PhotoAspect.finderWidthOverHeight) {
            ZStack {
                CameraColor.background
                if holdingOriginal {
                    Image(uiImage: session.originalImage ?? UIImage(cgImage: session.base))
                        .resizable()
                        .scaledToFit()
                } else if let preview = session.preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(CameraColor.accent)
                }
            }
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
        HStack(spacing: 8) {
            ForEach(EditorTab.allCases) { item in
                SelectPill(title: item.rawValue, selected: tab == item, width: 104, height: 36) {
                    tab = item
                }
            }
        }
        .padding(.horizontal, 24)
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
        VStack(spacing: 4) {
            Text("\(ExposureFormat.signedDecimal(session.exposureEV)) EV")
                .font(CameraFont.interface(12, weight: .medium))
                .foregroundStyle(CameraColor.accent)
            SharedRuler(
                labels: developLabels,
                index: developIndex,
                onChange: { index in
                    session.setExposure(-5 + Double(index) * 0.1)
                },
                onCommit: {}
            )
        }
        .padding(.horizontal, 24)
    }

    private var styleTool: some View {
        HStack(spacing: 8) {
            ForEach(ColorLook.allCases) { look in
                let selected = session.colorLook == look
                Button {
                    session.setColorLook(look)
                } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(swatch(look))
                            .frame(width: 62, height: 62)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selected ? CameraColor.accent : Color.clear, lineWidth: 1.5)
                            }
                        Text(look.title)
                            .font(CameraFont.interface(11))
                            .foregroundStyle(selected ? CameraColor.accent : CameraColor.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var effectsTool: some View {
        HStack(spacing: 18) {
            effectGroup(title: "光晕") {
                SelectPill(title: "关", selected: session.halo == false, width: 76, height: 34) {
                    session.setHalo(false)
                }
                SelectPill(title: "开", selected: session.halo, width: 76, height: 34) {
                    session.setHalo(true)
                }
            }
            effectGroup(title: "颗粒") {
                SelectPill(title: "关", selected: session.style == .off, width: 76, height: 34) {
                    session.setStyle(.off)
                }
                SelectPill(title: "细颗粒", selected: session.style == .fine, width: 76, height: 34) {
                    session.setStyle(.fine)
                }
            }
        }
    }

    private func effectGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(CameraFont.interface(11))
                .foregroundStyle(CameraColor.textSecondary)
            HStack(spacing: 8) { content() }
        }
    }

    private var toast: some View {
        Group {
            if savedCopy {
                Text("✓ 已保存新照片，原片保留")
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
            PhiGlyphButton(glyph: .reset, label: "还原调整") { resetAdjustments() }
            Spacer(minLength: 0)
            if canRetryOriginal, savedCopy == false {
                Button("重试", action: onRetryOriginal)
                    .font(CameraFont.fixed(13, weight: .medium))
                    .foregroundStyle(CameraColor.textSecondary)
                    .padding(.trailing, 8)
            }
            Button(action: onExport) {
                Text(session.isExporting ? "保存中…" : "另存照片")
                    .font(CameraFont.fixed(13, weight: .medium))
                    .foregroundStyle(CameraColor.background)
                    .lineLimit(1)
            }
            .buttonStyle(PillPlateStyle(fill: CameraColor.textPrimary, width: 120, height: 40))
            .disabled(session.isExporting || session.preview == nil)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: 44)
    }

    private var discardDialog: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("放弃这次调整？")
                    .font(CameraFont.interface(18, weight: .medium))
                    .foregroundStyle(CameraColor.textPrimary)
                Text("原片不会改变。")
                    .font(CameraFont.interface(13))
                    .foregroundStyle(CameraColor.textSecondary)
                Button("继续编辑") { confirmDiscard = false }
                    .font(CameraFont.interface(14, weight: .medium))
                    .foregroundStyle(CameraColor.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                Button("放弃调整") {
                    confirmDiscard = false
                    onClose()
                }
                .font(CameraFont.interface(14, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .padding(20)
            .frame(width: 342)
            .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var savedCopy: Bool {
        session.status == "已保存新照片，原片保留"
    }

    private var developLabels: [String] {
        (0...100).map { ExposureFormat.signedDecimal(-5 + Double($0) * 0.1) }
    }

    private var developIndex: Int {
        min(100, max(0, Int(((session.exposureEV + 5) / 0.1).rounded())))
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

    private func requestClose() {
        if dirty && savedCopy == false {
            confirmDiscard = true
        } else {
            onClose()
        }
    }

    private func resetAdjustments() {
        session.setExposure(0)
        session.setColorLook(.none)
        session.setHalo(false)
        session.setStyle(.off)
    }

    private func swatch(_ look: ColorLook) -> Color {
        switch look {
        case .none: CameraColor.surface
        case .positive: Color(red: 0.72, green: 0.38, blue: 0.28)
        case .negative: Color(red: 0.35, green: 0.48, blue: 0.62)
        case .mono: Color(white: 0.55)
        case .ccd: Color(red: 0.45, green: 0.28, blue: 0.32)
        }
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
                            .foregroundStyle(selected ? CameraColor.accent : CameraColor.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Rectangle()
                            .fill(selected ? CameraColor.accent : Color.clear)
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
    var enabled: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            option("关", selected: enabled == false) { onChange(false) }
            option("光晕", selected: enabled) { onChange(true) }
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

#Preview("Process") {
    ProcessStillView(
        session: ProcessSession.syntheticPreview(),
        canRetryOriginal: false,
        onExport: {},
        onRetryOriginal: {},
        onClose: {}
    )
}
