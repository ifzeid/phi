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

/// Shared Quiet Finder tick scale. Exposure compensation, shutter, and ISO use the same ivory ticks.
struct QuietTickScale: View {
    var label: String
    var index: Int
    var count: Int
    var horizontal: Bool
    /// When set, a drag moves the center tick. Exposure compensation leaves this nil and is driven by the viewfinder.
    var onSelect: ((Int) -> Void)?

    @State private var drag = DragBase()
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Canvas { context, size in
                    let span = horizontal ? size.width : size.height
                    let mid = span / 2
                    let step: CGFloat = 14
                    let upper = max(count - 1, 0)
                    for offset in 0...upper {
                        let delta = CGFloat(offset - index) * step
                        let position = mid + (horizontal ? delta : -delta)
                        if position < -12 || position > span + 12 { continue }
                        let selected = offset == index
                        let major = offset % 5 == 0
                        let length: CGFloat = selected ? 18 : (major ? 11 : 6)
                        var path = Path()
                        if horizontal {
                            path.move(to: CGPoint(x: position, y: 0))
                            path.addLine(to: CGPoint(x: position, y: length))
                        } else {
                            path.move(to: CGPoint(x: size.width, y: position))
                            path.addLine(to: CGPoint(x: size.width - length, y: position))
                        }
                        let color = selected ? CameraColor.textPrimary : CameraColor.textSecondary.opacity(major ? 0.9 : 0.55)
                        context.stroke(
                            path,
                            with: .color(color),
                            style: StrokeStyle(lineWidth: selected ? 1.2 : 0.8, lineCap: .round)
                        )
                    }
                }
                .allowsHitTesting(false)
                Text(label)
                    .font(CameraFont.parameter(12, medium: true))
                    .foregroundStyle(CameraColor.textPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: horizontal ? .bottom : .leading)
                    .padding(.bottom, horizontal ? 2 : 0)
                    .padding(.leading, horizontal ? 0 : 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onAppear { haptic.prepare() }
        .onChange(of: index) { _, _ in
            haptic.impactOccurred(intensity: 0.45)
            haptic.prepare()
        }
        .accessibilityLabel(horizontal ? "快门" : "刻度")
        .accessibilityValue(label)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let onSelect, count > 0 else { return }
                if drag.index == nil { drag.index = index }
                let base = drag.index ?? index
                let travel = horizontal ? value.translation.width : -value.translation.height
                let steps = Int((travel / 14).rounded())
                let next = min(max(base + steps, 0), count - 1)
                if next != index { onSelect(next) }
            }
            .onEnded { _ in
                drag.index = nil
            }
    }
}

private final class DragBase {
    var index: Int?
}
