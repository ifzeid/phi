import CoreGraphics
import CoreImage
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// Normalize orientation before any crop so pixel axes match what the user sees.
enum ImageFraming {
    static func uprightPixels(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage {
        if orientation == .up { return image }
        let ci = CIImage(cgImage: image).oriented(orientation)
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false
        ]
        let context = CIContext(options: options)
        let extent = ci.extent.integral
        guard extent.width > 1, extent.height > 1,
              let rendered = context.createCGImage(ci, from: extent) else {
            return image
        }
        return rendered
    }

    static func zoomedPixels(_ image: CGImage, zoom: Double) -> CGImage {
        guard zoom > 1.01 else { return image }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 2, height > 2 else { return image }
        let cropWidth = width / zoom
        let cropHeight = height / zoom
        let rect = CGRect(
            x: (width - cropWidth) / 2,
            y: (height - cropHeight) / 2,
            width: cropWidth,
            height: cropHeight
        ).integral
        guard rect.width > 1, rect.height > 1, let cropped = image.cropping(to: rect) else { return image }
        return cropped
    }

    static func framedPixels(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        aspect: PhotoAspect,
        zoom: Double
    ) -> CGImage {
        let upright = uprightPixels(image, orientation: orientation)
        let zoomed = zoomedPixels(upright, zoom: zoom)
        return aspect.cropped(zoomed)
    }

    #if canImport(UIKit)
    static func framed(_ image: UIImage, aspect: PhotoAspect, zoom: Double) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let pixels = framedPixels(cg, orientation: CGImagePropertyOrientation(image.imageOrientation), aspect: aspect, zoom: zoom)
        return UIImage(cgImage: pixels, scale: image.scale, orientation: .up)
    }
    #endif
}

#if canImport(UIKit)
extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
#endif
