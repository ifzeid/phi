#!/bin/zsh
set -euo pipefail
cd /Users/zeid/Developer/phi
OUT=/tmp/phi-b37-tests
mkdir -p "$OUT"

echo "COMPILE facts_sidecar"
swiftc -parse-as-library -o "$OUT/facts_sidecar" \
  Tests/facts_sidecar.swift Phi/Camera/FactsSidecar.swift Phi/Camera/CaptureFormat.swift
"$OUT/facts_sidecar"

echo "COMPILE photo_save_state"
swiftc -parse-as-library -o "$OUT/photo_save_state" \
  Tests/photo_save_state.swift Phi/Camera/PhotoLibrarySaveState.swift
"$OUT/photo_save_state"

echo "COMPILE chrome_layout"
swiftc -parse-as-library -o "$OUT/chrome_layout" \
  Tests/chrome_layout.swift Tests/SettingsPageStub.swift \
  Phi/Views/CaptureChromeLayout.swift Phi/Camera/CaptureFormat.swift
"$OUT/chrome_layout"

echo "COMPILE exposure_ticks"
swiftc -parse-as-library -o "$OUT/exposure_ticks" \
  Tests/exposure_ticks.swift Phi/Camera/ExposureFormatting.swift
"$OUT/exposure_ticks"

echo "B37 UNIT TESTS PASS"
