import SwiftUI

/// Format, aspect, ISO, and shutter. Grain stays on the develop screen.
struct FinderSettingsSheet: View {
    var format: CaptureFormat
    var onFormat: (CaptureFormat) -> Void
    var aspect: PhotoAspect
    var onAspect: (PhotoAspect) -> Void
    var iso: Float
    var isoChoices: [Float]
    var shutter: Double
    var shutterChoices: [Double]
    var manualSupported: Bool
    var onISO: (Float) -> Void
    var onShutter: (Double) -> Void
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                section("FORMAT", caption: formatCaption) {
                    CaptureFormatPicker(selection: format, onSelect: onFormat)
                }
                section("ASPECT", caption: "默认 3:4，即整幅传感器。其他画幅从中心裁切，取景和成片一致。这些画幅不写 RAW。") {
                    PhotoAspectPicker(selection: aspect, onSelect: onAspect)
                }
                section("ISO", caption: manualSupported ? "锁定这枚镜头的感光度" : "这枚镜头不能单独锁定 ISO 或快门。") {
                    StepValue(
                        text: isoText,
                        canDecrease: isoIndex > 0,
                        canIncrease: isoIndex < isoChoices.count - 1,
                        onDecrease: { stepISO(-1) },
                        onIncrease: { stepISO(1) }
                    )
                }
                section("SHUTTER", caption: "锁定快门时间") {
                    StepValue(
                        text: MeterFormat.shutter(seconds: shutter),
                        canDecrease: shutterIndex > 0,
                        canIncrease: shutterIndex < shutterChoices.count - 1,
                        onDecrease: { stepShutter(-1) },
                        onIncrease: { stepShutter(1) }
                    )
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

    private var formatCaption: String {
        switch format {
        case .jpegAndRaw:
            "默认。苹果的 HEIF/JPEG 和 RAW 作为同一张进相册。拍完不进入编辑。这一档如果不能出 RAW，就只存 HEIF/JPEG。"
        case .raw:
            "DNG 和苹果的 HEIF/JPEG 配成同一张。只存 DNG 时系统相册会拒收。编辑时才从 DNG 显影。"
        case .jpeg:
            "不请求 RAW。这台设备能写 HEIC 时存成 HEIC，否则 JPEG。拍完不进入编辑。"
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

private struct CaptureFormatPicker: View {
    var selection: CaptureFormat
    var onSelect: (CaptureFormat) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CaptureFormat.allCases) { format in
                let selected = format == selection
                Button {
                    onSelect(format)
                } label: {
                    VStack(spacing: 5) {
                        Text(format.title)
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
                .accessibilityLabel(format.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
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
