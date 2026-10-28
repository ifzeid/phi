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
