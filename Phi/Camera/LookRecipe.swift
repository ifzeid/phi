import CoreGraphics
import Foundation

/// A develop look in gamma-encoded (perceptual) RGB.
/// The matrix rows each sum to 1, so a neutral stays neutral. Off-diagonals stay within 0.08.
/// Split toning is a few percent and fades out at pure black and pure white.
struct LookRecipe {
    var matrix: [CGFloat]
    var curve: [(CGFloat, CGFloat)]
    var saturation: CGFloat
    var contrast: CGFloat
    var shadowTint: (CGFloat, CGFloat, CGFloat)
    var highlightTint: (CGFloat, CGFloat, CGFloat)
    var monochrome: Bool = false

    static let positive = LookRecipe(
        matrix: [
            1.03, -0.015, -0.015,
            -0.01, 1.02, -0.01,
            -0.01, 0.00, 1.01
        ],
        curve: [(0, 0.025), (0.25, 0.24), (0.50, 0.51), (0.75, 0.77), (1, 0.985)],
        saturation: 1.08,
        contrast: 1.03,
        shadowTint: (-0.018, 0.008, 0.030),
        highlightTint: (0.028, 0.006, -0.020)
    )

    static let negative = LookRecipe(
        matrix: [
            1.01, 0.01, -0.02,
            0.00, 0.99, 0.01,
            -0.02, 0.01, 1.01
        ],
        curve: [(0, 0.035), (0.22, 0.26), (0.50, 0.51), (0.78, 0.76), (1, 0.96)],
        saturation: 0.90,
        contrast: 0.96,
        shadowTint: (-0.010, 0.008, 0.028),
        highlightTint: (0.020, 0.004, -0.012)
    )

    static let mono = LookRecipe(
        matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
        curve: [(0, 0.04), (0.25, 0.23), (0.50, 0.50), (0.75, 0.78), (1, 0.98)],
        saturation: 1,
        contrast: 1,
        shadowTint: (0, 0, 0),
        highlightTint: (0, 0, 0),
        monochrome: true
    )

    static let ccd = LookRecipe(
        matrix: [
            1.02, -0.03, 0.01,
            -0.02, 1.04, -0.02,
            0.00, -0.02, 1.02
        ],
        curve: [(0, 0.03), (0.22, 0.21), (0.50, 0.52), (0.78, 0.80), (1, 0.97)],
        saturation: 1.10,
        contrast: 1.05,
        shadowTint: (-0.008, 0.012, 0.016),
        highlightTint: (-0.012, 0.022, 0.010)
    )

    func apply(red: CGFloat, green: CGFloat, blue: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        var r = red
        var g = green
        var b = blue
        if monochrome {
            let y = 0.45 * r + 0.42 * g + 0.13 * b
            r = y
            g = y
            b = y
        }
        r = Self.curveValue(r, points: curve)
        g = Self.curveValue(g, points: curve)
        b = Self.curveValue(b, points: curve)
        let rr = matrix[0] * r + matrix[1] * g + matrix[2] * b
        let gg = matrix[3] * r + matrix[4] * g + matrix[5] * b
        let bb = matrix[6] * r + matrix[7] * g + matrix[8] * b
        let luma = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb
        r = luma + saturation * (rr - luma)
        g = luma + saturation * (gg - luma)
        b = luma + saturation * (bb - luma)
        r = (r - 0.5) * contrast + 0.5
        g = (g - 0.5) * contrast + 0.5
        b = (b - 0.5) * contrast + 0.5
        let tone = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let shadow = Self.smooth(0.02, 0.16, tone) * (1 - Self.smooth(0.16, 0.48, tone))
        let highlight = Self.smooth(0.58, 0.78, tone) * (1 - Self.smooth(0.90, 0.99, tone))
        r += shadowTint.0 * shadow + highlightTint.0 * highlight
        g += shadowTint.1 * shadow + highlightTint.1 * highlight
        b += shadowTint.2 * shadow + highlightTint.2 * highlight
        return (Self.clamp(r), Self.clamp(g), Self.clamp(b))
    }

    /// 17³ cube of `apply`, red index fastest, matching `CIColorCube`.
    func cubeData() -> Data {
        let size = 17
        var samples = [Float](repeating: 0, count: size * size * size * 4)
        let last = CGFloat(size - 1)
        var offset = 0
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let mapped = apply(
                        red: CGFloat(red) / last,
                        green: CGFloat(green) / last,
                        blue: CGFloat(blue) / last
                    )
                    samples[offset] = Float(mapped.0)
                    samples[offset + 1] = Float(mapped.1)
                    samples[offset + 2] = Float(mapped.2)
                    samples[offset + 3] = 1
                    offset += 4
                }
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    static let cubeDimension = 17

