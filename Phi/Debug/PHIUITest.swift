import ImageIO
import os
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
/// Simulator screenshots.
/// `-PHIUITestScreen capture|album|editor|settings|flash|discard|style`
/// `-PHIUITestAspect 1:1|3:4|2:3|9:16` (also `4:3`, `3:2`, `16:9`)
/// `-PHIUITestEVRuler` keeps the capture exposure ruler visible
/// `-PHIUITestGrid` turns the crop grid on
/// `-PHIUITestManual` shows the M / ISO ruler
/// `-PHIUITestZoom 0.5|1|2|4` sets the zoom-cycle label
/// `-PHIUITestEditorTab exposure|style|effects`
/// `-PHIUITestLook none|positive|negative|mono|ccd`
/// `-PHIUITestHalo off|on`
/// `-PHIUITestImport <dir>` copies each HEIC+DNG pair into the local shot store
/// `-PHIUITestOpenEditor <basename>` opens that imported shot
/// `-PHIUITestEditorEV <value>` and `-PHIUITestEditorLook <name>` apply after open
/// `-PHIUITestEditorEVSweep` logs mean luma at −2, −1, −0.7, 0, +0.9, +2 for the open shot and fails if it rises as EV falls
/// `-PHIUITestEditorHalo` logs 关/开 on imported shots: far sky must stay put, bloom near lights must rise
/// `-PHIUITestEditorNight` renders an imported night DNG at EV −2 and checks sky, beam neutrality, and sharpness
/// `-PHIUITestEditorFinderEV` checks a finder-bias develop at EV 0 against the same file edited by that bias
/// `-PHIUITestSettings` opens the settings card and each sub-card in turn (`SETTINGS CARD <name>`), `-PHIUITestSettingsDwell <s>` per page
/// `-PHIUITestSettingsCard main|process|aspect|flash|output|exposure|style` opens one page and stays
/// `-PHIUITestPerf` logs launch, album, swipe, edit, save, and main-thread hangs
enum PHIUITest {
    enum Screen: String {
        case capture
        case album
        case editor
        case settings
        case flash
        case discard
        case style
    }

