import SwiftUI
import UIKit

/// 88 pt mechanical ruler. The red needle stays put. The tape moves under the finger.
/// Major ticks are 2×20 ivory, half ticks 1×13, fine ticks 1×6 grey.
struct CalibratedRuler: View {
    var leading: String
    var valueText: String
    var trailing: String
    var leadingMono: Bool = true
    var onLeading: (() -> Void)?
    var onTrailing: (() -> Void)?
    var value: Double
    var lower: Double
    var upper: Double
    var pointsPerUnit: CGFloat
    var fineStep: Double
    var majorEvery: Double
    var zeroMark: Bool
    var emphasizeNearestLabel: Bool
    var label: (Double) -> String
    var snap: (Double) -> Double
    var onChange: (Double) -> Void
    var onCommit: () -> Void

    @State private var live: Double?
    @State private var origin: Double = 0
    @State private var lastSent: Double?
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)

    private var shown: Double { live ?? value }

    var body: some View {
        ZStack(alignment: .top) {
            tickCanvas
            VStack(spacing: 0) {
                header
                    .frame(height: 40)
                Color.clear
                    .frame(height: 48)
                    .contentShape(Rectangle())
                    .gesture(drag)
            }
        }
        .frame(height: 88)
        .onAppear { haptic.prepare() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(leading)
        .accessibilityValue(valueText)
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 0) {
                headerControl(leading, mono: leadingMono, action: onLeading)
                Spacer(minLength: 8)
                headerControl(trailing, mono: true, action: onTrailing)
            }
            Text(valueText)
                .font(CameraFont.parameter(18))
                .foregroundStyle(CameraColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.top, 5)
    }

    private func headerControl(_ title: String, mono: Bool, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Text(title)
                .font(mono ? CameraFont.parameter(12) : CameraFont.interface(12))
                .foregroundStyle(CameraColor.textSecondary)
                .lineLimit(1)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private var tickCanvas: some View {
        Canvas { context, size in
            drawTicks(&context, size: size)
        }
        .allowsHitTesting(false)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                let scale = Double(pointsPerUnit)
                guard scale > 0 else { return }
                if live == nil {
                    origin = value
                    lastSent = snap(value)
                }
                let raw = origin - Double(gesture.translation.width) / scale
                let limited = min(max(raw, lower), upper)
                live = limited
                let next = snap(limited)
                guard next != lastSent else { return }
                lastSent = next
                onChange(next)
                haptic.impactOccurred(intensity: 0.45)
                haptic.prepare()
            }
            .onEnded { _ in
                let next = snap(live ?? value)
                live = nil
                lastSent = nil
                onChange(next)
                onCommit()
            }
    }

    private func drawTicks(_ context: inout GraphicsContext, size: CGSize) {
        let step = fineStep
        guard step > 0.00001, pointsPerUnit > 0, majorEvery > 0 else { return }
        let midX = size.width / 2
        let position = shown
        let reach = Double((size.width / 2 + 48) / pointsPerUnit)
        let first = Int(((position - reach) / step).rounded(.down))
        let last = Int(((position + reach) / step).rounded(.up))
        let majorCount = max(Int((majorEvery / step).rounded()), 1)
        let halfCount = majorCount / 2
        guard last >= first else { return }
        for index in first...last {
            let tick = Double(index) * step
            let x = midX + CGFloat(tick - position) * pointsPerUnit
            if x < -12 || x > size.width + 12 { continue }
            let slot = positiveMod(index, majorCount)
            let kind = tickKind(slot: slot, halfCount: halfCount)
            let tickWidth: CGFloat = kind == .major ? 2 : 1
            let tickHeight: CGFloat = kind == .major ? 20 : (kind == .half ? 13 : 6)
            let ink = kind == .major ? CameraColor.textPrimary : CameraColor.textSecondary
            let bar = CGRect(x: x - tickWidth / 2, y: 42, width: tickWidth, height: tickHeight)
            context.fill(Path(roundedRect: bar, cornerRadius: 0.5), with: .color(ink))
            if kind == .major {
                let majorTick = (tick / majorEvery).rounded() * majorEvery
                let caption = Text(label(majorTick)).font(CameraFont.parameter(11))
                let nearNeedle = abs(tick - position) < majorEvery * 0.35
                let captionInk = (emphasizeNearestLabel && nearNeedle) ? CameraColor.textPrimary : CameraColor.textSecondary
                context.draw(caption.foregroundColor(captionInk), at: CGPoint(x: x, y: 73), anchor: .center)
            }
            if zeroMark && abs(tick) < step * 0.45 {
                let dot = CGRect(x: x - 2, y: 34, width: 4, height: 4)
                context.fill(Path(ellipseIn: dot), with: .color(CameraColor.textSecondary))
            }
        }
        let needle = CGRect(x: midX - 1.5, y: 36, width: 3, height: 28)
        context.fill(Path(roundedRect: needle, cornerRadius: 1.5), with: .color(CameraColor.accent))
    }

    private func tickKind(slot: Int, halfCount: Int) -> TickKind {
        if slot == 0 { return .major }
        if halfCount > 0 && slot == halfCount { return .half }
        return .fine
    }

    private func positiveMod(_ value: Int, _ modulus: Int) -> Int {
        guard modulus > 0 else { return 0 }
        let raw = value % modulus
        if raw >= 0 { return raw }
        return raw + modulus
    }

    private enum TickKind {
        case major
        case half
        case fine
    }
}
