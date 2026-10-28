import Foundation

/// Named post-process looks. Off is `natural`.
/// Each other case owns a fixed grain recipe. Those numbers are not controls and must not be shown or edited in the UI.
enum GrainStyle: String, CaseIterable, Identifiable, Codable {
    case natural
    case fine
    case silver
    case push

    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: "NATURAL"
        case .fine: "FINE"
        case .silver: "SILVER"
        case .push: "PUSH"
        }
    }

    /// Nil means no grain is added.
    var profile: GrainProfile? {
        switch self {
        case .natural:
            return nil
        case .fine:
            return GrainProfile(seed: 0xF1E0_4A11, cell: 1, chroma: 0, contrast: 1.05, mix: 0.18, tileFraction: 0.16)
        case .silver:
            return GrainProfile(seed: 0x51A7_0C0A, cell: 3, chroma: 0.06, contrast: 1.2, mix: 0.28, tileFraction: 0.26)
        case .push:
            return GrainProfile(seed: 0x0B05_7E19, cell: 4, chroma: 0.22, contrast: 1.28, mix: 0.34, tileFraction: 0.32)
        }
    }

    static func stored(_ raw: String?) -> GrainStyle {
        guard let raw, let style = GrainStyle(rawValue: raw) else { return .natural }
        return style
    }
}

/// Hardcoded grain. `mix` is how much of the baked grain is dissolved onto the still.
struct GrainProfile {
    var seed: UInt32
    /// Noise cell in the 256px tile. 1 is the finest baked pattern.
    var cell: Int
    /// 0 is luminance only. Higher values keep a little of the tile's color.
    var chroma: Double
    var contrast: Double
    var mix: Double
    /// How much of the image width one tile covers.
    var tileFraction: Double
}

struct StillRecipe: Codable, Equatable {
    var exposureEV: Double
    var style: GrainStyle
    var originalWasRaw: Bool

    static let zero = StillRecipe(exposureEV: 0, style: .natural, originalWasRaw: false)
}
