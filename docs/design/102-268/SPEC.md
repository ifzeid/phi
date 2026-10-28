# PHI · 观止 — Design spec v2 (Figma section 102:268 "Phi UX UI")

Source: https://www.figma.com/design/A6cCsPJ7B7GbNH3DZoDCbi/App-Design-情绪版?node-id=102-268
Extracted via Figma MCP on 2026-10-29. All sizes are in pt on a 390×844 iPhone canvas.

Frames: `100:104` 01 Capture · `100:105` 02 Library & Edit · `100:106` 03 Develop & Save · `100:107` Components · `115:444` 04 App Icon (Grain Ring).
Screenshots are in `screens/`. Raw Figma reference code (React/Tailwind with node IDs) is in `raw/`. It's the source of truth for exact x/y values.

## 1. App icon: "颗粒圆环" (grain ring), the chosen option
- A pure grain ring. No solid shutter and no centre axis. The band's radial spread grew from 7.5 to 10 (about ⅓ thicker). The edges dissolve naturally, the centre stays empty (negative space), and the ring is brighter at the top and fades toward the bottom.
- Dark: background `#101413`, light grain. Light: background `#f1f2ec`, dark grain.
- Files: `app-icon/AppIcon-dark-1024.png`, `AppIcon-light-1024.png`, `AppIcon-tinted-1024.png` (grayscale, derived by me, not in Figma), plus transparent ring PNGs. The source SVGs (`grain_ring_*.svg`, about 8.8 MB each, made of thousands of dots) are kept local only and were not pushed.
- Asset catalog mapping: iOS's default "Any" appearance should be the **dark** variant (the app is dark-first). Use light as an alternate or for light appearance, and tinted for the Tinted appearance. Keep the 1024 square full-bleed; iOS applies the mask.
- Check legibility at 60/40/29 px. Figma shows the ring still reads at 29 px.

## 2. Tokens
| Token | Hex | Use |
|---|---|---|
| bg / camera | `#090a0a` | Screen background; unselected pill background |
| surface / selected | `#191b1b` | Selected pill background, flash menu, dialogs |
| border | `#343737` | Device frame and dividers |
| camera-primary (Figma variable) | `#f4f3ee` | Primary text, icons, shutter fill, primary button background |
| secondary text | `#a5aaa7` | Captions, readouts, ruler ticks |
| accent red | `#f45135` | **Selection, values, focus-reticle centre only.** Never used for the shutter. |
| scrim | `rgba(9,10,10,0.88)` | Lens-bar background over the photo |
| modal scrim | black at 60% | Discard dialog |
| shutter ring | `#707675` | Outer ring stroke |
| icon-dark bg / icon-light bg | `#101413` / `#f1f2ec` | App icon |

Typography (map to SwiftUI):
- **Noto Sans SC** Regular/Medium is used for Chinese UI. On iOS, use the system font (PingFang SC) at the same sizes, with `.medium` for "Medium".
- **SF Pro Medium (510)** is used for numbers and Latin labels in pills (14, 25, 50, 108, RAW, HEIC, 0.0 EV): `.system(size:13, weight:.medium)`.
- **IBM Plex Mono Regular** is used for technical readouts (RAW · 3:4, ISO 100, 1/250 s, WB AUTO, ruler numbers, 1/12, HEIC · 编辑副本). Either bundle IBM Plex Mono or use `.system(.monospaced)`.
- Sizes and line heights: 11/16 (readouts, ruler labels, style captions) · 12/17 (toast and value labels) · 13/19 (pills, body, buttons) · 14/20 (nav titles, row labels) · 16/23 (settings toggle row) · 18/26 (dialog title). Tracking is 0 everywhere.

Spacing and radii: pills are fully rounded (radius = height/2), e.g. heights 32/34/36/38/40/44. Cards and menus use radius 16–18. Horizontal page padding is 20–24, gaps are 8, 10 and 18.
Strokes: icons are 1.5 pt with round caps/joins; reticle corners 1.3 pt; reticle centre circle 1.6 pt red; shutter ring 1.5 pt.

