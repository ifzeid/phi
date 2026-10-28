import SwiftUI

/// Tokens from Figma section 102:268. Red is selection, values, and the reticle centre. The shutter stays ivory.
enum CameraColor {
    static let background = Color(red: 9.0 / 255, green: 10.0 / 255, blue: 10.0 / 255)
    static let surface = Color(red: 25.0 / 255, green: 27.0 / 255, blue: 27.0 / 255)
    static let border = Color(red: 52.0 / 255, green: 55.0 / 255, blue: 55.0 / 255)
    static let textPrimary = Color(red: 244.0 / 255, green: 243.0 / 255, blue: 238.0 / 255)
    static let textSecondary = Color(red: 165.0 / 255, green: 170.0 / 255, blue: 167.0 / 255)
    static let accent = Color(red: 244.0 / 255, green: 81.0 / 255, blue: 53.0 / 255)
    static let shutterRing = Color(red: 112.0 / 255, green: 118.0 / 255, blue: 117.0 / 255)
    static let scrim = Color(red: 9.0 / 255, green: 10.0 / 255, blue: 10.0 / 255).opacity(0.88)
}
