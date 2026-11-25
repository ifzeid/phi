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
    /// DEBUG screenshots. Skips Photos and shows SampleStill.
    var sampleGallery = false

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
    @State private var isDeleting = false

    private enum Phase {
        case checking
        case ready
        case denied
    }

    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
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
        .task(id: revision) {
            await reload()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-PHIUITestAlbumDelete") { await runDeleteCheck() }
            #endif
        }
        .modifier(HiddenSystemChrome())
        .modifier(UnderIsland())
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
                .ignoresSafeArea()
            }
        }
    }

    /// Figma 05: close at x 13, title at x 77, 选择 / 取消 pill 64×44 r22 on the right.
    private var header: some View {
        HStack(spacing: 20) {
            NativeCloseButton(label: "关闭相册", action: onClose)
            Text(selecting ? "已选择 \(selected.count) 张" : "照片")
                .font(CameraFont.interface(14, weight: .medium))
                .foregroundStyle(CameraColor.textPrimary)
            Spacer(minLength: 0)
            if phase == .ready, shots.isEmpty == false {
                Button {
                    selecting.toggle()
                    if selecting == false { selected = [] }
                } label: {
                    Text(selecting ? "取消" : "选择")
                        .font(CameraFont.interface(13, weight: .medium))
                        .foregroundStyle(CameraColor.textPrimary)
                        .frame(width: 64, height: 36)
                        .background(CameraColor.surface, in: Capsule())
                        .shadow(color: CameraColor.dropShadow, radius: 3, y: 2)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 64, height: 44)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 19)
        .frame(height: 56)
    }

    /// Figma 05/06 footer: h52, px20. `N 张照片` 12 secondary; `返回拍摄` pill 112×44 r22, or trash · count · share.
    private var albumBar: some View {
        HStack {
            if selecting {
                PhiGlyphButton(glyph: .trash, label: "删除所选照片", enabled: selected.isEmpty == false) {
                    requestDeleteSelected()
                }
                Spacer()
                Text("\(selected.count) 张照片")
                    .font(CameraFont.interface(12))
                    .foregroundStyle(CameraColor.textSecondary)
                Spacer()
                PhiGlyphButton(glyph: .share, label: "分享所选照片", enabled: selected.isEmpty == false) {
                    shareSelected()
                }
            } else {
                Text("\(shots.count) 张照片")
                    .font(CameraFont.interface(12))
                    .foregroundStyle(CameraColor.textSecondary)
                Spacer()
                Button(action: onClose) {
                    Text("返回拍摄")
                        .font(CameraFont.interface(13, weight: .medium))
                        .foregroundStyle(CameraColor.textPrimary)
                        .frame(width: 112, height: 44)
                        .background(CameraColor.surface, in: Capsule())
                        .shadow(color: CameraColor.dropShadow, radius: 3, y: 2)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
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
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(monthSections) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(section.title)
                            .font(CameraFont.interface(22, weight: .medium))
                            .foregroundStyle(CameraColor.textPrimary)
                            .frame(height: 32, alignment: .leading)
                            .padding(.horizontal, 19)
                            .padding(.top, 4)
                        Text(section.subtitle)
                            .font(CameraFont.interface(12))
                            .foregroundStyle(CameraColor.textSecondary)
                            .frame(height: 17, alignment: .leading)
                            .padding(.horizontal, 19)
                            .padding(.top, 4)
                            .padding(.bottom, 16)
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(section.items) { item in
                                Button {
                                    toggle(item)
                                } label: {
                                    AlbumThumb(shot: item.shot, marked: selecting ? selected.contains(item.shot.id) : nil)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(accessibilityName(item.shot, index: item.offset))
                                .accessibilityAddTraits(selecting && selected.contains(item.shot.id) ? .isSelected : [])
                                .accessibilityValue(selecting ? (selected.contains(item.shot.id) ? "已选中" : "未选中") : "")
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
        var assets: [PHAsset] = []
        for shot in shots where selected.contains(shot.id) {
            switch shot.source {
            case .local(let local):
                for file in local.files {
                    if let url = StillArchive.resolve(file.path) {
                        urls.append(url)
                    }
                }
            case .library(let asset):
                assets.append(asset)
            }
        }
        if assets.isEmpty {
            shareURLs = urls
            return
        }
        Task {
            let extra = await Self.shareFiles(for: assets)
            await MainActor.run { self.shareURLs = urls + extra }
        }
    }

    private static func shareFiles(for assets: [PHAsset]) async -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phi-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for asset in assets {
            guard let packed = await AlbumImage.loadOriginalData(asset) else { continue }
            let payload = ExportSource.filePayload(packed.data, url: nil)
            let name = asset.localIdentifier.replacingOccurrences(of: "/", with: "_") + "." + payload.ext
            let url = folder.appendingPathComponent(name)
            do {
                try payload.data.write(to: url, options: .atomic)
                urls.append(url)
            } catch {
                continue
            }
        }
        return urls
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
        if sampleGallery {
            shots = Self.sampleShots()
            phase = .ready
            #if DEBUG
            applyAlbumUITestHooks()
            #endif
            return
        }
        PerfTrace.beginAlbum()
        let locals = await Task.detached(priority: .userInitiated) {
            PhiLocalShots.load().reversed().map { AlbumShot.local($0) }
        }.value
        shots = Array(locals)
        phase = .ready
        let status = await PhotoLibrary.requestReadWrite()
        guard PhotoLibrary.canReadLibrary(status) else {
            limited = false
            libraryDenied = true
            phase = shots.isEmpty ? .denied : .ready
            return
        }
        libraryDenied = false
        limited = status == .limited
        let indexed = PhiShotIndex.load().map(\.localIdentifier)
        if let album = try? await PhotoLibrary.ensureAlbum() {
            await PhotoLibrary.fileIntoAlbum(indexed, album: album)
        }
        let assets = await Task.detached(priority: .utility) {
            PhotoLibrary.loadShots()
        }.value
        let known = Set(assets.map(\.localIdentifier))
        var items = assets.map { AlbumShot.library($0) }
        for shot in locals {
            if case .local(let local) = shot.source, let identifier = local.photosIdentifier, known.contains(identifier) {
                continue
            }
            items.append(shot)
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
        let allowed = await MainActor.run { () -> Bool in
            if isDeleting { return false }
            isDeleting = true
            return true
        }
        guard allowed else { return }

        let localIDs = targets.compactMap { shot -> String? in
            if case .local(let item) = shot.source { return item.id }
            return nil
        }
        let localShotIDs = Set(targets.filter { shot in
            if case .local = shot.source { return true }
            return false
        }.map(\.id))
        let libraryShotIDs = Set(targets.filter { shot in
            if case .library = shot.source { return true }
            return false
        }.map(\.id))
        let assets = targets.compactMap { shot -> PHAsset? in
            if case .library(let asset) = shot.source { return asset }
            return nil
        }

        // Locals stay on disk until Photos confirms, or until a local-only delete.
        var removedIDs = Set<String>()
        var photosCancelled = false
        if assets.isEmpty == false {
            // Our own confirm alert may still be dismissing. Photos then cannot present its sheet and
            // returns "cancelled" at once, which used to be swallowed: the first delete did nothing.
            try? await Task.sleep(nanoseconds: 450_000_000)
            var attempt = 0
            while true {
                attempt += 1
                let started = Date()
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.deleteAssets(assets as NSArray)
                    }
                    let photoIDs = assets.map(\.localIdentifier)
                    PhiShotIndex.remove(localIdentifiers: photoIDs)
                    let syncedLocalIDs = AlbumDeleteSync.localIDs(
                        matching: photoIDs,
                        records: PhiLocalShots.load().map { ($0.id, $0.photosIdentifier) }
                    )
                    if AlbumDeleteSync.shouldClearLocalRecords(photosConfirmed: true, cancelled: false) {
                        PhiLocalShots.remove(photosIdentifiers: photoIDs)
                        if localIDs.isEmpty == false {
                            PhiLocalShots.remove(ids: localIDs)
                        }
                    }
                    removedIDs.formUnion(libraryShotIDs)
                    removedIDs.formUnion(localShotIDs)
                    removedIDs.formUnion(syncedLocalIDs.map { "local-\($0)" })
                    Self.purgeDeletedCaches(targets)
                    NSLog("ALBUM DELETE ok assets=%d attempt=%d", assets.count, attempt)
                    break
                } catch {
                    let ns = error as NSError
                    let cancelled = ns.domain == PHPhotosErrorDomain && ns.code == 3072
                    let instant = Date().timeIntervalSince(started) < 0.35
                    NSLog("ALBUM DELETE error %@ %d attempt=%d instant=%d", ns.domain, ns.code, attempt, instant ? 1 : 0)
                    if cancelled, instant, attempt < 3 {
                        // No sheet was on screen long enough for a person to cancel it: present again.
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        continue
                    }
                    if cancelled {
                        photosCancelled = true
                    } else {
                        await MainActor.run {
                            deleteError = "删除没有完成（\(ns.domain) \(ns.code)）。"
                        }
                    }
                    break
                }
            }
        } else if localIDs.isEmpty == false {
            PhiLocalShots.remove(ids: localIDs)
            removedIDs.formUnion(localShotIDs)
            Self.purgeDeletedCaches(targets)
        }

        await MainActor.run {
            isDeleting = false
            if photosCancelled {
                return
            }
            viewerIndex = nil
            selected = []
            selecting = false
            // Photos change notifications can lag; do not show a deleted item again while it settles.
            if removedIDs.isEmpty == false {
                shots.removeAll { removedIDs.contains($0.id) }
            }
        }
        if photosCancelled { return }
        await reload()
        if removedIDs.isEmpty == false {
            await MainActor.run { shots.removeAll { removedIDs.contains($0.id) } }
        }
    }

    private static func purgeDeletedCaches(_ targets: [AlbumShot]) {
        ViewerCache.remove(ids: targets.map(\.id))
        for shot in targets {
            ShotCache.remove(stem: shot.cacheStem)
        }
    }

    #if DEBUG
    /// One confirmed delete of a local shot: gone from the grid and from the local index, first try.
    private static var deleteCheckRan = false
    private func runDeleteCheck() async {
        guard Self.deleteCheckRan == false else { return }
        Self.deleteCheckRan = true
        let target = shots.first { shot in
            if case .local = shot.source { return true }
            return false
        } ?? shots.first
        guard let target else {
            NSLog("ALBUM DELETE FAILED no shots to delete")
            return
        }
        let isLocal: Bool = { if case .local = target.source { return true }; return false }()
        let localID: String? = { if case .local(let item) = target.source { return item.id }; return nil }()
        let count = shots.count
        await commitDelete([target])
        let inGrid = shots.contains { $0.id == target.id }
        let inIndex = localID.map { id in PhiLocalShots.load().contains { $0.id == id } } ?? false
        let pass = inGrid == false && inIndex == false && deleteError == nil
        NSLog("ALBUM DELETE %@ local=%d before=%d after=%d inGridAfter=%d inIndexAfter=%d error=%@", pass ? "PASS" : "FAILED", isLocal ? 1 : 0, count, shots.count, inGrid ? 1 : 0, inIndex ? 1 : 0, deleteError ?? "none")
    }
    #endif

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
            lensZoom: PhiShotIndex.displayZoom(for: asset.localIdentifier),
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
            lensZoom: PhiLocalShots.displayZoom(of: shot),
            framed: PhotoAspect(rawValue: shot.aspect ?? "") ?? .threeByFour
        )
    }

    var cacheStem: String {
        switch source {
        case .local(let shot):
            return shot.id
        case .library(let asset):
            return ShotCache.stem(forLibrary: asset.localIdentifier)
        }
    }

    /// Display still on disk. A DNG is not used for the grid or the viewer.
    var stillURL: URL? {
        guard case .local(let shot) = source else { return nil }
        guard let file = PhiLocalShots.displayFile(of: shot) else { return nil }
        if file.filename.lowercased().hasSuffix(".dng") { return nil }
        return StillArchive.resolve(file.path)
    }

    private static func date(fromStamp id: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: id)
    }
}