## 3. Icons (`icons/*.svg` and `@3x.png`)
- Glyphs are 24 pt with a 1.5 pt line, inside a **44×44 pt hit area**. Colour is `#f4f3ee`. State is shown by **shape plus a check mark**, not by colour alone.
- Icons: flash_on, flash_off, flash_auto, grid_on, grid_off, settings (sliders), close, check, back, chevron, share, trash, compare (split rectangle), exposure (sun), style, effects (concentric circles), reset (counter-clockwise arrow), missing (broken image).
- Use them as template images (`.renderingMode(.template)`), so they can be tinted, or replace each with an equivalent SF Symbol.

## 4. Components
- **Shutter** (`shutter_white.svg`): 80×80 overall; outer ring r=38.25 with a 1.5 stroke in `#707675`; inner disc r=32 filled `#f4f3ee`. Always white.
- **Focus reticle** (`focus_reticle.svg`): a 76×76 square with 17 pt corner brackets (1.3 pt, `#f4f3ee`) and a centre circle r=7 (1.6 pt, red). Tapping moves it. When locked, it also shows the text "AE/AF LOCK".
- **Top bar**: the status bar is hidden. Flash icon sits at the left (x18, y12, 44×44) and grid at the right (x328). Centre pill: "RAW · 3:4" in mono 13, 150×32 at y≈54. Tapping it opens capture settings.
- **Photo canvas**: fixed geometry, 390×520 at y≈91–95, the same on every screen so the photo never jumps.
- **Lens selector** ("Focal lengths"): sits **below the photo, outside the viewfinder** (y≈617). Container 240×40, radius 20, background is the scrim, gap 8. Buttons are 48×32, radius 16. Selected: background `#191b1b` with red text. Unselected: background `#090a0a` with text `#f4f3ee`. Labels are equivalent mm (14 / 25 / 50 / 108); VoiceOver reads "25 毫米". **The list comes from the current device; don't hardcode the four.**
- **Exposure row** (y≈663, 390×44, padding 20). Auto mode: a left pill "A 自动" (88×36, selected style, red) and a right pill "0.0 EV" (94×36). Manual mode: "M 手动", "ISO 100" and "1/250 s" (108×36 each). The active parameter uses the selected style.
- **Horizontal ruler** (342×62): ticks are 1 pt wide in `#a5aaa7`. Minor ticks are 8 tall and major ticks 18 tall, every 11.4 pt (5 minor per major, majors 57 apart). Labels are mono 11 below. The current value's label is red, and a red centre needle is fixed in place. **When ISO, shutter or EV is tapped, the ruler replaces the lens bar.** Only one ruler is open at a time. Tapping the same parameter again, or empty viewfinder space, closes it and the lens bar returns. Dragging adjusts continuously, and on release the value snaps to the nearest one the device supports. In the editor, the exposure ruler uses the same component labelled −2…+2 (range −5…+5), with a value label like "+0.3 EV" in red.
- **Capture controls** (y≈710, 80 tall, padding 28): thumbnail on the left (the last shot), white shutter in the centre, settings (sliders) icon on the right.
- **Live readouts** (y≈793, 22 tall, padding 24): "ISO 100 · 1/250 s · WB AUTO", mono 11, `#a5aaa7`, spaced across the width.
- **Flash menu**: tapping flash opens a three-option dropdown (170×174, background `#191b1b`, radius 16, rows 48 tall: icon, label, and a check on the selected row). Choosing an option closes it immediately. Tapping outside closes it without changing anything. Grid is a direct on/off toggle that swaps its icon. If the lens or format makes flash unavailable, show it disabled with the reason; don't silently switch.
- **Capture settings sheet** (full screen, close X at top left, title "拍摄设置"):
  - 处理方式: a segmented row of 3 pills (111×38, radius 19). Figma labels them RAW / ProRAW / 标准. **The app's current naming is 0 / Φ / 1 (Bayer RAW / ProRAW / Apple 处理), so keep that.** Below it, a caption in 13 `#a5aaa7`.
  - Divider, then a "同时保存成片" toggle row (16/23; the switch is 42×26 with a red on-state). Below it, a HEIC | JPEG pill pair (171×38 each) and a caption. The spec note says this section shows only when the mode allows it; under ProRAW/HEIC restrictions, controls are disabled and the reason is shown.
  - 画幅: 1:1 / 3:4 / 2:3 / 9:16 pills, with the caption "预览与成片使用所选比例；RAW 保留完整画面".
  - Bottom info card (radius 12, `#191b1b`): "设备支持决定可选格式".
