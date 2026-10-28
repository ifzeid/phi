import SwiftUI

/// Numbers are measured 35mm equivalents, not a promise of three prime lenses.
struct FocalLengthPicker: View {
    var stops: [FocalStop]
    var selectedID: String?
    var onSelect: (FocalStop) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(stops) { stop in
                let selected = stop.id == selectedID
                Button {
                    onSelect(stop)
                } label: {
                    Text("\(stop.millimeters)")
                        .font(CameraFont.parameter(15, medium: selected))
                        .foregroundStyle(selected ? CameraColor.accent : CameraColor.textPrimary)
                        .frame(width: 56, height: 36)
                        .background {
                            if selected {
                                Circle()
                                    .fill(CameraColor.surface)
                                    .frame(width: 32, height: 32)
                            }
                        }
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(stop.millimeters) 毫米")
                .accessibilityHint(stop.isOpticalStep ? "这枚镜头的原生视角" : "主摄 2× 裁切")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.88))
                .frame(height: 36)
        }
        .accessibilityElement(children: .contain)
    }
}
