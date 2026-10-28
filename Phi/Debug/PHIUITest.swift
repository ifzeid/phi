import SwiftUI

#if DEBUG
/// Simulator screenshots. Launch with `-PHIUITestScreen capture|album|editor|settings|flash`.
enum PHIUITest {
    enum Screen: String {
        case capture
        case album
        case editor
        case settings
        case flash
    }

    static var screen: Screen? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-PHIUITestScreen"),
              arguments.indices.contains(flag + 1) else { return nil }
        return Screen(rawValue: arguments[flag + 1])
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
        case .editor:
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
                aspect: .threeByFour,
                onAspect: { _ in },
                onClose: {}
            )
            .background(CameraColor.background.ignoresSafeArea())
        }
    }

    private static func editorSession() -> ProcessSession {
        let image = PHIUITest.sample?.cgImage ?? ProcessSession.syntheticPreview().base
        let session = ProcessSession(
            base: image,
            exposureEV: 0,
            style: .off,
            isSample: true,
            originalWasRaw: true,
            sourceDNG: nil,
            framedAspect: .threeByFour
        )
        session.preview = PHIUITest.sample
        return session
    }
}
#endif
