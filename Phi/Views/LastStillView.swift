import SwiftUI
import UIKit

struct LastStillView: View {
    var image: UIImage?
    var note: String?
    var canRetry: Bool
    var onRetry: () -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CameraColor.background.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 88)
            } else {
                VStack(spacing: 10) {
                    Text("还没有照片")
                        .font(CameraFont.interface(20, weight: .medium))
                        .foregroundStyle(CameraColor.textPrimary)
                    Text("拍下的静帧会留在这里，并保存到相册。")
                        .font(CameraFont.interface(14))
                        .foregroundStyle(CameraColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack {
                Spacer()
                if let note {
                    Text(note)
                        .font(CameraFont.interface(13))
                        .foregroundStyle(CameraColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                if canRetry {
                    Button("重新保存到相册", action: onRetry)
                        .buttonStyle(QuietButtonStyle())
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }
            }
            .padding(.bottom, 24)

            Button(action: onClose) {
                PhiIcon(symbol: .close)
                    .frame(width: 44, height: 44)
                    .background(CameraColor.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("关闭")
        }
        .presentationBackground(CameraColor.background)
    }
}
