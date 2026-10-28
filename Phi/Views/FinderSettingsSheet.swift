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
                Text("设备支持决定可选格式")
                    .font(CameraFont.interface(13))
                    .foregroundStyle(CameraColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CameraColor.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(CameraColor.background)
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
                .fixedSize(horizontal: false, vertical: true)
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
                .font(CameraFont.interface(12))
                .foregroundStyle(CameraColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codecCaption: String {
        if mode == .standard {
            return "只存苹果处理好的成片，不请求 RAW。设备没有 HEVC 时，HEIC 会改存 JPEG。"
        }
        if saveHEIF {
            return "成片可选 HEIC 或 JPEG。关掉「同时保存成片」时系统仍需要这张主图，否则会拒收单独的 DNG。"
        }
        return "系统相册不能只有 DNG，所以仍会带上苹果的成片作为主图。"
    }

    private var modeCaption: String {
        switch mode {
        case .bayer:
            saveHEIF
                ? "单帧 Bayer。苹果的成片是主图，DNG 是副档。成片可选 HEIC 或 JPEG。关掉「同时保存成片」时系统仍需要这张主图，否则会拒收单独的 DNG。"
                : "单帧 Bayer。系统相册不能只有 DNG，所以仍会带上苹果的成片作为主图。"
        case .proRaw:
            saveHEIF
                ? "Apple ProRAW。这一档如果没有，会改用 Bayer RAW。ProRAW 在写入前已经过多帧和降噪。成片可选 HEIC 或 JPEG。设备没有 HEVC 时，HEIC 会改存 JPEG。"
                : "Apple ProRAW。这一档如果没有，会改用 Bayer RAW。ProRAW 在写入前已经过多帧和降噪。关掉「同时保存成片」时系统仍会带上成片作为主图。"
        case .standard:
            "只存苹果处理好的成片，不请求 RAW。在上面选 HEIC 或 JPEG。设备没有 HEVC 时，HEIC 会改存 JPEG。"
        }
    }

}

private struct PhotoAspectPicker: View {
    var selection: PhotoAspect
    var onSelect: (PhotoAspect) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PhotoAspect.allCases) { aspect in
                let selected = aspect == selection
                Button {
                    onSelect(aspect)
                } label: {
                    VStack(spacing: 5) {
                        Text(aspect.title)
                            .font(CameraFont.parameter(12, medium: selected))
                            .foregroundStyle(selected ? CameraColor.accent : CameraColor.textSecondary)
                            .lineLimit(1)
                        Rectangle()
                            .fill(selected ? CameraColor.accent : Color.clear)
                            .frame(width: 14, height: 1.5)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(aspect.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct ProcessModePicker: View {
    var selection: ProcessMode
    var onSelect: (ProcessMode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ProcessMode.allCases) { mode in
                let selected = mode == selection
                Button {
                    onSelect(mode)
                } label: {
                    VStack(spacing: 4) {
                        Text(mode.mark)
                            .font(CameraFont.parameter(16, medium: selected))
                            .foregroundStyle(selected ? CameraColor.accent : CameraColor.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(mode.fullName)
                            .font(CameraFont.interface(11))
                            .foregroundStyle(selected ? CameraColor.textPrimary : CameraColor.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Rectangle()
                            .fill(selected ? CameraColor.accent : Color.clear)
                            .frame(width: 14, height: 1.5)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.fullName)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

