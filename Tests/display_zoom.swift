import Foundation

@main
enum DisplayZoomTests {
    static func main() {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        for mode in [ProcessMode.bayer, .standard] {
            let zoom = DisplayZoom.forDisplayStill(processMode: mode, captureZoom: 2, hasDevelopedDisplay: false)
            expect(zoom == 1, "\(mode.rawValue) capture 2× undeveloped display zoom \(zoom), want 1")
            let developed = DisplayZoom.forDisplayStill(processMode: mode, captureZoom: 2, hasDevelopedDisplay: true)
            expect(developed == 1, "\(mode.rawValue) capture 2× developed display zoom \(developed), want 1")
        }

        let proRawUndeveloped = DisplayZoom.forDisplayStill(processMode: .proRaw, captureZoom: 2, hasDevelopedDisplay: false)
        expect(proRawUndeveloped == 2, "ProRAW undeveloped 2× display zoom \(proRawUndeveloped), want 2")
        let proRawDeveloped = DisplayZoom.forDisplayStill(processMode: .proRaw, captureZoom: 2, hasDevelopedDisplay: true)
        expect(proRawDeveloped == 1, "ProRAW developed 2× display zoom \(proRawDeveloped), want 1")

        let unknownUndeveloped = DisplayZoom.forDisplayStill(processMode: nil, captureZoom: 2, hasDevelopedDisplay: false)
        expect(unknownUndeveloped == 2, "unknown undeveloped 2× display zoom \(unknownUndeveloped), want 2")
        let unknownDeveloped = DisplayZoom.forDisplayStill(processMode: nil, captureZoom: 2, hasDevelopedDisplay: true)
        expect(unknownDeveloped == 1, "unknown developed 2× display zoom \(unknownDeveloped), want 1")

        let oneX = DisplayZoom.forDisplayStill(processMode: .standard, captureZoom: 1, hasDevelopedDisplay: true)
        expect(oneX == 1, "1× stays 1")

        if notes.isEmpty {
            print("DISPLAY ZOOM PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("DISPLAY ZOOM FAILED \(notes.count)")
        }
    }
}
