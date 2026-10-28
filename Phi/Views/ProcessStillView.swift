import SwiftUI

/// Post-capture develop surface. Exposure here changes the rendered still, not the camera meter.
/// Grain is a named look. The original RAW file is never rewritten.
struct ProcessStillView: View {
    @ObservedObject var session: ProcessSession
    var canRetryOriginal: Bool
    var onExport: () -> Void
    var onRetryOriginal: () -> Void
    var onClose: () -> Void

    private let developRange: ClosedRange<Double> = -2...2

    var body: some View {
        ZStack {
            CameraColor.background.ignoresSafeArea()
            VStack(spacing: 0) {
                image
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                panel
            }
        }
        .preferredColorScheme(.dark)
    }

    private var image: some View {
        ZStack {
            CameraColor.background
            if let preview = session.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            } else {
                ProgressView()
                    .tint(CameraColor.accent)
                    .accessibilityLabel("正在生成预览")
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Text("Exposure")
                    .font(CameraFont.interface(17, weight: .medium))
                    .foregroundStyle(CameraColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ExposureFormat.signedDecimal(session.exposureEV))
                        .font(CameraFont.parameter(22, medium: true))
                    Text("EV")
                        .font(CameraFont.parameter(12, medium: true))
                }
                .foregroundStyle(CameraColor.accent)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Develop exposure \(ExposureFormat.signedDecimal(session.exposureEV)) EV")
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        PhiIcon(symbol: .close, color: CameraColor.textPrimary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
            }

            ExposureRuler(
                value: session.exposureEV,
                range: developRange,
                onChange: { session.setExposure($0) },
                onCommit: {}
            )

            Text("DEVELOP")
                .font(CameraFont.interface(11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(CameraColor.textSecondary)
                .accessibilityLabel("这是成片曝光，不是相机测光")

            Text("STYLE")
                .font(CameraFont.interface(11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(CameraColor.textSecondary)
            ColorLookPicker(selection: session.colorLook) { session.setColorLook($0) }
            Text("HALO")
                .font(CameraFont.interface(11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(CameraColor.textSecondary)
            HaloToggle(enabled: session.halo) { session.setHalo($0) }
            Text("只在处理页。正片、负片、黑白互斥。光晕可叠在任何一档上，包括无。没有强度。")
                .font(CameraFont.interface(12))
                .foregroundStyle(CameraColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("GRAIN")
                .font(CameraFont.interface(11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(CameraColor.textSecondary)
            GrainStylePicker(selection: session.style) { session.setStyle($0) }
            Text("颗粒在色貌之后。打开就是 FINE，没有强度。取景不加颗粒。")
                .font(CameraFont.interface(12))
                .foregroundStyle(CameraColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(session.developInfo)
                .font(CameraFont.parameter(11))
                .foregroundStyle(CameraColor.textSecondary)
                .accessibilityLabel(session.developInfo)

            Button(action: onExport) {
                Text(session.isExporting ? "正在导出" : "保存处理图")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(session.isExporting || session.preview == nil || (session.sourceDNG == nil && session.isSample == false))
            .accessibilityHint("从 DNG 显影导出 HEIF。不改写相册里的原片。")

            if canRetryOriginal, session.isSample == false {
                Button("重试保存原片", action: onRetryOriginal)
                    .font(CameraFont.interface(13, weight: .medium))
                    .foregroundStyle(CameraColor.textSecondary)
                    .frame(minHeight: 44)
            }

            if let status = session.status {
                Text(status)
                    .font(CameraFont.interface(13))
                    .foregroundStyle(CameraColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
