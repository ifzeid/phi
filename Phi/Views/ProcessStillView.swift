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

            Text("GRAIN")
                .font(CameraFont.interface(11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(CameraColor.textSecondary)
            GrainStylePicker(selection: session.style) { session.setStyle($0) }
            Text("只在这里。打开就是 FINE，没有强度。取景不加颗粒，也不加光晕。")
                .font(CameraFont.interface(12))
                .foregroundStyle(CameraColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onExport) {
                Text(session.isExporting ? "正在导出" : "保存处理图")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(session.isExporting || session.preview == nil)
            .accessibilityHint("导出 HEIC 或 JPEG。不改写 RAW 原片。")

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

#Preview("Process") {
    ProcessStillView(
        session: ProcessSession.syntheticPreview(),
        canRetryOriginal: false,
        onExport: {},
        onRetryOriginal: {},
        onClose: {}
    )
}
