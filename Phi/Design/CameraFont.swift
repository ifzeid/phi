import SwiftUI
import UIKit

/// All interface and parameter type uses the iOS system font (SF Pro / PingFang for Chinese).
/// Point size is fixed so Dynamic Type does not shift the chrome.
enum CameraFont {
    static func interface(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func fixed(_ size: CGFloat, weight: UIFont.Weight = .regular) -> Font {
        Font(UIFont.systemFont(ofSize: size, weight: weight))
    }

    static func parameterSemibold(_ size: CGFloat) -> Font {
        Font(UIFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold))
    }

    static func parameter(_ size: CGFloat, medium: Bool = false) -> Font {
        Font(UIFont.monospacedDigitSystemFont(ofSize: size, weight: medium ? .medium : .regular))
    }
}
