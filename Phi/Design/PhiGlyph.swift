import AVFoundation
import SwiftUI

/// 24 pt glyphs from the Figma 102:268 icon set, inside a 44 pt hit target.
enum PhiGlyph: String {
    case back = "phi_back"
    case check = "phi_check"
    case chevron = "phi_chevron"
    case close = "phi_close"
    case compare = "phi_compare"
    case effects = "phi_effects"
    case exposure = "phi_exposure"
    case flashAuto = "phi_flash_auto"
    case flashOff = "phi_flash_off"
    case flashOn = "phi_flash_on"
    case gridOff = "phi_grid_off"
    case gridOn = "phi_grid_on"
    case missing = "phi_missing"
    case reset = "phi_reset"
    case settings = "phi_settings"
    case share = "phi_share"
    case style = "phi_style"
    case trash = "phi_trash"
}

struct PhiGlyphButton: View {
    var glyph: PhiGlyph
    var label: String
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            PhiGlyphImage(glyph: glyph)
                .foregroundStyle(enabled ? CameraColor.textPrimary : CameraColor.textSecondary.opacity(0.45))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(enabled == false)
        .accessibilityLabel(label)
    }
}

struct PhiGlyphImage: View {
    var glyph: PhiGlyph

    var body: some View {
        Image(glyph.rawValue)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 24, height: 24)
    }
}

/// Ivory disc in a #707675 ring. Red is not used on the shutter.
struct WhiteShutterButton: View {
    var isReady: Bool
    var isCapturing: Bool
    var action: () -> Void

    private var canTap: Bool { isReady && isCapturing == false }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(CameraColor.shutterRing, lineWidth: 1.5)
                    .frame(width: 76.5, height: 76.5)
                Circle()
                    .fill(CameraColor.textPrimary)
                    .frame(width: 64, height: 64)
            }
            .frame(width: 80, height: 80)
            .opacity(isReady ? 1 : 0.4)
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(canTap == false)
        .accessibilityLabel("快门")
        .accessibilityHint(isReady ? "拍摄一张静帧" : "相机还不能拍摄")
    }
}

/// Red corner frame sized by its parent. On the 3:4 finder that parent is the centre thirds cell, 130×174.
/// Locked state adds the AE/AF LOCK line. There is no centre circle.
struct FocusBracket: View {
    var locked: Bool

    var body: some View {
        GeometryReader { geo in
            let arm = min(CGFloat(29), geo.size.width * 0.24, geo.size.height * 0.18)
            CornerBrackets(arm: arm)
                .stroke(CameraColor.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .butt, lineJoin: .miter))
                .padding(0.8)
        }
        .overlay(alignment: .bottom) {
            if locked {
                Text("AE/AF LOCK")
                    .font(CameraFont.parameter(11))
                    .foregroundStyle(CameraColor.textPrimary)
                    .offset(y: 18)
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel(locked ? "对焦和曝光已锁定" : "对焦框")
    }
}

private struct CornerBrackets: Shape {
    var arm: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 0.8, dy: 0.8)
        let length = min(arm, inset.width / 2, inset.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: inset.minX + length, y: inset.minY))
        path.addLine(to: CGPoint(x: inset.minX, y: inset.minY))
        path.addLine(to: CGPoint(x: inset.minX, y: inset.minY + length))
        path.move(to: CGPoint(x: inset.maxX - length, y: inset.minY))
        path.addLine(to: CGPoint(x: inset.maxX, y: inset.minY))
        path.addLine(to: CGPoint(x: inset.maxX, y: inset.minY + length))
        path.move(to: CGPoint(x: inset.minX, y: inset.maxY - length))
        path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
        path.addLine(to: CGPoint(x: inset.minX + length, y: inset.maxY))
        path.move(to: CGPoint(x: inset.maxX, y: inset.maxY - length))
        path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
        path.addLine(to: CGPoint(x: inset.maxX - length, y: inset.maxY))
        return path
    }
}

