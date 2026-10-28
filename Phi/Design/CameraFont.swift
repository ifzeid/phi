import SwiftUI
import UIKit

/// Interface copy uses SF Pro (the iOS system sans). Parameters use bundled IBM Plex Mono.
/// If the face did not register, parameters fall back to the system monospace and are not presented as Plex.
enum CameraFont {
    static func interface(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func parameter(_ size: CGFloat, medium: Bool = false) -> Font {
        let name = medium ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular"
        if UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: medium ? .medium : .regular, design: .monospaced)
    }
}
