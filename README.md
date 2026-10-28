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
- 拍摄格式在设置里，不常驻在取景器上。默认 **JPEG+RAW**：相册里是同一张照片的处理图（HEIC，没有 HEVC 时用 JPEG）加 Bayer DNG。也可以只存 RAW，或只存 JPEG/HEIC。不启用 Apple ProRAW。顶栏是这次会写入的格式，例如 `RAW+HEIC · 3:4`。裁切档不能出 RAW 时只存处理图，并短提示，不崩溃。
- 画幅也在设置里。默认 **3:4**（整幅传感器）。另有 **1:1**、**2:3**、**9:16**，取景和成片都从中心裁切成同一比例。这三档不写 RAW，只存裁切后的 HEIC 或 JPEG。
- 快门旁的缩略图打开 **PHI 相册**：只浏览这台 App 写入的照片（相册名 `PHI`，以及本机记下的资源编号），不是整卷系统相册。拍摄保存仍先用「仅添加照片」。点进相册时才请求读取权限，系统允许的话可以只选中部分照片。从一张照片可以进入原来的处理页，或导出当前画面。失败时文件留在 App 内，可以重试。
- 焦段来自后置实体镜头的水平视角（超广角、主摄、长焦），不是探索稿里的 24 / 35 / 50。主摄若能做 2× 裁切，会多一档，约为主摄毫米数的两倍。默认停在主摄 1×。
- 在取景画面上上下拖动只改曝光补偿。刻度出现在画面右侧，松手后淡出，不常驻。往上更亮。没有 PHOTO / MANUAL 模式开关。
- ISO、快门、颗粒和拍摄格式在快门右侧的设置里。ISO 和快门会在镜头允许时锁定自定义曝光；不允许时只提示这枚镜头不能单独锁定。
- 焦段切换尽量留在同一颗虚拟多摄上，只改变 zoom，避免每点一次长焦就拆掉再装上输入（那会卡住）。裁切档（约 2×，常显示成 50mm 附近）如果当前 zoom 不能出 Bayer RAW，就改存 HEIC 或 JPEG，不再让 `capturePhoto` 抛异常。
- 对焦框是设计稿 `86:7` 里的角标加朱红短横。点画面会把它移到对焦点。
- 右上角三位数字是已拍摄张数（样例稿上的 `024` 只是示意）。取景下方的颗粒名字是**拍摄后的风格**，不是实时滤镜。`NATURAL` 表示不加颗粒。
- 拍完会进入处理页。可对成片做 **−2…+2 EV** 曝光（作用在预览像素上，不是相机测光），并在 `NATURAL` / `FINE` / `SILVER` / `PUSH` 之间切换。颗粒配方写死在代码里，没有数量、大小或强度控件。
- 「保存处理图」另存一张 HEIC（失败则 JPEG）。若原片是 RAW/DNG，那份文件不会被改写。

## 真机下一步 / Test on an iPhone

这台环境没有 Xcode，合并前没有在真机上跑过。请在一台 iPhone 上确认：

1. 拍一张。处理页应自动打开，画面是刚拍的成片，不是取景器里的假图。
2. 拖曝光条。数字和指示线一起动，预览跟着变亮或变暗，步进 0.1 EV。
3. 点 `FINE`、`SILVER`、`PUSH`、再回到 `NATURAL`。只能看到这四个名字，没有颗粒强度、大小或数量滑杆。`NATURAL` 应看不出颗粒。
4. 保存处理图。相册里多一张 HEIC 或 JPEG。若这张是 RAW，原来的 DNG 还在，内容不应被这次导出改掉。
4b. 设置里把画幅改成 1:1、2:3 或 9:16。取景框应马上变成这个比例。拍出来的处理图和取景是同一裁切。顶栏比例跟着变。这三档不进 RAW。改回 3:4 后，1× 又能写 RAW。
5. 点快门旁的缩略图应打开 PHI 相册网格，而不是直接进入上一张的处理页。点一张进全屏，再点「处理」才进入原来的处理页。系统可以只授权选中的照片。相册里不应出现观止没拍过的其他照片。没有缩略图时，空按钮仍可打开样张。
6. 在取景页先选一个风格再拍。下一张处理页默认就是这个风格。实时取景本身不加颗粒。
7. 模拟器没有相机时，取景失败后可以点「处理样张」，或点空缩略图。处理页应标明这是样张。
8. 冷启动后取景应很快出现，不要长时间停在整页「正在打开相机」。
9. iPhone 17 Pro 上没有 MANUAL 按钮。在取景上拖动只出现临时曝光刻度，松手后消失。ISO 和快门在快门右侧的设置里改，不应弹出「不能关闭自动曝光」。
10. 点长焦（约 108mm）应平滑切过去，画面不要卡住。点 2× 裁切（约 50mm）再按快门，App 不应崩溃。默认 JPEG+RAW 时，这一档顶栏应为 HEIC 或 JPEG，并短提示没有 RAW；相册里仍有处理图。原生 1× 主摄应在相册里同时有 RAW 和 HEIC（同一张）。设置里改成 RAW 或 JPEG 后再拍一张，相册内容应跟着变。
11. 焦段应接近该机的超广角、主摄、2× 和长焦，而不是 14 / 24 / 35。默认选中主摄。点画面出现角标对焦框。九宫格仍在右上角。

## 未做 / Stubbed

- LUT 导入（`.cube` / `.3dl`）仍然没有。
- 可调的颗粒强度、大小、数量。
- 视频。
- 方向 A（精密仪表）整页。取景上拖动只改曝光补偿。ISO、快门和颗粒在设置里。
- 前置摄像头、完整相册、白平衡和手动对焦距离面板。
- 裁切档和长焦虚拟变焦不保证 RAW。只有原生 1×、且当前格式列出 Bayer 时才请求 RAW。

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
