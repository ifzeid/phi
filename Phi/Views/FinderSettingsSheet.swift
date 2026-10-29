import SwiftUI

/// Capture settings. Every row comes from `SettingsChrome`.
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
        GeometryReader { geo in
            let scale = geo.size.width / SettingsToken.designWidth
            column
                .environment(\.settingsScale, scale)
                .padding(.top, 46)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
        .ignoresSafeArea(edges: .top)
        .background(CameraColor.background.ignoresSafeArea())
        .dynamicTypeSize(.large)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(CameraColor.background)
        .modifier(HiddenSystemChrome())
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "拍摄设置", closeLabel: "关闭设置", onClose: onClose)
            Color.clear.frame(height: SettingsToken.afterHeader)
            SettingsSection(
                title: "处理方式",
                caption: modeCaption,
                captionGap: SettingsToken.modeCaptionGap
            ) {
                SettingsPillGroup(
                    titles: ProcessMode.allCases.map(\.settingsTitle),
                    selection: ProcessMode.allCases.firstIndex(of: mode) ?? 0
                ) { index in
                    onMode(ProcessMode.allCases[index])
                }
            }
            Color.clear.frame(height: SettingsToken.modeCaptionToDivider)
            SettingsDivider()
            Color.clear.frame(height: SettingsToken.dividerToToggle)
            if mode.wantsRaw {
                SettingsToggleRow(title: "同时保存成片", isOn: saveHEIF, onChange: onSaveHEIF)
                if saveHEIF {
                    formatBlock
                }
            } else {
                formatBlock
            }
            Color.clear.frame(height: SettingsToken.formatCaptionToDivider)
            SettingsDivider()
            Color.clear.frame(height: SettingsToken.dividerToAspect)
            SettingsSection(
                title: "画幅",
                caption: "预览与成片使用所选比例；RAW 保留完整画面。",
                captionGap: SettingsToken.aspectCaptionGap
            ) {
                SettingsPillGroup(
                    titles: PhotoAspect.allCases.map(\.title),
                    selection: PhotoAspect.allCases.firstIndex(of: aspect) ?? 0
                ) { index in
                    onAspect(PhotoAspect.allCases[index])
                }
            }
            Color.clear.frame(height: SettingsToken.aspectCaptionToCard)
            SettingsHelpCard(
                title: "处理方式 · 0 / Φ / 1",
                bodyText: "0 · RAW：保留原始数据。\nΦ · ProRAW：保留 Apple ProRAW 数据。\n1 · 标准：只保存苹果处理后的成片。"
            )
            Color.clear.frame(height: 24)
        }
    }

    private var formatBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: SettingsToken.toggleToFormat)
            SettingsPillGroup(
                titles: ProcessedCodec.allCases.map(\.title),
                selection: ProcessedCodec.allCases.firstIndex(of: codec) ?? 0
            ) { index in
                onCodec(ProcessedCodec.allCases[index])
            }
            Color.clear.frame(height: SettingsToken.formatCaptionGap)
            SettingsCaption(text: codecCaption)
        }
    }

    private var codecCaption: String {
        if mode == .standard { return "成片为 HEIC 或 JPEG。" }
        if saveHEIF { return "成片与 RAW 一起保存，方便直接查看和分享。" }
        return "系统相册仍会带上成片作为主图。"
    }

    private var modeCaption: String {
        switch mode {
        case .bayer: "0 · 保留 RAW 原始数据，留给后期更多空间。"
        case .proRaw: "Φ · 保留 Apple ProRAW 数据。"
        case .standard: "1 · 只保存苹果处理后的成片。"
        }
    }
}
