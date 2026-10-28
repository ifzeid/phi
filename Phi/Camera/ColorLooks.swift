import CoreImage

/// Fixed develop looks. No brand names, no intensity controls.
/// Input and output are in the linear working space. Curves run in a temporary gamma so they are not crushed.
enum ColorLooks {
    static func apply(_ image: CIImage, look: ColorLook, halo: Bool) -> CIImage {
        var current = toPerceptual(image)
        current = baseFilm(current)
        switch look {
        case .none:
            break
        case .positive:
            current = positive(current)
        case .negative:
            current = negative(current)
        case .mono:
            current = mono(current)
        }
        if halo {
            current = bloom(current)
        }
        return toLinear(current)
    }

    private static func toPerceptual(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.4545])
    }

    /// Global film curve for the default look. Real blacks, a little midtone snap, soft highlight shoulder.
    /// No local tone mapping. Fine sharpening only.
    private static func baseFilm(_ image: CIImage) -> CIImage {
        let curved = tone(image, points: [
            (0.00, 0.00),
            (0.16, 0.09),
            (0.42, 0.40),
            (0.70, 0.74),
            (1.00, 0.97)
        ])
        let colored = curved.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.12,
            kCIInputBrightnessKey: 0,
            kCIInputContrastKey: 1.04
        ])
        return colored.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 0.6,
            kCIInputIntensityKey: 0.4
        ])
    }

    private static func toLinear(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.2])
    }

    private static func positive(_ image: CIImage) -> CIImage {
        let curved = tone(image, points: [
            (0, 0.015),
            (0.22, 0.16),
            (0.50, 0.52),
            (0.78, 0.86),
            (1, 0.98)
        ])
        let colored = curved.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.28,
            kCIInputBrightnessKey: -0.01,
            kCIInputContrastKey: 1.08
        ])
        return colored.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.08, y: 0.02, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.94, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0.02, z: 0.92, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.012, y: 0, z: -0.01, w: 0)
        ])
    }

    private static func negative(_ image: CIImage) -> CIImage {
        let lifted = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputHighlightAmount": 0.72,
            "inputShadowAmount": 0.42
        ])
        let curved = tone(lifted, points: [
            (0, 0.07),
            (0.25, 0.30),
            (0.50, 0.52),
            (0.75, 0.73),
            (1, 0.93)
        ])
        let colored = curved.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.78,
            kCIInputBrightnessKey: 0.02,
            kCIInputContrastKey: 0.92
        ])
        return colored.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.96, y: 0.04, z: 0, w: 0),
            "inputGVector": CIVector(x: 0.02, y: 0.98, z: 0.02, w: 0),
            "inputBVector": CIVector(x: 0, y: 0.04, z: 1.05, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.01, y: 0.01, z: 0.015, w: 0)
        ])
    }

    private static func mono(_ image: CIImage) -> CIImage {
        let weights = CIVector(x: 0.45, y: 0.42, z: 0.13, w: 0)
        let gray = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": weights,
            "inputGVector": weights,
            "inputBVector": weights,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let curved = tone(gray, points: [
            (0, 0.035),
            (0.20, 0.11),
            (0.48, 0.46),
            (0.76, 0.84),
            (1, 1)
        ])
        return curved.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 1.6,
            kCIInputIntensityKey: 0.35
        ])
    }

    /// High-light diffusion only. Fixed threshold and radius. Stacks on any base look.
    private static func bloom(_ image: CIImage) -> CIImage {
        let floor = CGFloat(0.78)
        let clamped = image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: floor, y: floor, z: floor, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
        let excess = clamped.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -floor, y: -floor, z: -floor, w: 0)
        ])
        let longest = Swift.max(image.extent.width, image.extent.height)
        let sigma = Swift.max(8, longest * 0.035)
        let blurred = excess.applyingGaussianBlur(sigma: sigma).cropped(to: image.extent)
        guard let screen = CIFilter(name: "CIScreenBlendMode") else { return image }
        screen.setValue(blurred, forKey: kCIInputImageKey)
        screen.setValue(image, forKey: kCIInputBackgroundImageKey)
        guard let bloomed = screen.outputImage?.cropped(to: image.extent) else { return image }
        guard let dissolve = CIFilter(name: "CIDissolveTransition") else { return image }
        dissolve.setValue(image, forKey: kCIInputImageKey)
        dissolve.setValue(bloomed, forKey: kCIInputTargetImageKey)
        dissolve.setValue(0.42, forKey: kCIInputTimeKey)
        let mixed = (dissolve.outputImage ?? image).cropped(to: image.extent)
        return mixed.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1,
            kCIInputBrightnessKey: 0.008,
            kCIInputContrastKey: 0.94
        ])
    }

    private static func tone(_ image: CIImage, points: [(CGFloat, CGFloat)]) -> CIImage {
        var parameters: [String: Any] = [:]
        for (index, point) in points.enumerated() {
            parameters["inputPoint\(index)"] = CIVector(x: point.0, y: point.1)
        }
        return image.applyingFilter("CIToneCurve", parameters: parameters)
    }
}

enum ColorLook: String, CaseIterable, Identifiable, Codable {
    case none
    case positive
    case negative
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "无"
        case .positive: "正片"
        case .negative: "负片"
        case .mono: "黑白"
        }
    }
}
