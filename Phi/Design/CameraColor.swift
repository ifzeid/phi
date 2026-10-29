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
    /// Figma's scrim is `rgba(9,10,10,0.88)`. On the `#090a0a` page that is invisible,
    /// so the plate is the same black lifted just enough to read as a capsule.
    static let scrim = Color(red: 22.0 / 255, green: 24.0 / 255, blue: 24.0 / 255)
}
