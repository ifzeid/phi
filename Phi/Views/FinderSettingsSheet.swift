import SwiftUI

/// Format, aspect, ISO, and shutter. Grain stays on the develop screen.
struct FinderSettingsSheet: View {
    var mode: ProcessMode
    var onMode: (ProcessMode) -> Void
    var saveHEIF: Bool
    var onSaveHEIF: (Bool) -> Void
    var codec: ProcessedCodec
    var onCodec: (ProcessedCodec) -> Void
    var aspect: PhotoAspect
    var onAspect: (PhotoAspect) -> Void
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                section("处理方式", caption: modeCaption) {
                    ProcessModePicker(selection: mode, onSelect: onMode)
                }
                Divider().overlay(CameraColor.border)
                companionBlock
                section("画幅", caption: "预览与成片使用所选比例；RAW 保留完整画面") {
                    PhotoAspectPicker(selection: aspect, onSelect: onAspect)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备支持决定可选格式")
                        .font(CameraFont.interface(13, weight: .medium))
                        .foregroundStyle(CameraColor.textPrimary)
                    Text("没有的格式会停用，并写明原因。")
                        .font(CameraFont.interface(13))
                        .foregroundStyle(CameraColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CameraColor.background)
        .modifier(UnderIsland())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(CameraColor.background)
        .modifier(HiddenSystemChrome())
    }

    private var header: some View {
        ZStack {
            Text("拍摄设置")
                .font(CameraFont.interface(14, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
            HStack {
                Button(action: onClose) {
                    PhiIcon(symbol: .close, color: CameraColor.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭设置")
                Spacer()
            }
        }
    }

    private var companionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode.wantsRaw {
                HStack {
                    Text("同时保存成片")
                        .font(CameraFont.interface(16, weight: .medium))
                        .foregroundStyle(CameraColor.textPrimary)
                    Spacer()
                    Toggle("同时保存成片", isOn: Binding(get: { saveHEIF }, set: onSaveHEIF))
                        .labelsHidden()
                        .tint(CameraColor.accent)
                        .scaleEffect(0.82)
                        .frame(width: 42, height: 26)
                }
                .frame(minHeight: 44)
            }
            if mode.wantsRaw == false || saveHEIF {
                HStack(spacing: 8) {
                    ForEach(ProcessedCodec.allCases) { item in
                        SelectPill(title: item.title, selected: item == codec, height: 38) {
                            onCodec(item)
                        }
                    }
                }
            }
            Text(codecCaption)
                .font(CameraFont.interface(13))
                .foregroundStyle(CameraColor.textSecondary)
                .lineLimit(1)
        }
    }

    private func section<Content: View>(_ title: String, caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(CameraFont.interface(11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(CameraColor.textSecondary)
            content()
            Text(caption)
                .font(CameraFont.interface(13))
                .foregroundStyle(CameraColor.textSecondary)
                .lineLimit(1)
        }
    }

    private var codecCaption: String {
        if mode == .standard { return "只存苹果成片。没有 HEVC 时改存 JPEG。" }
        if saveHEIF { return "成片为 HEIC 或 JPEG。关掉时仍保留主图。" }
        return "系统相册仍会带上成片作为主图。"
    }

    private var modeCaption: String {
        switch mode {
        case .bayer: "0 单帧 Bayer。DNG 是副档。"
        case .proRaw: "Φ 是 ProRAW。没有时改用 Bayer。"
        case .standard: "1 只存苹果处理好的成片。"
        }
    }

}

private struct PhotoAspectPicker: View {
    var selection: PhotoAspect
    var onSelect: (PhotoAspect) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PhotoAspect.allCases) { aspect in
                SelectPill(title: aspect.title, selected: aspect == selection, height: 38) {
                    onSelect(aspect)
                }
                .accessibilityLabel(aspect.title)
            }
        }
    }
}

private struct ProcessModePicker: View {
    var selection: ProcessMode
    var onSelect: (ProcessMode) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProcessMode.allCases) { mode in
                SelectPill(title: mode.mark, selected: mode == selection, width: 111, height: 38) {
                    onSelect(mode)
                }
                .accessibilityLabel(mode.fullName)
            }
        }
    }
}

