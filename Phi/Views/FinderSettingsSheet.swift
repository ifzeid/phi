import AVFoundation
import SwiftUI

/// Pages of the floating capture settings card (Figma 101:338 and 163:1207…1681).
enum SettingsPage: String, CaseIterable, Identifiable {
    case main
    case process
    case aspect
    case flash
    case output
    case exposure
    case style

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main: "拍摄设置"
        case .process: "处理方式"
        case .aspect: "画幅"
        case .flash: "闪光灯"
        case .output: "成片"
        case .exposure: "曝光"
        case .style: "风格"
        }
    }

    /// Card height in points, measured from Figma.
    var cardHeight: CGFloat { self == .main ? 300 : 236 }
}

enum SettingsCardToken {
    static let sideInset: CGFloat = 12
    static let radius: CGFloat = 36
    static let padding: CGFloat = 20
    static let tint = Color(red: 21.0 / 255.0, green: 24.0 / 255.0, blue: 23.0 / 255.0).opacity(0.18)
    static let selectedPill = Color(red: 16.0 / 255.0, green: 20.0 / 255.0, blue: 19.0 / 255.0).opacity(0.7)
    static let faint = CameraColor.textPrimary.opacity(0.4)
}

extension PhotoAspect {
    /// The capture chrome names ratios landscape first, as in Figma: 4:3, 3:2, 16:9.
    var chromeTitle: String {
        switch self {
        case .square: "1:1"
        case .threeByFour: "4:3"
        case .twoByThree: "3:2"
        case .nineBySixteen: "16:9"
        }
    }

    static let menuOrder: [PhotoAspect] = [.threeByFour, .square, .nineBySixteen, .twoByThree]
    static let cardOrder: [PhotoAspect] = [.threeByFour, .square, .twoByThree, .nineBySixteen]
}

extension ProcessMode {
    /// `0 · RAW`, `Φ · ProRAW`, `1 · 标准`.
    var menuTitle: String { "\(mark) · \(finderWord)" }
}

extension AVCaptureDevice.FlashMode {
    var settingsTitle: String {
        switch self {
        case .on: "开启"
        case .auto: "自动"
        default: "关闭"
        }
    }
}

/// Liquid Glass card. Stays over the camera; the chrome above keeps working.
struct FinderSettingsCard<Exposure: View>: View {
    @Binding var page: SettingsPage
    var mode: ProcessMode
    var onMode: (ProcessMode) -> Void
    var saveHEIF: Bool
    var onSaveHEIF: (Bool) -> Void
    var codec: ProcessedCodec
    var onCodec: (ProcessedCodec) -> Void
    var aspect: PhotoAspect
    var onAspect: (PhotoAspect) -> Void
    var flash: AVCaptureDevice.FlashMode
    var flashGlyph: PhiGlyph
    var flashEnabled: Bool
    var onFlash: (AVCaptureDevice.FlashMode) -> Void
    var look: ColorLook
    var onLook: (ColorLook) -> Void
    var onClose: () -> Void
    @ViewBuilder var exposureRuler: () -> Exposure

