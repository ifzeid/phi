# PHI tests

Lightweight unit tests that compile with `swiftc` (no Xcode):

```
Tests/run_b40.sh
```

That runner covers save-state, chrome layout, calibrated ruler metrics, display zoom, framed orientation, export source (including EXIF 6/8 and non-3:4 sizes), album delete sync, and source-warm timeout/order.

Simulator editor and performance cases use launch arguments (`-PHIUITestEditorNight`, `-PHIUITestEditorFraming`, `-PHIUITestEditorEVSweep`, `-PHIUITestPerf`, and others). They are not a claim that the suite is all green.

## Known remaining results (simulator, 2026-11-25)

- **Night chroma:** `EDITOR NIGHT FAILED` on `PHI-20261029-185924` export beam chroma **0.155**. Same result on builds 36, 37, 39, 40, and 41. This is a known develop/export issue, not treated as fixed.
- **12MP save budget:** `PerfTrace.saveMs` is **2000** ms. Quiet isolated official samples on Build 42 averaged about **2158** ms (`sharedTrue` 2153.1, current export-context policy 2157.8; n=5 each). No official sample was under 2000. The October 30 v31 baseline was 1808.5. This budget is **not met** on the current simulator/host; do not treat a single isolated pass as success.

Framing and Mode 0 2× EV sweep (`PHI-20261030-135913`, +2.0 = 0.775) passed on Builds 40 and 41 after the review-fix pass. Device camera behavior is not covered by these notes.
