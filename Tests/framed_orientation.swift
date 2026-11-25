import CoreGraphics
import Foundation
import ImageIO

@main
enum FramedOrientationTests {
    static func main() {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        let want = Double(PhotoAspect.threeByFour.widthOverHeight)
        // Landscape 4000×3000 buffer with EXIF/UIImage .right displays as 3000×4000 (3:4).
        let landscape = makeImage(width: 4000, height: 3000, mark: .topLeft)
        let framed = ImageFraming.framedPixels(landscape, orientation: .right, aspect: .threeByFour, zoom: 1)
        let ratio = Double(framed.width) / Double(framed.height)
        expect(abs(ratio - want) <= 0.03,
               "non-up .right framed display ratio \(String(format: "%.3f", ratio)), want \(String(format: "%.3f", want)) size=\(framed.width)x\(framed.height)")
        expect(framed.width < framed.height, "portrait 3:4 should be taller than wide")

        // Cropping the raw buffer first, then wrapping .right, is the bug: 2250×3000 displays as 4:3.
        let wrong = PhotoAspect.threeByFour.cropped(landscape)
        let wrongDisplayRatio = Double(wrong.height) / Double(wrong.width)
        expect(abs(wrongDisplayRatio - want) > 0.03,
               "sanity: un-normalized crop should still be the wrong display aspect")
        expect(abs(ratio - wrongDisplayRatio) > 0.03,
               "normalized framed result must differ from crop-then-rewrap")

        // Upright source already 3:4 stays 3:4.
        let upright = makeImage(width: 3000, height: 4000, mark: .topLeft)
        let uprightFramed = ImageFraming.framedPixels(upright, orientation: .up, aspect: .threeByFour, zoom: 1)
        let uprightRatio = Double(uprightFramed.width) / Double(uprightFramed.height)
        expect(abs(uprightRatio - want) <= 0.03, "upright framed ratio \(uprightRatio)")

        // 2× on an already-upright 4000×3000 4:3, then 3:4: zoom first on display axes.
        let zoomed = ImageFraming.framedPixels(landscape, orientation: .up, aspect: .threeByFour, zoom: 2)
        expect(zoomed.width < landscape.width, "2× should be smaller than the source width")
        let zoomRatio = Double(zoomed.width) / Double(zoomed.height)
        expect(abs(zoomRatio - want) <= 0.03, "2× framed ratio \(zoomRatio)")

        if notes.isEmpty {
            print("FRAMED ORIENTATION PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("FRAMED ORIENTATION FAILED \(notes.count)")
        }
    }

    enum Mark { case topLeft }

    static func makeImage(width: Int, height: Int, mark: Mark) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CoreGraphics origin is bottom-left; fill a 40×40 square at the displayed top-left
        // after a flip would be y = height-40, but for size/aspect tests the fill is enough.
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 40, width: 40, height: 40))
        _ = mark
        return context.makeImage()!
    }
}
