import ImageIO
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
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false
    @State private var pendingDelete: [AlbumShot] = []
    @State private var deleteError: String?
    @State private var shareURLs: [URL] = []

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
        .safeAreaInset(edge: .bottom) {
            albumBar
        }
        .alert("删除这些照片？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                let targets = pendingDelete
                pendingDelete = []
                Task { await commitDelete(targets) }
            }
            Button("取消", role: .cancel) {
                pendingDelete = []
            }
        } message: {
            Text("App 内的文件会去掉。系统相册里的照片会进入最近删除。")
        }
        .alert("无法删除", isPresented: Binding(get: { deleteError != nil }, set: { if $0 == false { deleteError = nil } })) {
            Button("好", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(isPresented: Binding(get: { shareURLs.isEmpty == false }, set: { if $0 == false { shareURLs = [] } })) {
            ActivityView(items: shareURLs.map { $0 as Any })
        }
        .overlay {
            if let viewerIndex, shots.indices.contains(viewerIndex) {
                AlbumPager(
                    shots: shots,
                    index: viewerIndex,
                    onClose: { self.viewerIndex = nil },
                    onEditLibrary: onEditLibrary,
                    onEditLocal: onEditLocal,
                    onRetryLocal: onRetryLocal,
                    onDelete: { requestDelete([$0]) }
                )
            }
        }
    }

    private var header: some View {
        HStack {
            PhiGlyphButton(glyph: .close, label: "关闭相册", action: onClose)
            Spacer()
            Text(selecting ? "已选择 \(selected.count) 张" : "照片")
                .font(CameraFont.interface(14, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
            Spacer()
            if phase == .ready, shots.isEmpty == false {
                Button(selecting ? "取消" : "选择") {
                    selecting.toggle()
                    if selecting == false { selected = [] }
                }
                .font(CameraFont.interface(14, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
                .frame(minWidth: 44, minHeight: 44)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
    }

    private var albumBar: some View {
        HStack {
            if selecting {
                PhiGlyphButton(glyph: .trash, label: "删除所选照片", enabled: selected.isEmpty == false) {
                    requestDeleteSelected()
                }
                Spacer()
                Text("\(selected.count) 张照片")
                    .font(CameraFont.interface(13))
                    .foregroundStyle(CameraColor.textSecondary)
                Spacer()
                PhiGlyphButton(glyph: .share, label: "分享所选照片", enabled: selected.isEmpty == false) {
                    shareSelected()
                }
            } else {
                Text("\(shots.count) 张照片")
                    .font(CameraFont.interface(13))
                    .foregroundStyle(CameraColor.textSecondary)
                Spacer()
                Button("返回拍摄", action: onClose)
                    .font(CameraFont.interface(14, weight: .medium))
                    .foregroundStyle(CameraColor.textPrimary)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(CameraColor.background)
    }

    private var monthSections: [AlbumMonth] {
        let calendar = Calendar(identifier: .gregorian)
        var order: [String] = []
        var buckets: [String: [AlbumItem]] = [:]
        for (offset, shot) in shots.enumerated() {
            let date = shot.date ?? Date()
            let parts = calendar.dateComponents([.year, .month], from: date)
            let key = "\(parts.year ?? 0)-\(parts.month ?? 0)"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(AlbumItem(offset: offset, shot: shot))
        }
        return order.compactMap { key in
            guard let items = buckets[key], let first = items.first else { return nil }
            let date = first.shot.date ?? Date()
            let title = Self.monthTitle(date)
            let today = calendar.isDateInToday(date)
            let subtitle = today ? "今天 · \(items.count) 张" : "\(items.count) 张"
            return AlbumMonth(id: key, title: title, subtitle: subtitle, items: items)
        }
    }

    private static func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(monthSections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(CameraFont.interface(22, weight: .medium))
                            .foregroundStyle(CameraColor.textPrimary)
                        Text(section.subtitle)
                            .font(CameraFont.interface(13))
                            .foregroundStyle(CameraColor.textSecondary)
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(section.items) { item in
                                Button {
                                    toggle(item)
                                } label: {
                                    AlbumThumb(shot: item.shot, marked: selecting ? selected.contains(item.shot.id) : nil)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(accessibilityName(item.shot, index: item.offset))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 0)
        }
    }

    private func toggle(_ item: AlbumItem) {
        if selecting {
            if selected.contains(item.shot.id) {
                selected.remove(item.shot.id)
            } else {
                selected.insert(item.shot.id)
            }
        } else {
            viewerIndex = item.offset
        }
    }

    private func shareSelected() {
        var urls: [URL] = []
        for shot in shots where selected.contains(shot.id) {
            if case .local(let local) = shot.source {
                for file in local.files {
                    if let url = StillArchive.resolve(file.path) {
                        urls.append(url)
                    }
                }
            }
        }
        shareURLs = urls
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

    private func requestDeleteSelected() {
        requestDelete(shots.filter { selected.contains($0.id) })
    }

    private func requestDelete(_ targets: [AlbumShot]) {
        guard targets.isEmpty == false else { return }
        let hasLocal = targets.contains { shot in
            if case .local = shot.source { return true }
            return false
        }
        if hasLocal {
            pendingDelete = targets
            confirmDelete = true
        } else {
            Task { await commitDelete(targets) }
        }
    }

    private func commitDelete(_ targets: [AlbumShot]) async {
        let localIDs = targets.compactMap { shot -> String? in
            if case .local(let item) = shot.source { return item.id }
            return nil
        }
        PhiLocalShots.remove(ids: localIDs)
        let assets = targets.compactMap { shot -> PHAsset? in
            if case .library(let asset) = shot.source { return asset }
            return nil
        }
        if assets.isEmpty == false {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                }
                PhiShotIndex.remove(localIdentifiers: assets.map(\.localIdentifier))
            } catch {
                let ns = error as NSError
                let cancelled = ns.domain == PHPhotosErrorDomain && ns.code == 3072
                if cancelled == false {
                    await MainActor.run {
                        deleteError = "\(ns.domain) \(ns.code)"
                    }
                }
            }
        }
        await MainActor.run {
            viewerIndex = nil
            selected = []
            selecting = false
        }
        await reload()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct AlbumItem: Identifiable {
    var offset: Int
    var shot: AlbumShot
    var id: String { shot.id }
}

private struct AlbumMonth: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var items: [AlbumItem]
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
    var missing: Bool
    var lensZoom: Double
    var framed: PhotoAspect

    static func library(_ asset: PHAsset) -> AlbumShot {
        AlbumShot(
            id: "lib-\(asset.localIdentifier)",
            source: .library(asset),
            date: asset.creationDate,
            hasRaw: PhiRawAsset.contains(asset),
            needsRetry: false,
            missing: false,
            lensZoom: PhiShotIndex.lensZoom(for: asset.localIdentifier),
            framed: PhiShotIndex.aspect(for: asset.localIdentifier) ?? .threeByFour
        )
    }

    static func local(_ shot: PhiLocalShots.Shot) -> AlbumShot {
        let resolved = shot.files.compactMap { StillArchive.resolve($0.path) }
        return AlbumShot(
            id: "local-\(shot.id)",
            source: .local(shot),
            date: Self.date(fromStamp: shot.id),
            hasRaw: shot.hasRaw,
            needsRetry: shot.saveFailed == true && shot.savedToPhotos == false,
            missing: resolved.isEmpty,
            lensZoom: shot.lensZoom ?? 1,
            framed: PhotoAspect(rawValue: shot.aspect ?? "") ?? .threeByFour
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
    var marked: Bool? = nil
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if shot.missing {
                    VStack(spacing: 6) {
                        PhiGlyphImage(glyph: .missing)
                            .foregroundStyle(CameraColor.textSecondary)
                        Text("文件不可用")
                            .font(CameraFont.interface(11))
                            .foregroundStyle(CameraColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CameraColor.surface)
                } else if let image {
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
            .overlay(alignment: .topLeading) {
                if let marked {
                    ZStack {
                        Circle()
                            .stroke(CameraColor.textPrimary, lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                        if marked {
                            Circle()
                                .fill(CameraColor.accent)
                                .frame(width: 18, height: 18)
                            PhiGlyphImage(glyph: .check)
                                .foregroundStyle(CameraColor.textPrimary)
                                .scaleEffect(0.6)
                        }
                    }
                    .padding(6)
                    .accessibilityHidden(true)
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
            if image == nil {
                image = DevelopCache.image(for: asset.localIdentifier)
            }
            if let sharp = await AlbumImage.load(asset, target: AlbumImage.gridTarget, fast: false) {
                image = AlbumImage.framed(sharp, aspect: shot.framed, zoom: shot.lensZoom)
            }
        case .local(let local):
            let maxSide = AlbumImage.gridTarget.width
            let aspect = shot.framed
            let zoom = shot.lensZoom
            if let preview = await Task.detached(priority: .utility, operation: {
                AlbumImage.localPreview(local, maxSide: maxSide)
            }).value {
                image = AlbumImage.framed(preview, aspect: aspect, zoom: zoom)
            }
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
    var onDelete: (AlbumShot) -> Void

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
                            onRetryLocal: onRetryLocal,
                            onDelete: onDelete
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
                    .font(CameraFont.interface(14, weight: .medium))
                    .foregroundStyle(CameraColor.textPrimary)
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
    var onDelete: (AlbumShot) -> Void
    @State private var image: UIImage?
    @State private var share = false

    private var metaLine: String {
        let kind = shot.hasRaw ? "RAW" : "HEIC"
        return "\(kind) · \(shot.framed.title)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraColor.background
                if shot.missing {
                    VStack(spacing: 8) {
                        PhiGlyphImage(glyph: .missing)
                            .foregroundStyle(CameraColor.textSecondary)
                        Text("文件不可用")
                            .font(CameraFont.interface(13))
                            .foregroundStyle(CameraColor.textSecondary)
                    }
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(CameraColor.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(390.0 / 520.0, contentMode: .fit)
            Text(metaLine)
                .font(CameraFont.parameter(11))
                .foregroundStyle(CameraColor.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            HStack(spacing: 8) {
                PhiGlyphButton(glyph: .trash, label: "删除") { onDelete(shot) }
                PhiGlyphButton(glyph: .share, label: "分享", enabled: image != nil) { share = true }
                Spacer()
                if shot.needsRetry, case .local(let local) = shot.source {
                    Button("重试") { onRetryLocal(local.id) }
                        .font(CameraFont.interface(13, weight: .medium))
                        .foregroundStyle(CameraColor.textSecondary)
                }
                Button(action: edit) {
                    Text("编辑")
                        .font(CameraFont.interface(14, weight: .medium))
                        .foregroundStyle(CameraColor.accent)
                        .frame(width: 88, height: 44)
                        .background(CameraColor.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑")
            }
            .padding(.horizontal, 16)
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
            if image == nil {
                image = DevelopCache.image(for: asset.localIdentifier)
            }
            if let sharp = await AlbumImage.load(asset, target: AlbumImage.viewerTarget, fast: false) {
                image = AlbumImage.framed(sharp, aspect: shot.framed, zoom: shot.lensZoom)
            }
        case .local(let local):
            let maxSide = AlbumImage.viewerTarget.width
            let aspect = shot.framed
            let zoom = shot.lensZoom
            if let preview = await Task.detached(priority: .userInitiated, operation: {
                AlbumImage.localPreview(local, maxSide: maxSide)
            }).value {
                image = AlbumImage.framed(preview, aspect: aspect, zoom: zoom)
            }
        }
    }
}

enum AlbumImage {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    static var screenScale: CGFloat {
        let scale = screen?.scale ?? 3
        return scale > 0 ? scale : 3
    }

    static var gridTarget: CGSize {
        let width = screen?.bounds.width ?? 390
        let side = max(120, width / 3) * screenScale
        return CGSize(width: side, height: side)
    }

    static var viewerTarget: CGSize {
        let bounds = screen?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
        return CGSize(width: bounds.width * screenScale, height: bounds.height * screenScale)
    }

    static func load(_ asset: PHAsset, target: CGSize, fast: Bool) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.version = .current
            let resumed = ResumeOnce()
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if cancelled {
                    resumed.resume(continuation, with: nil)
                    return
                }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if fast == false || degraded == false {
                    resumed.resume(continuation, with: image)
                }
            }
        }
    }

    /// Full original pixels for 编辑. Avoids PHImageManagerMaximumSize, which often returns a degraded frame and then nothing.
    static func loadOriginal(_ asset: PHAsset) async -> UIImage? {
        let data: Data? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .original
            let resumed = DataResume()
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if cancelled {
                    resumed.resume(continuation, with: nil)
                    return
                }
                resumed.resume(continuation, with: data)
            }
        }
        if let data, let image = image(data: data, maxSide: nil) {
            return image
        }
        return await load(asset, target: viewerTarget, fast: false)
    }

    static func framed(_ image: UIImage, aspect: PhotoAspect, zoom: Double) -> UIImage {
        let zoomed = LensCrop.cropped(image, zoom: zoom)
        guard let cg = zoomed.cgImage else { return zoomed }
        return UIImage(cgImage: aspect.cropped(cg), scale: zoomed.scale, orientation: zoomed.imageOrientation)
    }

    static func localPreview(_ shot: PhiLocalShots.Shot, maxSide: CGFloat) -> UIImage? {
        let ordered = shot.files.sorted { lhs, rhs in
            let leftRaw = lhs.filename.lowercased().hasSuffix(".dng")
            let rightRaw = rhs.filename.lowercased().hasSuffix(".dng")
            return leftRaw == false && rightRaw
        }
        for file in ordered {
            guard let url = StillArchive.resolve(file.path),
                  let image = fileImage(url: url, maxSide: maxSide) else { continue }
            return image
        }
        return nil
    }

    static func fileImage(url: URL, maxSide: CGFloat?) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return image(from: source, maxSide: maxSide)
    }

    private static func image(data: Data, maxSide: CGFloat?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return image(from: source, maxSide: maxSide)
    }

    private static func image(from source: CGImageSource, maxSide: CGFloat?) -> UIImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let pixelHeight = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        let nativeLongest = max(pixelWidth, pixelHeight)
        let cap = maxSide ?? (nativeLongest > 0 ? nativeLongest : 1)
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: cap
        ]
        let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        guard let cg else { return nil }
        return UIImage(cgImage: cg)
    }
}

private final class DataResume: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<Data?, Never>, with data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard didResume == false else { return }
        didResume = true
        continuation.resume(returning: data)
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
