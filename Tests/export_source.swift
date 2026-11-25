import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum ExportSourceTests {
    static func main() {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phi-export-source-test", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let fullURL = folder.appendingPathComponent("full.jpg")
        let previewURL = folder.appendingPathComponent("preview.jpg")
        writeJPEG(fullURL, image: makeImage(width: 4032, height: 3024), orientation: 1)
        writeJPEG(previewURL, image: makeImage(width: 1280, height: 960), orientation: 1)

        let loaded = ExportSource.loadImage(url: fullURL, data: nil)
        expect(loaded != nil, "full-res file should decode")
        if let loaded {
            expect(loaded.image.width == 4032 && loaded.image.height == 3024,
                   "export source was \(loaded.image.width)x\(loaded.image.height), want 4032x3024 not the 1280 preview")
            expect((loaded.fileData?.count ?? 0) > 0, "original file bytes should be available for a neutral copy")
        }

        let preview = ExportSource.loadImage(url: previewURL, data: nil)
        expect(preview?.image.width == 1280, "sanity: preview file is 1280 wide")
        expect(loaded?.image.width != preview?.image.width, "full-res must not equal the 1280 proxy")

        let fallback = ExportSource.loadImage(url: nil, data: nil)
        expect(fallback == nil, "missing source should be nil so the caller can fall back explicitly")

        let data = try! Data(contentsOf: fullURL)
        let fromData = ExportSource.loadImage(url: nil, data: data)
        expect(fromData?.image.width == 4032, "in-memory original data should also be full resolution")

        let payload = ExportSource.filePayload(data, url: fullURL)
        expect(payload.ext == "jpg", "jpeg payload ext \(payload.ext)")
        expect(payload.data.count == data.count, "neutral export must keep original bytes")

        // --- orientation 6 / 8, aspect, zoom, neutral vs non-neutral ---
        let landscape = makeImage(width: 4000, height: 3000, mark: .rightEdge)
        for exif in [6, 8] {
            let url = folder.appendingPathComponent("ori\(exif).jpg")
            writeJPEG(url, image: landscape, orientation: exif)
            let file = try! Data(contentsOf: url)
            expect(ExportSource.exifOrientation(of: file).rawValue == UInt32(exif),
                   "EXIF of ori\(exif) file is \(ExportSource.exifOrientation(of: file).rawValue)")

            // Neutral copy keeps the original pixels and the original orientation tag.
            let neutral = ExportSource.filePayload(file, url: url)
            expect(neutral.data.count == file.count, "ori\(exif) neutral copy must keep original bytes")
            expect(ExportSource.exifOrientation(of: neutral.data).rawValue == UInt32(exif),
                   "ori\(exif) neutral copy lost EXIF (now \(ExportSource.exifOrientation(of: neutral.data).rawValue))")
            let neutralPixels = ExportSource.decode(neutral.data)
            expect(neutralPixels?.width == 4000 && neutralPixels?.height == 3000,
                   "ori\(exif) neutral pixels should stay 4000x3000, got \(neutralPixels?.width ?? 0)x\(neutralPixels?.height ?? 0)")

            let orientation = CGImagePropertyOrientation(rawValue: UInt32(exif))!
            let prepared = ExportSource.preparedDisplayPixels(
                url: url,
                data: nil,
                fallback: nil,
                aspect: .threeByFour,
                zoom: 1
            )
            expect(prepared != nil, "ori\(exif) prepared pixels missing")
            if let prepared {
                let ratio = Double(prepared.width) / Double(prepared.height)
                let want = Double(PhotoAspect.threeByFour.widthOverHeight)
                expect(prepared.width < prepared.height, "ori\(exif) 3:4 display should be portrait, got \(prepared.width)x\(prepared.height)")
                expect(abs(ratio - want) <= 0.03, "ori\(exif) prepared ratio \(ratio) want \(want)")
                let direct = ImageFraming.framedPixels(landscape, orientation: orientation, aspect: .threeByFour, zoom: 1)
                expect(prepared.width == direct.width && prepared.height == direct.height,
                       "ori\(exif) prepared \(prepared.width)x\(prepared.height) != framedPixels \(direct.width)x\(direct.height)")

                // Non-neutral encode tags orientation 1 to match the already-upright pixels.
                let encodedURL = folder.appendingPathComponent("ori\(exif)-developed.jpg")
                writeJPEG(encodedURL, image: prepared, orientation: 1)
                let encoded = try! Data(contentsOf: encodedURL)
                expect(ExportSource.exifOrientation(of: encoded).rawValue == 1,
                       "ori\(exif) developed file must tag orientation 1, got \(ExportSource.exifOrientation(of: encoded).rawValue)")
                let encodedPixels = ExportSource.decode(encoded)
                expect(encodedPixels?.width == prepared.width && encodedPixels?.height == prepared.height,
                       "ori\(exif) developed pixels \(encodedPixels?.width ?? 0)x\(encodedPixels?.height ?? 0) must match prepared \(prepared.width)x\(prepared.height)")
            }
        }

        let upright = makeImage(width: 4000, height: 3000)
        let squareURL = folder.appendingPathComponent("square.jpg")
        writeJPEG(squareURL, image: upright, orientation: 1)
        let square = ExportSource.preparedDisplayPixels(url: squareURL, data: nil, fallback: nil, aspect: .square, zoom: 1)
        expect(square != nil && square!.width == square!.height,
               "square aspect should be 1:1, got \(square?.width ?? 0)x\(square?.height ?? 0)")

        let sixteen = ExportSource.preparedDisplayPixels(url: squareURL, data: nil, fallback: nil, aspect: .nineBySixteen, zoom: 1)
        if let sixteen {
            let ratio = Double(sixteen.width) / Double(sixteen.height)
            expect(abs(ratio - Double(PhotoAspect.nineBySixteen.widthOverHeight)) <= 0.03,
                   "9:16 prepared ratio \(ratio)")
        } else {
            expect(false, "9:16 prepared missing")
        }

        let twoByThree = ExportSource.preparedDisplayPixels(url: squareURL, data: nil, fallback: nil, aspect: .twoByThree, zoom: 1)
        if let twoByThree {
            let ratio = Double(twoByThree.width) / Double(twoByThree.height)
            expect(abs(ratio - Double(PhotoAspect.twoByThree.widthOverHeight)) <= 0.03,
                   "2:3 prepared ratio \(ratio)")
        } else {
            expect(false, "2:3 prepared missing")
        }

        let zoomed = ExportSource.preparedDisplayPixels(url: squareURL, data: nil, fallback: nil, aspect: .threeByFour, zoom: 2)
        let unzoomed = ExportSource.preparedDisplayPixels(url: squareURL, data: nil, fallback: nil, aspect: .threeByFour, zoom: 1)
        expect(zoomed != nil && unzoomed != nil, "2x / 1x prepared missing")
        if let zoomed, let unzoomed {
            expect(zoomed.width * 2 <= unzoomed.width + 4,
                   "2x crop should be about half the width: 2x=\(zoomed.width) 1x=\(unzoomed.width)")
            let ratio = Double(zoomed.width) / Double(zoomed.height)
            expect(abs(ratio - Double(PhotoAspect.threeByFour.widthOverHeight)) <= 0.03,
                   "2x 3:4 ratio \(ratio)")
        }

        // Orientation 6 + 2x + square: bake first, then zoom, then aspect, once.
        let combo = ExportSource.preparedDisplayPixels(
            url: folder.appendingPathComponent("ori6.jpg"),
            data: nil,
            fallback: nil,
            aspect: .square,
            zoom: 2
        )
        expect(combo != nil && combo!.width == combo!.height, "ori6 2x square should be 1:1, got \(combo?.width ?? 0)x\(combo?.height ?? 0)")
        if let combo {
            expect(combo.width < 3000, "ori6 2x square should be smaller than the upright short side, got \(combo.width)")
        }

        if notes.isEmpty {
            print("EXPORT SOURCE PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("EXPORT SOURCE FAILED \(notes.count)")
        }
    }

    enum Mark { case none, rightEdge }

    static func makeImage(width: Int, height: Int, mark: Mark = .none) -> CGImage {
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
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.25, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if mark == .rightEdge {
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: width - 40, y: 0, width: 40, height: height))
        }
        return context.makeImage()!
    }

    static func writeJPEG(_ url: URL, image: CGImage, orientation: Int) {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation
        ]
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        CGImageDestinationFinalize(destination)
        try! data.write(to: url, options: .atomic)
    }
}
