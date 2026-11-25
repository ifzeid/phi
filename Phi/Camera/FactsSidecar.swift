import Foundation

/// `<stem>.facts` sidecar (`zoom=2 aspect=square`) for PHI HEICs without EXIF digital zoom.
enum FactsSidecar {
    static func parse(_ text: String) -> (zoom: Double?, aspect: PhotoAspect?) {
        var zoom: Double?
        var aspect: PhotoAspect?
        for pair in text.split(whereSeparator: { $0.isWhitespace }) {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard kv.count == 2 else { continue }
            if kv[0] == "zoom", let z = Double(kv[1]), z > 1.01 { zoom = z }
            if kv[0] == "aspect", let a = PhotoAspect(rawValue: kv[1]) { aspect = a }
        }
        return (zoom, aspect)
    }
}
