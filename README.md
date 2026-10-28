# PHI · 观止

iPhone-only camera. Quiet Finder is the working default: a large viewfinder, focal lengths along its lower edge, and a centered shutter. The exposure sheet opens above that shutter and does not move it.

English / internal name: Phi. Home screen name: **观止**. Bundle ID: `com.zeid.phi`.

This repository was assembled on a machine without Xcode. It has not been compiled here. Open it on a Mac.

## 打开 / Open

需要 Mac、Xcode 16 或更新版本（iOS 18 SDK）。部署目标是 **iOS 18**，只含 iPhone（`TARGETED_DEVICE_FAMILY = 1`），没有 iPad target，也没有 Mac Catalyst。

1. 用 Xcode 打开 `Phi.xcodeproj`。
2. 运行目标选一台 iPhone，不要选 iPad 或 Mac。
3. 真机需要在 Signing 里选好 Team。模拟器通常可以不选。
4. Run。没有 Storyboard。

模拟器没有后置相机。授权之后会看到取景框里的说明，而不是一张假的实时画面。曝光条在没有相机时仍可拖动，用来对一下刻度和数字；快门不会假装已经拍到照片。

Requires a Mac with Xcode 16 or newer and the iOS 18 SDK. iPhone only. No storyboards. The Simulator has no rear camera, so the viewfinder states that instead of showing a stand-in photo.

## 已实现 / What works

- `AVCaptureSession` 后置预览，`.photo` preset。
- 拍照使用 `photoQualityPrioritization = .speed`（输出上的上限也是 `.speed`）。
- 设备提供 Bayer RAW 时保存 DNG，并附带一张用于缩略图的处理图；否则保存 HEIC，再不行则 JPEG。顶栏格式是真实结果，例如 `RAW · 4:3` 或 `HEIC · 4:3`。不启用 Apple ProRAW。
- 快门旁的缩略图是 App 内最近一张。保存走「仅添加照片」权限。失败时文件留在 App 内，可以重试。
- 焦段来自后置实体镜头的水平视角（超广角、主摄、长焦），不是探索稿里的 24 / 35 / 50。主摄若能做 2× 裁切，会多一档，约为主摄毫米数的两倍。默认停在主摄 1×。
- 自动曝光补偿、ISO、快门都在取景画面上直接拖动，没有 PHOTO / MANUAL 模式开关。先点取景下方的 EV、ISO 或快门数值，再上下拖画面。往上更亮。ISO 和快门会在镜头允许时锁定自定义曝光；不允许时只提示这枚镜头不能单独锁定，不会进入另一个模式。
- 右上角三位数字是已拍摄张数（样例稿上的 `024` 只是示意）。取景器左下是**拍摄后的颗粒风格**，不是实时滤镜。`NATURAL` 表示不加颗粒。
- 拍完会进入处理页。可对成片做 **−2…+2 EV** 曝光（作用在预览像素上，不是相机测光），并在 `NATURAL` / `FINE` / `SILVER` / `PUSH` 之间切换。颗粒配方写死在代码里，没有数量、大小或强度控件。
- 「保存处理图」另存一张 HEIC（失败则 JPEG）。若原片是 RAW/DNG，那份文件不会被改写。

## 真机下一步 / Test on an iPhone

这台环境没有 Xcode，合并前没有在真机上跑过。请在一台 iPhone 上确认：

1. 拍一张。处理页应自动打开，画面是刚拍的成片，不是取景器里的假图。
2. 拖曝光条。数字和指示线一起动，预览跟着变亮或变暗，步进 0.1 EV。
3. 点 `FINE`、`SILVER`、`PUSH`、再回到 `NATURAL`。只能看到这四个名字，没有颗粒强度、大小或数量滑杆。`NATURAL` 应看不出颗粒。
4. 保存处理图。相册里多一张 HEIC 或 JPEG。若这张是 RAW，原来的 DNG 还在，内容不应被这次导出改掉。
5. 关掉处理页，再点快门旁的缩略图。曝光和风格应还是刚才那组。
6. 在取景页先选一个风格再拍。下一张处理页默认就是这个风格。实时取景本身不加颗粒。
7. 模拟器没有相机时，取景失败后可以点「处理样张」，或点空缩略图。处理页应标明这是样张。
8. 冷启动后取景应很快出现，不要长时间停在整页「正在打开相机」。
9. iPhone 17 Pro 上没有 MANUAL 按钮。点取景上的 EV、ISO 或快门，再上下拖画面。ISO / 快门应能改，而不是弹出「不能关闭自动曝光」。焦段应接近该机的超广角、主摄、2× 和长焦，而不是 14 / 24 / 35。默认选中主摄。

## 未做 / Stubbed

- LUT 导入（`.cube` / `.3dl`）仍然没有。
- 可调的颗粒强度、大小、数量。
- 视频。
- 方向 A（精密仪表）整页。取景上拖动改的是曝光补偿、ISO 或快门，不是一整页仪表。
- 前置摄像头、完整相册、白平衡和手动对焦距离面板。
- 超广角如果落在 24/35/50 之外，这版的三档选择器不会单独列出它。

## 去算法：做到哪一步 / What is not de-algorithmized

这里减弱了一部分计算摄影，**不是**「完全去算法」。

会做的：

- 优先 Bayer RAW（DNG），不打开 ProRAW。
- 静帧质量优先级设为 `.speed`，少走融合和增强那条慢路径。速度优先不等于系统保证关闭了所有多帧合成。
- 设备允许时关闭几何畸变校正、内容感知畸变校正，并关掉低光增强的自动开启。
- 预览不加品牌 LUT，也不改照片颜色来迁就界面。
- 颗粒只加在拍摄之后的处理页和「保存处理图」那张导出上，不加在实时取景或 RAW 原片上。

仍然存在的：

- 预览是系统视频管线，不是传感器的原始信号。
- RAW 仍经过封装和相机 ISP，不是科研级的裸 dump。
- 处理图（缩略图那张）仍然是系统成像的结果。
- `.speed` 和上面的开关不能证明 Deep Fusion、Smart HDR 或降噪已经完全关闭。

## 设计 / Design

- 技能：[`Design/design-quiet-camera/SKILL.md`](Design/design-quiet-camera/SKILL.md)
- 探索稿与图标：[`Assets/`](Assets/)
- 色板：背景 `#090A0A`，面板 `#191B1B`，线 `#343737`，字 `#F4F3EE` / `#A5AAA7`，强调色 `#F45135`
- 界面字是 SF Pro。参数字是随包的 IBM Plex Mono（SIL Open Font License，见 `Phi/Fonts/OFL.txt`）。如果字体没有注册成功，参数会退回系统等宽，不会冒充 Plex。
- 产品图标是象牙色机身加朱红快门短横，来自 `Assets/app-icon-mark.svg`。`Design/design-quiet-camera/assets/icon.svg` 是技能自己的铅笔图标，不是 App 图标。
- `Assets/icons/` 里有几份导出文件名和路径内容对不上。运行时图标在 `Phi/Design/PhiIcon.swift`，按几何重画，不按那些文件名。

Figma（只读）：file `A6cCsPJ7B7GbNH3DZoDCbi`，Quiet Finder `86:80`，曝光 `86:135`，图标 `91:74`。
