import SwiftUI

/// 80pt control, 78pt border ring, 64pt vermilion core. The frame does not move when the exposure sheet opens.
struct ShutterButton: View {
    var isReady: Bool
    var isCapturing: Bool
    var action: () -> Void

    private var canTap: Bool { isReady && !isCapturing }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(CameraColor.border, lineWidth: 1.5)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(CameraColor.accent)
                    .frame(width: 64, height: 64)
            }
            .frame(width: 80, height: 80)
            .opacity(isReady ? 1 : 0.4)
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(!canTap)
        .accessibilityLabel("快门")
        .accessibilityHint(isReady ? "拍摄一张静帧" : "相机还不能拍摄")
        .accessibilityValue(isCapturing ? "正在保存" : "")
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
