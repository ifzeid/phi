#!/bin/zsh
set -euo pipefail
cd /Users/zeid/Developer/phi
OUT=/tmp/phi-b40-tests
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

echo "COMPILE calibrated_ruler"
swiftc -parse-as-library -o "$OUT/calibrated_ruler" \
  Tests/calibrated_ruler.swift Phi/Views/CalibratedRulerMetrics.swift
"$OUT/calibrated_ruler"

echo "COMPILE exposure_ticks"
swiftc -parse-as-library -o "$OUT/exposure_ticks" \
  Tests/exposure_ticks.swift Phi/Camera/ExposureFormatting.swift
"$OUT/exposure_ticks"

echo "COMPILE framed_orientation"
swiftc -parse-as-library -o "$OUT/framed_orientation" \
  Tests/framed_orientation.swift \
  Phi/Camera/ImageFraming.swift Phi/Camera/CaptureFormat.swift
"$OUT/framed_orientation"

echo "COMPILE display_zoom"
swiftc -parse-as-library -o "$OUT/display_zoom" \
  Tests/display_zoom.swift Phi/Camera/CaptureFormat.swift
"$OUT/display_zoom"

echo "COMPILE export_source"
swiftc -parse-as-library -o "$OUT/export_source" \
  Tests/export_source.swift Phi/Camera/ExportSource.swift \
  Phi/Camera/ImageFraming.swift Phi/Camera/CaptureFormat.swift
"$OUT/export_source"

echo "COMPILE album_delete_sync"
swiftc -parse-as-library -o "$OUT/album_delete_sync" \
  Tests/album_delete_sync.swift Phi/Camera/AlbumDeleteSync.swift
"$OUT/album_delete_sync"

echo "COMPILE source_warm_wait"
swiftc -parse-as-library -o "$OUT/source_warm_wait" \
  Tests/source_warm_wait.swift Phi/Camera/SourceWarmWait.swift
"$OUT/source_warm_wait"

echo "B40 UNIT TESTS PASS"
