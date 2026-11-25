import SwiftUI

/// Ceramic White tokens from Figma section 336:1726 (`--body`, `--ink`, `--secondary`, `--line`, `--camera-accent`, `--surface`).
enum CameraColor {
    static let background = Color(red: 246.0 / 255, green: 245.0 / 255, blue: 241.0 / 255)
    static let surface = Color.white
    static let border = Color(red: 197.0 / 255, green: 200.0 / 255, blue: 194.0 / 255)
    static let textPrimary = Color(red: 40.0 / 255, green: 43.0 / 255, blue: 41.0 / 255)
    static let textSecondary = Color(red: 119.0 / 255, green: 123.0 / 255, blue: 118.0 / 255)
    static let accent = Color(red: 244.0 / 255, green: 81.0 / 255, blue: 53.0 / 255)
    static let shutterRing = Color(red: 197.0 / 255, green: 200.0 / 255, blue: 194.0 / 255)
    static let scrim = Color(red: 46.0 / 255, green: 59.0 / 255, blue: 51.0 / 255).opacity(0.18)
    static let surround = Color(red: 211.0 / 255, green: 215.0 / 255, blue: 207.0 / 255)
    static let gridLine = Color(red: 244.0 / 255, green: 243.0 / 255, blue: 238.0 / 255).opacity(0.135)
    static let dropShadow = Color(red: 46.0 / 255, green: 59.0 / 255, blue: 51.0 / 255).opacity(0.08)
    static let destructiveWash = Color(red: 244.0 / 255, green: 81.0 / 255, blue: 53.0 / 255).opacity(0.16)
    static let quietWash = Color(red: 40.0 / 255, green: 43.0 / 255, blue: 41.0 / 255).opacity(0.08)
}
