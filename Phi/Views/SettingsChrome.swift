import SwiftUI

/// Capture settings, measured from Figma `101:338` (390×844).
/// Vertical sizes stay in points. Horizontal padding and pill tracks scale with the screen width.
enum SettingsToken {
    static let designWidth: CGFloat = 390
    static let pageInset: CGFloat = 20
    static let pillGap: CGFloat = 8
    static let pillHeight: CGFloat = 44
    static let pillRadius: CGFloat = 22
    static let controlRowHeight: CGFloat = 44
    static let toggleRowHeight: CGFloat = 48
    static let switchWidth: CGFloat = 42
    static let switchHeight: CGFloat = 26
    static let headerHeight: CGFloat = 44
    static let closeLeading: CGFloat = 14
    static let titleGap: CGFloat = 20
    static let sectionLine: CGFloat = 19
    static let rowLine: CGFloat = 23
    static let cardTitleLine: CGFloat = 20
    static let cardBodyLine: CGFloat = 19
    static let cardHeight: CGFloat = 126
    static let cardRadius: CGFloat = 14
    static let cardInset: CGFloat = 16
    static let cardTitleTop: CGFloat = 14
    static let afterHeader: CGFloat = 24
    static let headerToControls: CGFloat = 11
    static let modeCaptionGap: CGFloat = 8
    static let modeCaptionToDivider: CGFloat = 28
    static let dividerToToggle: CGFloat = 19
    static let toggleToFormat: CGFloat = 5
    static let formatCaptionGap: CGFloat = 10
    static let formatCaptionToDivider: CGFloat = 33
    static let dividerToAspect: CGFloat = 21
    static let aspectCaptionGap: CGFloat = 13
    static let aspectCaptionToCard: CGFloat = 28

    static func sectionFont() -> Font { CameraFont.fixed(13, weight: .regular) }
    static func rowFont() -> Font { CameraFont.fixed(16, weight: .regular) }
    static func pillFont() -> Font { CameraFont.fixed(13, weight: .medium) }
    static func titleFont() -> Font { CameraFont.fixed(14, weight: .medium) }
    static func cardTitleFont() -> Font { CameraFont.fixed(14, weight: .medium) }
    static func cardBodyFont() -> Font { CameraFont.fixed(13, weight: .regular) }
}

private struct SettingsScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var settingsScale: CGFloat {
        get { self[SettingsScaleKey.self] }
        set { self[SettingsScaleKey.self] = newValue }
    }
}

struct SettingsHeader: View {
    var title: String
    var closeLabel: String
    var onClose: () -> Void
    @Environment(\.settingsScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            NativeCloseButton(label: closeLabel, action: onClose)
                .frame(width: SettingsToken.headerHeight, height: SettingsToken.headerHeight)
            Text(title)
                .font(SettingsToken.titleFont())
                .foregroundStyle(CameraColor.textPrimary)
                .frame(height: SettingsToken.cardTitleLine)
                .padding(.leading, SettingsToken.titleGap * scale)
            Spacer(minLength: 0)
        }
        .padding(.leading, SettingsToken.closeLeading * scale)
        .frame(height: SettingsToken.headerHeight)
    }
}

struct SettingsSection<Content: View>: View {
    var title: String
    var caption: String
    var captionGap: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCaption(text: title)
            Color.clear.frame(height: SettingsToken.headerToControls)
            content()
            Color.clear.frame(height: captionGap)
            SettingsCaption(text: caption)
        }
    }
}

struct SettingsCaption: View {
    var text: String
    @Environment(\.settingsScale) private var scale

    var body: some View {
        Text(text)
            .font(SettingsToken.sectionFont())
            .foregroundStyle(CameraColor.textSecondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SettingsToken.sectionLine)
            .padding(.horizontal, SettingsToken.pageInset * scale)
    }
}

struct SettingsRow<Content: View>: View {
    var height: CGFloat = SettingsToken.controlRowHeight
    @ViewBuilder var content: () -> Content
    @Environment(\.settingsScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, SettingsToken.pageInset * scale)
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

struct SettingsToggleRow: View {
    var title: String
    var isOn: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        SettingsRow(height: SettingsToken.toggleRowHeight) {
            Text(title)
                .font(SettingsToken.rowFont())
                .foregroundStyle(CameraColor.textPrimary)
                .frame(height: SettingsToken.rowLine)
            Spacer(minLength: 8)
            SettingsSwitch(isOn: isOn, onChange: onChange)
        }
    }
}

struct SettingsSwitch: View {
    var isOn: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        Capsule()
            .fill(isOn ? CameraColor.accent : CameraColor.border)
            .frame(width: SettingsToken.switchWidth, height: SettingsToken.switchHeight)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(CameraColor.textPrimary)
                    .frame(width: 22, height: 22)
                    .padding(.horizontal, 2)
            }
            .frame(width: SettingsToken.switchWidth, height: SettingsToken.switchHeight)
            .contentShape(Capsule())
            .onTapGesture { onChange(!isOn) }
            .accessibilityLabel(isOn ? "已打开" : "已关闭")
            .accessibilityAddTraits(.isButton)
    }
}

struct SettingsPillGroup: View {
    var titles: [String]
    var selection: Int
    var onSelect: (Int) -> Void
    @Environment(\.settingsScale) private var scale

    var body: some View {
        HStack(spacing: SettingsToken.pillGap * scale) {
            ForEach(titles.indices, id: \.self) { index in
                let selected = index == selection
                Button {
                    onSelect(index)
                } label: {
                    Text(titles[index])
                        .font(SettingsToken.pillFont())
                        .foregroundStyle(selected ? CameraColor.accent : CameraColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .buttonStyle(PillPlateStyle(
                    fill: selected ? CameraColor.surface : CameraColor.background,
                    width: nil,
                    height: SettingsToken.pillHeight
                ))
                .accessibilityLabel(titles[index])
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, SettingsToken.pageInset * scale)
        .frame(height: SettingsToken.controlRowHeight)
    }
}

struct SettingsDivider: View {
    @Environment(\.settingsScale) private var scale

    var body: some View {
        Rectangle()
            .fill(CameraColor.border)
            .frame(height: 1)
            .padding(.horizontal, SettingsToken.pageInset * scale)
    }
}

struct SettingsHelpCard: View {
    var title: String
    var bodyText: String
    @Environment(\.settingsScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SettingsToken.cardTitleFont())
                .foregroundStyle(CameraColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: SettingsToken.cardTitleLine)
            Text(bodyText)
                .font(SettingsToken.cardBodyFont())
                .foregroundStyle(CameraColor.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: SettingsToken.cardBodyLine * 3, alignment: .top)
        }
        .padding(.horizontal, SettingsToken.cardInset * scale)
        .padding(.top, SettingsToken.cardTitleTop)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: SettingsToken.cardHeight, alignment: .top)
        .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: SettingsToken.cardRadius, style: .continuous))
        .padding(.horizontal, SettingsToken.pageInset * scale)
    }
}
