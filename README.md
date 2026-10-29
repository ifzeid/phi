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
- 处理方式在设置里，取景顶栏用短标：**0**（Bayer RAW）、**Φ**（ProRAW）、**1**（只存苹果的 HEIF/JPEG）。0 和 Φ 默认同时保存成片：苹果的成片是主图，DNG 是副档。关掉时系统仍需要这张主图，否则会拒收单独的 DNG。开关打开时，同一行可选 HEIC 或 JPEG；模式 1 没有这个开关，同一位置直接选 HEIC 或 JPEG。旧的「同时保存 HEIF」和成片格式会迁过来，默认仍是 HEIC。旧的 JPEG+RAW 会迁成 0 且成片开，RAW 迁成 0 且成片关，JPEG 迁成 1。质量优先级保持 `.speed`。有定位权限时写入 GPS。Software 为 `PHI` 加版本号。
- 拍完不打开编辑。缩略图更新，取景留着拍下一张。苹果的 HEIF/JPEG 原字节和 Bayer DNG 按格式同时写入 App 相册和系统相册。只存 DNG、没有主图时系统会拒收，所以 RAW 档也会配上苹果那张 HEIF/JPEG。编辑从相册里的「编辑」开始，有 DNG 就从 DNG 显影。默认色貌「无」是恒等：不加曲线、不加饱和。局部色调映射、降噪、锐化、detail、摩尔纹、boost、对比度旋钮保持 0。正片、负片、黑白、CCD 是各自的配方，不另叠一条底片曲线。光晕可叠在任何一档上。CCD 只在编辑里，没有强度，可与光晕同开。它在 RAW 显影上加更纯的红蓝、稍暖的肤色、更硬的高光肩、阴影里很轻的色噪和横条、大约 8MP 的柔和再加很小半径的锐化。降噪、锐化、detail、摩尔纹在 RAW 滤镜上仍是 0。导出是全尺寸、质量 0.98 的一次 HEIF，不写 10-bit depth 标记，并带上原来的 EXIF/GPS。裁切档没有 RAW 时，编辑退回那张存档图。
- 画幅也在设置里。默认 **3:4**。另有 **1:1**、**2:3**、**9:16**：取景和 PHI 显影成片从中心裁切。系统存档的 HEIF 保持整幅原文件，不重编码。这三档不写 RAW。
- 快门旁的缩略图打开 **PHI 相册**，不是编辑页。相册只列这台 App 写入的照片（相册名 `PHI`，本机记下的资源编号，以及还没写进系统相册的 App 内文件），不是整卷系统相册。拍摄保存仍先用「仅添加照片」。点进相册时才请求读取权限，系统允许的话可以只选中部分照片。全屏里点「编辑」才进入显影；也可以导出当前画面。系统相册写入失败时，提示里带 NSError 的 domain 和 code，照片留在 App 相册，可以重试。拍完相册会马上刷新。
- 焦段来自后置实体镜头的水平视角（超广角、主摄、长焦），不是探索稿里的 24 / 35 / 50。主摄若能做 2× 裁切，会多一档，约为主摄毫米数的两倍。默认停在主摄 1×。
- 在取景画面上上下拖动只改曝光补偿。刻度出现在画面右侧，松手后淡出，不常驻。往上更亮。取景框下方的「手动」默认关闭。打开后，取景框上沿是快门刻度，右侧是感光度刻度，右上角标出当前数值。关掉回到连续自动曝光。设置里的 ISO / SHUTTER 用同一个开关，加减和刻度同步。
- 点画面先做一次自动对焦，再回到连续对焦。长焦仍强制切到实体长焦镜头。平滑自动对焦和对焦范围只改在实体镜头上，并且在锁定配置之后。换镜头或改静态格式之后会重新打开连续对焦。主体近于长焦最近对焦距离时，取景上短提示「太近」。
- 点焦段会立刻切到那颗实体镜头，不走虚拟多摄的变焦。超广角、主摄、长焦都是对应的 `AVCaptureDevice`，光学档 zoom 为 1。长焦是 `builtInTelephotoCamera`。裁切档（约 2×，常显示成 50mm）取景是主摄 zoom 2，按快门时回到 zoom 1 拍整幅 Bayer，显影再按取景裁切。换镜头在 session 队列里一次 `beginConfiguration` 完成，提交之后才读 RAW 格式列表。取景层用 `resizeAspectFill` 铺满，顶栏毫米数是当前设备的实际视场。
- 写入系统相册的主图是相机原来的 HEIF/JPEG 字节，不经 ImageIO 重写。DNG 是 `.alternatePhoto`。两者的像素尺寸按同一档静态格式对齐。失败提示大约 3 秒后消失，点一下也会消失。重试会按文件真实类型再写一次。
- 对焦框是设计稿 `86:7` 里的角标加朱红短横。点画面会把它移到对焦点。
- 右上角三位数字是已拍摄张数（样例稿上的 `024` 只是示意）。取景不加颗粒，也不加光晕。
- 编辑只从相册的「编辑」进入。曝光旋钮作用在 DNG 显影上。色貌有 **无 / 正片 / 负片 / 黑白 / CCD**，互斥。**光晕**可叠在任何一档上。颗粒只有 **OFF** 和 **FINE**，加在色貌之后。都没有强度滑杆，也不出现在取景上。编辑页会写明来源是 DNG 还是系统成片，以及像素、HEIF 质量和导出字节数。
- 「保存处理图」另存一张 HEIC（失败则 JPEG）。若原片是 RAW/DNG，那份文件不会被改写。

