import Foundation

enum ExposureFormat {
    /// One decimal. Zero stays `0.0`. Negative values use a minus sign, so the label can sit on the same tick as the needle.
    static func signedDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded) < 0.05 { return "0.0" }
        let digits = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), abs(rounded))
        return rounded > 0 ? "+\(digits)" : "−\(digits)"
    }

    static func tick(_ value: Int) -> String {
        if value == 0 { return "0" }
        return value > 0 ? "+\(value)" : "−\(abs(value))"
    }
}

enum MeterFormat {
    static func iso(_ value: Float) -> String {
        guard value > 0 else { return "ISO —" }
        return "ISO \(Int(value.rounded()))"
    }

    static func shutter(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "— S" }
        if seconds >= 0.4 {
            let digits = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            return "\(digits) S"
        }
        let denominator = max(1, Int((1.0 / seconds).rounded()))
        return "1/\(denominator) S"
    }
}

enum ExposureStops {
    /// Third-stop ISO values inside the device format range.
    static func isos(min: Float, max: Float) -> [Float] {
        guard max >= min, min > 0 else { return [] }
        var values: [Float] = []
        var iso = min
        var steps = 0
        while iso <= max * 1.01, steps < 90 {
            let display: Float = iso >= 100 ? iso.rounded() : (iso * 10).rounded() / 10
            let clamped = min(max, max(min, display))
            if values.last.map({ abs($0 - clamped) > 0.4 }) ?? true {
                values.append(clamped)
            }
            iso *= pow(2, 1.0 / 3.0)
            steps += 1
        }
        if let last = values.last, last < max - 0.5 {
            values.append(max)
        }
        return values
    }

    /// Standard shutter speeds that fall inside the device limits.
    static func shutters(min secondsMin: Double, max secondsMax: Double) -> [Double] {
        guard secondsMax >= secondsMin, secondsMin > 0 else { return [] }
        let candidates = [
            1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250,
            1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2,
            1.0, 2.0, 4.0, 8.0
        ]
        let filtered = candidates.filter { $0 + 0.000_000_1 >= secondsMin && $0 <= secondsMax * 1.02 }
        return filtered.isEmpty ? [secondsMin, secondsMax] : filtered
    }

    static func nearestIndex(to value: Float, in choices: [Float]) -> Int {
        guard !choices.isEmpty else { return 0 }
        return choices.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0
    }

    static func nearestIndex(to value: Double, in choices: [Double]) -> Int {
        guard !choices.isEmpty else { return 0 }
        return choices.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0
    }
}

enum AspectLabel {
    /// Longer side first, so a portrait 3024×4032 frame still reads `4:3`.
    static func photo(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "—" }
        let longSide = max(width, height)
        let shortSide = min(width, height)
        let divisor = max(gcd(longSide, shortSide), 1)
        return "\(longSide / divisor):\(shortSide / divisor)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }
}
