import SwiftUI

/// Locked ISO and shutter. One ruler at a time; the other value stays visible and tappable.
struct ManualExposureSheet: View {
    var iso: Float
    var shutterSeconds: Double
    var isoChoices: [Float]
    var shutterChoices: [Double]
    var editingISO: Bool
    var onEditingISO: (Bool) -> Void
    var onISO: (Float) -> Void
    var onShutter: (Double) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Text(editingISO ? "ISO" : "SHUTTER")
                    .font(CameraFont.interface(17, weight: .medium))
                    .foregroundStyle(CameraColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(editingISO ? isoText(iso) : shutterText(shutterSeconds))
                    .font(CameraFont.parameter(22, medium: true))
                    .foregroundStyle(CameraColor.accent)
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        PhiIcon(symbol: .close, color: CameraColor.textPrimary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭手动曝光")
                }
            }

            if editingISO {
                StepRuler(
                    index: ExposureStops.nearestIndex(to: iso, in: isoChoices),
                    count: max(isoChoices.count, 1),
                    leading: isoChoices.first.map(isoText) ?? "—",
                    trailing: isoChoices.last.map(isoText) ?? "—"
                ) { index in
                    guard isoChoices.indices.contains(index) else { return }
                    onISO(isoChoices[index])
                }
            } else {
                StepRuler(
                    index: ExposureStops.nearestIndex(to: shutterSeconds, in: shutterChoices),
                    count: max(shutterChoices.count, 1),
                    leading: shutterChoices.first.map(shutterText) ?? "—",
                    trailing: shutterChoices.last.map(shutterText) ?? "—"
                ) { index in
                    guard shutterChoices.indices.contains(index) else { return }
                    onShutter(shutterChoices[index])
                }
            }

            HStack(spacing: 12) {
                parameterButton("ISO", value: isoText(iso), selected: editingISO) { onEditingISO(true) }
                parameterButton("S", value: shutterText(shutterSeconds), selected: !editingISO) { onEditingISO(false) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func parameterButton(_ title: String, value: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(CameraFont.interface(11, weight: .medium))
                    .tracking(1.1)
                    .foregroundStyle(CameraColor.textSecondary)
                Text(value)
                    .font(CameraFont.parameter(15, medium: true))
                    .foregroundStyle(selected ? CameraColor.accent : CameraColor.textPrimary)
                Rectangle()
                    .fill(selected ? CameraColor.accent : Color.clear)
                    .frame(width: 18, height: 1.5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func isoText(_ value: Float) -> String {
        value >= 100 ? "\(Int(value.rounded()))" : String(format: "%.0f", value)
    }

    private func shutterText(_ seconds: Double) -> String {
        MeterFormat.shutter(seconds: seconds).replacingOccurrences(of: " S", with: "")
    }
}

/// Index ruler. The needle sits on the selected step, using the same mapping as the drag.
struct StepRuler: View {
    var index: Int
    var count: Int
    var leading: String
    var trailing: String
    var onChange: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let inset: CGFloat = 12
            let x = xPosition(index, width: width, inset: inset)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let steps = max(count - 1, 1)
                    let tickCount = min(count, 25)
                    for tick in 0..<tickCount {
                        let sample = tickCount == 1 ? 0 : Int((Double(tick) / Double(tickCount - 1) * Double(steps)).rounded())
                        let tickX = xPosition(sample, width: size.width, inset: inset)
                        var path = Path()
                        path.move(to: CGPoint(x: tickX, y: 24))
                        path.addLine(to: CGPoint(x: tickX, y: tick == 0 || tick == tickCount - 1 ? 8 : 14))
                        context.stroke(path, with: .color(CameraColor.border), lineWidth: 1)
                    }
                }
                .frame(height: 28)
                Text(leading)
                    .font(CameraFont.parameter(11))
                    .foregroundStyle(CameraColor.textSecondary)
                    .position(x: inset + 18, y: 46)
                Text(trailing)
                    .font(CameraFont.parameter(11))
                    .foregroundStyle(CameraColor.textSecondary)
                    .position(x: width - inset - 18, y: 46)
                Rectangle()
                    .fill(CameraColor.accent)
                    .frame(width: 2, height: 26)
                    .position(x: x, y: 13)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onChange(index(at: gesture.location.x, width: width, inset: inset))
                    }
            )
        }
        .frame(height: 64)
        .accessibilityElement()
        .accessibilityValue("\(index + 1) of \(max(count, 1))")
        .accessibilityAdjustableAction { direction in
            let next = index + (direction == .increment ? 1 : -1)
            onChange(min(max(next, 0), max(count - 1, 0)))
        }
    }

    private func xPosition(_ index: Int, width: CGFloat, inset: CGFloat) -> CGFloat {
        let usable = max(width - inset * 2, 1)
        guard count > 1 else { return inset + usable / 2 }
        let fraction = CGFloat(min(max(index, 0), count - 1)) / CGFloat(count - 1)
        return inset + fraction * usable
    }

    private func index(at x: CGFloat, width: CGFloat, inset: CGFloat) -> Int {
        let usable = max(width - inset * 2, 1)
        let fraction = min(max((x - inset) / usable, 0), 1)
        guard count > 1 else { return 0 }
        return Int((fraction * CGFloat(count - 1)).rounded())
    }
}
