import SwiftUI

/// Line icons traced from the exploration SVGs (24×24, 1.35pt round stroke).
/// Several files under `Assets/icons/` were exported with swapped names; these paths follow the geometry, not those filenames.
enum PhiSymbol {
    case flash
    case grid
    case controls
    case focus
    case close
    case swap

    var path: Path {
        switch self {
        case .flash:
            var path = Path()
            path.move(to: CGPoint(x: 13, y: 2))
            path.addLine(to: CGPoint(x: 5, y: 14))
            path.addLine(to: CGPoint(x: 11, y: 14))
            path.addLine(to: CGPoint(x: 10, y: 22))
            path.addLine(to: CGPoint(x: 19, y: 9))
            path.addLine(to: CGPoint(x: 12, y: 9))
            path.closeSubpath()
            return path
        case .grid:
            var path = Path()
            path.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 1, height: 1))
            path.move(to: CGPoint(x: 9, y: 3))
            path.addLine(to: CGPoint(x: 9, y: 21))
            path.move(to: CGPoint(x: 15, y: 3))
            path.addLine(to: CGPoint(x: 15, y: 21))
            path.move(to: CGPoint(x: 3, y: 9))
            path.addLine(to: CGPoint(x: 21, y: 9))
            path.move(to: CGPoint(x: 3, y: 15))
            path.addLine(to: CGPoint(x: 21, y: 15))
            return path
        case .controls:
            var path = Path()
            for x in [CGFloat(5), 12, 19] {
                path.move(to: CGPoint(x: x, y: 4))
                path.addLine(to: CGPoint(x: x, y: 20))
            }
            path.move(to: CGPoint(x: 2, y: 8))
            path.addLine(to: CGPoint(x: 8, y: 8))
            path.move(to: CGPoint(x: 9, y: 16))
            path.addLine(to: CGPoint(x: 15, y: 16))
            path.move(to: CGPoint(x: 16, y: 10))
            path.addLine(to: CGPoint(x: 22, y: 10))
            return path
        case .focus:
            var path = Path()
            path.move(to: CGPoint(x: 8, y: 3))
            path.addLine(to: CGPoint(x: 3, y: 3))
            path.addLine(to: CGPoint(x: 3, y: 8))
            path.move(to: CGPoint(x: 16, y: 3))
            path.addLine(to: CGPoint(x: 21, y: 3))
            path.addLine(to: CGPoint(x: 21, y: 8))
            path.move(to: CGPoint(x: 3, y: 16))
            path.addLine(to: CGPoint(x: 3, y: 21))
            path.addLine(to: CGPoint(x: 8, y: 21))
            path.move(to: CGPoint(x: 21, y: 16))
            path.addLine(to: CGPoint(x: 21, y: 21))
            path.addLine(to: CGPoint(x: 16, y: 21))
            path.addEllipse(in: CGRect(x: 9, y: 9, width: 6, height: 6))
            return path
        case .close:
            var path = Path()
            path.move(to: CGPoint(x: 6, y: 6))
            path.addLine(to: CGPoint(x: 18, y: 18))
            path.move(to: CGPoint(x: 18, y: 6))
            path.addLine(to: CGPoint(x: 6, y: 18))
            return path
        case .swap:
            var path = Path()
            path.move(to: CGPoint(x: 4, y: 8))
            path.addLine(to: CGPoint(x: 18, y: 8))
            path.addLine(to: CGPoint(x: 15, y: 5))
            path.move(to: CGPoint(x: 20, y: 16))
            path.addLine(to: CGPoint(x: 6, y: 16))
            path.addLine(to: CGPoint(x: 9, y: 19))
            path.move(to: CGPoint(x: 4, y: 8))
            path.addLine(to: CGPoint(x: 4, y: 13))
            path.move(to: CGPoint(x: 20, y: 16))
            path.addLine(to: CGPoint(x: 20, y: 11))
            return path
        }
    }
}

/// Focus mark from Figma `86:7` viewfinder overlay (360×480).
/// Ivory corner brackets at 70% and a vermilion dash, both 1.2pt.
struct FocusReticle: View {
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 88
            let scaleY = size.height / 48
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scaleX, y: y * scaleY)
            }
            var brackets = Path()
            brackets.move(to: p(12, 0))
            brackets.addLine(to: p(0, 0))
            brackets.addLine(to: p(0, 12))
            brackets.move(to: p(76, 0))
            brackets.addLine(to: p(88, 0))
            brackets.addLine(to: p(88, 12))
            brackets.move(to: p(0, 36))
            brackets.addLine(to: p(0, 48))
            brackets.addLine(to: p(12, 48))
            brackets.move(to: p(88, 36))
            brackets.addLine(to: p(88, 48))
            brackets.addLine(to: p(76, 48))
            context.stroke(
                brackets,
                with: .color(CameraColor.textPrimary.opacity(0.7)),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )
            var dash = Path()
            dash.move(to: p(32, 24))
            dash.addLine(to: p(56, 24))
            context.stroke(
                dash,
                with: .color(CameraColor.accent),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
            )
        }
        .frame(width: 88, height: 48)
        .accessibilityHidden(true)
    }
}

struct PhiIcon: View {
    var symbol: PhiSymbol
    var color: Color = CameraColor.textPrimary

    var body: some View {
        symbol.path
            .stroke(color, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            .frame(width: 24, height: 24)
    }
}

struct IconHitButton: View {
    var symbol: PhiSymbol
    var active: Bool = false
    var badge: String?
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                PhiIcon(symbol: symbol, color: active ? CameraColor.textPrimary : CameraColor.textSecondary)
                    .frame(width: 36, height: 36)
                    .background {
                        if active {
                            Circle().fill(CameraColor.surface)
                        }
                    }
                if let badge {
                    Text(badge)
                        .font(CameraFont.parameter(9, medium: true))
                        .foregroundStyle(CameraColor.textPrimary)
                        .padding(.horizontal, 3)
                        .background(CameraColor.background, in: Capsule())
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Grain ring used on the permission gate. The home-screen icon is the asset-catalog AppIcon,
/// which follows the system appearance. This mark is the dark ring, because the gate is dark.
struct PhiMark: View {
    var body: some View {
        Image("PhiGrainRing")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .clipShape(GrainRingMask())
            .accessibilityHidden(true)
    }
}

/// Squircle close to the iOS icon mask, so the ring reads as the app icon at any size.
private struct GrainRingMask: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let radius = side * 0.2237
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        return Path(roundedRect: CGRect(origin: origin, size: CGSize(width: side, height: side)), cornerRadius: radius)
    }
}
