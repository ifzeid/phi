import SwiftUI

/// Discrete looks only. There is no amount, size, or strength control.
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
                            .font(CameraFont.interface(11, weight: selected ? .semibold : .regular))
                            .tracking(0.8)
                            .foregroundStyle(selected ? CameraColor.accent : CameraColor.textSecondary)
                            .lineLimit(1)
                        Rectangle()
                            .fill(selected ? CameraColor.accent : Color.clear)
                            .frame(width: 14, height: 1.5)
                    }
                    .frame(minWidth: 64, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style == .natural ? "自然，不加颗粒" : "颗粒风格 \(style.title)")
                .accessibilityHint("命名风格，配方已固定")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}