- **Album / Library**: nav row with X, "照片" and "选择". A big date header "2026年10月" (22/32 Medium), then "今天 · 12 张". 3-column square grid with about 2 pt gaps. A missing file shows a placeholder tile with the `missing` icon and "文件不可用". The bottom bar has "12 张照片" and a "返回拍摄" button.
  - **Selection**: "已选择 2 张", "取消". Selected items show a red filled check circle; unselected show an empty ring. The bottom bar has trash, "2 张照片" and share; trash and share are disabled when nothing is selected.
- **Photo viewer**: X, date title and an "1/12" mono counter. The photo is fixed at 390×520. Below it is a metadata line in mono 11 ("RAW · 25 mm · ISO 100 · 1/250 s"). The bottom bar has trash, share and an "编辑" pill (88×44, selected style, red). Swipe horizontally to change photos. Pinch zoom stays inside the canvas.
- **Editor**: title "编辑照片", with the compare icon at the top right (hold to see the original). A category segment of 曝光 / 风格 / 效果 (104×36 pills, y≈615). **The tool area has a fixed height, so the photo and the save button never move when you switch tabs.**
  - 风格: single choice of 无 / 正片 / 负片 / 黑白 / CCD, shown as 62-wide thumbnails with an 11 pt caption (red when selected). No intensity slider.
  - 效果: 光晕 off/on and 颗粒 off/细颗粒 (76×34 pills, in a 160-wide group). The two are independent and can combine with a style.
  - Actions row: X (leave) at the left, reset in the middle, and a primary "另存照片" button (120×40, `#f4f3ee` background, dark text).
  - Switching category keeps the adjusted values; switching style doesn't clear exposure or effects.
- **Save flow / toast**: while saving, the button reads "保存中…" and is disabled. On success, the app opens the new copy (title "编辑后的照片", counter 13/13, meta "HEIC · 编辑副本") and shows an inline toast "✓ 已保存新照片，原片保留" (12/17, centred, 260×44) above the action bar. On failure, it stays in the editor and offers a retry. Export (share) and 另存 are separate actions.
- **Discard dialog**: leaving with unsaved changes shows a 60% black scrim and a card (342×204, `#191b1b`, radius 18) titled "放弃这次调整？" with the subtitle "原片不会改变。" and two 294×44 buttons: "继续编辑" (red text) and "放弃调整". With no changes, leaving returns straight to the viewer.

## 5. Mapping to the app (likely SwiftUI files)
| Design | App screen / view |
|---|---|
| CameraAuto / CameraManual / CameraFlash | Camera root view: top bar, viewfinder, lens bar, exposure row, ruler, shutter, readouts |
| CaptureSettings | Settings sheet (processing mode, companion HEIC/JPEG, aspect ratio) |
| Library / Selection | PHI album grid with multi-select delete and share |
| Photo viewer | Album detail / pager |
| Editor 曝光/风格/效果 | Editor (Process) view |
| Saved / Discard | Editor save flow and confirmation |
| Components | Shared icon set, Shutter, FocusReticle, PillButton, Ruler |
| App icon | Assets.xcassets/AppIcon (dark / light / tinted) |

## 6. Key changes compared with a generic camera UI
1. The status bar is hidden and the top bar has only flash and grid. The format pill doubles as the settings entry.
2. The lens bar moves **out of the viewfinder** to below the photo, and the ruler replaces it while a parameter is being adjusted.
3. The shutter is **white**. Red is reserved for selection, values and the focus-reticle centre.
4. The focus reticle is a 1:1 square with corner brackets and a red centre.
5. The photo canvas has fixed geometry everywhere, and editor tools have a fixed height, so nothing jumps.
6. Flash is an explicit three-option menu with a check mark, not a cycling tap.
7. Icons use one system: 24 pt, 1.5 pt line, 44 pt hit area, and state shown by shape as well as colour.
8. Saving creates an edited copy (原片保留), with an explicit discard confirmation.
9. The app icon is a grain ring that echoes Φ and the app's natural-grain look.