extension AlbumBrowser {
    #if DEBUG
    private func applyAlbumUITestHooks() {
        if ProcessInfo.processInfo.arguments.contains("-PHIUITestAlbumSelect") {
            selecting = true
            selected = Set(shots.filter { $0.missing == false }.prefix(2).map(\.id))
        }
        if ProcessInfo.processInfo.arguments.contains("-PHIUITestAlbumViewer") {
            viewerIndex = shots.firstIndex { $0.missing == false }
        }
    }
    #endif

    fileprivate static func sampleStill(framed: PhotoAspect, missing: Bool) -> UIImage? {

        guard missing == false, let sample = UIImage(named: "SampleStill"), let cg = sample.cgImage else { return nil }
        return UIImage(cgImage: framed.cropped(cg), scale: sample.scale, orientation: sample.imageOrientation)
    }

    fileprivate static func sampleShots() -> [AlbumShot] {
        let today = Date()
        let older = Calendar.current.date(byAdding: .day, value: -40, to: today) ?? today
        func shot(id: String, date: Date, missing: Bool, raw: Bool, framed: PhotoAspect = .threeByFour) -> AlbumShot {
            let local = PhiLocalShots.Shot(
                id: id,
                files: [],
                hasRaw: raw,
                savedToPhotos: false,
                photosIdentifier: nil,
                saveFailed: false,
                aspect: framed.rawValue,
                lensZoom: 1
            )
            return AlbumShot(
                id: id,
                source: .local(local),
                date: date,
                hasRaw: raw,
                needsRetry: false,
                missing: missing,
                lensZoom: 1,
                framed: framed
            )
        }
        return [
            shot(id: "sample-1", date: today, missing: false, raw: true, framed: {
                #if DEBUG
                PHIUITest.aspect ?? .threeByFour
                #else
                .threeByFour
                #endif
            }()),
            shot(id: "sample-2", date: today, missing: false, raw: false),
            shot(id: "sample-missing", date: today, missing: true, raw: false),
            shot(id: "sample-3", date: older, missing: false, raw: true)
        ]
    }
}

