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
            let toastHeight: CGFloat = savedCopy ? 44 : 0
            let controls: CGFloat = 48 + toolHeight + toastHeight + 44
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
                if savedCopy {
                    toast
                        .frame(height: 44)
                }
                actions
                    .frame(height: 44)
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
        .preferredColorScheme(.dark)
        .modifier(HiddenSystemChrome())
        .modifier(UnderIsland())
        .background {
            DiscardEditAlert(isPresented: $confirmDiscard, onDiscard: onClose)
                .allowsHitTesting(false)
        }
        .onAppear {
            captureBaseline()
        }
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
                        .font(CameraFont.fixed(14, weight: .regular))
                        .foregroundStyle(selected ? CameraColor.accent : CameraColor.textSecondary)
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
        VStack(spacing: 8) {
            effectRow(title: "光晕") {
                ForEach(HaloLevel.allCases) { level in
                    SelectPill(title: level.title, selected: session.halo == level, width: 76, height: 44, idleInk: CameraColor.textSecondary) {
                        session.setHalo(level)
                    }
                    .accessibilityLabel(level == .off ? "关闭光晕" : "\(level.title)光晕")
                }
            }
            effectRow(title: "颗粒") {
                SelectPill(title: "关", selected: session.style == .off, width: 76, height: 44, idleInk: CameraColor.textSecondary) {
                    session.setStyle(.off)
                }
                SelectPill(title: "细颗粒", selected: session.style == .fine, width: 76, height: 44, idleInk: CameraColor.textSecondary) {
                    session.setStyle(.fine)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func effectRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(CameraFont.fixed(14, weight: .regular))
                .foregroundStyle(CameraColor.textPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                content()
            }
        }
        .frame(height: 44)
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

    private var showsRetry: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PHIUITestSaveFailed") { return true }
        #endif
        return canRetryOriginal && saveFailed
    }

    /// '重试' appears only after this edit's photo-library save failed.
    private var saveFailed: Bool {
        guard savedCopy == false, let status = session.status else { return false }
        return status.hasPrefix("未能写入相册")
    }

    private var savedCopy: Bool {
        session.status == "已保存新照片，原片保留"
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

/// System alert. The app tint is vermilion, which would paint the cancel action red.
/// The alert's own tint stays ivory, so only the destructive action is red.
private struct DiscardEditAlert: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onDiscard: () -> Void

    func makeUIViewController(context: Context) -> DiscardAlertHost {
        let host = DiscardAlertHost()
        host.view.backgroundColor = .clear
        return host
    }

    func updateUIViewController(_ host: DiscardAlertHost, context: Context) {
        host.onDiscard = onDiscard
        host.onDismiss = { isPresented = false }
        host.isPresented = isPresented
        if isPresented {
            host.showIfNeeded()
        }
    }
}

private final class DiscardAlertHost: UIViewController {
    var isPresented = false
    var onDiscard: () -> Void = {}
    var onDismiss: () -> Void = {}

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showIfNeeded()
    }

    func showIfNeeded() {
        guard isPresented, presentedViewController == nil, view.window != nil else { return }
        let alert = UIAlertController(
            title: "放弃这次调整？",
            message: "未保存的调整将丢失，原片不会改变。",
            preferredStyle: .alert
        )
        alert.overrideUserInterfaceStyle = .dark
        alert.view.tintColor = UIColor(red: 244.0 / 255.0, green: 243.0 / 255.0, blue: 238.0 / 255.0, alpha: 1)
        let discard = UIAlertAction(title: "放弃调整", style: .destructive) { [weak self] _ in
            self?.onDismiss()
            self?.onDiscard()
        }
        let stay = UIAlertAction(title: "继续编辑", style: .cancel) { [weak self] _ in
            self?.onDismiss()
        }
        alert.addAction(discard)
        alert.addAction(stay)
        let ivory = alert.view.tintColor
        present(alert, animated: true) {
            alert.view.tintColor = ivory
        }
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
