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
        let fig = CaptureChromeLayout.measure(width: 390, height: 844, island: 47, home: 34, scale: 3)
        shutterOnScreen(fig, height: 844, home: 34, name: "Figma")
        expect(abs(fig.shutterSize.height - 64) < 0.5, "Figma shutter height should stay 64, got \(fig.shutterSize.height)")

        let small = CaptureChromeLayout.measure(width: 320, height: 568, island: 20, home: 20, scale: 2)
        shutterOnScreen(small, height: 568, home: 20, name: "small-screen")

        let se = CaptureChromeLayout.measure(width: 375, height: 667, island: 20, home: 20, scale: 2)
        shutterOnScreen(se, height: 667, home: 20, name: "SE")

        let pro = CaptureChromeLayout.measure(width: 402, height: 874, island: 62, home: 34, scale: 3)
        shutterOnScreen(pro, height: 874, home: 34, name: "17 Pro")
        expect(abs(pro.shutterSize.height - 64) < 0.5, "17 Pro shutter height should stay 64, got \(pro.shutterSize.height)")


        // 4 pt at every scale (12 px on @3x, 8 px on @2x).
        expect(abs(CaptureChromeLayout.finderBorderWidth(scale: 3) - 4) < 0.001, "3x border should be 4 pt")
        expect(abs(CaptureChromeLayout.finderBorderWidth(scale: 2) - 4) < 0.001, "2x border should be 4 pt")
        expect(abs(CaptureChromeLayout.finderBorderWidth(scale: 1) - 4) < 0.001, "1x border should be 4 pt")
        expect(abs(fig.finderBorderWidth - 4) < 0.001, "Figma border stored wrong: \(fig.finderBorderWidth)")
        expect(abs(pro.finderBorderWidth - 4) < 0.001, "17 Pro border stored wrong: \(pro.finderBorderWidth)")
        expect(abs(small.finderBorderWidth - 4) < 0.001, "small-screen border stored wrong: \(small.finderBorderWidth)")
        expect(abs(se.finderBorderWidth - 4) < 0.001, "SE border stored wrong: \(se.finderBorderWidth)")

        func topGap(_ layout: CaptureChromeLayout, name: String) {
            let buttonBottom = layout.settingsCenter.y + 18
            let expectedTop = buttonBottom + CaptureChromeLayout.topButtonGap
            expect(abs(layout.surroundFrame.minY - expectedTop) < 0.5,
                   "\(name) surround top \(layout.surroundFrame.minY) should sit \(CaptureChromeLayout.topButtonGap) pt below the button row (\(buttonBottom))")
            expect(layout.surroundFrame.minY >= buttonBottom + CaptureChromeLayout.topButtonGap - 0.5,
                   "\(name) no clear gap between top buttons and finder frame")
        }
        topGap(fig, name: "Figma")
        topGap(small, name: "small-screen")
        topGap(se, name: "SE")
        topGap(pro, name: "17 Pro")

        // Shared capture/editor content rect: same measure + aspect → same x/y/w/h.
        // Metric is the image content, not the 4 pt surround.
        func contentChecks(_ layout: CaptureChromeLayout, name: String) {
            let three = layout.contentFrame(for: .threeByFour)
            expect(three == layout.photoFrame, "\(name) 3:4 content must equal photoFrame, got \(three) vs \(layout.photoFrame)")
            expect(three.minX >= 16 - 0.5 || layout.photoFrame.width < layout.width - 32,
                   "\(name) 3:4 content should respect the side inset when unshrunk")
            expect(layout.surroundFrame.minX == layout.photoFrame.minX - 4, "\(name) surround is not 4 pt outside the content")
            expect(layout.surroundFrame.minY == layout.photoFrame.minY - 4, "\(name) surround top is not 4 pt outside the content")

            let square = layout.contentFrame(for: .square)
            expect(abs(square.width - square.height) < 0.5, "\(name) 1:1 content is not square: \(square)")
            expect(abs(square.width - layout.photoFrame.width) < 0.5, "\(name) 1:1 should use the full photo width")
            expect(abs(square.midX - layout.photoFrame.midX) < 0.5, "\(name) 1:1 not horizontally centered in the 3:4 slot")
            expect(abs(square.midY - layout.photoFrame.midY) < 0.5, "\(name) 1:1 not vertically centered in the 3:4 slot")
            expect(square.minY > layout.photoFrame.minY + 1, "\(name) 1:1 should letterbox inside the 3:4 slot, not fill it")

            let tall = layout.contentFrame(for: .nineBySixteen)
            expect(abs((tall.width / tall.height) - (9.0 / 16.0)) < 0.01, "\(name) 9:16 content ratio off: \(tall)")
            expect(abs(tall.height - layout.photoFrame.height) < 0.5, "\(name) 9:16 should use the full photo height")
            expect(abs(tall.midX - layout.photoFrame.midX) < 0.5, "\(name) 9:16 not horizontally centered")
            expect(tall.minX > layout.photoFrame.minX + 1, "\(name) 9:16 should be narrower than the 3:4 slot")

            // Top button baseline is the same 36 pt row for capture and editor.
            expect(abs(layout.topButtonCenterY - (layout.settingsCenter.y)) < 0.001, "\(name) top baseline drifted")
            expect(abs(layout.rawCenter.y - layout.settingsCenter.y) < 0.001, "\(name) RAW and settings baselines differ")
            expect(abs(CaptureChromeLayout.topButtonHeight - 36) < 0.001, "top button height must stay 36 pt")
        }
        contentChecks(fig, name: "Figma")
        contentChecks(small, name: "small-screen")
        contentChecks(se, name: "SE")
        contentChecks(pro, name: "17 Pro")

        // ProcessMode UI strings share the homepage RAW wording; marks stay off-screen.
        for mode in ProcessMode.allCases {
            expect(mode.settingsTitle == mode.finderWord, "\(mode) settingsTitle \(mode.settingsTitle) != finderWord \(mode.finderWord)")
            expect(["0", "Φ", "1", "0.5"].contains(mode.finderWord) == false, "\(mode) finderWord is a schematic mark: \(mode.finderWord)")
            expect(mode.finderWord.contains("0") == false && mode.finderWord.contains("1") == false && mode.finderWord.contains("0.5") == false,
                   "\(mode) finderWord still contains a schematic digit: \(mode.finderWord)")
        }
        expect(ProcessMode.bayer.finderWord == "RAW", "bayer should display RAW")
        expect(ProcessMode.proRaw.finderWord == "ProRAW", "proRaw should display ProRAW")
        expect(ProcessMode.standard.finderWord == "标准", "standard should display 标准")
        expect(ProcessMode.bayer.mark == "0", "log mark for bayer should remain 0")
        expect(ProcessMode.standard.mark == "1", "log mark for standard should remain 1")

        if notes.isEmpty {
            print("CHROME LAYOUT PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("CHROME LAYOUT FAILED \(notes.count)")
        }
    }
}