    private static func curveValue(_ value: CGFloat, points: [(CGFloat, CGFloat)]) -> CGFloat {
        let x = clamp(value)
        if x <= points[0].0 { return points[0].1 }
        for index in 1..<points.count {
            let end = points[index]
            let start = points[index - 1]
            if x <= end.0 {
                let span = end.0 - start.0
                let t = span == 0 ? 0 : (x - start.0) / span
                return start.1 + t * (end.1 - start.1)
            }
        }
        return points[points.count - 1].1
    }

    private static func smooth(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        let span = edge1 - edge0
        guard span != 0 else { return value < edge0 ? 0 : 1 }
        let t = min(1, max(0, (value - edge0) / span))
        return t * t * (3 - 2 * t)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}

enum LookCalibration {
    struct Sample {
        var name: String
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
        var neutral: Bool
    }

    static let samples: [Sample] = [
        Sample(name: "grey 0.05", red: 0.05, green: 0.05, blue: 0.05, neutral: true),
        Sample(name: "grey 0.20", red: 0.20, green: 0.20, blue: 0.20, neutral: true),
        Sample(name: "grey 0.50", red: 0.50, green: 0.50, blue: 0.50, neutral: true),
        Sample(name: "grey 0.80", red: 0.80, green: 0.80, blue: 0.80, neutral: true),
        Sample(name: "grey 0.96", red: 0.96, green: 0.96, blue: 0.96, neutral: true),
        Sample(name: "skin", red: 0.86, green: 0.62, blue: 0.48, neutral: false),
        Sample(name: "sky", red: 0.36, green: 0.58, blue: 0.86, neutral: false),
        Sample(name: "orange", red: 0.93, green: 0.48, blue: 0.14, neutral: false),
        Sample(name: "foliage", red: 0.28, green: 0.50, blue: 0.18, neutral: false),
        Sample(name: "red", red: 0.78, green: 0.14, blue: 0.12, neutral: false)
    ]

    /// Empty when every look keeps neutrals near neutral and memory-color hues within 10°.
    static func failures() -> [String] {
        var notes: [String] = []
        let looks: [(String, LookRecipe)] = [
            ("正片", .positive),
            ("负片", .negative),
            ("黑白", .mono),
            ("CCD", .ccd)
        ]
        for (title, recipe) in looks {
            for sample in samples {
                let out = recipe.apply(red: sample.red, green: sample.green, blue: sample.blue)
                if recipe.monochrome {
                    let spread = max(out.0, out.1, out.2) - min(out.0, out.1, out.2)
                    if spread > 0.004 {
                        notes.append("\(title) \(sample.name) is not grey")
                    }
                    continue
                }
                if sample.neutral {
                    let chroma = labChroma(out)
                    if chroma > 6 {
                        notes.append("\(title) \(sample.name) chroma \(chroma)")
                    }
                    if title != "负片" {
                        let delta = deltaE(sample, out)
                        if delta > 8 {
                            notes.append("\(title) \(sample.name) ΔE \(delta)")
                        }
                    }
                } else {
                    let shift = hueDelta(sample, out)
                    if shift > 10 {
                        notes.append("\(title) \(sample.name) hue \(shift)°")
                    }
                }
            }
        }
        return notes
    }

    private static func deltaE(_ sample: Sample, _ out: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        let a = lab(sample.red, sample.green, sample.blue)
        let b = lab(out.0, out.1, out.2)
        let dL = a.0 - b.0
        let da = a.1 - b.1
        let db = a.2 - b.2
        return (dL * dL + da * da + db * db).squareRoot()
    }

    private static func labChroma(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        let value = lab(rgb.0, rgb.1, rgb.2)
        return (value.1 * value.1 + value.2 * value.2).squareRoot()
    }

    private static func hueDelta(_ sample: Sample, _ out: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        let a = lab(sample.red, sample.green, sample.blue)
        let b = lab(out.0, out.1, out.2)
        let ha = atan2(a.2, a.1)
        let hb = atan2(b.2, b.1)
        var delta = abs(hb - ha) * 180 / .pi
        if delta > 180 { delta = 360 - delta }
        return delta
    }

    private static func lab(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        func linear(_ channel: CGFloat) -> CGFloat { pow(max(channel, 0), 2.2) }
        let r = linear(red)
        let g = linear(green)
        let b = linear(blue)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        func f(_ t: CGFloat) -> CGFloat {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0)
        }
        let fx = f(x / 0.95047)
        let fy = f(y / 1)
        let fz = f(z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
