import SwiftUI

/// Shared flowing-glass material for in-app notices, the settings card, and the discard card.
/// Warm, slightly smoky, and translucent so the ceramic background can show through.
/// Native `glassEffect` is used when the SDK is iOS 26+; otherwise an ultra-thin material
/// plus a light tint. Reduce Transparency gets a readable opaque ceramic plate.
enum FlowGlassToken {
    static let bannerCorner: CGFloat = 16
    /// Figma 358:2297 Save confirmation / Liquid Glass toast.
    static let toastCorner: CGFloat = 24
    static let toastHeight: CGFloat = 48
    static let cardCorner: CGFloat = 36
    static let discardCorner: CGFloat = 24
    static let tint = Color(red: 246.0 / 255, green: 245.0 / 255, blue: 241.0 / 255).opacity(0.22)
    static let readableFill = Color(red: 246.0 / 255, green: 245.0 / 255, blue: 241.0 / 255).opacity(0.94)
    static let stroke = Color.white.opacity(0.55)

    /// One device pixel, in points.
    static func hairline(scale: CGFloat) -> CGFloat {
        1 / max(scale, 1)
    }
}

struct FlowGlass: ViewModifier {
    var cornerRadius: CGFloat
    var scale: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let line = FlowGlassToken.hairline(scale: scale)
        if reduceTransparency {
            content
                .background(FlowGlassToken.readableFill, in: shape)
                .overlay(shape.strokeBorder(FlowGlassToken.stroke, lineWidth: line))
                .environment(\.colorScheme, .light)
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(FlowGlassToken.tint), in: shape)
                .overlay(shape.strokeBorder(FlowGlassToken.stroke, lineWidth: line))
                .environment(\.colorScheme, .light)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(FlowGlassToken.tint, in: shape)
                .overlay(shape.strokeBorder(FlowGlassToken.stroke, lineWidth: line))
                .environment(\.colorScheme, .light)
        }
    }
}

extension View {
    func flowGlass(cornerRadius: CGFloat, scale: CGFloat) -> some View {
        modifier(FlowGlass(cornerRadius: cornerRadius, scale: scale))
    }
}

/// Figma 358:2297 — Save confirmation / Liquid Glass toast.
/// Designed only for a successful save: 358×48, 16 pt side inset in the parent, 24 pt corners,
/// 18 pt `checkmark.circle`, 13 pt Medium ink, copy “已保存新照片，原片保留”.
/// Processing and failure have no toast node in the current file; those states are handled elsewhere.
struct AppNoticeBanner: View {
    var kind: EditorPrompt
    var progress: Double = 0
    var scale: CGFloat = 3

    var body: some View {
        let _ = (kind, progress)
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
                .frame(width: 18, height: 18)
            Text("已保存新照片，原片保留")
                .font(CameraFont.interface(13, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: FlowGlassToken.toastHeight, maxHeight: FlowGlassToken.toastHeight)
        .flowGlass(cornerRadius: FlowGlassToken.toastCorner, scale: scale)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已保存新照片，原片保留")
    }
}