    static var screen: Screen? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-PHIUITestScreen"),
              arguments.indices.contains(flag + 1) else { return nil }
        return Screen(rawValue: arguments[flag + 1])
    }

    static var aspect: PhotoAspect? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-PHIUITestAspect"),
              arguments.indices.contains(flag + 1) else { return nil }
        switch arguments[flag + 1] {
        case "1:1", "1x1": return .square
        case "3:4", "4:3": return .threeByFour
        case "2:3", "3:2": return .twoByThree
        case "9:16", "16:9": return .nineBySixteen
        default: return PhotoAspect(rawValue: arguments[flag + 1])
        }
    }

    /// Capture chrome with the sample still instead of the camera.
    static var capturesSample: Bool {
        screen == .capture || screen == .flash || screen == .settings
    }

    static var settingsTour: Bool {
        ProcessInfo.processInfo.arguments.contains("-PHIUITestSettings")
    }

    static var settingsDwell: Double {
        Double(argument("-PHIUITestSettingsDwell") ?? "") ?? 3
    }

    static var settingsCard: SettingsPage? {
        if let name = argument("-PHIUITestSettingsCard") { return SettingsPage(rawValue: name) ?? .main }
        if screen == .settings, settingsTour == false { return .main }
        return nil
    }

    static func logSettings(_ line: String) {
        Logger(subsystem: "com.zeid.phi", category: "uitest").notice("\(line, privacy: .public)")
        print(line)
    }

    static var showEVRuler: Bool {
        ProcessInfo.processInfo.arguments.contains("-PHIUITestEVRuler")
    }

    static var showGrid: Bool {
        ProcessInfo.processInfo.arguments.contains("-PHIUITestGrid")
    }

    /// Manual ruler. Shows M / ISO instead of A / EV, and keeps that ruler on screen.
    static var manual: Bool {
        ProcessInfo.processInfo.arguments.contains("-PHIUITestManual")
    }

    static var zoom: CaptureZoom? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-PHIUITestZoom"),
              arguments.indices.contains(flag + 1) else { return nil }
        switch arguments[flag + 1] {
        case "0.5", "0.5x", "0.5×": return .half
        case "1", "1x", "1×": return .one
        case "2", "2x", "2×": return .two
        case "4", "4x", "4×": return .four
        default: return nil
        }
    }

    static var editorTab: EditorTabName? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-PHIUITestEditorTab"),
              arguments.indices.contains(flag + 1) else { return nil }
        switch arguments[flag + 1] {
        case "exposure", "曝光": return .exposure
        case "style", "风格": return .style
        case "effects", "效果": return .effects
        default: return nil
        }
    }

    enum EditorTabName {
        case exposure
        case style
        case effects
    }

    static var look: ColorLook? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-PHIUITestLook"),
              arguments.indices.contains(flag + 1) else { return nil }
        switch arguments[flag + 1] {
        case "none", "无": return .none
        case "positive", "正片": return .positive
        case "negative", "负片": return .negative
        case "mono", "黑白": return .mono
        case "ccd", "CCD": return .ccd
        default: return ColorLook(rawValue: arguments[flag + 1])
        }
    }

    static var halo: HaloLevel? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-PHIUITestHalo"),
              arguments.indices.contains(flag + 1) else { return nil }
        switch arguments[flag + 1] {
        case "off", "关": return .off
        case "on", "开", "weak", "弱", "strong", "强": return .on
        default: return HaloLevel(rawValue: arguments[flag + 1])
        }
    }

    /// UITest launches start from the defaults. A launch argument is the only override.
    static func resetPersistedState() {
        let defaults = UserDefaults.standard
        defaults.set((aspect ?? .threeByFour).rawValue, forKey: PhotoAspect.storageKey)
        defaults.set(showGrid, forKey: "phi.showGrid")
        defaults.set(ProcessMode.bayer.rawValue, forKey: ProcessMode.storageKey)
        defaults.set(true, forKey: ProcessMode.saveProcessedKey)
        defaults.set(true, forKey: ProcessMode.saveHEIFKey)
        defaults.set(ProcessedCodec.heic.rawValue, forKey: ProcessedCodec.storageKey)
        defaults.set(ColorLook.none.rawValue, forKey: CaptureService.captureLookKey)
    }

    static var importDirectory: String? { argument("-PHIUITestImport") }

    static var openEditorBasename: String? { argument("-PHIUITestOpenEditor") }

    /// First finder appearance only, so a second `onAppear` does not stack editors.
    static func openEditorOnce() -> String? {
        guard didOpenEditor == false, let name = openEditorBasename else { return nil }
        didOpenEditor = true
        return name
    }

    static var editorEV: Double? {
        guard let raw = argument("-PHIUITestEditorEV"), let value = Double(raw) else { return nil }
        return min(5, max(-5, value))
    }

    static var editorLook: ColorLook? {
        guard let raw = argument("-PHIUITestEditorLook") else { return nil }
        if let look = ColorLook(rawValue: raw) { return look }
        return ColorLook.allCases.first { $0.title == raw }
    }

    static var editorDrag: Bool {
        ProcessInfo.processInfo.arguments.contains("-PHIUITestEditorDrag")
    }

    /// Mean luma at +2, +0.9, 0, −0.7, −1, −2. Mode 0 uses the open DNG editor. HEIF uses the imported still.
    static var editorEVSweep: Bool {
        ProcessInfo.processInfo.arguments.contains("-PHIUITestEditorEVSweep")
    }

    /// Finder EV baked into the pixels at editor 0 versus the same stop applied in post.
    static var editorFinderEV: Bool {
        ProcessInfo.processInfo.arguments.contains("-PHIUITestEditorFinderEV")
    }

    /// Night DNG at EV −2: sky percentiles, beam chroma, and Laplacian sharpness against a default RAW render.
    static var editorNight: Bool {
        ProcessInfo.processInfo.arguments.contains("-PHIUITestEditorNight")
    }

    /// 关 / 弱 / 强 on each imported still. Far pixels stay put; pixels near highlights get brighter.
    static var editorHalo: Bool {
        ProcessInfo.processInfo.arguments.contains("-PHIUITestEditorHalo")
    }

    static var perf: Bool {
        ProcessInfo.processInfo.arguments.contains("-PHIUITestPerf")
    }

    /// Copies each same-basename HEIC+DNG pair into the local shot store. Safe to call once per launch.
    static func importPairsIfRequested() {
        guard didImport == false else { return }
        didImport = true
        guard let path = importDirectory else { return }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let log = Logger(subsystem: "com.zeid.phi", category: "uitest")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        if urls.isEmpty {
            let line = "EDITOR IMPORT missing \(directory.path)"
            print(line)
            log.error("\(line, privacy: .public)")
            return
        }
        var heic: [String: URL] = [:]
        var dng: [String: URL] = [:]
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent
            switch url.pathExtension.lowercased() {
            case "heic", "heif":
                heic[stem] = url
            case "dng":
                dng[stem] = url
            default:
                break
            }
        }
        for stem in Set(heic.keys).intersection(dng.keys).sorted() {
            guard let heifURL = heic[stem], let dngURL = dng[stem] else { continue }
            let facts = captureFacts(heifURL: heifURL)
            guard let heifFile = copyIntoStills(heifURL, name: "\(stem).apple.heic"),
                  let dngFile = copyIntoStills(dngURL, name: "\(stem).dng") else {
                let line = "EDITOR IMPORT failed \(stem)"
                print(line)
                log.error("\(line, privacy: .public)")
                continue
            }
            let files = [
                LibraryRecord.File(
                    path: heifFile.lastPathComponent,
                    typeIdentifier: UTType.heic.identifier,
                    filename: heifFile.lastPathComponent,
                    alternate: false
                ),
                LibraryRecord.File(
                    path: dngFile.lastPathComponent,
                    typeIdentifier: "com.adobe.raw-image",
                    filename: dngFile.lastPathComponent,
                    alternate: true
                )
            ]
            PhiLocalShots.remember(PhiLocalShots.Shot(
                id: stem,
                files: files,
                hasRaw: true,
                savedToPhotos: false,
                photosIdentifier: nil,
                saveFailed: false,
                aspect: facts.aspect.rawValue,
                lensZoom: facts.zoom,
                processMode: ProcessMode.bayer.rawValue,
                captureEV: facts.bias
            ))
            StillArchive.storeLastRecord(LibraryRecord(files: files))
            let zoomText = facts.zoom.map { String(format: "%.2f", $0) } ?? "1"
            let line = "EDITOR IMPORT \(stem) aspect \(facts.aspect.title) zoom \(zoomText)"
            print(line)
            log.notice("\(line, privacy: .public)")
        }
    }

    /// Diff the HEIF against the first Metal frame, after the proxies are warm, then apply EV, look, or the drag run.
    static func measureOpenedEditor(source: UIImage, session: ProcessSession) {
        guard openEditorBasename != nil else { return }
        let heif = source.cgImage
        session.onFirstDrawn = { drawn in
            if let heif {
                EditorMatch.logNeutralDiff(heif: heif, editor: drawn)
            }
            Task {
                await session.waitUntilWarm()
                await applyLaunchEdits(session)
            }
        }
    }

    private static func applyLaunchEdits(_ session: ProcessSession) async {
        if editorEVSweep {
            await runEVSweep(session)
        }
        if editorHalo {
            runHaloSweep(session)
        }
        if editorNight {
            runNightCheck(session)
        }
        if editorFinderEV {
            runFinderEVCheck(session)
        }
        if editorEVSweep || editorHalo || editorNight || editorFinderEV {
            return
        }
        if editorDrag {
            await runDrag(session)
            return
        }
        if let editorLook {
            _ = await session.measureEdit { $0.setColorLook(editorLook) }
        }
        if let editorEV {
            _ = await session.measureEdit { $0.setExposure(editorEV, interactive: true) }
            await MainActor.run { session.refinePreview() }
        }
    }

    /// Stops from bright to dark. Each mean has to fall. EV 0 is the frame the editor shows at the detent.
    private static let sweepStops: [Double] = [2, 0.9, 0, -0.7, -1, -2]

    private static func runEVSweep(_ session: ProcessSession) async {
        await MainActor.run {
            if session.colorLook != .none { session.setColorLook(.none) }
            if session.halo != .off { session.setHalo(.off) }
            if session.style != .off { session.setStyle(.off) }
        }
        let name = openEditorBasename ?? "shot"
        var failed = false
        if session.rendersFromDNG {
            let dngFailed = await sweepLive(session, mode: "0", file: name)
            let heifFailed = sweepHEIF(file: name, aspect: session.framedAspect)
            failed = dngFailed || heifFailed
        } else {
            let heifFailed = await sweepLive(session, mode: "heif", file: name)
            let dngFailed = session.sourceDNG == nil ? false : sweepDNG(session, file: name)
            failed = heifFailed || dngFailed
        }
        let peers = sweepImportedPeers(except: name)
        failed = failed || peers
        if failed {
            assertionFailure("EDITOR EV SWEEP FAILED")
        }
    }

    /// What the open editor draws: the original at EV 0, and the preview plate at every other stop.
    private static func sweepLive(_ session: ProcessSession, mode: String, file: String) async -> Bool {
        var rows: [(Double, Float)] = []
        for ev in sweepStops {
            _ = await session.measureEdit { $0.setExposure(ev, interactive: false) }
            let mean = await MainActor.run { () -> Float? in
                if abs(ev) < 0.0001, session.showsSavedFile {
                    let original = session.originalImage?.cgImage ?? session.base
                    return EditorMatch.displayMeanLuma(original)
                }
                guard let frame = session.liveFrame?.image, let image = StillPipeline.displayImage(frame) else {
                    return nil
                }
                return EditorMatch.displayMeanLuma(image)
            }
            guard let mean else {
                logSweep("EDITOR EV SWEEP FAILED mode=\(mode) file=\(file) ev \(ev) did not render")
                return true
            }
            rows.append((ev, mean))
        }
        return reportSweep(mode: mode, file: file, rows: rows)
    }

    /// Imported camera HEIF, through the same preview plate as a non-RAW editor. EV 0 is the file itself.
    private static func sweepHEIF(file: String, aspect: PhotoAspect) -> Bool {
        guard let image = importedHEIF(stem: file) else {
            logSweep("EDITOR EV SWEEP FAILED mode=heif file=\(file) missing")
            return true
        }
        let zero = EditorMatch.displayMeanLuma(image)
        var rows: [(Double, Float)] = [(0, zero)]
        let cache = PreviewCache()
        for ev in sweepStops where abs(ev) > 0.0001 {
            guard let rendered = cache.previewImage(
                source: image,
                dng: nil,
                aspect: aspect,
                exposureEV: ev,
                style: .off,
                look: .none,
                halo: .off,
                lensZoom: 1,
                maxSide: EditorMatch.previewMaxSide
            ), let cg = StillPipeline.displayImage(rendered) else {
                logSweep("EDITOR EV SWEEP FAILED mode=heif file=\(file) ev \(ev) did not render")
                return true
            }
            rows.append((ev, EditorMatch.displayMeanLuma(cg)))
        }
        rows.sort { $0.0 > $1.0 }
        return reportSweep(mode: "heif", file: file, rows: rows)
    }

    /// DNG plate for a shot that was opened on its HEIF. EV 0 is the mode 0 develop the editor would show.
    private static func sweepDNG(_ session: ProcessSession, file: String) -> Bool {
        guard let dng = session.sourceDNG else {
            logSweep("EDITOR EV SWEEP FAILED mode=0 file=\(file) missing")
            return true
        }
        let source = session.originalImage?.cgImage ?? session.base
        var rows: [(Double, Float)] = []
        let cache = PreviewCache()
        for ev in sweepStops {
            let measured = dngMean(
                ev: ev,
                dng: dng,
                source: source,
                session: session,
                cache: cache
            )
            guard let measured else {
                logSweep(String(format: "EDITOR EV SWEEP FAILED mode=0 file=%@ ev %+.1f did not render", file, ev))
                return true
            }
            rows.append((ev, measured))
        }
        return reportSweep(mode: "0", file: file, rows: rows)
    }

    private static func dngMean(
        ev: Double,
        dng: Data,
        source: CGImage,
        session: ProcessSession,
        cache: PreviewCache
    ) -> Float? {
        if abs(ev) < 0.0001 {
            guard let developed = RawDevelop.image(
                dng: dng,
                exposureEV: 0,
                style: .off,
                look: .none,
                halo: .off,
                aspect: session.framedAspect,
                lensZoom: session.lensZoom,
                maxSide: EditorMatch.previewMaxSide,
                draft: false
            ) else { return nil }
            return EditorMatch.displayMeanLuma(developed)
        }
        guard let rendered = cache.previewImage(
            source: source,
            dng: dng,
            aspect: session.framedAspect,
            exposureEV: ev,
            style: .off,
            look: .none,
            halo: .off,
            lensZoom: session.lensZoom,
            maxSide: EditorMatch.previewMaxSide
        ), let cg = StillPipeline.displayImage(rendered) else { return nil }
        return EditorMatch.displayMeanLuma(cg)
    }

    /// Every other imported still. The open shot is already measured on screen.
    private static func sweepImportedPeers(except open: String) -> Bool {
        let folder = StillArchive.directory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var stems = Set<String>()
        for url in urls {
            let stem = shotStem(url)
            if stem.isEmpty == false, stem != open {
                stems.insert(stem)
            }
        }
        var failed = false
        for stem in stems.sorted() {
            let shot = PhiLocalShots.shot(id: stem)
            let aspect = shot?.aspect.flatMap(PhotoAspect.init(rawValue:)) ?? .threeByFour
            let zoom = shot?.lensZoom ?? 1
            let dngURL = folder.appendingPathComponent("\(stem).dng")
            if FileManager.default.fileExists(atPath: dngURL.path), let dng = try? Data(contentsOf: dngURL) {
                let source = importedHEIF(stem: stem) ?? sessionlessImage()
                if let source {
                    failed = sweepDNGData(
                        dng: dng,
                        source: source,
                        aspect: aspect,
                        zoom: zoom,
                        file: stem
                    ) || failed
                }
            }
            if importedHEIF(stem: stem) != nil {
                failed = sweepHEIF(file: stem, aspect: aspect) || failed
            }
        }
        return failed
    }

    private static func sweepDNGData(
        dng: Data,
        source: CGImage,
        aspect: PhotoAspect,
        zoom: Double,
        file: String
    ) -> Bool {
        var rows: [(Double, Float)] = []
        let cache = PreviewCache()
        for ev in sweepStops {
            var measured: Float?
            if abs(ev) < 0.0001 {
                guard let developed = RawDevelop.image(
                    dng: dng,
                    exposureEV: 0,
                    style: .off,
                    look: .none,
                    halo: .off,
                    aspect: aspect,
                    lensZoom: zoom,
                    maxSide: EditorMatch.previewMaxSide,
                    draft: false
                ) else {
                    logSweep("EDITOR EV SWEEP FAILED mode=0 file=\(file) ev +0.0 did not render")
                    return true
                }
                measured = EditorMatch.displayMeanLuma(developed)
            } else if let rendered = cache.previewImage(
                source: source,
                dng: dng,
                aspect: aspect,
                exposureEV: ev,
                style: .off,
                look: .none,
                halo: .off,
                lensZoom: zoom,
                maxSide: EditorMatch.previewMaxSide
            ), let cg = StillPipeline.displayImage(rendered) {
                measured = EditorMatch.displayMeanLuma(cg)
            } else {
                measured = nil
            }
            guard let measured else {
                logSweep(String(format: "EDITOR EV SWEEP FAILED mode=0 file=%@ ev %+.1f did not render", file, ev))
                return true
            }
            rows.append((ev, measured))
        }
        return reportSweep(mode: "0", file: file, rows: rows)
    }

    private static func shotStem(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".apple") {
            name = String(name.dropLast(".apple".count))
        }
        return name
    }

    private static func sessionlessImage() -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }

    /// Camera HEIF for an imported pair. The develop, when present, is `stem.heic` and is not this file.
    private static func importedHEIF(stem: String) -> CGImage? {
        let names = [
            "\(stem).apple.heic",
            "\(stem).apple.HEIC",
            "\(stem).heic",
            "\(stem).HEIC",
            "\(stem).heif",
            "\(stem).HEIF"
        ]
        for name in names {
            let url = StillArchive.directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let image = AlbumImage.fileImage(url: url, maxSide: nil)?.cgImage else { continue }
            return image
        }
        return nil
    }

    private static func reportSweep(mode: String, file: String, rows: [(Double, Float)]) -> Bool {
        for row in rows {
            logSweep(String(format: "EDITOR EV SWEEP mode=%@ file=%@ ev=%+.1f mean=%.3f", mode, file, row.0, row.1))
        }
        var failed = false
        var index = 1
        while index < rows.count {
            let darker = rows[index]
            let brighter = rows[index - 1]
            if darker.1 >= brighter.1 - 0.002 {
                logSweep(String(
                    format: "EDITOR EV SWEEP FAILED mode=%@ file=%@ ev %+.1f mean %.3f is not below ev %+.1f mean %.3f",
                    mode, file, darker.0, darker.1, brighter.0, brighter.1
                ))
                failed = true
            }
            index += 1
        }
        return failed
    }

    private static func logSweep(_ line: String) {
        print(line)
        Logger(subsystem: "com.zeid.phi", category: "uitest").notice("\(line, privacy: .public)")
    }

    /// 关 / 弱 / 强. Pixels farther than three wide-blur radii from a highlight must stay put.
    private static func runHaloSweep(_ session: ProcessSession) {
        let name = openEditorBasename ?? "shot"
        var failed = false
        if session.rendersFromDNG, let dng = session.sourceDNG {
            failed = haloDNG(dng, aspect: session.framedAspect, zoom: session.lensZoom, file: name) || failed
            if importedHEIF(stem: name) != nil {
                failed = haloHEIF(file: name, aspect: session.framedAspect) || failed
            }
        } else {
            let image = session.originalImage?.cgImage ?? session.base
            failed = haloRendered(file: name, mode: "heif") { level in
                StillPipeline.render(
                    image,
                    exposureEV: 0,
                    style: .off,
                    look: .none,
                    halo: level,
                    lensZoom: 1,
                    maxSide: EditorMatch.previewMaxSide
                )
            } || failed
            if let dng = session.sourceDNG {
                failed = haloDNG(dng, aspect: session.framedAspect, zoom: session.lensZoom, file: name) || failed
            }
        }
        failed = haloPeers(except: name) || failed
        logSweep(String(format: "EDITOR HALO MAX RISE %.4f", haloMaxRise))
        if haloMaxRise < 0.005 {
            logSweep(String(format: "EDITOR HALO FAILED 开 never raised glow near lights (max rise %.4f)", haloMaxRise))
            failed = true
        }
        if failed {
            assertionFailure("EDITOR HALO FAILED")
        }
    }

    private static func haloPeers(except open: String) -> Bool {
        let folder = StillArchive.directory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var stems = Set<String>()
        for url in urls {
            let stem = shotStem(url)
            if stem.isEmpty == false, stem != open {
                stems.insert(stem)
            }
        }
        var failed = false
        for stem in stems.sorted() {
            let shot = PhiLocalShots.shot(id: stem)
            let aspect = shot?.aspect.flatMap(PhotoAspect.init(rawValue:)) ?? .threeByFour
            let zoom = shot?.lensZoom ?? 1
            let dngURL = folder.appendingPathComponent("\(stem).dng")
            if FileManager.default.fileExists(atPath: dngURL.path), let dng = try? Data(contentsOf: dngURL) {
                failed = haloDNG(dng, aspect: aspect, zoom: zoom, file: stem) || failed
            }
            if importedHEIF(stem: stem) != nil {
                failed = haloHEIF(file: stem, aspect: aspect) || failed
            }
        }
        return failed
    }

    private static func haloDNG(_ dng: Data, aspect: PhotoAspect, zoom: Double, file: String) -> Bool {
        haloRendered(file: file, mode: "0") { level in
            RawDevelop.image(
                dng: dng,
                exposureEV: 0,
                style: .off,
                look: .none,
                halo: level,
                aspect: aspect,
                lensZoom: zoom,
                maxSide: EditorMatch.previewMaxSide,
                draft: false
            )
        }
    }

    private static func haloHEIF(file: String, aspect: PhotoAspect) -> Bool {
        guard let image = importedHEIF(stem: file) else {
            logSweep("EDITOR HALO mode=heif file=\(file) missing")
            return false
        }
        return haloRendered(file: file, mode: "heif") { level in
            StillPipeline.render(
                image,
                exposureEV: 0,
                style: .off,
                look: .none,
                halo: level,
                lensZoom: 1,
                maxSide: EditorMatch.previewMaxSide
            )
        }
    }

    private static func haloRendered(file: String, mode: String, render: (HaloLevel) -> CGImage?) -> Bool {
        let levels: [HaloLevel] = [.off, .on]
        var rendered: [(HaloLevel, [Float], Int, Int)] = []
        for level in levels {
            guard let image = render(level), let lumas = displayLumas(image) else {
                logSweep("EDITOR HALO FAILED mode=\(mode) file=\(file) level=\(level.title) did not render")
                return true
            }
            rendered.append((level, lumas, image.width, image.height))
        }
        guard let off = rendered.first else { return true }
        let width = off.2
        let height = off.3
        if rendered.contains(where: { $0.2 != width || $0.3 != height || $0.1.count != off.1.count }) {
            logSweep("EDITOR HALO FAILED mode=\(mode) file=\(file) frames differ in size")
            return true
        }
        let longest = max(width, height)
        let farRadius = max(1, Int((HaloOptics.wideRadius * CGFloat(longest) * 4).rounded(.up)))
        let nearRadius = max(2, Int((HaloOptics.mediumRadius * CGFloat(longest) * 2).rounded(.up)))
        let distance = haloDistance(lumas: off.1, width: width, height: height, limit: farRadius)
        var farIndex: [Int] = []
        var nearIndex: [Int] = []
        let knee = HaloOptics.knee
        for index in off.1.indices {
            let steps = distance[index]
            if steps < 0 {
                farIndex.append(index)
            } else if steps > 0, steps <= nearRadius, off.1[index] < knee {
                nearIndex.append(index)
            }
        }
        let offLumas = off.1
        var rows: [(HaloLevel, HaloBand, HaloBand, Float)] = []
        for item in rendered {
            var peak = Float(0)
            if item.0 != .off {
                for index in farIndex {
                    peak = max(peak, abs(item.1[index] - offLumas[index]))
                }
            }
            rows.append((
                item.0,
                haloBand(item.1, indices: farIndex),
                haloBand(item.1, indices: nearIndex),
                peak
            ))
        }
        for row in rows {
            logSweep(String(
                format: "EDITOR HALO mode=%@ file=%@ level=%@ R=%d farN=%d farP1=%.3f farP5=%.3f farMean=%.3f farMax=%.3f nearN=%d nearMean=%.3f",
                mode,
                file,
                row.0.title,
                farRadius,
                farIndex.count,
                row.1.p1,
                row.1.p5,
                row.1.mean,
                row.3,
                nearIndex.count,
                row.2.mean
            ))
        }
        guard let base = rows.first else { return true }
        var failed = false
        let slack = Float(1) / 255
        if farIndex.isEmpty {
            logSweep("EDITOR HALO mode=\(mode) file=\(file) far=none")
        }
        if nearIndex.isEmpty {
            logSweep("EDITOR HALO mode=\(mode) file=\(file) near=none")
        }
        for row in rows.dropFirst() {
            if farIndex.isEmpty == false {
                let farMoved = abs(row.1.p1 - base.1.p1) >= slack
                    || abs(row.1.p5 - base.1.p5) >= slack
                    || abs(row.1.mean - base.1.mean) >= slack
                    || row.3 >= slack
                if farMoved {
                    logSweep(String(
                        format: "EDITOR HALO FAILED mode=%@ file=%@ level=%@ far sky moved p1 %.3f→%.3f p5 %.3f→%.3f mean %.3f→%.3f max %.3f",
                        mode, file, row.0.title,
                        base.1.p1, row.1.p1, base.1.p5, row.1.p5, base.1.mean, row.1.mean, row.3
                    ))
                    failed = true
                }
            }
            if nearIndex.isEmpty == false {
                haloMaxRise = max(haloMaxRise, row.2.mean - base.2.mean)
            }
            // 开 is the former 弱 scatter: the glow is subtle per file, so a file only fails if it darkens.
            if nearIndex.isEmpty == false, row.2.mean < base.2.mean - slack {
                logSweep(String(
                    format: "EDITOR HALO FAILED mode=%@ file=%@ level=%@ near mean %.3f fell from %.3f",
                    mode, file, row.0.title, row.2.mean, base.2.mean
                ))
                failed = true
            }
        }
        return failed
    }

    private static var haloMaxRise: Float = 0

    private struct HaloBand {
        var p1: Float
        var p5: Float
        var mean: Float
    }

    private static func haloBand(_ lumas: [Float], indices: [Int]) -> HaloBand {
        guard indices.isEmpty == false else {
            return HaloBand(p1: 0, p5: 0, mean: 0)
        }
        var values = [Float]()
        values.reserveCapacity(indices.count)
        var sum = Float(0)
        for index in indices {
            let sample = lumas[index]
            values.append(sample)
            sum += sample
        }
        values.sort()
        let p1 = values[min(values.count - 1, values.count / 100)]
        let p5 = values[min(values.count - 1, values.count * 5 / 100)]
        return HaloBand(p1: p1, p5: p5, mean: sum / Float(values.count))
    }

    private static func haloDistance(lumas: [Float], width: Int, height: Int, limit: Int) -> [Int] {
        let count = width * height
        var distance = [Int](repeating: -1, count: count)
        var queue = [Int]()
        queue.reserveCapacity(count / 8)
        let knee = HaloOptics.knee
        for index in 0..<count where lumas[index] >= knee {
            distance[index] = 0
            queue.append(index)
        }
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let steps = distance[index]
            if steps >= limit { continue }
            let x = index % width
            let y = index / width
            if x > 0 { haloVisit(index - 1, steps: steps, distance: &distance, queue: &queue) }
            if x + 1 < width { haloVisit(index + 1, steps: steps, distance: &distance, queue: &queue) }
            if y > 0 { haloVisit(index - width, steps: steps, distance: &distance, queue: &queue) }
            if y + 1 < height { haloVisit(index + width, steps: steps, distance: &distance, queue: &queue) }
        }
        return distance
    }

    private static func haloVisit(_ index: Int, steps: Int, distance: inout [Int], queue: inout [Int]) {
        if distance[index] >= 0 { return }
        distance[index] = steps + 1
        queue.append(index)
    }

    private static func displayLumas(_ image: CGImage) -> [Float]? {
        let width = image.width
        let height = image.height
        guard width > 1, height > 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var lumas = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            let red = Float(bytes[offset]) / 255
            let green = Float(bytes[offset + 1]) / 255
            let blue = Float(bytes[offset + 2]) / 255
            lumas[index] = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        return lumas
    }

    /// Editor 0 on a frame already biased by N stops equals editing a meter-0 frame by N.
    /// The sensor bias is simulated on the linear plate; clipping is left out of the mean.
    private static func runFinderEVCheck(_ session: ProcessSession) {
        logSweep("EDITOR FINDER EV dial 0 is the captured frame; meter total is captureEV + dial")
        var stems = Set<String>()
        if let open = openEditorBasename { stems.insert(open) }
        let folder = StillArchive.directory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls where url.pathExtension.lowercased() == "dng" {
            let stem = shotStem(url)
            if stem.isEmpty == false { stems.insert(stem) }
        }
        if stems.isEmpty, let dng = session.sourceDNG {
            let failed = finderPair(dng: dng, aspect: session.framedAspect, zoom: session.lensZoom, file: openEditorBasename ?? "shot", captureEV: nil)
            if failed { assertionFailure("EDITOR FINDER EV FAILED") }
            return
        }
        if stems.isEmpty {
            logSweep("EDITOR FINDER EV FAILED no imported DNG")
            assertionFailure("EDITOR FINDER EV FAILED")
            return
        }
        var failed = false
        for stem in stems.sorted() {
            let shot = PhiLocalShots.shot(id: stem)
            let aspect = shot?.aspect.flatMap(PhotoAspect.init(rawValue:)) ?? session.framedAspect
            let zoom = shot?.lensZoom ?? session.lensZoom
            let captureEV = shot?.captureEV
            let dngURL = folder.appendingPathComponent("\(stem).dng")
            guard let dng = try? Data(contentsOf: dngURL) else { continue }
            failed = finderPair(dng: dng, aspect: aspect, zoom: zoom, file: stem, captureEV: captureEV) || failed
        }
        if failed {
            assertionFailure("EDITOR FINDER EV FAILED")
        }
    }

    private static func finderPair(
        dng: Data,
        aspect: PhotoAspect,
        zoom: Double,
        file: String,
        captureEV: Double?
    ) -> Bool {
        guard let plate = RawDevelop.scenePlate(
            dng: dng,
            aspect: aspect,
            lensZoom: zoom,
            maxSide: 512,
            draft: false
        ) else {
            logSweep("EDITOR FINDER EV FAILED file=\(file) did not develop")
            return true
        }
        let biasText = captureEV.map { String(format: "%.1f", $0) } ?? "none"
        var failed = false
        for stop in [-1.0, 1.0] {
            guard let postMean = unclippedMean(StillPipeline.expose(plate, ev: stop)),
                  let finderMean = unclippedMean(StillPipeline.expose(biased(plate, stops: stop), ev: 0)) else {
                logSweep("EDITOR FINDER EV FAILED file=\(file) ev \(stop) did not render")
                return true
            }
            let scale = max(postMean, 0.02)
            let delta = abs(postMean - finderMean) / scale
            logSweep(String(
                format: "EDITOR FINDER EV file=%@ captureEV=%@ stop=%+.1f postMean=%.3f finderMean=%.3f delta=%.3f",
                file, biasText, stop, Double(postMean), Double(finderMean), Double(delta)
            ))
            if delta > 0.08 {
                logSweep(String(
                    format: "EDITOR FINDER EV FAILED file=%@ stop=%+.1f post %.3f finder %.3f",
                    file, stop, Double(postMean), Double(finderMean)
                ))
                failed = true
            }
        }
        return failed
    }

    /// Sensor exposure changed by `stops` before a develop at EV 0.
    private static func biased(_ plate: StillPipeline.LinearPlate, stops: Double) -> StillPipeline.LinearPlate {
        var copy = plate
        let factor = Float(pow(2, stops))
        var index = 0
        while index + 2 < copy.pixels.count {
            copy.pixels[index] *= factor
            copy.pixels[index + 1] *= factor
            copy.pixels[index + 2] *= factor
            index += 4
        }
        return copy
    }

    /// Mean display luma, skipping pixels that clipped in this render.
    private static func unclippedMean(_ image: CIImage) -> Float? {
        guard let cg = StillPipeline.displayImage(image), let plane = displayRGB(cg) else { return nil }
        var sum = Float(0)
        var count = 0
        let pixels = plane.red.count
        for index in 0..<pixels {
            let red = plane.red[index]
            let green = plane.green[index]
            let blue = plane.blue[index]
            if red >= 0.98 || green >= 0.98 || blue >= 0.98 { continue }
            sum += 0.2126 * red + 0.7152 * green + 0.0722 * blue
            count += 1
        }
        guard count > 0 else { return nil }
        return sum / Float(count)
    }

    /// Imported night DNG at EV −2, preview and export, against a default CIRAWFilter at the same stop.
    private static func runNightCheck(_ session: ProcessSession) {
        var stems = Set<String>()
        if let open = openEditorBasename {
            stems.insert(open)
        }
        let folder = StillArchive.directory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls where url.pathExtension.lowercased() == "dng" {
            let stem = shotStem(url)
            if stem.isEmpty == false {
                stems.insert(stem)
            }
        }
        if let dng = session.sourceDNG, stems.isEmpty {
            let failed = nightDNG(dng, aspect: session.framedAspect, zoom: session.lensZoom, file: openEditorBasename ?? "shot")
            if failed {
                assertionFailure("EDITOR NIGHT FAILED")
            }
            return
        }
        if stems.isEmpty {
            logSweep("EDITOR NIGHT FAILED no imported DNG")
            assertionFailure("EDITOR NIGHT FAILED")
            return
        }
        var failed = false
        for stem in stems.sorted() {
            let shot = PhiLocalShots.shot(id: stem)
            let aspect = shot?.aspect.flatMap(PhotoAspect.init(rawValue:)) ?? session.framedAspect
            let zoom = shot?.lensZoom ?? session.lensZoom
            let dngURL = folder.appendingPathComponent("\(stem).dng")
            guard let dng = try? Data(contentsOf: dngURL) else {
                if session.sourceDNG != nil, stem == openEditorBasename {
                    failed = nightDNG(session.sourceDNG!, aspect: aspect, zoom: zoom, file: stem) || failed
                }
                continue
            }
            failed = nightDNG(dng, aspect: aspect, zoom: zoom, file: stem) || failed
        }
        if failed {
            assertionFailure("EDITOR NIGHT FAILED")
        }
    }

    private static func nightDNG(_ dng: Data, aspect: PhotoAspect, zoom: Double, file: String) -> Bool {
        let ev = -2.0
        var failed = false
        failed = nightPair(dng: dng, aspect: aspect, zoom: zoom, file: file, ev: ev, maxSide: EditorMatch.previewMaxSide, kind: "preview") || failed
        failed = nightPair(dng: dng, aspect: aspect, zoom: zoom, file: file, ev: ev, maxSide: nil, kind: "export") || failed
        failed = halideLuma(dng: dng, aspect: aspect, zoom: zoom, file: file) || failed
        return failed
    }

    /// Mean display luma at the Halide reference stops. Compare these numbers to Process Zero screenshots.
    /// Stops must darken. The log is the measurement; it does not encode a target luma.
    private static func halideLuma(dng: Data, aspect: PhotoAspect, zoom: Double, file: String) -> Bool {
        let stops = [0.0, -1.0, -2.0, -4.0, -5.0]
        var means: [Float] = []
        var failed = false
        for ev in stops {
            guard let image = RawDevelop.image(
                dng: dng,
                exposureEV: ev,
                style: .off,
                look: .none,
                halo: .off,
                aspect: aspect,
                lensZoom: zoom,
                maxSide: EditorMatch.previewMaxSide,
                draft: false
            ), let plane = displayRGB(image) else {
                logSweep(String(format: "EDITOR HALIDE LUMA FAILED file=%@ ev=%+.1f did not render", file, ev))
                return true
            }
            let mean = EditorMatch.displayMeanLuma(image)
            let sky = skyPercentiles(plane)
            let clipped = clippedFraction(plane)
            means.append(mean)
            logSweep(String(
                format: "EDITOR HALIDE LUMA file=%@ ev=%+.1f mean=%.4f skyP5=%.3f,%.3f,%.3f clipped=%.4f tag=%.3f applied=%.3f",
                file,
                ev,
                Double(mean),
                Double(sky.p5.0), Double(sky.p5.1), Double(sky.p5.2),
                Double(clipped),
                Double(RawDevelop.lastBaseline),
                Double(RawDevelop.lastAppliedBaseline)
            ))
        }
        for index in 1..<means.count {
            if means[index] > means[index - 1] - 0.002 {
                logSweep(String(
                    format: "EDITOR HALIDE LUMA FAILED file=%@ ev %+.1f mean %.4f did not darken from %.4f",
                    file,
                    stops[index],
                    Double(means[index]),
                    Double(means[index - 1])
                ))
                failed = true
            }
        }
        return failed
    }

    /// Share of pixels with a channel already at the display ceiling. Beams should stay under this.
    private static func clippedFraction(_ plane: RGBPlane) -> Float {
        let count = plane.red.count
        guard count > 0 else { return 0 }
        var clipped = 0
        for index in 0..<count {
            if plane.red[index] >= 0.98 || plane.green[index] >= 0.98 || plane.blue[index] >= 0.98 {
                clipped += 1
            }
        }
        return Float(clipped) / Float(count)
    }

    private static func nightPair(
        dng: Data,
        aspect: PhotoAspect,
        zoom: Double,
        file: String,
        ev: Double,
        maxSide: CGFloat?,
        kind: String
    ) -> Bool {
        guard let ours = RawDevelop.image(
            dng: dng,
            exposureEV: ev,
            style: .off,
            look: .none,
            halo: .off,
            aspect: aspect,
            lensZoom: zoom,
            maxSide: maxSide,
            draft: false
        ), let reference = referenceRAW(dng: dng, ev: ev, aspect: aspect, zoom: zoom, maxSide: maxSide) else {
            logSweep("EDITOR NIGHT FAILED file=\(file) kind=\(kind) did not render")
            return true
        }
        guard let oursRGB = displayRGB(ours), let referenceRGB = displayRGB(reference) else {
            logSweep("EDITOR NIGHT FAILED file=\(file) kind=\(kind) pixels missing")
            return true
        }
        let sky = skyPercentiles(oursRGB)
        let beam = beamChroma(oursRGB)
        let oursSharp = normalizedLaplacian(oursRGB)
        let referenceSharp = normalizedLaplacian(referenceRGB)
        let ratio = referenceSharp > 0.0000001 ? oursSharp / referenceSharp : 1
        if let apple = referenceRAW(dng: dng, ev: ev, aspect: aspect, zoom: zoom, maxSide: maxSide, apple: true),
           let appleRGB = displayRGB(apple) {
            let appleSharp = normalizedLaplacian(appleRGB)
            logSweep(String(
                format: "EDITOR NIGHT file=%@ kind=%@ appleDefaultRef=%.5f ratioVsAppleTone=%.3f (tone differs; not the gate)",
                file, kind, Double(appleSharp), Double(appleSharp > 0.0000001 ? oursSharp / appleSharp : 1)
            ))
        }
        logSweep(String(
            format: "EDITOR NIGHT file=%@ kind=%@ ev=%.0f skyP1=%.3f,%.3f,%.3f skyP5=%.3f,%.3f,%.3f beamChroma=%.3f sharp=%.5f ref=%.5f ratio=%.3f",
            file,
            kind,
            ev,
            Double(sky.p1.0), Double(sky.p1.1), Double(sky.p1.2),
            Double(sky.p5.0), Double(sky.p5.1), Double(sky.p5.2),
            Double(beam),
            Double(oursSharp),
            Double(referenceSharp),
            Double(ratio)
        ))
        var failed = false
        let skySpread = max(sky.p5.0, sky.p5.1, sky.p5.2) - min(sky.p5.0, sky.p5.1, sky.p5.2)
        if sky.p5.0 > 0.07 || sky.p5.1 > 0.07 || sky.p5.2 > 0.07 || skySpread > 0.03 {
            logSweep(String(
                format: "EDITOR NIGHT FAILED file=%@ kind=%@ sky p5 %.3f %.3f %.3f is not a neutral black",
                file, kind, sky.p5.0, sky.p5.1, sky.p5.2
            ))
            failed = true
        }
        if beam > 0.08 {
            logSweep(String(format: "EDITOR NIGHT FAILED file=%@ kind=%@ beam chroma %.3f", file, kind, beam))
            failed = true
        }
        if ratio < 0.85 {
            logSweep(String(
                format: "EDITOR NIGHT FAILED file=%@ kind=%@ sharpness %.5f is below 85%% of reference %.5f",
                file, kind, oursSharp, referenceSharp
            ))
            failed = true
        }
        return failed
    }

    /// Sharpness reference: CIRAWFilter with its own default detail stage (as-shot noise reduction,
    /// sharpness, detail), but the same tone path as PHI (baseline gain + EV, filmic toe and shoulder).
    /// Apple's default tone curve and local tone map change the edge-to-variance ratio by themselves,
    /// so a reference with a different curve measured tone, not softness. `apple` keeps that old reference for the log.
    private static func referenceRAW(
        dng: Data,
        ev: Double,
        aspect: PhotoAspect,
        zoom: Double,
        maxSide: CGFloat?,
        apple: Bool = false
    ) -> CGImage? {
        guard let filter = CIRAWFilter(imageData: dng, identifierHint: nil) else { return nil }
        filter.isDraftModeEnabled = false
        filter.scaleFactor = 1
        let baseline = filter.baselineExposure
        if apple {
            filter.exposure = Float(ev)
        } else {
            filter.baselineExposure = 0
            filter.exposure = 0
            filter.shadowBias = 0
            filter.boostAmount = 0
            filter.localToneMapAmount = 0
            filter.isGamutMappingEnabled = true
            filter.extendedDynamicRangeAmount = 1
            filter.contrastAmount = 0
            filter.isLensCorrectionEnabled = false
        }
        guard let output = filter.outputImage else { return nil }
        let zoomed = zoom > 1 ? zoom : 1
        var framed = aspect.cropped(LensCrop.cropped(output, zoom: zoomed))
        if let maxSide {
            framed = StillPipeline.scaledToSide(framed, maxSide: maxSide)
        }
        if apple {
            return StillPipeline.displayImage(framed)
        }
        guard let plate = StillPipeline.linearPlate(of: framed, baseline: baseline, filmic: true) else { return nil }
        return StillPipeline.displayImage(StillPipeline.expose(plate, ev: ev))
    }

    private struct RGBPlane {
        var red: [Float]
        var green: [Float]
        var blue: [Float]
        var width: Int
        var height: Int
    }

    private static func displayRGB(_ image: CGImage) -> RGBPlane? {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var red = [Float](repeating: 0, count: width * height)
        var green = [Float](repeating: 0, count: width * height)
        var blue = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            red[index] = Float(bytes[offset]) / 255
            green[index] = Float(bytes[offset + 1]) / 255
            blue[index] = Float(bytes[offset + 2]) / 255
        }
        return RGBPlane(red: red, green: green, blue: blue, width: width, height: height)
    }

    /// p1 and p5 of each channel inside the darkest fifth. On a night frame that region is the sky.
    private static func skyPercentiles(_ plane: RGBPlane) -> (p1: (Float, Float, Float), p5: (Float, Float, Float)) {
        let count = plane.red.count
        var order = Array(0..<count)
        order.sort { lhs, rhs in
            let left = 0.2126 * plane.red[lhs] + 0.7152 * plane.green[lhs] + 0.0722 * plane.blue[lhs]
            let right = 0.2126 * plane.red[rhs] + 0.7152 * plane.green[rhs] + 0.0722 * plane.blue[rhs]
            return left < right
        }
        let take = max(1, count / 5)
        var red = [Float]()
        var green = [Float]()
        var blue = [Float]()
        red.reserveCapacity(take)
        for index in 0..<take {
            let pixel = order[index]
            red.append(plane.red[pixel])
            green.append(plane.green[pixel])
            blue.append(plane.blue[pixel])
        }
        red.sort()
        green.sort()
        blue.sort()
        func pick(_ values: [Float], _ fraction: Int) -> Float {
            values[min(values.count - 1, values.count * fraction / 100)]
        }
        return (
            (pick(red, 1), pick(green, 1), pick(blue, 1)),
            (pick(red, 5), pick(green, 5), pick(blue, 5))
        )
    }

    /// Mean chroma of bright pixels that are already close to neutral: the searchlight beams, not the orange tower.
    private static func beamChroma(_ plane: RGBPlane) -> Float {
        var samples = [Float]()
        var bright = 0
        let count = plane.red.count
        for index in 0..<count {
            let red = plane.red[index]
            let green = plane.green[index]
            let blue = plane.blue[index]
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let peak = max(red, max(green, blue))
            let floor = min(red, min(green, blue))
            guard luma >= 0.72, peak > 0.04 else { continue }
            bright += 1
            let chroma = (peak - floor) / peak
            if chroma <= 0.2 {
                samples.append(chroma)
            }
        }
        if bright == 0 { return 0 }
        guard samples.isEmpty == false else { return 1 }
        return samples.reduce(0, +) / Float(samples.count)
    }

    /// Laplacian variance divided by luma variance, so a darker exposure is not scored as blur.
    private static func normalizedLaplacian(_ plane: RGBPlane) -> Float {
        let width = plane.width
        let height = plane.height
        let count = width * height
        var luma = [Float](repeating: 0, count: count)
        var lumaSum = Float(0)
        for index in 0..<count {
            let sample = 0.2126 * plane.red[index] + 0.7152 * plane.green[index] + 0.0722 * plane.blue[index]
            luma[index] = sample
            lumaSum += sample
        }
        let lumaMean = lumaSum / Float(count)
        var lumaSquare = Float(0)
        for sample in luma {
            let delta = sample - lumaMean
            lumaSquare += delta * delta
        }
        let lumaVar = lumaSquare / Float(count)
        var sum = Float(0)
        var square = Float(0)
        var seen = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = y * width + x
                let response = luma[center - 1] + luma[center + 1] + luma[center - width] + luma[center + width] - 4 * luma[center]
                sum += response
                square += response * response
                seen += 1
            }
        }
        guard seen > 0 else { return 0 }
        let mean = sum / Float(seen)
        let variance = square / Float(seen) - mean * mean
        return variance / max(lumaVar, 0.000001)
    }

    /// Thirty EV steps on the warm 800 px proxy. Prints the median and the 95th percentile.
    private static func runDrag(_ session: ProcessSession) async {
        await MainActor.run { session.resetLatencySamples() }
        var samples: [Double] = []
        samples.reserveCapacity(30)
        for index in 0..<30 {
            let step = Double((index % 10) + 1) * 0.1
            let ev = index % 2 == 0 ? step : -step
            let ms = await session.measureEdit { $0.setExposure(ev, interactive: true) }
            samples.append(ms)
        }
        await MainActor.run { session.refinePreview() }
        samples.sort()
        let p50 = samples[(samples.count - 1) / 2]
        let p95Index = min(samples.count - 1, Int((Double(samples.count) * 0.95).rounded(.up)) - 1)
        let line = String(format: "EDITOR DRAG p50 %.1f ms p95 %.1f ms", p50, samples[p95Index])
        print(line)
        Logger(subsystem: "com.zeid.phi", category: "uitest").notice("\(line, privacy: .public)")
    }

    private static var didImport = false
    private static var didOpenEditor = false

    private static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func copyIntoStills(_ source: URL, name: String) -> URL? {
        let destination = StillArchive.directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Pixel aspect from the oriented HEIF. Digital zoom, when the file has one, is the crop.
    private static func captureFacts(heifURL: URL) -> (aspect: PhotoAspect, zoom: Double?, bias: Double?) {
        guard let source = CGImageSourceCreateWithURL(heifURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return (.threeByFour, nil, nil)
        }
        var width = number(props[kCGImagePropertyPixelWidth as String])
        var height = number(props[kCGImagePropertyPixelHeight as String])
        let orientation = Int(number(props[kCGImagePropertyOrientation as String]))
        if (5...8).contains(orientation) {
            swap(&width, &height)
        }
        let aspect: PhotoAspect
        if width > 1, height > 1 {
            let ratio = CGFloat(width / height)
            let nearest = PhotoAspect.allCases.min { lhs, rhs in
                abs(lhs.widthOverHeight - ratio) < abs(rhs.widthOverHeight - ratio)
            }
            if let nearest, abs(nearest.widthOverHeight - ratio) < CGFloat(0.06) {
                aspect = nearest
            } else {
                aspect = .threeByFour
            }
        } else {
            aspect = .threeByFour
        }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let digital = number(exif?[kCGImagePropertyExifDigitalZoomRatio as String])
        let zoom = digital > 1.01 ? digital : nil
        let bias = exif?[kCGImagePropertyExifExposureBiasValue as String] == nil
            ? nil
            : number(exif?[kCGImagePropertyExifExposureBiasValue as String])
        return (aspect, zoom, bias)
    }

    private static func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return 0
    }

    static var sample: UIImage? { UIImage(named: "SampleStill") }

    static var lensStops: [FocalStop] {
        [
            FocalStop(id: "ui-14", millimeters: 14, zoomFactor: 1, isOpticalStep: true, deviceID: "ui-14"),
            FocalStop(id: "ui-25", millimeters: 25, zoomFactor: 1, isOpticalStep: true, deviceID: "ui-25"),
            FocalStop(id: "ui-50", millimeters: 50, zoomFactor: 2, isOpticalStep: false, deviceID: "ui-25"),
            FocalStop(id: "ui-108", millimeters: 108, zoomFactor: 1, isOpticalStep: true, deviceID: "ui-108")
        ]
    }
}

