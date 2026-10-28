import Foundation

/// Develop-only grain. Off adds nothing. On is the fixed FINE recipe — there is no amount control.
enum GrainStyle: String, CaseIterable, Identifiable {
    case off
    case fine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "OFF"
        case .fine: "FINE"
        }
    }

    /// Nil means no grain is added.
    var profile: GrainProfile? {
        switch self {
        case .off:
            return nil
        case .fine:
            return GrainProfile(seed: 0xF1E0_4A11, cell: 1, chroma: 0, contrast: 1.05, mix: 0.18, tileFraction: 0.16)
        }
    }
}

extension GrainStyle: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // Older builds stored NATURAL / SILVER / PUSH. Those looks are gone; only an explicit FINE stays on.
        self = raw == GrainStyle.fine.rawValue ? .fine : .off
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Hardcoded FINE grain. `mix` is how much of the baked grain is dissolved onto the still. It is not a slider.
struct GrainProfile {
    var seed: UInt32
    /// Noise cell in the 256px tile. 1 is the finest baked pattern.
    var cell: Int
    /// 0 is luminance only.
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
    var colorLook: ColorLook
    var halo: Bool

    static let zero = StillRecipe(exposureEV: 0, style: .off, originalWasRaw: false, colorLook: .none, halo: false)

    enum CodingKeys: String, CodingKey {
        case exposureEV
        case style
        case originalWasRaw
        case colorLook
        case halo
    }

    init(exposureEV: Double, style: GrainStyle, originalWasRaw: Bool, colorLook: ColorLook = .none, halo: Bool = false) {
        self.exposureEV = exposureEV
        self.style = style
        self.originalWasRaw = originalWasRaw
        self.colorLook = colorLook
        self.halo = halo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposureEV = try container.decode(Double.self, forKey: .exposureEV)
        style = try container.decodeIfPresent(GrainStyle.self, forKey: .style) ?? .off
        originalWasRaw = try container.decodeIfPresent(Bool.self, forKey: .originalWasRaw) ?? false
        colorLook = try container.decodeIfPresent(ColorLook.self, forKey: .colorLook) ?? .none
        halo = try container.decodeIfPresent(Bool.self, forKey: .halo) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exposureEV, forKey: .exposureEV)
        try container.encode(style, forKey: .style)
        try container.encode(originalWasRaw, forKey: .originalWasRaw)
        try container.encode(colorLook, forKey: .colorLook)
        try container.encode(halo, forKey: .halo)
    }
}
