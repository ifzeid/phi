import Foundation

@main
enum ExposureTicks {
    static func main() {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        expect(ExposureFormat.tick(-2) == "−2", "tick -2 is \(ExposureFormat.tick(-2))")
        expect(ExposureFormat.tick(-1) == "−1", "tick -1 is \(ExposureFormat.tick(-1))")
        expect(ExposureFormat.tick(0) == "0", "tick 0 is \(ExposureFormat.tick(0))")
        expect(ExposureFormat.tick(1) == "1", "tick 1 is \(ExposureFormat.tick(1))")
        expect(ExposureFormat.tick(2) == "2", "tick 2 is \(ExposureFormat.tick(2))")
        for value in [-2, -1, 0, 1, 2] {
            let label = ExposureFormat.tick(value)
            expect(label.contains(".") == false, "tick \(value) kept a decimal: \(label)")
        }

        expect(ExposureFormat.readout(0) == "0", "readout 0 is \(ExposureFormat.readout(0))")
        expect(ExposureFormat.readout(0.0) == "0", "readout 0.0 is \(ExposureFormat.readout(0.0))")
        expect(ExposureFormat.readout(1) == "1", "readout 1 is \(ExposureFormat.readout(1))")
        expect(ExposureFormat.readout(-2) == "−2", "readout -2 is \(ExposureFormat.readout(-2))")
        expect(ExposureFormat.readout(0.3) == "+0.3", "fractional live readout lost a decimal")
        expect(ExposureFormat.readout(-0.3) == "−0.3", "negative fraction readout is \(ExposureFormat.readout(-0.3))")
        expect(ExposureFormat.signedDecimal(0) == "0", "signedDecimal 0 is not 0")
        expect(ExposureFormat.readout(0).contains(".") == false, "live zero still has a decimal")
        expect(ExposureFormat.readout(1).contains(".") == false, "live 1 still has a decimal")

        if notes.isEmpty {
            print("exposure ticks passed")
        } else {
            print(notes.joined(separator: "\n"))
            exit(1)
        }
    }
}
