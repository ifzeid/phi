import SwiftUI

@main
struct PhiApp: App {
    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if let screen = PHIUITest.screen {
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
