import CoreGraphics
import Foundation

@main
enum ChromeLayoutTests {
    static func main() {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        func shutterOnScreen(_ layout: CaptureChromeLayout, height: CGFloat, home: CGFloat, name: String) {
            let bottom = layout.shutterCenter.y + layout.shutterSize.height / 2
            let limit = height - home - 3
            expect(bottom <= limit + 0.5, "\(name) shutter extends past the home limit: bottom=\(bottom) limit=\(limit) height=\(layout.shutterSize.height)")
            expect(layout.rulerFrame.minY >= layout.photoFrame.maxY + 8 - 0.5,
                   "\(name) ruler overlaps photo: rulerTop=\(layout.rulerFrame.minY) photoMaxY=\(layout.photoFrame.maxY)")
        }

        // Figma 390×844, safe top 47, home 34 — ruler stays under the photo, shutter 148×64 unchanged.
        let fig = CaptureChromeLayout.measure(width: 390, height: 844, island: 47, home: 34)
        shutterOnScreen(fig, height: 844, home: 34, name: "Figma")
        expect(abs(fig.shutterSize.height - 64) < 0.5, "Figma shutter height should stay 64, got \(fig.shutterSize.height)")

        let small = CaptureChromeLayout.measure(width: 320, height: 568, island: 20, home: 20)
        shutterOnScreen(small, height: 568, home: 20, name: "small-screen")

        let se = CaptureChromeLayout.measure(width: 375, height: 667, island: 20, home: 20)
        shutterOnScreen(se, height: 667, home: 20, name: "SE")

        let pro = CaptureChromeLayout.measure(width: 402, height: 874, island: 62, home: 34)
        shutterOnScreen(pro, height: 874, home: 34, name: "17 Pro")
        expect(abs(pro.shutterSize.height - 64) < 0.5, "17 Pro shutter height should stay 64, got \(pro.shutterSize.height)")

        if notes.isEmpty {
            print("CHROME LAYOUT PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("CHROME LAYOUT FAILED \(notes.count)")
        }
    }
}
