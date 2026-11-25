import CoreGraphics
import Foundation
import ImageIO

@main
enum FramedOrientationProbe {
    static func main() {
        // Landscape sensor buffer 4000×3000 (4:3). A phone portrait still is often this
        // bitmap plus UIImage.Orientation.right, displayed as 3000×4000 (3:4).
        let landscape = makeImage(width: 4000, height: 3000)
        let cropped = PhotoAspect.threeByFour.cropped(landscape)
        let pixelRatio = Double(cropped.width) / Double(cropped.height)
        // AlbumImage.framed keeps imageOrientation and crops the raw CGImage.
        let displayedWidth = cropped.height   // .right swaps axes for display
        let displayedHeight = cropped.width
        let displayRatio = Double(displayedWidth) / Double(displayedHeight)
        let want = Double(PhotoAspect.threeByFour.widthOverHeight)

        print("FRAMED ORIENTATION PROBE")
        print("source pixels \(landscape.width)x\(landscape.height) ratio=\(String(format: "%.3f", Double(landscape.width)/Double(landscape.height)))")
        print("crop-on-cgImage \(cropped.width)x\(cropped.height) ratio=\(String(format: "%.3f", pixelRatio))")
        print("if orientation=.right, displayed \(displayedWidth)x\(displayedHeight) ratio=\(String(format: "%.3f", displayRatio)) want=\(String(format: "%.3f", want))")

        if abs(displayRatio - want) > 0.03 {
            print("EVIDENCE: framed() on a non-up UIImage yields display aspect \(String(format: "%.3f", displayRatio)), not \(String(format: "%.3f", want)).")
            print("CAUSE: PhotoAspect.cropped and LensCrop.cropped use cgImage pixel axes; orientation is re-wrapped, not applied.")
            print("EditorMatch.failures() uses UIImage(cgImage:) (.up) so it does not catch this.")
        } else {
            print("display aspect matched 3:4 (unexpected for this probe)")
        }

        // Correct order: bake orientation, then crop.
        let upright = makeImage(width: 3000, height: 4000) // drawn result of .right
        let uprightCropped = PhotoAspect.threeByFour.cropped(upright)
        let uprightRatio = Double(uprightCropped.width) / Double(uprightCropped.height)
        print("upright-then-crop \(uprightCropped.width)x\(uprightCropped.height) ratio=\(String(format: "%.3f", uprightRatio))")
        if abs(uprightRatio - want) > 0.03 {
            print("FAIL upright path")
            exit(1)
        }
        print("MINIMAL FIX: normalize orientation (StillPipeline.normalizedCGImage) inside AlbumImage.framed before crop; return .up.")
        print("FRAMED ORIENTATION PROBE DONE")
    }

    static func makeImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
