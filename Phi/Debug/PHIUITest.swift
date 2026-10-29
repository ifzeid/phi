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
/// `-PHIUITestHalo off|weak|strong`
/// `-PHIUITestImport <dir>` copies each HEIC+DNG pair into the local shot store
/// `-PHIUITestOpenEditor <basename>` opens that imported shot
/// `-PHIUITestEditorEV <value>` and `-PHIUITestEditorLook <name>` apply after open
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
        case "weak", "弱": return .weak
        case "strong", "强": return .strong
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
            guard let heifFile = copyIntoStills(heifURL, name: "\(stem).heic"),
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
                lensZoom: facts.zoom
            ))
            StillArchive.storeLastRecord(LibraryRecord(files: files))
            let zoomText = facts.zoom.map { String(format: "%.2f", $0) } ?? "1"
            let line = "EDITOR IMPORT \(stem) aspect \(facts.aspect.title) zoom \(zoomText)"
            print(line)
            log.notice("\(line, privacy: .public)")
        }
    }

    /// Neutral diff against the HEIF, then the requested EV / look. Latency is logged when the frame is shown.
    static func measureOpenedEditor(source: UIImage, framed: UIImage, session: ProcessSession) {
        guard openEditorBasename != nil else { return }
        if let heif = source.cgImage, let editor = framed.cgImage {
            EditorMatch.logNeutralDiff(heif: heif, editor: editor)
        }
        guard editorEV != nil || editorLook != nil else { return }
        let started = CFAbsoluteTimeGetCurrent()
        if let editorEV {
            session.setExposure(editorEV)
        }
        if let editorLook {
            session.setColorLook(editorLook)
        }
        guard session.isNeutral else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        let line = String(format: "EDITOR RENDER LATENCY %.1f ms", ms)
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
    private static func captureFacts(heifURL: URL) -> (aspect: PhotoAspect, zoom: Double?) {
        guard let source = CGImageSourceCreateWithURL(heifURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return (.threeByFour, nil)
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
        return (aspect, zoom)
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

struct PHIUITestHost: View {
    var screen: PHIUITest.Screen

    init(screen: PHIUITest.Screen) {
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
            FinderSettingsSheet(
                mode: .bayer,
                onMode: { _ in },
                saveHEIF: true,
                onSaveHEIF: { _ in },
                codec: .heic,
                onCodec: { _ in },
                aspect: PHIUITest.aspect ?? .threeByFour,
                onAspect: { _ in },
                onClose: {}
            )
            .background(CameraColor.background.ignoresSafeArea())
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
