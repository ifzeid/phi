import SwiftUI
import UIKit

/// 88 pt mechanical ruler (Figma 124:628). The red 2×22 needle stays put. The tape moves under the finger.
/// All ticks are 1 pt at 55%: whole units 12 pt, half units 9 pt, fine ticks 6 pt. Labels are integers only.
/// `gridStep` is the walk step; a tick is drawn where the value is a multiple of `fineStep`, a half or a whole unit.
/// Double-tap calls `onReset`.
/// `hapticEvery` limits the click to those units. Zero clicks on every snap.
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
    /// Haptic only when the needle crosses a multiple of this. 0 clicks on every snapped step.
    var hapticEvery: Double = 0
    /// Walk step for drawing. Defaults to `fineStep`. Use 0.1 with fine 0.2 so the half stop lands on the grid.
    var gridStep: Double? = nil
    var zeroMark: Bool
    var showsLabels: Bool = true
    var height: CGFloat = 88
    var emphasizeNearestLabel: Bool
    var label: (Double) -> String
    var snap: (Double) -> Double
    var onChange: (Double) -> Void
    var onCommit: () -> Void
    var onReset: (() -> Void)? = nil

    @State private var live: Double?
    @State private var origin: Double = 0
    @State private var lastSent: Double?
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)

    private var shown: Double { live ?? value }

    private var marks: CalibratedRulerMetrics.Marks { CalibratedRulerMetrics.marks(for: height) }

    var body: some View {
        ZStack(alignment: .top) {
            tickCanvas
            VStack(spacing: 0) {
                header
                    .frame(height: marks.headerHeight)
                Color.clear
                    .frame(height: max(height - marks.headerHeight, 12 * marks.scale))
                    .contentShape(Rectangle())
                    .gesture(drag)
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        guard let onReset else { return }
                        live = nil
                        lastSent = nil
                        onReset()
                        haptic.impactOccurred(intensity: 0.45)
                    })
            }
        }
        .frame(height: height)
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
                .font(CameraFont.parameter(16))
                .foregroundStyle(CameraColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(height: marks.headerTextHeight)
        .padding(.top, marks.headerPaddingTop)
        .frame(height: marks.headerHeight, alignment: .top)
    }

    private func headerControl(_ title: String, mono: Bool, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Text(title)
                .font(mono ? CameraFont.parameter(12) : CameraFont.interface(12))
                .foregroundStyle(CameraColor.textSecondary)
                .lineLimit(1)
                .frame(height: marks.headerTextHeight)
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
                let previous = lastSent ?? next
                lastSent = next
                onChange(next)
                if hapticEvery <= 0 || Self.crossedMark(previous, next, every: hapticEvery) {
                    haptic.impactOccurred(intensity: 0.45)
                    haptic.prepare()
                }
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
        let step = gridStep ?? fineStep
        guard step > 0.00001, fineStep > 0.00001, pointsPerUnit > 0, majorEvery > 0 else { return }
        let midX = size.width / 2
        let position = shown
        let reach = Double((size.width / 2 + 48) / pointsPerUnit)
        let first = Int(((max(position - reach, lower - step)) / step).rounded(.down))
        let last = Int(((min(position + reach, upper + step)) / step).rounded(.up))
        guard last >= first else { return }
        let fineInk = CameraColor.border.opacity(0.55)
        let majorInk = CameraColor.border.opacity(0.85)
        for index in first...last {
            let tick = Double(index) * step
            if tick < lower - step * 0.5 || tick > upper + step * 0.5 { continue }
            let x = midX + CGFloat(tick - position) * pointsPerUnit
            if x < -12 || x > size.width + 12 { continue }
            guard let kind = tickKind(tick) else { continue }
            let tickHeight: CGFloat = kind == .major ? marks.tickMajor : (kind == .half ? marks.tickHalf : marks.tickFine)
            let bar = CGRect(x: x - 0.5, y: marks.tickY, width: 1, height: tickHeight)
            context.fill(Path(roundedRect: bar, cornerRadius: 0.5), with: .color(kind == .major ? majorInk : fineInk))
            if kind == .major, showsLabels {
                let majorTick = (tick / majorEvery).rounded() * majorEvery
                let caption = Text(label(majorTick)).font(CameraFont.parameter(11))
                let nearNeedle = abs(tick - position) < majorEvery * 0.35
                let captionInk = (emphasizeNearestLabel && nearNeedle) ? CameraColor.textPrimary : CameraColor.textSecondary
                context.draw(caption.foregroundColor(captionInk), at: CGPoint(x: x, y: marks.labelY), anchor: .center)
            }
            if zeroMark && abs(tick) < step * 0.45 {
                let dotSize = marks.zeroDotSize
                let dot = CGRect(x: x - dotSize / 2, y: marks.zeroDotY, width: dotSize, height: dotSize)
                context.fill(Path(ellipseIn: dot), with: .color(CameraColor.textSecondary))
            }
        }
        let needle = CGRect(x: midX - marks.needleWidth / 2, y: marks.needleY, width: marks.needleWidth, height: marks.needleHeight)
        context.fill(Path(roundedRect: needle, cornerRadius: 1.5), with: .color(CameraColor.accent))
    }

    private func tickKind(_ tick: Double) -> TickKind? {
        if Self.isMultiple(tick, of: majorEvery) { return .major }
        if Self.isMultiple(tick, of: majorEvery / 2) { return .half }
        if Self.isMultiple(tick, of: fineStep) { return .fine }
        return nil
    }

    private static func isMultiple(_ value: Double, of unit: Double) -> Bool {
        guard unit > 0 else { return false }
        let ratio = value / unit
        return abs(ratio - ratio.rounded()) < 0.001
    }

    /// True when `next` lands on or passes a multiple of `every` that `previous` had not.
    private static func crossedMark(_ previous: Double, _ next: Double, every: Double) -> Bool {
        guard every > 0 else { return true }
        let low = min(previous, next)
        let high = max(previous, next)
        let first = Int((low / every).rounded(.down))
        let last = Int((high / every).rounded(.down))
        if first != last { return true }
        let onMark = abs(next / every - (next / every).rounded()) < 0.0001
        let wasMark = abs(previous / every - (previous / every).rounded()) < 0.0001
        return onMark && wasMark == false
    }

    private enum TickKind {
        case major
        case half
        case fine
    }
}