## 真机下一步 / Test on an iPhone

这台环境没有 Xcode，合并前没有在真机上跑过。请在一台 iPhone 上确认：

1. 拍一张长焦 JPEG+RAW。快门之后应留在取景，只更新缩略图，不弹出编辑。系统相册和 App 相册里都有这张：苹果的 HEIF 和 DNG 配成一张。打开 App 相册，点「编辑」。信息应写「来源 DNG」和完整像素（约 3024×4032），不是 1600 宽的预览。保存处理图应是一张数 MB 的 HEIF（质量 0.98，全像素），噪点还在。那次导出不改写系统 HEIF 和 DNG。如果这一档没有 Bayer RAW，编辑页会写明，并且不会把系统成片另存成 PHI。
2. 拖处理页曝光。预览按 EV 变亮变暗。保存处理图后，新文件应是 Display P3，并带原来的 EXIF/GPS。DNG 和系统 HEIF 不被改写。
3. 处理页有无、正片、负片、黑白、CCD，互斥。光晕可叠在任何一档上，包括 CCD。颗粒只有 OFF 和 FINE，加在色貌之后。都没有强度滑杆。取景上没有这些开关。CCD 不出现在实时取景。
4. 保存处理图。相册里多一张 HEIC 或 JPEG。若这张是 RAW，原来的 DNG 还在，内容不应被这次导出改掉。
4b. 设置里把画幅改成 1:1、2:3 或 9:16。选中项应马上变，关掉设置后取景框变成这个比例，并被记住。显影和相册里的预览是同一裁切。DNG 仍是整幅。改回 3:4 后取景恢复。RAW 不会因为画幅关掉。
5. 点快门旁的缩略图应打开 PHI 相册网格。点一张进全屏，再点「编辑」才进入显影。系统可以只授权选中的照片。相册里不应出现观止没拍过的其他照片。写入系统相册失败时，这张仍在 App 相册里，标着未存入，可以重试，提示里有 domain 和 code。没有缩略图时，空按钮仍可打开样张。
6. 从相册点「编辑」时颗粒是 `OFF`。取景上不能预先选风格。
7. 模拟器没有相机时，取景失败后可以点「编辑样张」，或点空缩略图。编辑页应标明这是样张。
8. 冷启动后取景应很快出现，不要长时间停在整页「正在打开相机」。
9. 取景框下方「手动」默认关闭，拖动只出现临时曝光刻度。打开后，上沿快门刻度和右侧感光度刻度可以拖，右上角是 ISO 和快门。设置里的开关和加减跟取景框是同一组数。关掉后回到自动曝光。
10. 点长焦（约 108mm）应很快切过去，远近都能连续对焦。点一下先合焦再回到连续对焦。太近时短提示「太近」。14、25、50 的对焦也不应变慢或锁死。点 2× 裁切再按快门，App 不应崩溃。108mm RAW+HEIC 不应再出现 PHPhotosErrorDomain 3300。失败提示大约 3 秒后消失。相册网格和全屏应是清晰的画面。点「编辑」应进入显影：有 DNG 从 DNG 显影，只有 HEIF 的裁切档也能打开。未写入系统相册的照片应能看见，并能重试。文件真的不在时显示「文件丢失」，可以删除。
11. 焦段应接近该机的超广角、主摄、2× 和长焦，而不是 14 / 24 / 35。默认选中主摄。点画面出现角标对焦框，对焦应很快锁上再继续跟焦。九宫格仍在。张数在取景左上角，曝光状态在右上角。

