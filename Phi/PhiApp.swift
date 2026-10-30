import SwiftUI

@main
struct PhiApp: App {
    init() {
        PerfTrace.boot()
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if PHIUITest.openEditorBasename != nil {
            QuietFinderView()
        } else if let screen = PHIUITest.screen {
            PHIUITestHost(screen: screen)
        } else {
            QuietFinderView()
        }
        #else
        QuietFinderView()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            root
                .preferredColorScheme(.dark)
                .tint(CameraColor.accent)
                .modifier(HiddenSystemChrome())
        }
    }
}
