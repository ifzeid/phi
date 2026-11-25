import CoreGraphics
import Foundation

/// Standalone compile stub for Tests/chrome_layout.swift only.
enum SettingsPage {
    case main
    var cardHeight: CGFloat { self == .main ? 392 : 236 }
}
