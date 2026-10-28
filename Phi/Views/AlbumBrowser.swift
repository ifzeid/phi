import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Grid and pager for stills PHI saved. Photos assets in the PHI album, plus files kept in the app when Photos rejects the write.
struct AlbumBrowser: View {
    var revision: Int
    var onClose: () -> Void
    var onEditLibrary: (PHAsset) -> Void
    var onEditLocal: (String) -> Void
    var onRetryLocal: (String) -> Void

    @State private var shots: [AlbumShot] = []
    @State private var phase: Phase = .checking
    @State private var limited = false
    @State private var libraryDenied = false
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
                if libraryDenied, phase == .ready {
                    Text("系统相册还没授权。下面是留在 App 内的照片。")
                        .font(CameraFont.interface(12))
                        .foregroundStyle(CameraColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
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
                    if shots.isEmpty {
                        empty
                    } else {
                        grid
                    }
                }
            }
        }
        .task(id: revision) { await reload() }
        .overlay {
            if let viewerIndex, shots.indices.contains(viewerIndex) {
                AlbumPager(
                    shots: shots,
                    index: viewerIndex,
                    onClose: { self.viewerIndex = nil },
                    onEditLibrary: onEditLibrary,
                    onEditLocal: onEditLocal,
                    onRetryLocal: onRetryLocal
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
                    Text("\(shots.count)")
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
                ForEach(Array(shots.enumerated()), id: \.element.id) { offset, shot in
                    Button {
                        viewerIndex = offset
                    } label: {
                        AlbumThumb(shot: shot)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityName(shot, index: offset))
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
                 : "拍完会留在这里，并同时写入系统相册。")
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
        let locals = PhiLocalShots.load().reversed()
        let status = await PhotoLibrary.requestReadWrite()
        guard PhotoLibrary.canReadLibrary(status) else {
            limited = false
            libraryDenied = true
            shots = locals.map { AlbumShot.local($0) }
            phase = shots.isEmpty ? .denied : .ready
            return
        }
        libraryDenied = false
        limited = status == .limited
        if let album = try? await PhotoLibrary.ensureAlbum() {
            await PhotoLibrary.fileIntoAlbum(PhiShotIndex.load().map(\.localIdentifier), album: album)
        }
        let assets = PhotoLibrary.loadShots()
        let known = Set(assets.map(\.localIdentifier))
        var items = assets.map { AlbumShot.library($0) }
        for shot in locals {
            if let identifier = shot.photosIdentifier, known.contains(identifier) { continue }
            items.append(AlbumShot.local(shot))
        }
        shots = items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        phase = .ready
    }

    private func accessibilityName(_ shot: AlbumShot, index: Int) -> String {
        let raw = shot.hasRaw ? "，含 RAW" : ""
        let pending = shot.needsRetry ? "，未写入系统相册" : ""
        return "第 \(index + 1) 张\(raw)\(pending)"
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

private struct AlbumShot: Identifiable {
    enum Source {
        case library(PHAsset)
        case local(PhiLocalShots.Shot)
    }

    var id: String
    var source: Source
    var date: Date?
    var hasRaw: Bool
    var needsRetry: Bool

    static func library(_ asset: PHAsset) -> AlbumShot {
        AlbumShot(
            id: "lib-\(asset.localIdentifier)",
            source: .library(asset),
            date: asset.creationDate,
            hasRaw: PhiRawAsset.contains(asset),
            needsRetry: false
        )
    }

    static func local(_ shot: PhiLocalShots.Shot) -> AlbumShot {
        AlbumShot(
            id: "local-\(shot.id)",
            source: .local(shot),
            date: Self.date(fromStamp: shot.id),
            hasRaw: shot.hasRaw,
            needsRetry: shot.saveFailed == true && shot.savedToPhotos == false
        )
    }

    private static func date(fromStamp id: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: id)
    }
}

private struct AlbumThumb: View {
    var shot: AlbumShot
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
                if shot.hasRaw {
                    Text("RAW")
                        .font(CameraFont.parameter(9, medium: true))
                        .foregroundStyle(CameraColor.accent)
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if shot.needsRetry {
                    Text("未存入")
                        .font(CameraFont.parameter(9, medium: true))
                        .foregroundStyle(CameraColor.textPrimary)
                        .padding(5)
                }
            }
            .clipped()
            .task { await load() }
    }

    private func load() async {
        switch shot.source {
        case .library(let asset):
            if let cached = DevelopCache.image(for: asset.localIdentifier) {
                image = cached
                return
            }
            let target = CGSize(width: 240, height: 240)
            image = await AlbumImage.load(asset, target: target, fast: true)
        case .local(let local):
            image = AlbumImage.localPreview(local)
        }
    }
}

private struct AlbumPager: View {
    var shots: [AlbumShot]
    @State var index: Int
    var onClose: () -> Void
    var onEditLibrary: (PHAsset) -> Void
    var onEditLocal: (String) -> Void
    var onRetryLocal: (String) -> Void

    var body: some View {
        ZStack {
            CameraColor.background.ignoresSafeArea()
            VStack(spacing: 0) {
                pagerHeader
                TabView(selection: $index) {
                    ForEach(Array(shots.enumerated()), id: \.element.id) { offset, shot in
                        AlbumPage(
                            shot: shot,
                            onEditLibrary: onEditLibrary,
                            onEditLocal: onEditLocal,
                            onRetryLocal: onRetryLocal
                        )
                        .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
    }

    private var pagerHeader: some View {
        ZStack {
            if shots.indices.contains(index) {
                Text(Self.stamp(shots[index].date))
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
                Text("\(index + 1)/\(shots.count)")
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
    var shot: AlbumShot
    var onEditLibrary: (PHAsset) -> Void
    var onEditLocal: (String) -> Void
    var onRetryLocal: (String) -> Void
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
                    Text(shot.hasRaw ? "RAW" : "正在打开")
                        .font(CameraFont.interface(13, weight: .medium))
                        .foregroundStyle(CameraColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 16) {
                if shot.hasRaw {
                    Text("RAW")
                        .font(CameraFont.parameter(12, medium: true))
                        .foregroundStyle(CameraColor.accent)
                }
                Spacer()
                if shot.needsRetry, case .local(let local) = shot.source {
                    Button("重试") { onRetryLocal(local.id) }
                        .font(CameraFont.interface(15, weight: .medium))
                        .foregroundStyle(CameraColor.textSecondary)
                        .frame(minHeight: 44)
                }
                Button("导出") { share = true }
                    .font(CameraFont.interface(15, weight: .medium))
                    .foregroundStyle(image == nil ? CameraColor.border : CameraColor.textSecondary)
                    .disabled(image == nil)
                    .frame(minHeight: 44)
                Button(action: edit) {
                    Text("编辑")
                        .font(CameraFont.interface(15, weight: .medium))
                        .foregroundStyle(CameraColor.accent)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(CameraColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(CameraColor.border, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑")
            }
            .padding(.horizontal, 24)
            .frame(height: 64)
        }
        .task { await load() }
        .sheet(isPresented: $share) {
            if let image {
                ActivityView(items: [image])
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func edit() {
        switch shot.source {
        case .library(let asset):
            onEditLibrary(asset)
        case .local(let local):
            onEditLocal(local.id)
        }
    }

    private func load() async {
        switch shot.source {
        case .library(let asset):
            if let cached = DevelopCache.image(for: asset.localIdentifier) {
                image = cached
                return
            }
            image = await AlbumImage.load(asset, target: PHImageManagerMaximumSize, fast: false)
        case .local(let local):
            image = AlbumImage.localPreview(local)
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

    static func localPreview(_ shot: PhiLocalShots.Shot) -> UIImage? {
        guard let file = PhiLocalShots.displayFile(of: shot) else { return nil }
        return UIImage(contentsOfFile: file.path)
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