extension PHIUITest {
    /// Cached thumbs, a screen JPEG open, and a 12MP render. Logs the budgets the device run compares.
    static func runPerf(openShot: @MainActor @escaping (String) -> Void) async {
        PerfTrace.startWatchdog()
        let first = "perf-a"
        let second = "perf-b"
        await Task.detached(priority: .userInitiated) {
            preparePerfShot(first)
            preparePerfShot(second)
            // Same warm Core Image kernels as when the debug self-check ran on the main thread.
            _ = DevelopEffectCheck.confirm
        }.value
        PerfTrace.beginAlbum()
        _ = await Task.detached(priority: .userInitiated) {
            ShotCache.gridImage(stem: first)
        }.value
        PerfTrace.noteAlbumThumbnail()
        PerfTrace.beginSwipe()
        _ = await Task.detached(priority: .userInitiated) {
            ShotCache.screenImage(stem: second)
        }.value
        PerfTrace.endSwipe()
        await MainActor.run { openShot(first) }
        await PerfTrace.waitForFirstFrame(timeout: 1)
        let saveMs = await Task.detached(priority: .userInitiated) {
            benchmarkTwelveMegapixel()
        }.value
        let saveLine = String(format: "PERF SAVE %.1f", saveMs)
        print(saveLine)
        Logger(subsystem: "com.zeid.phi", category: "perf").notice("\(saveLine, privacy: .public)")
        let hangs = PerfTrace.hangSnapshot()
        let hangLine = String(format: "PERF HANGS count=%d over250=%d", hangs.over100, hangs.over250)
        print(hangLine)
        Logger(subsystem: "com.zeid.phi", category: "perf").notice("\(hangLine, privacy: .public)")
        let times = PerfTrace.intervals()
        var failed: [String] = []
        if times.album < 0 || times.album >= PerfTrace.albumMs {
            failed.append(String(format: "album %.1f", times.album))
        }
        if times.edit < 0 || times.edit >= PerfTrace.editMs {
            failed.append(String(format: "edit %.1f", times.edit))
        }
        if saveMs < 0 || saveMs >= PerfTrace.saveMs {
            failed.append(String(format: "save %.1f", saveMs))
        }
        if hangs.over250 > 0 {
            failed.append("hangs \(hangs.over250)")
        }
        if failed.isEmpty == false {
            let line = "PERF FAILED \(failed.joined(separator: ", "))"
            print(line)
            Logger(subsystem: "com.zeid.phi", category: "perf").error("\(line, privacy: .public)")
            assertionFailure(line)
        }
    }

