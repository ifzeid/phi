import Foundation

@main
enum FactsSidecarTests {
    static func main() {
        var notes: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition == false { notes.append(message) }
        }

        let spaced = FactsSidecar.parse("zoom=2 aspect=square")
        expect(spaced.zoom == 2, "space-separated zoom is \(String(describing: spaced.zoom))")
        expect(spaced.aspect == .square, "aspect=square is \(String(describing: spaced.aspect))")

        let newline = FactsSidecar.parse("zoom=2\naspect=square\n")
        expect(newline.zoom == 2 && newline.aspect == .square, "newline sidecar failed")

        let crlf = FactsSidecar.parse("zoom=2\r\naspect=square\r\n")
        expect(crlf.zoom == 2 && crlf.aspect == .square, "CRLF sidecar failed")

        let cr = FactsSidecar.parse("zoom=2\raspect=square")
        expect(cr.zoom == 2 && cr.aspect == .square, "CR sidecar failed")

        let tabs = FactsSidecar.parse("  zoom=2.5\taspect=threeByFour  ")
        expect(tabs.zoom == 2.5, "tab/trim zoom is \(String(describing: tabs.zoom))")
        expect(tabs.aspect == .threeByFour, "tab aspect is \(String(describing: tabs.aspect))")

        let ignored = FactsSidecar.parse("zoom=1 aspect=nope")
        expect(ignored.zoom == nil, "zoom=1 should be ignored, got \(String(describing: ignored.zoom))")
        expect(ignored.aspect == nil, "unknown aspect should be ignored")

        if notes.isEmpty {
            print("FACTS SIDECAR PASS")
        } else {
            notes.forEach { print("FAIL \($0)") }
            fatalError("FACTS SIDECAR FAILED \(notes.count)")
        }
    }
}
