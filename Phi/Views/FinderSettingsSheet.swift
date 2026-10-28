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
    var iso: Float
    var isoChoices: [Float]
    var shutter: Double
    var shutterChoices: [Double]
    var manualSupported: Bool
    var manual: Bool
    var onManual: (Bool) -> Void
    var onISO: (Float) -> Void
    var onShutter: (Double) -> Void
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                section("处理", caption: modeCaption) {
                    ProcessModePicker(selection: mode, onSelect: onMode)
                    companionRow
                }
                section("画幅", caption: "取景框、缩略图和显影按这个比例中心裁切。DNG 仍是整幅，裁切记在这张照片上。") {
                    PhotoAspectPicker(selection: aspect, onSelect: onAspect)
                }
                section("ISO / SHUTTER", caption: exposureCaption) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("手动曝光")
                                .font(CameraFont.interface(15, weight: .medium))
                                .foregroundStyle(CameraColor.textPrimary)
                            Text("Manual exposure")
                                .font(CameraFont.interface(12))
                                .foregroundStyle(CameraColor.textSecondary)
                        }
                        Spacer()
                        Toggle("手动曝光", isOn: Binding(get: { manual }, set: onManual))
                            .labelsHidden()
                            .tint(CameraColor.accent)
                            .disabled(manualSupported == false)
                    }
                    .frame(minHeight: 44)
                    StepValue(
                        text: isoText,
                        canDecrease: manual && isoIndex > 0,
                        canIncrease: manual && isoIndex < isoChoices.count - 1,
                        onDecrease: { stepISO(-1) },
                        onIncrease: { stepISO(1) }
                    )
                    .opacity(manual ? 1 : 0.4)
                    StepValue(
                        text: MeterFormat.shutter(seconds: shutter),
                        canDecrease: manual && shutterIndex > 0,
                        canIncrease: manual && shutterIndex < shutterChoices.count - 1,
                        onDecrease: { stepShutter(-1) },
                        onIncrease: { stepShutter(1) }
                    )
                    .opacity(manual ? 1 : 0.4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CameraColor.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(CameraColor.background)
    }

    private var header: some View {
        ZStack {
            Text("Control")
                .font(CameraFont.interface(17, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
            HStack {
                Spacer()
                Button(action: onClose) {
                    PhiIcon(symbol: .close, color: CameraColor.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭设置")
            }
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

    private var exposureCaption: String {
        if manualSupported == false {
            return "这枚镜头不能单独锁定 ISO 或快门。"
        }
        if manual {
            return "打开后在取景框里拖动刻度。这里的加减和取景框是同一组数值。关掉回到自动曝光。"
        }
        return "默认关闭。取景框下方仍是自动曝光。打开后，快门和感光度出现在取景框里。"
    }

    private var companionRow: some View {
        HStack(spacing: 10) {
            Text(mode.wantsRaw ? "同时保存成片" : "成片")
                .font(CameraFont.interface(15, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if mode.wantsRaw == false || saveHEIF {
                ProcessedCodecSwitch(selection: codec, onSelect: onCodec)
            }
            if mode.wantsRaw {
                Toggle("同时保存成片", isOn: Binding(get: { saveHEIF }, set: onSaveHEIF))
                    .labelsHidden()
                    .tint(CameraColor.accent)
            }
        }
        .frame(minHeight: 44)
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

    private var isoIndex: Int {
        guard isoChoices.isEmpty == false else { return 0 }
        return ExposureStops.nearestIndex(to: iso, in: isoChoices)
    }

    private var shutterIndex: Int {
        guard shutterChoices.isEmpty == false else { return 0 }
        return ExposureStops.nearestIndex(to: shutter, in: shutterChoices)
    }

    private var isoText: String {
        guard iso > 0 else { return "—" }
        if iso >= 100 { return "\(Int(iso.rounded()))" }
        return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), iso)
    }

    private func stepISO(_ delta: Int) {
        guard isoChoices.isEmpty == false else {
            onISO(iso)
            return
        }
        let index = min(max(isoIndex + delta, 0), isoChoices.count - 1)
        onISO(isoChoices[index])
    }

    private func stepShutter(_ delta: Int) {
        guard shutterChoices.isEmpty == false else {
            onShutter(shutter)
            return
        }
        let index = min(max(shutterIndex + delta, 0), shutterChoices.count - 1)
        onShutter(shutterChoices[index])
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

private struct ProcessedCodecSwitch: View {
    var selection: ProcessedCodec
    var onSelect: (ProcessedCodec) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ProcessedCodec.allCases.enumerated()), id: \.element.id) { index, codec in
                if index > 0 {
                    Rectangle()
                        .fill(CameraColor.border)
                        .frame(width: 1, height: 14)
                }
                let selected = codec == selection
                Button {
                    onSelect(codec)
                } label: {
                    Text(codec.title)
                        .font(CameraFont.parameter(11, medium: selected))
                        .foregroundStyle(selected ? CameraColor.accent : CameraColor.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(codec.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 2)
        .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CameraColor.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("成片格式")
    }
}

private struct StepValue: View {
    var text: String
    var canDecrease: Bool
    var canIncrease: Bool
    var onDecrease: () -> Void
    var onIncrease: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton("−", enabled: canDecrease, label: "减小", action: onDecrease)
            Text(text)
                .font(CameraFont.parameter(22, medium: true))
                .foregroundStyle(CameraColor.accent)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            stepButton("+", enabled: canIncrease, label: "增大", action: onIncrease)
        }
        .frame(height: 52)
        .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CameraColor.border, lineWidth: 1)
        }
    }

    private func stepButton(_ title: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CameraFont.parameter(20, medium: true))
                .foregroundStyle(enabled ? CameraColor.textPrimary : CameraColor.border)
                .frame(width: 56, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