struct SelectPill: View {
    var title: String
    var selected: Bool
    var width: CGFloat? = nil
    var height: CGFloat = 36
    /// Unselected plates use the page color, which disappears on `#090a0a`. Pass a fill to keep the capsule visible.
    var plate: Color? = nil
    var idleInk: Color = CameraColor.textPrimary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(CameraFont.fixed(13, weight: .medium))
                .foregroundStyle(selected ? CameraColor.accent : idleInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .buttonStyle(PillPlateStyle(
            fill: plate ?? (selected ? CameraColor.surface : CameraColor.background),
            width: width,
            height: height
        ))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Draws the capsule in the button style body, so the plate is not dropped with the label background.
struct PillPlateStyle: ButtonStyle {
    var fill: Color
    var width: CGFloat?
    var height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width, height: height)
            .background {
                Capsule().fill(fill)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// One horizontal ruler. The red needle stays fixed; the ticks move under the finger.
struct SharedRuler: View {
    var labels: [String]
    var index: Int
    var onChange: (Int) -> Void
    var onCommit: () -> Void

    @State private var dragOrigin: Int?
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack {
                tickCanvas(width: width)
                Rectangle()
                    .fill(CameraColor.accent)
                    .frame(width: 1.5, height: 22)
                    .position(x: width / 2, y: 16)
            }
        }
        .frame(height: 62)
        .contentShape(Rectangle())
        .gesture(drag)
        .onAppear { haptic.prepare() }
        .onChange(of: index) { _, _ in
            haptic.impactOccurred(intensity: 0.45)
            haptic.prepare()
        }
        .accessibilityElement()
        .accessibilityValue(labels.indices.contains(index) ? labels[index] : "")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard labels.isEmpty == false else { return }
                if dragOrigin == nil { dragOrigin = index }
                let base = dragOrigin ?? index
                let steps = Int(((-value.translation.width) / 11.4).rounded())
                let next = min(max(base + steps, 0), labels.count - 1)
                if next != index { onChange(next) }
            }
            .onEnded { _ in
                dragOrigin = nil
                onCommit()
            }
    }

    private func tickCanvas(width: CGFloat) -> some View {
        Canvas { context, size in
            let step: CGFloat = 11.4
            let mid = size.width / 2
            for offset in labels.indices {
                let x = mid + CGFloat(offset - index) * step
                if x < -28 || x > size.width + 28 { continue }
                let major = offset % 5 == 0
                let height: CGFloat = major ? 18 : 8
                var path = Path()
                path.move(to: CGPoint(x: x, y: 4))
                path.addLine(to: CGPoint(x: x, y: 4 + height))
                context.stroke(path, with: .color(CameraColor.textSecondary), lineWidth: 1)
                if major {
                    let labelX = min(max(x, 22), size.width - 22)
                    let text = Text(labels[offset]).font(CameraFont.parameter(11))
                    context.draw(
                        text.foregroundColor(offset == index ? CameraColor.accent : CameraColor.textSecondary),
                        at: CGPoint(x: labelX, y: 40),
                        anchor: .center
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct FlashChoiceMenu: View {
    var selection: AVCaptureDevice.FlashMode
    var enabled: Bool
    var reason: String?
    var onSelect: (AVCaptureDevice.FlashMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            row(.off, title: "关闭", glyph: .flashOff)
            row(.auto, title: "自动", glyph: .flashAuto)
            row(.on, title: "开启", glyph: .flashOn)
            if enabled == false, let reason {
                Text(reason)
                    .font(CameraFont.interface(12))
                    .foregroundStyle(CameraColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 170)
        .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ mode: AVCaptureDevice.FlashMode, title: String, glyph: PhiGlyph) -> some View {
        Button {
            onSelect(mode)
        } label: {
            HStack(spacing: 10) {
                PhiGlyphImage(glyph: glyph)
                    .foregroundStyle(CameraColor.textPrimary)
                Text(title)
                    .font(CameraFont.interface(14, weight: .medium))
                    .foregroundStyle(CameraColor.textPrimary)
                Spacer()
                if selection == mode {
                    PhiGlyphImage(glyph: .check)
                        .foregroundStyle(CameraColor.textPrimary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
        .buttonStyle(.plain)
        .disabled(enabled == false)
        .accessibilityAddTraits(selection == mode ? .isSelected : [])
    }
}
