import Photos
import SwiftUI
import UIKit

/// Grid and pager for stills PHI saved. Only the PHI album and assets this app recorded — not the rest of the library.
struct AlbumBrowser: View {
    var onClose: () -> Void
    var onProcess: (PHAsset) -> Void

    @State private var assets: [PHAsset] = []
    @State private var phase: Phase = .checking
    @State private var limited = false
    @State private var viewerIndex: Int?

    private enum Phase {
        case checking
        case ready
        case denied
    }

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ZStack {
            CameraColor.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                switch phase {
                case .checking:
                    Spacer()
                    Text("正在读取 PHI 相册")
                        .font(CameraFont.interface(15, weight: .medium))
                        .foregroundStyle(CameraColor.textSecondary)
                    Spacer()
                case .denied:
                    denied
                case .ready:
                    if assets.isEmpty {
                        empty
                    } else {
                        grid
                    }
                }
            }
        }
        .task { await reload() }
        .overlay {
            if let viewerIndex, assets.indices.contains(viewerIndex) {
                AlbumPager(
                    assets: assets,
                    index: viewerIndex,
                    onClose: { self.viewerIndex = nil },
                    onProcess: onProcess
                )
            }
        }
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text("PHI")
                    .font(CameraFont.parameter(13, medium: true))
                    .foregroundStyle(CameraColor.textPrimary)
                if phase == .ready {
                    Text("\(assets.count)")
                        .font(CameraFont.parameter(11))
                        .foregroundStyle(CameraColor.textSecondary)
                }
            }
            HStack {
                Button(action: onClose) {
                    PhiIcon(symbol: .close, color: CameraColor.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭相册")
                Spacer()
                if limited {
                    Button("管理照片") { presentLimitedPicker() }
                        .font(CameraFont.interface(13, weight: .medium))
                        .foregroundStyle(CameraColor.textSecondary)
                        .padding(.trailing, 8)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { offset, asset in
                    Button {
                        viewerIndex = offset
                    } label: {
                        AlbumThumb(asset: asset)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityName(asset, index: offset))
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("还没有用观止拍的照片")
                .font(CameraFont.interface(17, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
            Text(limited
                 ? "如果只允许了部分照片，点右上角“管理照片”，把观止保存的照片加进来。"
                 : "拍完并写入相册之后，会出现在这里。")
                .font(CameraFont.interface(13))
                .foregroundStyle(CameraColor.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var denied: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("需要读取 PHI 相册")
                .font(CameraFont.interface(17, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
            Text("只用来回看这台 App 保存的照片。系统对话框里可以改为“选中的照片”。")
                .font(CameraFont.interface(13))
                .foregroundStyle(CameraColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("打开系统设置") { openSettings() }
                .buttonStyle(QuietButtonStyle())
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func reload() async {
        let status = await PhotoLibrary.requestReadWrite()
        guard PhotoLibrary.canReadLibrary(status) else {
            phase = .denied
            limited = false
            assets = []
            return
        }
        limited = status == .limited
        if let album = try? await PhotoLibrary.ensureAlbum() {
            await PhotoLibrary.fileIntoAlbum(PhiShotIndex.load().map(\.localIdentifier), album: album)
        }
        assets = PhotoLibrary.loadShots()
        phase = .ready
    }

    private func accessibilityName(_ asset: PHAsset, index: Int) -> String {
        let raw = PhiRawAsset.contains(asset) ? "，含 RAW" : ""
        return "第 \(index + 1) 张\(raw)"
    }

    private func presentLimitedPicker() {
        guard let controller = UIApplication.topViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct AlbumThumb: View {
    var asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    CameraColor.surface
                }
            }
            .overlay(alignment: .bottomLeading) {
                if PhiRawAsset.contains(asset) {
                    Text("RAW")
                        .font(CameraFont.parameter(9, medium: true))
                        .foregroundStyle(CameraColor.accent)
                        .padding(5)
                }
            }
            .clipped()
            .task { await load() }
    }

    private func load() async {
        if let cached = DevelopCache.image(for: asset.localIdentifier) {
            image = cached
            return
        }
        let target = CGSize(width: 240, height: 240)
        image = await AlbumImage.load(asset, target: target, fast: true)
    }
}

private struct AlbumPager: View {
    var assets: [PHAsset]
    @State var index: Int
    var onClose: () -> Void
    var onProcess: (PHAsset) -> Void

    var body: some View {
        ZStack {
            CameraColor.background.ignoresSafeArea()
            VStack(spacing: 0) {
                pagerHeader
                TabView(selection: $index) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { offset, asset in
                        AlbumPage(asset: asset, onProcess: onProcess)
                            .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
    }

    private var pagerHeader: some View {
        ZStack {
            if assets.indices.contains(index) {
                Text(Self.stamp(assets[index].creationDate))
                    .font(CameraFont.parameter(12))
                    .foregroundStyle(CameraColor.textSecondary)
            }
            HStack {
                Button(action: onClose) {
                    PhiIcon(symbol: .close, color: CameraColor.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
                Spacer()
                Text("\(index + 1)/\(assets.count)")
                    .font(CameraFont.parameter(12, medium: true))
                    .foregroundStyle(CameraColor.textPrimary)
                    .padding(.trailing, 12)
            }
        }
        .padding(.leading, 8)
        .frame(height: 52)
    }

    private static func stamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.MM.dd HH:mm"
        return formatter.string(from: date)
    }
}

private struct AlbumPage: View {
    var asset: PHAsset
    var onProcess: (PHAsset) -> Void
    @State private var image: UIImage?
    @State private var share = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraColor.background
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("正在打开")
                        .font(CameraFont.interface(13, weight: .medium))
                        .foregroundStyle(CameraColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if PhiRawAsset.contains(asset) {
                    Text("RAW")
                        .font(CameraFont.parameter(12, medium: true))
                        .foregroundStyle(CameraColor.accent)
                }
                Spacer()
                Button("导出") { share = true }
                    .font(CameraFont.interface(15, weight: .medium))
                    .foregroundStyle(image == nil ? CameraColor.border : CameraColor.textSecondary)
                    .disabled(image == nil)
                Spacer()
                Button("处理") {
                    onProcess(asset)
                }
                .font(CameraFont.interface(15, weight: .medium))
                .foregroundStyle(CameraColor.accent)
            }
            .padding(.horizontal, 24)
            .frame(height: 64)
        }
        .task {
            if let cached = DevelopCache.image(for: asset.localIdentifier) {
                image = cached
                return
            }
            image = await AlbumImage.load(asset, target: PHImageManagerMaximumSize, fast: false)
        }
        .sheet(isPresented: $share) {
            if let image {
                ActivityView(items: [image])
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

enum AlbumImage {
    static func load(_ asset: PHAsset, target: CGSize, fast: Bool) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = fast ? .fastFormat : .highQualityFormat
            options.resizeMode = fast ? .fast : .none
            let resumed = ResumeOnce()
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if cancelled {
                    resumed.resume(continuation, with: nil)
                    return
                }
                if fast || degraded == false {
                    resumed.resume(continuation, with: image)
                }
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<UIImage?, Never>, with image: UIImage?) {
        lock.lock()
        defer { lock.unlock() }
        guard didResume == false else { return }
        didResume = true
        continuation.resume(returning: image)
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private extension UIApplication {
    static var topViewController: UIViewController? {
        let scene = shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
