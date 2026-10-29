import SwiftUI

/// EV ruler from −5…+5. Major marks every 1 EV, one minor mark at each half stop. The needle uses the same value as the number.
struct ExposureSheet: View {
    var ev: Double
    var range: ClosedRange<Double>
    var autoExposure: Bool
    var onEV: (Double) -> Void
    var onCommit: () -> Void
    var onAuto: (Bool) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                Text("Exposure")
                    .font(CameraFont.interface(17, weight: .medium))
                    .foregroundStyle(CameraColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ExposureFormat.signedDecimal(ev))
                        .font(CameraFont.parameter(22, medium: true))
                    Text("EV")
                        .font(CameraFont.parameter(12, medium: true))
                }
                .foregroundStyle(CameraColor.accent)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Exposure \(ExposureFormat.signedDecimal(ev)) EV")
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        PhiIcon(symbol: .close, color: CameraColor.textPrimary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭曝光")
                }
            }

            ExposureRuler(value: ev, range: range, onChange: onEV, onCommit: onCommit)

            HStack(alignment: .center) {
                Text("AUTO EXPOSURE")
                    .font(CameraFont.interface(11, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(CameraColor.textSecondary)
                Spacer()
                Toggle("Auto exposure", isOn: Binding(get: { autoExposure }, set: onAuto))
                    .labelsHidden()
                    .tint(CameraColor.accent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct ExposureRuler: View {
    var value: Double
    var range: ClosedRange<Double>
    var onChange: (Double) -> Void
    var onCommit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let inset: CGFloat = 10
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let steps = max(Int(((range.upperBound - range.lowerBound) / 0.5).rounded()), 1)
                    for index in 0...steps {
                        let sample = range.lowerBound + Double(index) * 0.5
                        let x = xPosition(sample, width: size.width, inset: inset)
                        let major = index % 2 == 0
                        let height: CGFloat = major ? 16 : 11
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: 24))
                        tick.addLine(to: CGPoint(x: x, y: 24 - height))
                        context.stroke(
                            tick,
                            with: .color(major ? CameraColor.textSecondary : CameraColor.border),
                            lineWidth: major ? 1.25 : 1
                        )
                    }
                }
                .frame(height: 28)

                ForEach(tickValues, id: \.self) { tick in
                    Text(ExposureFormat.tick(tick))
                        .font(CameraFont.parameter(11))
                        .foregroundStyle(CameraColor.textSecondary)
                        .position(x: xPosition(Double(tick), width: width, inset: inset), y: 44)
                }

                Rectangle()
                    .fill(CameraColor.accent)
                    .frame(width: 2, height: 26)
                    .position(x: xPosition(value, width: width, inset: inset), y: 13)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onChange(value(at: gesture.location.x, width: width, inset: inset))
                    }
                    .onEnded { _ in
                        onCommit()
                    }
            )
        }
        .frame(height: 64)
        .accessibilityElement()
        .accessibilityLabel("Exposure")
        .accessibilityValue("\(ExposureFormat.signedDecimal(value)) EV")
        .accessibilityAdjustableAction { direction in
            let next = value + (direction == .increment ? 0.1 : -0.1)
            let clamped = min(max(next, range.lowerBound), range.upperBound)
            onChange((clamped * 10).rounded() / 10)
            onCommit()
        }
    }

    private var tickValues: [Int] {
        let lower = Int(ceil(range.lowerBound - 0.001))
        let upper = Int(floor(range.upperBound + 0.001))
        guard upper >= lower else { return [] }
        return Array(lower...upper)
    }

    private func xPosition(_ sample: Double, width: CGFloat, inset: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let usable = max(width - inset * 2, 1)
        guard span > 0 else { return width / 2 }
        let fraction = (sample - range.lowerBound) / span
        return inset + CGFloat(fraction) * usable
    }

    private func value(at x: CGFloat, width: CGFloat, inset: CGFloat) -> Double {
        let usable = max(width - inset * 2, 1)
        let fraction = min(max((x - inset) / usable, 0), 1)
        let raw = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        let stepped = (raw * 10).rounded() / 10
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

#Preview("Needle at −0.3") {
    ZStack(alignment: .bottom) {
        CameraColor.background.ignoresSafeArea()
        ExposureSheet(
            ev: -0.3,
            range: -5...5,
            autoExposure: true,
            onEV: { _ in },
            onCommit: {},
            onAuto: { _ in },
            onClose: {}
        )
        .padding(.bottom, 140)
    }
}
