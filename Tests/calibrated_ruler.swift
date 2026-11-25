import CoreGraphics
import Foundation

@main
enum CalibratedRulerTests {
    static func main() {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        let design = CalibratedRulerMetrics.marks(for: 88)
        expect(abs(design.tickY - 42) < 0.01, "88pt tickY should stay 42, got \(design.tickY)")
        expect(abs(design.needleY - 39) < 0.01, "88pt needleY should stay 39, got \(design.needleY)")
        expect(abs(design.needleHeight - 22) < 0.01, "88pt needleHeight should stay 22, got \(design.needleHeight)")
        expect(abs(design.labelY - 70) < 0.01, "88pt labelY should stay 70, got \(design.labelY)")
        expect(abs(design.headerHeight - 40) < 0.01, "88pt headerHeight should stay 40, got \(design.headerHeight)")
        expect(design.needleMaxY <= 88, "88pt needle overflows height")
        expect(design.labelMaxY <= 88 + 0.5, "88pt labels overflow height: \(design.labelMaxY)")

        for height in [CGFloat(56), 64, 70, 88] {
            let marks = CalibratedRulerMetrics.marks(for: height)
            expect(marks.height == height, "marks.height \(marks.height) != \(height)")
            expect(marks.tickY >= 0, "tickY negative at \(height)")
            expect(marks.tickMajorMaxY <= height + 0.5,
                   "major ticks overflow \(height): maxY=\(marks.tickMajorMaxY)")
            expect(marks.needleY >= 0 && marks.needleMaxY <= height + 0.5,
                   "needle overflows \(height): \(marks.needleY)...\(marks.needleMaxY)")
            expect(marks.labelY >= 0 && marks.labelMaxY <= height + 0.5,
                   "labels overflow \(height): y=\(marks.labelY) maxY=\(marks.labelMaxY)")
            expect(marks.zeroDotY >= 0 && marks.zeroDotY + marks.zeroDotSize <= height + 0.5,
                   "zero dot overflows \(height)")
            expect(marks.headerHeight < height, "header should leave room for ticks at \(height)")
        }

        // The small-screen layout height that used to keep drawing at 88 pt.
        let small = CalibratedRulerMetrics.marks(for: 56)
        expect(small.scale < 1, "56pt ruler should scale down, scale=\(small.scale)")
        expect(small.needleHeight < 22, "56pt needle should shrink")
        expect(abs(small.needleMaxY - 61 * 56 / 88) < 0.5, "56pt needle end should scale with 88pt design")

        if notes.isEmpty {
            print("CALIBRATED RULER PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("CALIBRATED RULER FAILED \(notes.count)")
        }
    }
}
