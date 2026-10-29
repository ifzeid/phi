import SwiftUI

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
