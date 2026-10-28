import SwiftUI

/// Off, or the single FINE recipe. No other presets and no intensity control.
struct GrainStylePicker: View {
    var selection: GrainStyle
    var onSelect: (GrainStyle) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(GrainStyle.allCases) { style in
                let selected = style == selection
                Button {
                    onSelect(style)
                } label: {
                    VStack(spacing: 5) {
                        Text(style.title)
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
                .accessibilityLabel(style == .off ? "关闭颗粒" : "FINE 颗粒")
                .accessibilityHint("只在编辑时生效，配方已固定")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}
