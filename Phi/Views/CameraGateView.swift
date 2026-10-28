import SwiftUI

struct CameraGateView: View {
    var denied: Bool
    var onPrimary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            PhiMark()
                .frame(width: 120, height: 120)
                .padding(.bottom, 28)
            Text("PHI · 观止")
                .font(CameraFont.interface(34, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
            Text(denied ? "相机权限已关闭" : "安静取景")
                .font(CameraFont.interface(17, weight: .regular))
                .foregroundStyle(CameraColor.textSecondary)
                .padding(.top, 10)
            Text(denied
                 ? "在系统设置里允许「观止」使用相机，然后回到这里。\nAllow Camera access for 观止 in Settings."
                 : "启用后置相机。取景是实时画面，不是示例照片。\nEnable the rear camera. The viewfinder is a live preview.")
                .font(CameraFont.interface(15))
                .foregroundStyle(CameraColor.textSecondary)
                .padding(.top, 18)
                .fixedSize(horizontal: false, vertical: true)
            Button(denied ? "打开设置" : "启用相机", action: onPrimary)
                .buttonStyle(QuietButtonStyle())
                .padding(.top, 28)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CameraColor.background.ignoresSafeArea())
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CameraFont.interface(16, weight: .medium))
            .foregroundStyle(CameraColor.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
