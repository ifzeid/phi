import SwiftUI

/// Halide is only the layout: shutter ticks along the top, ISO ticks down the right, a small badge in the corner.
/// The ticks are the Quiet Finder ivory monospace, not a copy of another camera's artwork.
struct ExposureBadge: View {
    var automatic: Bool
    var iso: String
    var shutter: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if automatic {
                Text("AUTO")
                    .font(CameraFont.parameter(12, medium: true))
            } else {
                Text(iso)
                    .font(CameraFont.parameter(12, medium: true))
                Text(shutter)
                    .font(CameraFont.parameter(11, medium: true))
            }
        }
        .foregroundStyle(CameraColor.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(automatic ? "自动曝光" : "手动曝光 \(iso) \(shutter)")
    }
}

struct ManualTickScale: View {
    var labels: [String]
    var index: Int
    var horizontal: Bool
    var onSelect: (Int) -> Void

    @State private var drag = DragBase()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in
                    let span = horizontal ? size.width : size.height
                    let mid = span / 2
                    let step: CGFloat = 14
                    for offset in labels.indices {
                        let delta = CGFloat(offset - index) * step
                        let position = mid + (horizontal ? delta : -delta)
                        if position < -10 || position > span + 10 { continue }
                        let selected = offset == index
                        let height: CGFloat = selected ? 16 : (offset % 3 == 0 ? 10 : 6)
                        var path = Path()
                        if horizontal {
                            path.move(to: CGPoint(x: position, y: 0))
                            path.addLine(to: CGPoint(x: position, y: height))
                        } else {
                            path.move(to: CGPoint(x: size.width, y: position))
                            path.addLine(to: CGPoint(x: size.width - height, y: position))
                        }
                        let color = selected ? CameraColor.textPrimary : CameraColor.textSecondary.opacity(0.8)
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: selected ? 1.2 : 0.8, lineCap: .round))
                    }
                }
                if labels.indices.contains(index) {
                    Text(labels[index])
                        .font(CameraFont.parameter(12, medium: true))
                        .foregroundStyle(CameraColor.textPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: horizontal ? .bottom : .leading)
                        .padding(.bottom, horizontal ? 2 : 0)
                        .padding(.leading, horizontal ? 0 : 2)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard labels.isEmpty == false else { return }
                    if drag.index == nil { drag.index = index }
                    let base = drag.index ?? index
                    let travel = horizontal ? value.translation.width : -value.translation.height
                    let steps = Int((travel / 14).rounded())
                    let next = min(max(base + steps, 0), labels.count - 1)
                    if next != index { onSelect(next) }
                }
                .onEnded { _ in
                    drag.index = nil
                }
        )
        .accessibilityLabel(horizontal ? "快门" : "感光度")
        .accessibilityValue(labels.indices.contains(index) ? labels[index] : "")
    }
}

private final class DragBase {
    var index: Int?
}
