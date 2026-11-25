# PHI Figma 102:268: changes from v1 (/workspace/phi-figma-spec) to v2 (current state, exported 2026-10-29 11:30 UTC+8)

Source file: A6cCsPJ7B7GbNH3DZoDCbi, section 102:268. All sizes are pt on a 390×844 canvas.
Full node diff by id: raw/metadata-diff.txt (279 added, 85 removed, 120 modified). Exact x/y values are in raw/*.tsx.txt (reference code with node IDs). Assets are in assets/<frame>/.

## Frames
| id | name | screenshot | raw |
|---|---|---|---|
| 100:104 | 01 Capture (自动拍摄 / 手动调节 / 闪光灯选择 / 拍摄设置) | screens/01-capture.png | raw/01-capture.tsx.txt |
| 100:105 | 02 Library & Edit (照片网格 / 批量选择 / 照片浏览 / 曝光调整) | screens/02-library-edit.png | raw/02-library-edit.tsx.txt |
| 100:106 | 03 Develop & Save (选择风格 / 效果叠加 / 另存完成 / 退出编辑) | screens/03-develop-save.png | raw/03-develop-save.tsx.txt |
| 100:107 | Components (icons, shutter, reticle) | screens/components.png | raw/components.tsx.txt |
| 115:444 | 04 App Icon | unchanged; see v1 app-icon/ | n/a |
| **124:508** | **NEW: PHI v3 / Controls (style badges, zoom cycle, calibrated rulers)** | screens/05-v3-controls.png | raw/05-v3-controls.tsx.txt |

## 01 Capture (CameraAuto / Manual / Flash), a major layout change
- Subtitle: "沉浸式顶栏 · 快门右侧倍率 · 固定风格徽记 · 机械刻度".
- **Top bar:** flash stays top-left (x18 y12, 44×44). **Settings (sliders) icon is new at top-right (x328 y4).** **Grid moves down below it (x328, y12→48).** Format pill unchanged (120,54, 150×32, "RAW · 3:4"); it is renamed "tap to configure".
- Photo canvas: 390×520 at y92 (unchanged).
- **REMOVED:** the focal-length bar 14/25/50/108 (y618), the exposure-mode row "A 自动 / 0.0 EV" or "M 手动 / ISO / 1/250 s" pills (y664), the bottom settings icon in the capture row, and the live readouts row "ISO · 1/250 s · WB AUTO" (y794).
- **NEW ruler block always under the photo:** `PHI / Ruler / Auto EV` (auto) or `PHI / Ruler / ISO` (manual), 342×88 at x24 y618 (replaces the old 342×62 ruler).
  - Header line: left mono 11 "A / EV" or "M / ISO" (tap A/M to switch mode), centre value large (~18, e.g. "0.0", "200"), right "EV" or "1/250 s" (in manual, tapping the shutter readout switches the ruler to shutter).
  - Ticks: three lengths. Major is 2×20 in #f4f3ee, half is 1×13 and minor is 1×6 in #a5aaa7, all radius 0.5. A fixed red needle sits at the centre and the tape moves. Labels are mono 11 below (−1 0 +1 / 50 100 200 400 800).
- **Capture row:** thumbnail 44×48 at x28 y731. White shutter 80×80 at x155 y715 (was y711). **NEW zoom-cycle button `PHI / Zoom cycle` (96×88 hit, 56pt circle, bg #191b1b) at x270 y711**, label IBM Plex Mono 20 red "1×". Tapping cycles 0.5× → 1× → 2× → 4×, skipping levels the device lacks. Only the current level is shown.
- Focus reticle: now **130×174 frame at (131,265), aligned to the thirds-grid cell**, with red corner brackets (components shows "1:1 对焦框", red corners, no centre circle in capture). It was 76×76 with a red centre circle.
- **Flash menu:** the custom 170×174 #191b1b dropdown (icon + label + check rows) is REMOVED. It is replaced by **`System Menu / Flash`, an iOS Liquid Glass system menu (238×140 at x14 y62)** with text rows 关闭 / 自动 / 开启, a leading ✓ on the selected row, and no icons.
- Interaction note change: "调整曝光时不替换倍率" (the ruler no longer replaces anything; zoom stays put).

## 01 Capture: 拍摄设置 (Settings 101:334)
- Segment pill labels now carry the naming: **"0 RAW" / "Φ ProRAW" / "1 标准"**. The caption reads "0 · 保留 RAW 原始数据，留给后期更多空间。"
- **All pills grow from 38 to 44 tall** (y offset 3→0, text y 9.5→12.5): processing 111×44, HEIC/JPEG 171×44, aspect 81.5×44.
- The bottom Help card grows 92→126 tall. Title "处理方式 · 0 / Φ / 1", body three lines: "0 · RAW：保留原始数据。 Φ · ProRAW：保留 Apple ProRAW 数据。 1 · 标准：只保存苹果处理后的成片。" (replaces "设备支持决定可选格式").

## 02 Library & Edit
- Grid, selection and photo viewer: positions unchanged (only text/notes differences).
- **曝光调整 (editor exposure):** the tab row 曝光 / 风格 / 效果 is now **plain text tabs** (`Text tab`, 104×44, y2) with no pill backgrounds. The selected tab is white with a small red dot under it, the others grey.
- The old "曝光补偿 … +0.3 EV" label row (y664) and the 342×62 ruler (y696) are REMOVED. They are replaced by **`PHI / Ruler / Edit EV` 342×88 at x24 y672**: header "曝光" left, "+0.3" centre, "EV" right, same three-length ticks, red needle at the centre, labels −1 0 +1.
- The bottom bar (✕ / reset / "另存照片" white pill) is unchanged.

## 03 Develop & Save
- **选择风格:** the style photo thumbnails (62×84 "Style previews" with a photo per look, first labelled "无") are REMOVED. They are replaced by **`Fixed style badges / no photo thumbnails` (350×90 at x20 y669): five text-only choices 原始 / 正片 / 负片 / 黑白 / CCD (64×86 each).** Selected: bg #191b1b capsule (radius 22) with red #f45135 text 14. Default: grey #a5aaa7 text and no background or stroke. **"无" is renamed "原始".**
- Tabs are text tabs (as in the editor).
- 效果叠加: the effects rows (光晕 关/开, 颗粒 关/细颗粒) and their pills are largely unchanged. The EV ruler in this column is now the Edit EV component.
- 另存完成: unchanged.
- **退出编辑:** the custom "Discard confirmation" card (342×204, title + 2 stacked buttons) is REMOVED. It is replaced by **`System Alert / Discard edits`, an iOS system alert (300×240 at x45 y302)**: title "放弃这次调整？", body "未保存的调整将丢失，原片不会改变。", buttons "放弃调整" (destructive red) and "继续编辑".

## Components (100:107)
- The icon set is the same list (flash_on/off/auto, grid_on/off, settings, close, check, back, share, trash, compare, exposure, style, effects, reset, chevron, missing). The SVGs were re-exported to assets/components/.
- Focus reticle: now a 130×174 "1:1 对焦框" with red corners (the old 76×76 frame with a red centre circle is removed).
- Control-rule text: "闪光灯：点按打开关 / 自动 / 开列表；网格：一次点击直接切换开 / 关。参数：一次只调一个标尺；倍率保持在快门右侧，调整曝光时不替换倍率。倍率按钮单击循环 0.5× / 1× / 2× / 4×；跳过设备不可用档位，不承诺全部为原生镜头。"

## NEW frame 124:508, PHI v3 / Controls
- Choice badges (Default and Selected) for the five looks, specced as above.
- Zoom cycle symbols for 0.5× / 1× / 2× / 4× (96×88, 56pt circle).
- Three ruler symbols: Auto EV, ISO, Edit EV (342×88). Rule: "数值在中心；红针固定，尺带移动。长/中/短刻线区分整档、半档与细调。当前值 +0.3 时，零点必须在指针左侧。"
- Handoff notes 01–04: settings moves top-right with grid under it; a single 56pt zoom button keeps its position and size; 原始 applies no look and the badges never change with the photo (editing only, not live capture filters); in manual, tapping ISO or shutter switches the ruler; selection is shown by colour, outline, needle and text together; step sizes and ISO values come from the device.

## Implementation impact (for the next UI PR)
1. Capture: remove the lens row, exposure pills and readouts. Add a top-right settings icon, move grid to y48, add the permanent 88pt ruler block at y618, and add the zoom-cycle button right of the shutter.
2. Replace the custom flash dropdown with a native SwiftUI `Menu` (Liquid Glass), and the custom discard card with a native `.alert`.
3. Settings: 44pt pills, 0/Φ/1 labels, new help card text.
4. Editor: text tabs with a red dot, new Edit EV ruler, text-only style badges with 无→原始.
5. Reticle: 130×174, red corners.