    private static func preparePerfShot(_ stem: String) {
        let url = StillArchive.directory.appendingPathComponent("PHI-\(stem).jpg")
        writeSolidJPEG(url, side: 640)
        ShotCache.storeIfNeeded(stem: stem, fromFile: url)
        let file = LibraryRecord.File(
            path: url.lastPathComponent,
            typeIdentifier: UTType.jpeg.identifier,
            filename: url.lastPathComponent,
            alternate: false
        )
        PhiLocalShots.remember(PhiLocalShots.Shot(
            id: stem,
            files: [file],
            hasRaw: false,
            savedToPhotos: true,
            photosIdentifier: nil,
            saveFailed: false,
            aspect: PhotoAspect.threeByFour.rawValue,
            lensZoom: 1,
            processMode: ProcessMode.standard.rawValue
        ))
    }

    /// Full-res render and HEIF encode of a 12MP frame. This is the save budget.
    private static func benchmarkTwelveMegapixel() -> Double {
        let width = 4032
        let height = 3024
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }
        context.setFillColor(CGColor(srgbRed: 0.25, green: 0.22, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return -1 }
        let started = CFAbsoluteTimeGetCurrent()
        let rendered = StillPipeline.render(
            image,
            exposureEV: 0,
            style: .off,
            look: .none,
            halo: .off,
            lensZoom: 1,
            maxSide: nil
        )
        guard let rendered, StillPipeline.encodeDeveloped(rendered) != nil else { return -1 }
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    private static func writeSolidJPEG(_ url: URL, side: Int) {
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: url, options: .atomic)
    }
}

