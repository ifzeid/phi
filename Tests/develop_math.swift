import Foundation

func appliedBaseline(_ tag: Double) -> Double {
    tag > 0 ? tag - 1.5 : tag
}

func sceneGain(baseline: Double, ev: Double) -> Double {
    let stops = appliedBaseline(baseline) + min(5, max(-5, ev))
    return pow(2, stops)
}

func shoulder(_ x: Double) -> Double {
    let value = max(x, 0)
    let knee = 0.62
    let softness = 0.55
    if value <= knee { return value }
    let span = value - knee
    return min(knee + (1 - knee) * (span / (span + softness)), 1)
}

func toneMap(_ x: Double) -> Double {
    let value = max(x, 0)
    let toe = 0.045
    let toed: Double
    if value <= 0 {
        toed = 0
    } else if value >= toe {
        toed = value
    } else {
        let t = value / toe
        toed = toe * t * t
    }
    return shoulder(toed)
}

func emphasis(_ y: Double) -> Double {
    let luma = min(max(y, 0), 1)
    let knee = 0.80
    let end = 0.96
    if luma <= knee { return 0 }
    if luma >= end { return 1 }
    let t = (luma - knee) / (end - knee)
    return t * t * (3 - 2 * t)
}

func addBloom(base: Double, glow: Double, scatter: Double) -> Double {
    let extra = scatter * glow
    if extra <= 0.0001 { return base }
    if base >= 1 { return base }
    return min(base + extra, 1)
}

func snapTenth(_ raw: Double) -> Double {
    let clamped = min(5, max(-5, raw))
    return (clamped * 10).rounded() / 10
}

func tickKind(_ index: Int) -> String {
    let majorCount = 2
    let halfCount = 1
    let raw = index % majorCount
    let slot = raw >= 0 ? raw : raw + majorCount
    if slot == 0 { return "major" }
    if slot == halfCount { return "half" }
    return "fine"
}

var notes: [String] = []
func expect(_ ok: Bool, _ message: String) {
    if ok == false { notes.append(message) }
}

expect(toneMap(0) == 0 && toneMap(-0.2) == 0, "black point is not 0")
expect(abs(toneMap(0.18) - 0.18) < 1e-9, "mid gray moved")
let high = shoulder(2)
expect(high < 1 && high > 0.62, "shoulder did not roll a highlight")
expect(abs(sceneGain(baseline: 0, ev: -1) - 0.5) < 1e-12, "zero baseline was trimmed")
expect(abs(sceneGain(baseline: 2, ev: 0) - pow(2, 0.5)) < 1e-12, "EV 0 is not 1.5 under a +2 tag")

let sample = 0.18
var previous = 2.0
for ev in stride(from: 5, through: -5, by: -1) {
    let mapped = toneMap(sample * sceneGain(baseline: 0, ev: Double(ev)))
    expect(mapped < previous - 1e-9, "EV \(ev) did not darken")
    expect(toneMap(0) == 0, "black lifted at EV \(ev)")
    previous = mapped
}
for stop in [-1.0, 0.4, 1.0] {
    let post = toneMap(sample * sceneGain(baseline: 1.2, ev: stop))
    let finder = toneMap(sample * pow(2, stop) * sceneGain(baseline: 1.2, ev: 0))
    expect(abs(post - finder) < 1e-12, "finder EV \(stop) is not editor EV \(stop)")
}
expect(emphasis(0.2) == 0, "halo mask is not zero below the knee")
expect(addBloom(base: 0.02, glow: 0, scatter: 1.05) == 0.02, "halo changed a pixel with no glow")
expect(addBloom(base: 0.02, glow: 1e-6, scatter: 1.05) == 0.02, "halo dust changed a far pixel")
expect(addBloom(base: 0.40, glow: 0.10, scatter: 0.42) > 0.40, "halo did not add energy beside a highlight")
let kinds = (-10...10).map(tickKind)
expect(kinds.filter { $0 == "major" }.count == 11 && kinds.filter { $0 == "half" }.count == 10 && kinds.contains("fine") == false, "ruler ticks are not half stops")
expect(snapTenth(0.14) == 0.1 && snapTenth(0.16) == 0.2 && snapTenth(9) == 5 && snapTenth(-9) == -5, "EV snap is not 0.1 inside ±5")

if notes.isEmpty {
    print("develop math passed")
} else {
    print(notes.joined(separator: "\n"))
    exit(1)
}
