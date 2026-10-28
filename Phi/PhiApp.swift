import SwiftUI

@main
struct PhiApp: App {
    var body: some Scene {
        WindowGroup {
            QuietFinderView()
                .preferredColorScheme(.dark)
                .tint(CameraColor.accent)
        }
    }
}