## 未做 / Stubbed

- LUT 导入（`.cube` / `.3dl`）仍然没有。
- 可调的颗粒强度、大小、数量。
- 视频。
- 方向 A（精密仪表）整页。取景上拖动只改曝光补偿。ISO 和快门在设置里。颗粒只在处理页。
- 前置摄像头、完整相册、白平衡和手动对焦距离面板。
- 裁切档的系统相册预览仍是整幅 HEIF。PHI 显影按取景中心裁切，不改 DNG 字节。DNG 显影关掉降噪、锐化、detail 和摩尔纹。无是恒等。HEIF 编辑只改曝光、光晕或颗粒。导出像素转正，方向写成 1，并带 Display P3。相册可以单张或多选删除。

## 去算法：做到哪一步 / What is not de-algorithmized

这里减弱了一部分计算摄影，**不是**「完全去算法」。

会做的：

- 优先 Bayer RAW（DNG），不打开 ProRAW。拍摄仍是 `.speed`。
- App 内成片从这张 DNG 显影，关掉局部色调映射和降噪。默认色貌「无」不另加曲线。噪点会比系统 HEIF 更明显。
- 相册里另外保留系统生成的 HEIF/JPEG 原字节和 DNG，不把系统图再压成 8 位 sRGB。
- 设备允许时关闭几何畸变校正、内容感知畸变校正，并关掉低光增强的自动开启。
- 颗粒只加在处理页的 FINE，不加在实时取景或 DNG 原片上。

仍然存在的：

- 取景预览仍是系统视频管线。
- DNG 仍是相机封装的 Bayer，不是科研级裸 dump。`.speed` 不能证明多帧合成已经完全关闭。
- 系统 HEIF 自己仍可能带降噪和 HDR。PHI 不把它当作成片，但文件留在相册里。

## 设计 / Design

- 技能：[`Design/design-quiet-camera/SKILL.md`](Design/design-quiet-camera/SKILL.md)
- 探索稿与图标：[`Assets/`](Assets/)
- 色板：背景 `#090A0A`，面板 `#191B1B`，线 `#343737`，字 `#F4F3EE` / `#A5AAA7`，强调色 `#F45135`
- 界面字是 SF Pro。参数字是随包的 IBM Plex Mono（SIL Open Font License，见 `Phi/Fonts/OFL.txt`）。如果字体没有注册成功，参数会退回系统等宽，不会冒充 Plex。
- 产品图标是象牙色机身加朱红快门短横，来自 `Assets/app-icon-mark.svg`。`Design/design-quiet-camera/assets/icon.svg` 是技能自己的铅笔图标，不是 App 图标。
- `Assets/icons/` 里有几份导出文件名和路径内容对不上。运行时图标在 `Phi/Design/PhiIcon.swift`，按几何重画，不按那些文件名。

Figma（只读）：file `A6cCsPJ7B7GbNH3DZoDCbi`，Quiet Finder `86:80`，曝光 `86:135`，图标 `91:74`。