/// Album multi-select badge. 24 pt, 8 pt from the bottom-right.
/// User t198u: the circle fill is Color.black.opacity(0.4) in both states.
/// Stroke and check stay fully opaque white — do not fade the whole badge.
private enum AlbumSelectionMark {
    static let size: CGFloat = 24
    static let inset: CGFloat = 8
    /// Inner frame of the 24 pt check glyph.
    static let checkSize: CGFloat = 13.2
    static let fill = Color.black.opacity(0.4)
    static let stroke = Color.white
}

private struct AlbumSelectionMarkView: View {
    var selected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(AlbumSelectionMark.fill)
            Circle()
                .strokeBorder(AlbumSelectionMark.stroke, lineWidth: 1)
            if selected {
                PhiGlyphImage(glyph: .check)
                    .foregroundStyle(Color.white)
                    .scaleEffect(AlbumSelectionMark.checkSize / 24)
                    .frame(width: AlbumSelectionMark.checkSize, height: AlbumSelectionMark.checkSize)
            }
        }
        .frame(width: AlbumSelectionMark.size, height: AlbumSelectionMark.size)
        .accessibilityHidden(true)
    }
}

private struct AlbumThumb: View {
    var shot: AlbumShot
    var marked: Bool? = nil
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(128.0 / 127.0, contentMode: .fit)
            .overlay {
                if shot.missing {
                    VStack(spacing: 6) {
                        PhiGlyphImage(glyph: .missing)
                            .foregroundStyle(CameraColor.textSecondary)
                        Text("文件不可用")
                            .font(CameraFont.interface(10))
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
            .overlay(alignment: .bottomTrailing) {
                if let marked {
                    // 24 pt circle, 8 pt from the bottom-right of the 128×127 thumb; no photo border.
                    // Fill is 40% black in every state; white stroke and check stay opaque.
                    // Selected is marked by the white check, not a different fill.
                    AlbumSelectionMarkView(selected: marked)
                        .padding(AlbumSelectionMark.inset)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if shot.needsRetry {
                    Text("未存入")
                        .font(CameraFont.parameter(9, medium: true))
                        .foregroundStyle(CameraColor.surface)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(CameraColor.textPrimary.opacity(0.82), in: Capsule())
                        .padding(5)
                }
            }
            .clipped()
            .task { await load() }
    }

    private func load() async {
        if shot.id.hasPrefix("sample-") {
            image = AlbumBrowser.sampleStill(framed: shot.framed, missing: shot.missing)
            if image != nil { PerfTrace.noteAlbumThumbnail() }
            return
        }
        let stem = shot.cacheStem
        let aspect = shot.framed
        let zoom = shot.lensZoom
        let still = shot.stillURL
        let asset: PHAsset? = {
            if case .library(let asset) = shot.source { return asset }
            return nil
        }()
        let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
            if let cached = ShotCache.gridImage(stem: stem) {
                return AlbumImage.framed(cached, aspect: aspect, zoom: zoom)
            }
            if let still {
                ShotCache.storeIfNeeded(stem: stem, fromFile: still)
                if let cached = ShotCache.gridImage(stem: stem) {
                    return AlbumImage.framed(cached, aspect: aspect, zoom: zoom)
                }
            }
            return nil
        }.value
        if let loaded {
            image = loaded
            PerfTrace.noteAlbumThumbnail()
            return
        }
        if let asset, let sharp = await AlbumImage.load(asset, target: CGSize(width: ShotCache.gridSide, height: ShotCache.gridSide), fast: true) {
            let framed = AlbumImage.framed(sharp, aspect: aspect, zoom: zoom)
            image = framed
            PerfTrace.noteAlbumThumbnail()
            if let cg = sharp.cgImage {
                Task.detached(priority: .utility) {
                    ShotCache.store(stem: stem, image: cg)
                }
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
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let width: CGFloat = geo.size.width
            let height: CGFloat = geo.size.height
            let island: CGFloat = geo.safeAreaInsets.top > 1 ? geo.safeAreaInsets.top : ScreenEdge.windowTop
            let home: CGFloat = max(geo.safeAreaInsets.bottom > 1 ? geo.safeAreaInsets.bottom : ScreenEdge.windowBottom, 21)
            let layout = CaptureChromeLayout.measure(width: width, height: height, island: island, home: home, scale: displayScale)
            let shot = shots.indices.contains(index) ? shots[index] : nil
            let content = layout.contentFrame(for: shot?.framed ?? .threeByFour)
            ZStack(alignment: .topLeading) {
                CameraColor.background
                    .frame(width: width, height: height)

                if let shot {
                    AlbumPage(
                        shot: shot,
                        onEditLibrary: onEditLibrary,
                        onEditLocal: onEditLocal,
                        onRetryLocal: onRetryLocal,
                        onDelete: onDelete,
                        content: content,
                        width: width,
                        height: height,
                        home: home
                    )
                    .id(shot.id)
                    .gesture(swipe)
                }

                pagerHeader
                    .frame(width: width, height: CaptureChromeLayout.topButtonHeight)
                    .position(x: width / 2, y: layout.topButtonCenterY)
            }
            .frame(width: width, height: height)
        }
        .ignoresSafeArea()
        .task(id: index) {
            await prefetchNeighbors()
        }
        .onChange(of: index) { _, _ in
            PerfTrace.beginSwipe()
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            let horizontal = value.translation.width
            guard abs(horizontal) > abs(value.translation.height) else { return }
            if horizontal < -40, index + 1 < shots.count {
                index += 1
            } else if horizontal > 40, index > 0 {
                index -= 1
            }
        }
    }

    /// Decode the screen JPEG for the pages beside the current one. The pager only builds the visible page.
    private func prefetchNeighbors() async {
        let neighbors = [index - 1, index + 1].filter { shots.indices.contains($0) }
        let shots = neighbors.map { self.shots[$0] }
        await Task.detached(priority: .utility) {
            for shot in shots {
                if ViewerCache.image(id: shot.id) != nil { continue }
                guard let image = AlbumImage.screenStill(shot) else { continue }
                ViewerCache.store(image, id: shot.id)
            }
        }.value
    }

    private var pagerHeader: some View {
        ZStack {
            if shots.indices.contains(index) {
                Text(Self.stamp(shots[index].date))
                    .font(CameraFont.interface(14, weight: .medium))
                    .foregroundStyle(CameraColor.textPrimary)
            }
            HStack {
                NativeCloseButton(label: "关闭", action: onClose)
                Spacer()
                Text("\(index + 1)/\(shots.count)")
                    .font(CameraFont.parameter(12, medium: true))
                    .foregroundStyle(CameraColor.textPrimary)
                    .padding(.trailing, 12)
            }
        }
        .padding(.leading, 8)
    }

    private static func stamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }
}

private struct AlbumPage: View {
    var shot: AlbumShot
    var onEditLibrary: (PHAsset) -> Void
    var onEditLocal: (String) -> Void
    var onRetryLocal: (String) -> Void
    var onDelete: (AlbumShot) -> Void
    /// Shared with the finder / develop editor so the still sits in the same content rect.
    var content: CGRect
    var width: CGFloat
    var height: CGFloat
    var home: CGFloat
    @State private var image: UIImage?
    @State private var share = false

    private var metaLine: String {
        let kind = shot.hasRaw ? "RAW" : "HEIC"
        return "\(kind) · \(shot.framed.title)"
    }

    var body: some View {
        let footerHeight = max(height - content.maxY - home, 0)
        ZStack(alignment: .topLeading) {
            // No decorative CameraColor.surround / 8 pt pad. 16 pt is the photo corner, not a frame.
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
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(width: content.width, height: content.height)
            .position(x: content.midX, y: content.midY)

            VStack(spacing: 0) {
                Text(metaLine)
                    .font(CameraFont.parameter(12))
                    .foregroundStyle(CameraColor.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    PhiGlyphButton(glyph: .trash, label: "删除") { onDelete(shot) }
                    Spacer(minLength: 0)
                    if shot.needsRetry, case .local(let local) = shot.source {
                        Button("重试") { onRetryLocal(local.id) }
                            .font(CameraFont.interface(13, weight: .medium))
                            .foregroundStyle(CameraColor.textSecondary)
                            .padding(.trailing, 12)
                    }
                    Button(action: edit) {
                        Text("编辑")
                            .font(CameraFont.fixed(14, weight: .medium))
                            .foregroundStyle(CameraColor.textPrimary)
                            .frame(width: 148, height: 48)
                            .background(CameraColor.surface, in: Capsule())
                            .shadow(color: CameraColor.dropShadow, radius: 3, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑")
                    Spacer(minLength: 0)
                    PhiGlyphButton(glyph: .share, label: "分享", enabled: image != nil) { share = true }
                }
                .padding(.horizontal, 20)
                .frame(height: 64)
            }
            .frame(width: width, height: footerHeight, alignment: .top)
            .position(x: width / 2, y: content.maxY + footerHeight / 2)
        }
        .frame(width: width, height: height)
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
        if shot.id.hasPrefix("sample-") {
            image = AlbumBrowser.sampleStill(framed: shot.framed, missing: shot.missing)
            PerfTrace.endSwipe()
            return
        }
        if let cached = ViewerCache.image(id: shot.id) {
            image = cached
            PerfTrace.endSwipe()
            return
        }
        let shot = shot
        if let preview = await Task.detached(priority: .userInitiated, operation: {
            AlbumImage.screenStill(shot)
        }).value {
            ViewerCache.store(preview, id: shot.id)
            image = preview
        } else if case .library(let asset) = shot.source,
                  let sharp = await AlbumImage.load(asset, target: AlbumImage.viewerTarget, fast: true) {
            let framed = AlbumImage.framed(sharp, aspect: shot.framed, zoom: shot.lensZoom)
            ViewerCache.store(framed, id: shot.id)
            image = framed
            if let cg = sharp.cgImage {
                let stem = shot.cacheStem
                Task.detached(priority: .utility) {
                    ShotCache.store(stem: stem, image: cg)
                }
            }
        }
        PerfTrace.endSwipe()
    }
}


/// Screen JPEGs for the page on screen and its two neighbors.
enum ViewerCache {
    private static let lock = NSLock()
    private static var images: [String: UIImage] = [:]
    private static var order: [String] = []

    static func image(id: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[id]
    }

    static func store(_ image: UIImage, id: String) {
        lock.lock()
        images[id] = image
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > 4 {
            images[order.removeFirst()] = nil
        }
        lock.unlock()
    }

    static func remove(ids: [String]) {
        lock.lock()
        for id in ids {
            images[id] = nil
            order.removeAll { $0 == id }
        }
        lock.unlock()
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
    static func loadOriginalData(_ asset: PHAsset) async -> (data: Data, uti: String)? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .original
            let resumed = DataUTIResume()
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if cancelled {
                    resumed.resume(continuation, with: nil)
                    return
                }
                if let data {
                    resumed.resume(continuation, with: (data, uti ?? "public.image"))
                } else {
                    resumed.resume(continuation, with: nil)
                }
            }
        }
    }

    static func loadOriginal(_ asset: PHAsset) async -> UIImage? {
        if let packed = await loadOriginalData(asset), let image = image(data: packed.data, maxSide: nil) {
            return image
        }
        return await load(asset, target: viewerTarget, fast: false)
    }

    static func framed(_ image: UIImage, aspect: PhotoAspect, zoom: Double) -> UIImage {
        ImageFraming.framed(image, aspect: aspect, zoom: zoom)
    }

    /// Screen JPEG for the viewer. Built once from the display still and reused by the neighbor prefetch.
    /// File-private: `AlbumShot` is private to this file.
    fileprivate static func screenStill(_ shot: AlbumShot) -> UIImage? {
        let stem = shot.cacheStem
        if let cached = ShotCache.screenImage(stem: stem) {
            return framed(cached, aspect: shot.framed, zoom: shot.lensZoom)
        }
        if let still = shot.stillURL {
            ShotCache.storeIfNeeded(stem: stem, fromFile: still)
            if let cached = ShotCache.screenImage(stem: stem) {
                return framed(cached, aspect: shot.framed, zoom: shot.lensZoom)
            }
        }
        return nil
    }

    static func localPreview(_ shot: PhiLocalShots.Shot, maxSide: CGFloat) -> UIImage? {
        let preferred = PhiLocalShots.displayFile(of: shot)
        let ordered = shot.files.sorted { lhs, rhs in
            if lhs.path == preferred?.path { return true }
            if rhs.path == preferred?.path { return false }
            return PhiLocalShots.isAppleFallback(lhs) == false && PhiLocalShots.isAppleFallback(rhs)
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

private final class DataUTIResume: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<(data: Data, uti: String)?, Never>, with value: (data: Data, uti: String)?) {
        lock.lock()
        defer { lock.unlock() }
        guard didResume == false else { return }
        didResume = true
        continuation.resume(returning: value)
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
