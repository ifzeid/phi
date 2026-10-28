import Foundation

/// What a shutter press writes into Photos. The processed file is HEIC when the device offers HEVC, otherwise JPEG.
enum CaptureFormat: String, CaseIterable, Identifiable {
    /// Processed still plus Bayer RAW, as one paired library asset. Zeid's usual setting.
    case jpegAndRaw
    case raw
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpegAndRaw: "JPEG+RAW"
        case .raw: "RAW"
        case .jpeg: "JPEG"
        }
    }

    /// Ask the camera for Bayer when this stop can deliver it.
    var wantsRaw: Bool { self != .jpeg }

    static let storageKey = "phi.captureFormat"

    static func stored(_ raw: String?) -> CaptureFormat {
        guard let raw, let format = CaptureFormat(rawValue: raw) else { return .jpegAndRaw }
        return format
    }

    /// Top-bar readout. `rawDelivered` is false on a crop stop that cannot shoot Bayer.
    static func label(preference: CaptureFormat, rawDelivered: Bool, codec: String, aspect: String) -> String {
        let head: String
        switch preference {
        case .jpeg:
            head = codec
        case .raw:
            head = rawDelivered ? "RAW" : codec
        case .jpegAndRaw:
            head = rawDelivered ? "RAW+\(codec)" : codec
        }
        guard aspect != "—" else { return head }
        return "\(head) · \(aspect)"
    }
}