struct PHIUITestHost: View {
    var screen: PHIUITest.Screen

    init(screen: PHIUITest.Screen) {
        PerfTrace.noteFirstFrame()
        PHIUITest.resetPersistedState()
        self.screen = screen
    }

    var body: some View {
        switch screen {
        case .capture, .flash:
            QuietFinderView()
        case .album:
            AlbumBrowser(
                revision: 0,
                onClose: {},
                onEditLibrary: { _ in },
                onEditLocal: { _ in },
                onRetryLocal: { _ in },
                sampleGallery: true
            )
        case .editor, .style, .discard:
            ProcessStillView(
                session: PHIUITestHost.editorSession(),
                canRetryOriginal: false,
                onExport: {},
                onRetryOriginal: {},
                onClose: {}
            )
        case .settings:
            QuietFinderView()
        }
    }

    private static func editorSession() -> ProcessSession {
        let image = PHIUITest.sample?.cgImage ?? ProcessSession.syntheticPreview().base
        let look = PHIUITest.look ?? .none
        let halo = PHIUITest.halo ?? .off
        let session = ProcessSession(
            base: image,
            exposureEV: 0,
            style: .off,
            isSample: true,
            originalWasRaw: true,
            sourceDNG: nil,
            framedAspect: PHIUITest.aspect ?? .threeByFour,
            colorLook: look,
            halo: halo
        )
        if look == .none, halo == .off {
            session.preview = PHIUITest.sample
        } else {
            session.schedule()
        }
        return session
    }
}
#endif