    @GestureState private var pull: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(SettingsCardToken.faint)
                .frame(width: 32, height: 3)
                .padding(.top, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 20, alignment: .top)
            content
                .padding(.horizontal, SettingsCardToken.padding)
            Spacer(minLength: 0)
        }
        .frame(height: page.cardHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .modifier(SettingsGlass())
        .offset(y: max(pull, 0))
        .gesture(
            DragGesture(minimumDistance: 8)
                .updating($pull) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    if value.translation.height > 60 { onClose() }
                }
        )
        .animation(.easeOut(duration: 0.2), value: page)
        .dynamicTypeSize(.large)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .main:
            mainPage
        default:
            subPage
        }
    }

    // MARK: Main

    private var mainPage: some View {
        VStack(spacing: 20) {
            HStack(spacing: 0) {
                Text("拍摄设置")
                    .font(CameraFont.fixed(14, weight: .regular))
                    .foregroundStyle(CameraColor.textPrimary)
                Spacer(minLength: 0)
                closeButton
            }
            .frame(height: 28)
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    tile(.process, caption: "处理方式") { tileText(mode.mark, size: 22) }
                    tile(.aspect, caption: "画幅") { tileText(aspect.chromeTitle, size: 22) }
                    tile(.flash, caption: "闪光灯") {
                        PhiGlyphImage(glyph: flashGlyph)
                            .foregroundStyle(CameraColor.textPrimary)
                    }
                }
                HStack(spacing: 16) {
                    tile(.output, caption: "格式") { tileText(codec.title, size: 14) }
                    tile(.exposure, caption: "曝光") { tileText("±", size: 22) }
                    tile(.style, caption: "风格") { tileText(look.title, size: 16) }
                }
            }
        }
    }

    private func tileText(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(CameraFont.fixed(size, weight: .regular))
            .foregroundStyle(CameraColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func tile<Face: View>(_ target: SettingsPage, caption: String, @ViewBuilder face: () -> Face) -> some View {
        Button {
            page = target
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(CameraColor.surface)
                        .overlay { Circle().stroke(CameraColor.border, lineWidth: 1) }
                    face()
                }
                .frame(width: 60, height: 60)
                Text(caption)
                    .font(CameraFont.fixed(12, weight: .regular))
                    .foregroundStyle(SettingsCardToken.faint)
                    .frame(height: 24)
            }
            .frame(width: 98, height: 92)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(caption)
    }

    // MARK: Sub pages

    private var subPage: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(page.title)
                    .font(CameraFont.fixed(14, weight: .regular))
                    .foregroundStyle(CameraColor.textPrimary)
                HStack(spacing: 0) {
                    Button {
                        page = .main
                    } label: {
                        PhiGlyphImage(glyph: .back)
                            .foregroundStyle(CameraColor.textPrimary)
                            .frame(width: 44, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回")
                    .offset(x: -10)
                    Spacer(minLength: 0)
                    closeButton
                }
            }
            .frame(height: 28)
            subBody
        }
    }

    @ViewBuilder
    private var subBody: some View {
        switch page {
        case .process:
            valueBlock(mode.menuTitle)
            optionRow(ProcessMode.allCases.map(\.menuTitle), selected: ProcessMode.allCases.firstIndex(of: mode), size: 14) {
                onMode(ProcessMode.allCases[$0])
            }
            footnote("RAW 保留原始数据；ProRAW 保留 Apple ProRAW；标准仅保存成片。")
        case .aspect:
            valueBlock(aspect.chromeTitle)
            optionRow(PhotoAspect.cardOrder.map(\.chromeTitle), selected: PhotoAspect.cardOrder.firstIndex(of: aspect), size: 12) {
                onAspect(PhotoAspect.cardOrder[$0])
            }
            footnote("预览与成片按所选比例裁切，RAW 保留完整画面。")
        case .flash:
            let modes: [AVCaptureDevice.FlashMode] = [.off, .auto, .on]
            valueBlock(flash.settingsTitle)
            optionRow(modes.map(\.settingsTitle), selected: modes.firstIndex(of: flash), size: 14, enabled: flashEnabled) {
                onFlash(modes[$0])
            }
            footnote(flashEnabled ? "" : "这枚镜头或当前格式不能用闪光灯。")
        case .output:
            let codecs = ProcessedCodec.allCases
            let enabled = mode.wantsRaw == false || saveHEIF
            valueBlock(codec.title)
            optionRow(codecs.map(\.title), selected: codecs.firstIndex(of: codec), size: 14, enabled: enabled) {
                onCodec(codecs[$0])
            }
            if mode.wantsRaw {
                HStack(spacing: 0) {
                    Text("同时保存成片 · \(saveHEIF ? "已开启" : "已关闭")")
                        .font(CameraFont.fixed(11, weight: .regular))
                        .foregroundStyle(CameraColor.textSecondary)
                    Spacer(minLength: 8)
                    SettingsSwitch(isOn: saveHEIF, onChange: onSaveHEIF)
                }
                .frame(height: 44)
                .padding(.top, 6)
            } else {
                footnote("标准模式只保存成片。")
            }
        case .exposure:
            exposureRuler()
                .frame(height: 70)
                .padding(.top, 22)
            footnote("横向滑动调节 · 双击归零")
        case .style:
            valueBlock(look.title)
            optionRow(ColorLook.allCases.map(\.title), selected: ColorLook.allCases.firstIndex(of: look), size: 12) {
                onLook(ColorLook.allCases[$0])
            }
            footnote("")
        case .main:
            EmptyView()
        }
    }

    private func valueBlock(_ text: String) -> some View {
        Text(text)
            .font(CameraFont.fixed(26, weight: .regular))
            .foregroundStyle(CameraColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(height: 38)
            .padding(.top, 20)
            .padding(.bottom, 18)
    }

    private func optionRow(
        _ titles: [String],
        selected: Int?,
        size: CGFloat,
        enabled: Bool = true,
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(titles.indices, id: \.self) { index in
                let isOn = index == selected
                Button {
                    onSelect(index)
                } label: {
                    Text(titles[index])
                        .font(CameraFont.fixed(size, weight: .regular))
                        .foregroundStyle(isOn ? CameraColor.accent : CameraColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background {
                            if isOn {
                                Capsule().fill(SettingsCardToken.selectedPill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(titles[index])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .frame(height: 44)
        .disabled(enabled == false)
        .opacity(enabled ? 1 : 0.4)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(CameraFont.fixed(11, weight: .regular))
            .foregroundStyle(CameraColor.textSecondary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .padding(.top, 10)
    }

    private var closeButton: some View {
        NativeCloseButton(label: "关闭设置", diameter: 30, action: onClose)
            .frame(height: 28)
            .offset(x: 7)
    }
}

/// iOS 26+ Liquid Glass (regular, dark) with the Figma tint. Older systems get a dark material.
private struct SettingsGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsCardToken.radius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(SettingsCardToken.tint), in: shape)
                .environment(\.colorScheme, .dark)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(SettingsCardToken.tint, in: shape)
                .environment(\.colorScheme, .dark)
        }
    }
}
