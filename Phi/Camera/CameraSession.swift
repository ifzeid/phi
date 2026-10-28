import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import os

enum CameraGate: Equatable {
    case unknown
    case needsPermission
    case denied
    case authorized
}

/// Owns the capture session, the rear camera, and the controls that must stay honest about the hardware.
final class CameraSession: ObservableObject {
    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()

    @Published private(set) var gate: CameraGate = .unknown
    @Published private(set) var isRunning = false
    @Published private(set) var isConfigured = false
    @Published private(set) var formatLabel = "—"
    @Published private(set) var focalStops: [FocalStop] = []
    @Published private(set) var selectedStopID: String?
    @Published private(set) var exposureEV: Double = 0
    @Published private(set) var exposureRange: ClosedRange<Double> = -2...2
    @Published private(set) var autoExposure = true
    @Published private(set) var manualExposureSupported = false
    @Published private(set) var manualISOValue: Float = 100
    @Published private(set) var manualShutterSeconds: Double = 1.0 / 125
    @Published private(set) var isoChoices: [Float] = []
    @Published private(set) var shutterChoices: [Double] = []
    @Published private(set) var activeDeviceID = ""
    @Published private(set) var isoText = "ISO —"
    @Published private(set) var shutterText = "— S"
    @Published private(set) var whiteBalanceText = "WB —"
    @Published private(set) var flashMode: AVCaptureDevice.FlashMode = .off
    @Published private(set) var flashAvailable = false
    @Published private(set) var focusLocked = false
    @Published var statusMessage: String?

    private let sessionQueue = DispatchQueue(label: "com.zeid.phi.capture")
    private let log = Logger(subsystem: "com.zeid.phi", category: "camera")
    private var device: AVCaptureDevice?
    private var didConfigure = false
    private var meterObservations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var restartAttempts = 0
    private var currentInput: AVCaptureDeviceInput?
    private var inputsByID: [String: AVCaptureDeviceInput] = [:]
    /// Device whose active format was chosen so the HEIF and the DNG share one pixel size.
    private var stillFormatDeviceID: String?
    private var customExposureQueued = false
    private var focusReturnObservation: NSKeyValueObservation?
    private var manualISO: Float?
    private var manualDuration: CMTime?
    private var supportedFlashModes: [AVCaptureDevice.FlashMode] = []
    /// Session-queue copy of the auto/manual choice. The published flag is for SwiftUI.
    private var exposureIsAuto = true
    private var lensStops: [FocalStop] = []
    private var wideMillimeters = 0
    /// Crop stops and non-1× virtual zooms must not request Bayer RAW. `capturePhoto` throws if they do.
    private var rawSuppressed = false
    private var activeStopOptical = true
    private var captureFormat: CaptureFormat = .jpegAndRaw
    private var photoAspect: PhotoAspect = .threeByFour
    /// The preview's rotation coordinator is created on the main thread. Suspend it before swapping inputs.
    let previewAnchor = PreviewAnchor()

    var videoDevice: AVCaptureDevice? { device }

    init() {
        session.automaticallyConfiguresApplicationAudioSession = false
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleRuntimeError(note)
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.statusMessage = nil
            self?.isRunning = self?.session.isRunning ?? false
        })
    }

    deinit {
        meterObservations.forEach { $0.invalidate() }
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func refreshAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            gate = .authorized
            start()
        case .notDetermined:
            gate = .needsPermission
        case .denied, .restricted:
            gate = .denied
        @unknown default:
            gate = .denied
        }
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshAuthorization()
            }
        }
    }

    func start() {
        CaptureLocation.shared.start()
        sessionQueue.async {
            do {
                try self.configureIfNeeded()
                let deviceID = self.device?.uniqueID ?? ""
                // Let the preview layer attach before startRunning blocks this queue.
                DispatchQueue.main.async {
                    self.activeDeviceID = deviceID
                    self.isConfigured = true
                    if self.statusMessage == "正在打开相机" {
                        self.statusMessage = nil
                    }
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.publishLensesAndManualSupport()
                let running = self.session.isRunning
                DispatchQueue.main.async {
                    self.isRunning = running
                    if running {
                        self.restartAttempts = 0
                    } else {
                        self.statusMessage = "相机没有启动。The camera didn't start."
                    }
                }
            } catch {
                self.log.error("Camera setup failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    self.isConfigured = false
                    self.isRunning = false
                    self.statusMessage = "无法打开后置相机。Couldn't open the rear camera."
                }
            }
        }
    }

    func stop() {
        CaptureLocation.shared.stop()
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    func cycleFlash() {
        guard flashAvailable else {
            statusMessage = "后置闪光灯不可用。Flash isn't available on this camera."
            return
        }
        let order = supportedFlashModes
        guard let index = order.firstIndex(of: flashMode) else {
            flashMode = order.first ?? .off
            return
        }
        flashMode = order[(index + 1) % order.count]
        statusMessage = nil
    }

    func select(stop: FocalStop) {
        selectedStopID = stop.id
        sessionQueue.async {
            let switching = self.needsDeviceSwitch(for: stop)
            let work = {
                do {
                    try self.performSelect(stop)
                    if switching {
                        self.previewAnchor.resume(device: self.device)
                    }
                } catch {
                    if switching {
                        self.previewAnchor.resume(device: self.device)
                    }
                    DispatchQueue.main.async {
                        self.statusMessage = "焦段没有切过去。Couldn't change zoom."
                    }
                }
            }
            if switching {
                // Drop the preview coordinator on the main thread before beginConfiguration.
                // Creating or destroying it on the session queue deadlocks the telephoto switch.
                DispatchQueue.main.async {
                    self.previewAnchor.suspend()
                    self.sessionQueue.async(execute: work)
                }
            } else {
                work()
            }
        }
    }

    func setManualISO(_ iso: Float) {
        manualISOValue = iso
        autoExposure = false
        sessionQueue.async {
            self.exposureIsAuto = false
            self.manualISO = iso
            self.queueCustomExposure()
        }
    }

    func setManualShutter(_ seconds: Double) {
        manualShutterSeconds = seconds
        autoExposure = false
        sessionQueue.async {
            self.exposureIsAuto = false
            self.manualDuration = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            self.queueCustomExposure()
        }
    }

    func setFocusLocked(_ locked: Bool) {
        sessionQueue.async {
            do {
                try self.lockDevice { device in
                    if locked, device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    } else if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }
                DispatchQueue.main.async {
                    self.focusLocked = locked
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "对焦锁不可用。Focus lock isn't available."
                }
            }
        }
    }

    func focus(at devicePoint: CGPoint) {
        let point = CGPoint(
            x: min(max(devicePoint.x, 0), 1),
            y: min(max(devicePoint.y, 0), 1)
        )
        sessionQueue.async {
            self.applyTapFocus(point)
        }
    }

    /// One-shot autofocus at the tap, then back to continuous. Smooth autofocus stays off.
    private func applyTapFocus(_ point: CGPoint) {
        focusReturnObservation?.invalidate()
        focusReturnObservation = nil
        try? lockDevice { device in
            Self.prepareFocusHardware(device)
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if self.exposureIsAuto {
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        }
        guard let device else { return }
        focusReturnObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] device, _ in
            guard device.isAdjustingFocus == false else { return }
            self?.sessionQueue.async {
                self?.restoreContinuousFocus()
            }
        }
        sessionQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let device = self?.device, device.isAdjustingFocus == false else { return }
            self?.restoreContinuousFocus()
        }
        DispatchQueue.main.async {
            self.focusLocked = false
        }
    }

    private func restoreContinuousFocus() {
        focusReturnObservation?.invalidate()
        focusReturnObservation = nil
        try? lockDevice { device in
            Self.prepareFocusHardware(device)
            if device.isFocusModeSupported(.continuousAutoFocus), device.focusMode != .continuousAutoFocus {
                device.focusMode = .continuousAutoFocus
            }
            if self.exposureIsAuto, device.isExposureModeSupported(.continuousAutoExposure), device.exposureMode != .continuousAutoExposure {
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    private static func prepareFocusHardware(_ device: AVCaptureDevice) {
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = false
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .none
        }
    }

    /// Applies the latest ISO and shutter. Skips the preview teardown once this camera already allows custom exposure.
    private func queueCustomExposure() {
        if customExposureQueued { return }
        customExposureQueued = true
        sessionQueue.async {
            self.customExposureQueued = false
            guard self.exposureIsAuto == false else { return }
            if self.device?.isExposureModeSupported(.custom) == true {
                try? self.lockCustomExposure()
                return
            }
            DispatchQueue.main.async {
                self.previewAnchor.suspend()
                self.sessionQueue.async {
                    self.applyCustomOrExplain()
                    self.previewAnchor.resume(device: self.device)
                }
            }
        }
    }

    /// `enabled == false` locks exposure so ISO and shutter can be set directly.
    /// If no physical camera supports `.custom`, this flips back to auto and explains why.
    @discardableResult
    func setAutoExposure(_ enabled: Bool) -> Bool {
        autoExposure = enabled
        if !enabled {
            exposureEV = 0
        }
        let ev = exposureEV
        if enabled {
            sessionQueue.async {
                self.exposureIsAuto = enabled
                self.applyExposureMode(enabled: enabled, ev: ev)
            }
        } else {
            runOnSessionAfterSuspendingPreview {
                self.exposureIsAuto = enabled
                self.applyExposureMode(enabled: enabled, ev: ev)
            }
        }
        return true
    }

    private func applyExposureMode(enabled: Bool, ev: Double) {
        guard didConfigure else { return }
        do {
            if enabled {
                try lockDevice { device in
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    let bias = self.clampedBias(Float(ev), device: device)
                    device.setExposureTargetBias(bias, completionHandler: nil)
                }
                return
            }
            try ensureCustomExposureDevice()
            guard let device, device.isExposureModeSupported(.custom) else {
                failCustomLock()
                return
            }
            try lockCustomExposure(seedFromMeter: manualISO == nil)
            publishManualRanges()
        } catch {
            failCustomLock()
        }
    }

    private func applyCustomOrExplain() {
        do {
            try ensureCustomExposureDevice()
            guard device?.isExposureModeSupported(.custom) == true else {
                failCustomLock()
                return
            }
            try lockCustomExposure()
            publishManualRanges()
        } catch {
            failCustomLock()
        }
    }

    private func failCustomLock() {
        exposureIsAuto = true
        DispatchQueue.main.async {
            self.autoExposure = true
            self.statusMessage = "这枚镜头不能单独锁定 ISO 或快门。"
        }
    }

    func setExposureEV(_ value: Double) {
        let stepped = (min(max(value, exposureRange.lowerBound), exposureRange.upperBound) * 10).rounded() / 10
        exposureEV = stepped
        autoExposure = true
        sessionQueue.async {
            self.exposureIsAuto = true
            try? self.lockDevice { device in
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.setExposureTargetBias(self.clampedBias(Float(stepped), device: device), completionHandler: nil)
            }
        }
    }

    /// After a drag, snap the label to the bias the device actually accepted.
    func commitExposureEV() {
        sessionQueue.async {
            guard let device = self.device, self.exposureIsAuto else { return }
            let actual = Double(device.exposureTargetBias)
            DispatchQueue.main.async {
                self.exposureEV = (actual * 10).rounded() / 10
            }
        }
    }

    func setCaptureFormat(_ format: CaptureFormat) {
        captureFormat = format
        sessionQueue.async {
            self.captureFormat = format
            guard self.didConfigure else { return }
            self.publishDeliveryLabel()
        }
    }

    func setPhotoAspect(_ aspect: PhotoAspect) {
        photoAspect = aspect
        sessionQueue.async {
            self.photoAspect = aspect
            guard self.didConfigure else { return }
            self.publishDeliveryLabel()
        }
    }

    func capturePhoto(
        format: CaptureFormat,
        delegate: AVCapturePhotoCaptureDelegate,
        note: @escaping (_ usingRaw: Bool, _ codec: String) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        let flash = flashMode
        sessionQueue.async {
            self.captureFormat = format
            guard self.session.isRunning else {
                DispatchQueue.main.async {
                    self.statusMessage = "相机还没准备好。Camera isn't ready."
                    completion(false)
                }
                return
            }
            let switching = self.needsPhysicalRawSwitch() || self.needsStillFormatWork()
            let shoot = {
                self.settleRawCamera()
                let prepared = self.makeSettings(flash: flash)
                if prepared.usingRaw == false, self.captureFormat.wantsRaw, self.photoAspect.allowsRaw {
                    DispatchQueue.main.async {
                        self.statusMessage = "这一档没有 Bayer RAW，不会把系统成片当成 PHI 显影保存。"
                    }
                }
                note(prepared.usingRaw, prepared.codecName)
                self.photoOutput.capturePhoto(with: prepared.settings, delegate: delegate)
                self.publishDeliveryLabel()
                if switching {
                    self.previewAnchor.resume(device: self.device)
                }
                DispatchQueue.main.async {
                    completion(true)
                }
            }
            if switching {
                DispatchQueue.main.async {
                    self.previewAnchor.suspend()
                    self.sessionQueue.async(execute: shoot)
                }
            } else {
                shoot()
            }
        }
    }

    // MARK: - Setup

    private enum SetupError: Error {
        case noCamera
        case cannotAdd
    }

    /// The main wide camera starts fastest and supports custom exposure.
    /// Virtual multi-cameras (`builtInTripleCamera` and friends) report `.custom` as unsupported.
    private static func bestDevice() -> AVCaptureDevice? {
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            return wide
        }
        return backCameras().first
    }

    private static func backCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        ).devices
    }

    private func configureIfNeeded() throws {
        if didConfigure { return }
        guard let device = Self.bestDevice() else { throw SetupError.noCamera }
        self.device = device

        session.beginConfiguration()
        var didCommit = false
        defer {
            if !didCommit {
                session.commitConfiguration()
            }
        }
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw SetupError.cannotAdd
        }
        session.addInput(input)
        currentInput = input
        session.addOutput(photoOutput)
        // Speed is set before any AVCapturePhotoSettings is created. A higher value throws.
        photoOutput.maxPhotoQualityPrioritization = .speed
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = false
        }
        do {
            try prepare(device)
        } catch {
            session.removeInput(input)
            session.removeOutput(photoOutput)
            throw error
        }
        session.commitConfiguration()
        didCommit = true

        if photoOutput.isContentAwareDistortionCorrectionSupported {
            photoOutput.isContentAwareDistortionCorrectionEnabled = false
        }
        // Deferred delivery can return a proxy instead of file bytes, and capturePhoto throws
        // unless the delegate implements the proxy callback. Keep the still in-process.
        if photoOutput.isAutoDeferredPhotoDeliverySupported {
            photoOutput.isAutoDeferredPhotoDeliveryEnabled = false
        }
        // Upgrade before the preview exists, so the later 108mm stop only ramps zoom.
        adoptVirtualCameraIfPossible()
        prebuildInputs()
        let active = self.device ?? device
        try? prepare(active)
        observeMeter(active)
        let discovery = discover(active)
        didConfigure = true
        if !exposureIsAuto {
            applyExposureMode(enabled: false, ev: 0)
        }
        publish(discovery)
        log.info("Capture format \(discovery.label, privacy: .public), raw \(discovery.raw, privacy: .public)")
    }

    private func prepare(_ device: AVCaptureDevice) throws {
        try lockDevice { device in
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.setExposureTargetBias(0, completionHandler: nil)
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = false
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = false
            }
            Self.prepareFocusHardware(device)
        }
    }

    private struct Discovery {
        var label: String
        var raw: Bool
        var range: ClosedRange<Double>
        var manual: Bool
        var flashModes: [AVCaptureDevice.FlashMode]
        var flashAvailable: Bool
    }

    private func discover(_ device: AVCaptureDevice) -> Discovery {
        let raw = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let codec = processedPhotoCodec().name
        let lower = max(-2, Double(device.minExposureTargetBias))
        let upper = min(2, Double(device.maxExposureTargetBias))
        let range: ClosedRange<Double> = lower < upper ? lower...upper : 0...0
        let ordered = Self.orderedFlash(photoOutput.supportedFlashModes)
        let manual = supportsCustomExposure(device) || Self.backCameras().contains { $0.isExposureModeSupported(.custom) }
        let hardwareRaw = raw && rawSuppressed == false && activeStopOptical && captureFormat.wantsRaw && photoAspect.allowsRaw
        return Discovery(
            label: CaptureFormat.label(preference: captureFormat, rawDelivered: hardwareRaw, codec: codec, aspect: photoAspect.title),
            raw: raw,
            range: range,
            manual: manual,
            flashModes: ordered,
            flashAvailable: ordered.contains(.on) || ordered.contains(.auto)
        )
    }

    private func publish(_ discovery: Discovery) {
        DispatchQueue.main.async {
            self.formatLabel = discovery.label
            self.exposureRange = discovery.range
            self.manualExposureSupported = discovery.manual
            self.supportedFlashModes = discovery.flashModes
            self.flashAvailable = discovery.flashAvailable
            if !discovery.flashModes.contains(self.flashMode) {
                self.flashMode = .off
            }
        }
    }

    private func observeMeter(_ device: AVCaptureDevice) {
        meterObservations.forEach { $0.invalidate() }
        meterObservations = [
            device.observe(\.iso, options: [.initial, .new]) { [weak self] device, _ in
                self?.publishMeter(device)
            },
            device.observe(\.exposureDuration, options: [.new]) { [weak self] device, _ in
                self?.publishMeter(device)
            },
            device.observe(\.whiteBalanceMode, options: [.initial, .new]) { [weak self] device, _ in
                self?.publishMeter(device)
            }
        ]
    }

    private func publishMeter(_ device: AVCaptureDevice) {
        let isoValue = device.iso
        let shutterSeconds = CMTimeGetSeconds(device.exposureDuration)
        let iso = MeterFormat.iso(isoValue)
        let shutter = MeterFormat.shutter(seconds: shutterSeconds)
        let whiteBalance = Self.whiteBalanceLabel(device)
        DispatchQueue.main.async {
            if self.isoText != iso { self.isoText = iso }
            if self.shutterText != shutter { self.shutterText = shutter }
            if self.whiteBalanceText != whiteBalance { self.whiteBalanceText = whiteBalance }
            if self.autoExposure {
                self.manualISOValue = isoValue
                if shutterSeconds.isFinite, shutterSeconds > 0 {
                    self.manualShutterSeconds = shutterSeconds
                }
            }
        }
    }

    private static func whiteBalanceLabel(_ device: AVCaptureDevice) -> String {
        switch device.whiteBalanceMode {
        case .locked:
            let gains = device.deviceWhiteBalanceGains
            guard gains.redGain > 0, gains.greenGain > 0, gains.blueGain > 0 else { return "WB LOCK" }
            let kelvin = device.temperatureAndTintValues(for: gains).temperature
            guard kelvin.isFinite, kelvin > 0 else { return "WB LOCK" }
            return "WB \(Int(kelvin.rounded()))K"
        case .autoWhiteBalance, .continuousAutoWhiteBalance:
            return "WB AUTO"
        @unknown default:
            return "WB AUTO"
        }
    }

    private func makeSettings(flash: AVCaptureDevice.FlashMode) -> (settings: AVCapturePhotoSettings, usingRaw: Bool, codecName: String) {
        alignPhotoDimensions()
        let bayer = (captureFormat.wantsRaw && photoAspect.allowsRaw) ? bayerFormatIfDeliverable() : nil
        let processedCodec = processedPhotoCodec()
        let processed: [String: Any] = [AVVideoCodecKey: processedCodec.codec]
        let settings: AVCapturePhotoSettings
        // RAW mode still asks for Apple's processed companion. Photos rejects a DNG with no primary photo,
        // so the shutter stores that HEIF/JPEG beside the DNG. PHI develop waits until 编辑. JPEG mode never requests Bayer.
        if let bayer {
            settings = AVCapturePhotoSettings(rawPixelFormatType: bayer, processedFormat: processed)
        } else {
            settings = AVCapturePhotoSettings(format: processed)
        }
        let dimensions = photoOutput.maxPhotoDimensions
        if dimensions.width > 0, dimensions.height > 0 {
            settings.maxPhotoDimensions = dimensions
        }
        settings.photoQualityPrioritization = .speed
        if photoOutput.supportedFlashModes.contains(flash) {
            settings.flashMode = flash
        }
        // Preview formats belong to the settings object. The output no longer exposes them.
        if let preview = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: preview)
            ]
        }
        let usingRaw = bayer != nil
        let codecName = processedCodec.name
        let label = CaptureFormat.label(
            preference: captureFormat,
            rawDelivered: usingRaw,
            codec: codecName,
            aspect: photoAspect.title
        )
        DispatchQueue.main.async {
            if self.formatLabel != label { self.formatLabel = label }
        }
        return (settings, usingRaw, codecName)
    }

    /// HEIC stills use the HEVC photo codec. `AVVideoCodecType` has no `.heic` case; that name is `AVFileType.heic`.
    /// JPEG is the fallback when HEVC is not in `availablePhotoCodecTypes`.
    private func processedPhotoCodec() -> (codec: AVVideoCodecType, name: String) {
        let codecs = photoOutput.availablePhotoCodecTypes
        if let hevc = codecs.first(where: { $0 == .hevc || $0.rawValue.caseInsensitiveCompare("heic") == .orderedSame }) {
            return (hevc, "HEIC")
        }
        return (.jpeg, "JPEG")
    }

    private func applyZoom(_ factor: Double, ramp: Bool) throws {
        try lockDevice { device in
            let lower = device.minAvailableVideoZoomFactor
            let upper = device.maxAvailableVideoZoomFactor
            let zoom = Swift.min(upper, Swift.max(lower, CGFloat(factor)))
            guard zoom.isFinite else { return }
            if abs(device.videoZoomFactor - zoom) < 0.01 { return }
            if ramp, device.isRampingVideoZoom == false {
                device.ramp(toVideoZoomFactor: zoom, withRate: 24)
            } else {
                device.videoZoomFactor = zoom
            }
        }
    }

    /// One configuration block. The photo output stays attached. Inputs are built once and reused.
    private func switchInput(to newDevice: AVCaptureDevice, matchStillFormat: Bool = false) throws {
        let sameDevice = device?.uniqueID == newDevice.uniqueID
        if sameDevice, matchStillFormat == false { return }
        if sameDevice, matchStillFormat, stillFormatDeviceID == newDevice.uniqueID { return }
        let input = try cachedInput(for: newDevice)
        session.beginConfiguration()
        if sameDevice == false {
            if let currentInput {
                session.removeInput(currentInput)
            }
            guard session.canAddInput(input) else {
                if let currentInput, session.canAddInput(currentInput) {
                    session.addInput(currentInput)
                }
                session.commitConfiguration()
                throw SetupError.cannotAdd
            }
            session.addInput(input)
            currentInput = input
            device = newDevice
        }
        if matchStillFormat, let active = device {
            do {
                try active.lockForConfiguration()
            } catch {
                session.commitConfiguration()
                throw error
            }
            if let format = Self.matchedStillFormat(for: active), active.activeFormat != format {
                active.activeFormat = format
            }
            active.unlockForConfiguration()
            stillFormatDeviceID = active.uniqueID
        }
        session.commitConfiguration()
        if sameDevice == false {
            observeMeter(newDevice)
            let deviceID = newDevice.uniqueID
            DispatchQueue.main.async {
                self.activeDeviceID = deviceID
            }
        }
    }

    private func cachedInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        if let existing = inputsByID[device.uniqueID] { return existing }
        let input = try AVCaptureDeviceInput(device: device)
        inputsByID[device.uniqueID] = input
        return input
    }

    private func prebuildInputs() {
        if let currentInput, let device, inputsByID[device.uniqueID] == nil {
            inputsByID[device.uniqueID] = currentInput
        }
        var cameras = Self.backCameras()
        if let virtual = Self.virtualBackCamera() {
            cameras.append(virtual)
        }
        for camera in cameras {
            if inputsByID[camera.uniqueID] != nil { continue }
            if let input = try? AVCaptureDeviceInput(device: camera) {
                inputsByID[camera.uniqueID] = input
            }
        }
    }

    /// Virtual multi-cam devices report custom exposure as unsupported. Physical cameras on the same phone do not.
    private func supportsCustomExposure(_ device: AVCaptureDevice) -> Bool {
        if device.isExposureModeSupported(.custom) { return true }
        return device.constituentDevices.contains { $0.isExposureModeSupported(.custom) }
    }

    private func ensureCustomExposureDevice() throws {
        guard let device else { return }
        if device.isExposureModeSupported(.custom) { return }
        let selectedID = selectedStopID
        let stop = lensStops.first { $0.id == selectedID }
        let match = Self.backCameras().first { camera in
            camera.uniqueID == stop?.deviceID && camera.isExposureModeSupported(.custom)
        }
        let constituent = device.constituentDevices.first { $0.deviceType == .builtInWideAngleCamera && $0.isExposureModeSupported(.custom) }
            ?? device.constituentDevices.first { $0.isExposureModeSupported(.custom) }
        let fallback = Self.backCameras().first { $0.deviceType == .builtInWideAngleCamera && $0.isExposureModeSupported(.custom) }
            ?? Self.backCameras().first { $0.isExposureModeSupported(.custom) }
        guard let target = match ?? constituent ?? fallback else { return }
        try switchInput(to: target)
        let zoom = stop?.zoomFactor ?? 1
        try applyZoom(zoom, ramp: false)
        rawSuppressed = stop?.isOpticalStep == false
        publishDeliveryLabel()
    }

    private func lockCustomExposure(seedFromMeter: Bool = false) throws {
        try lockDevice { device in
            guard device.isExposureModeSupported(.custom) else { return }
            if seedFromMeter || self.manualISO == nil || self.manualDuration == nil {
                self.manualISO = device.iso
                self.manualDuration = device.exposureDuration
            }
            let format = device.activeFormat
            let iso = min(max(self.manualISO ?? device.iso, format.minISO), format.maxISO)
            var duration = self.manualDuration ?? device.exposureDuration
            if CMTimeCompare(duration, format.minExposureDuration) < 0 { duration = format.minExposureDuration }
            if CMTimeCompare(duration, format.maxExposureDuration) > 0 { duration = format.maxExposureDuration }
            self.manualISO = iso
            self.manualDuration = duration
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            let seconds = CMTimeGetSeconds(duration)
            DispatchQueue.main.async {
                self.manualISOValue = iso
                self.manualShutterSeconds = seconds
            }
        }
    }

    private func publishManualRanges() {
        guard let device else { return }
        let format = device.activeFormat
        let isos = ExposureStops.isos(minISO: format.minISO, maxISO: format.maxISO)
        let shutters = ExposureStops.shutters(
            secondsMin: CMTimeGetSeconds(format.minExposureDuration),
            secondsMax: CMTimeGetSeconds(format.maxExposureDuration)
        )
        DispatchQueue.main.async {
            self.isoChoices = isos
            self.shutterChoices = shutters
        }
    }

    /// Main-thread suspend, then session-queue work, then reattach the preview coordinator.
    private func runOnSessionAfterSuspendingPreview(_ work: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.previewAnchor.suspend()
            self.sessionQueue.async {
                work()
                self.previewAnchor.resume(device: self.device)
            }
        }
    }

    private func isVirtual(_ device: AVCaptureDevice) -> Bool {
        device.constituentDevices.isEmpty == false
    }

    private static func virtualBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera
        ]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return nil
    }

    /// Swap the wide camera for the virtual multi-cam once, at 1×, before the preview exists.
    private func adoptVirtualCameraIfPossible() {
        guard let current = device, isVirtual(current) == false else { return }
        guard let virtual = Self.virtualBackCamera(), virtual.uniqueID != current.uniqueID else { return }
        do {
            try switchInput(to: virtual)
            try applyZoom(1, ramp: false)
            log.info("Using virtual camera for focal changes")
        } catch {
            log.error("Virtual camera upgrade failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func virtualDeviceSnapshot() -> VirtualZoomDevice? {
        let source = device.flatMap { isVirtual($0) ? $0 : nil } ?? Self.virtualBackCamera()
        guard let source, isVirtual(source) else { return nil }
        return VirtualZoomDevice(
            minimum: Double(source.minAvailableVideoZoomFactor),
            maximum: Double(source.maxAvailableVideoZoomFactor),
            switchOvers: source.virtualDeviceSwitchOverVideoZoomFactors.map { Double($0) },
            constituentIDs: source.constituentDevices.map(\.uniqueID)
        )
    }

    private func virtualZoom(for stop: FocalStop) -> Double? {
        guard let snapshot = virtualDeviceSnapshot() else { return nil }
        return VirtualZoomMath.factor(
            deviceID: stop.deviceID,
            millimeters: stop.millimeters,
            optical: stop.isOpticalStep,
            wideMillimeters: wideMillimeters,
            device: snapshot
        )
    }

    private func needsDeviceSwitch(for stop: FocalStop) -> Bool {
        guard let device else { return false }
        if exposureIsAuto, virtualZoom(for: stop) != nil {
            return isVirtual(device) == false && Self.virtualBackCamera() != nil
        }
        return device.uniqueID != stop.deviceID
    }

    private func performSelect(_ stop: FocalStop) throws {
        activeStopOptical = stop.isOpticalStep
        let zoom: Double
        let ramp: Bool
        if exposureIsAuto, let virtualZoom = virtualZoom(for: stop) {
            if let device, isVirtual(device) == false, let virtual = Self.virtualBackCamera() {
                try switchInput(to: virtual)
            }
            zoom = virtualZoom
            ramp = true
        } else if let target = AVCaptureDevice(uniqueID: stop.deviceID) {
            try switchInput(to: target)
            zoom = stop.zoomFactor
            ramp = zoom > 1.05
        } else {
            zoom = stop.zoomFactor
            ramp = true
        }
        rawSuppressed = !stop.isOpticalStep
        // Lock exposure before the zoom ramp. Locking again afterwards cancels the ramp.
        if !exposureIsAuto {
            try lockCustomExposure()
        } else {
            let bias = self.exposureEV
            try lockDevice { device in
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.setExposureTargetBias(self.clampedBias(Float(bias), device: device), completionHandler: nil)
            }
        }
        try applyZoom(zoom, ramp: ramp)
        alignPhotoDimensions()
        publishManualRanges()
        publishDeliveryLabel()
    }

    /// Optical tele on the virtual camera sits at a switch-over zoom, where Bayer RAW is often unavailable.
    /// The physical camera at zoom 1 is the native delivery.
    private func needsPhysicalRawSwitch() -> Bool {
        guard captureFormat.wantsRaw, photoAspect.allowsRaw else { return false }
        guard let stop = lensStops.first(where: { $0.id == selectedStopID }), stop.isOpticalStep else { return false }
        guard let device else { return false }
        let onNative = device.uniqueID == stop.deviceID && abs(Double(device.videoZoomFactor) - 1) < 0.05
        return onNative == false
    }

    private func settleRawCamera() {
        guard captureFormat.wantsRaw, photoAspect.allowsRaw else { return }
        guard let stop = lensStops.first(where: { $0.id == selectedStopID }), stop.isOpticalStep else {
            rawSuppressed = true
            activeStopOptical = false
            return
        }
        activeStopOptical = true
        if needsPhysicalRawSwitch(), let physical = AVCaptureDevice(uniqueID: stop.deviceID) {
            do {
                try switchInput(to: physical, matchStillFormat: true)
                try applyZoom(1, ramp: false)
            } catch {
                rawSuppressed = true
                return
            }
        } else if let device {
            do {
                try switchInput(to: device, matchStillFormat: true)
                if abs(Double(device.videoZoomFactor) - 1) > 0.05 {
                    try applyZoom(1, ramp: false)
                }
            } catch {
                rawSuppressed = true
                return
            }
        }
        if let device, isVirtual(device), abs(Double(device.videoZoomFactor) - 1) > 0.05 {
            rawSuppressed = true
            return
        }
        let listed = photoOutput.availableRawPhotoPixelFormatTypes.contains {
            AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
        }
        rawSuppressed = listed == false
    }

    /// Bayer RAW is requested for an optical stop when the photo output lists a Bayer format.
    /// A 2× crop still skips RAW. Optical tele is not skipped just because the virtual-camera zoom is above 1.
    private func bayerFormatIfDeliverable() -> OSType? {
        guard rawSuppressed == false, activeStopOptical else { return nil }
        return photoOutput.availableRawPhotoPixelFormatTypes.first {
            AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
        }
    }

    private func publishDeliveryLabel() {
        let outputHasBayer = photoOutput.availableRawPhotoPixelFormatTypes.contains {
            AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
        }
        let usingRaw = captureFormat.wantsRaw && photoAspect.allowsRaw && rawSuppressed == false && activeStopOptical && outputHasBayer
        let name = processedPhotoCodec().name
        let label = CaptureFormat.label(
            preference: captureFormat,
            rawDelivered: usingRaw,
            codec: name,
            aspect: photoAspect.title
        )
        DispatchQueue.main.async {
            if self.formatLabel != label { self.formatLabel = label }
        }
    }

    /// The processed photo is scaled down to `maxPhotoDimensions`. The DNG stays at the format's full readout.
    /// Those two sizes have to be the same or Photos returns invalidResource. Pick a ~12MP format, then use its largest size for both.
    private func alignPhotoDimensions() {
        guard let device else { return }
        guard let match = Self.largestPhotoDimensions(device.activeFormat) else { return }
        let current = photoOutput.maxPhotoDimensions
        if current.width != match.width || current.height != match.height {
            photoOutput.maxPhotoDimensions = match
        }
    }

    private func needsStillFormatWork() -> Bool {
        guard captureFormat.wantsRaw, photoAspect.allowsRaw else { return false }
        guard let stop = lensStops.first(where: { $0.id == selectedStopID }), stop.isOpticalStep else { return false }
        guard let device else { return false }
        return stillFormatDeviceID != device.uniqueID
    }

    /// Prefer the format whose full photo size is nearest 12MP, so Bayer and the HEIF are the same frame.
    private static func matchedStillFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let ranked: [(AVCaptureDevice.Format, Int)] = device.formats.compactMap { format in
            guard let area = largestPhotoDimensions(format).map({ Int($0.width) * Int($0.height) }), area > 0 else {
                return nil
            }
            return (format, area)
        }
        guard ranked.isEmpty == false else { return nil }
        let nearTwelve = ranked.filter { abs($0.1 - 12_000_000) <= 4_000_000 }
        let pool = nearTwelve.isEmpty ? ranked : nearTwelve
        return pool.min(by: { abs($0.1 - 12_000_000) < abs($1.1 - 12_000_000) })?.0
    }

    private static func largestPhotoDimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        format.supportedMaxPhotoDimensions.max { lhs, rhs in
            Int(lhs.width) * Int(lhs.height) < Int(rhs.width) * Int(rhs.height)
        }
    }

    private func publishLensesAndManualSupport() {
        let samples: [LensSample] = Self.backCameras().compactMap { camera in
            guard let millimeters = Self.millimeters(for: camera) else { return nil }
            let allowsCrop = camera.deviceType == .builtInWideAngleCamera && camera.maxAvailableVideoZoomFactor >= 2
            return LensSample(
                id: camera.uniqueID,
                millimeters: millimeters,
                isWide: camera.deviceType == .builtInWideAngleCamera,
                allowsTwoXCrop: allowsCrop
            )
        }
        let stops = FocalLengthMath.stops(from: samples)
        lensStops = stops
        wideMillimeters = samples.first { $0.isWide }?.millimeters ?? 0
        let wideID = samples.first { $0.isWide }?.id ?? device?.uniqueID
        let selected = FocalLengthMath.defaultStop(stops, wideDeviceID: wideID)
        let manual = (device.map(supportsCustomExposure) ?? false) || Self.backCameras().contains { $0.isExposureModeSupported(.custom) }
        let lensList = stops.map { String($0.millimeters) }.joined(separator: "/")
        log.info("Lenses \(lensList, privacy: .public), manual \(manual, privacy: .public)")
        publishManualRanges()
        DispatchQueue.main.async {
            self.focalStops = stops
            if self.selectedStopID == nil {
                self.selectedStopID = selected?.id
            }
            self.manualExposureSupported = manual
        }
    }

    private static func millimeters(for device: AVCaptureDevice) -> Int? {
        let format = device.formats.max { lhs, rhs in
            photoArea(lhs) < photoArea(rhs)
        } ?? device.activeFormat
        guard let mm = FocalLengthMath.equivalentMillimeters(horizontalFOVDegrees: Double(format.videoFieldOfView)) else {
            return nil
        }
        return Int(mm.rounded())
    }

    private static func photoArea(_ format: AVCaptureDevice.Format) -> Int {
        format.supportedMaxPhotoDimensions.reduce(0) { partial, dimensions in
            partial + Int(dimensions.width) * Int(dimensions.height)
        }
    }

    private func clampedBias(_ value: Float, device: AVCaptureDevice) -> Float {
        min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
    }

    private func lockDevice(_ body: (AVCaptureDevice) throws -> Void) throws {
        guard let device else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        try body(device)
    }

    private static func orderedFlash(_ modes: [AVCaptureDevice.FlashMode]) -> [AVCaptureDevice.FlashMode] {
        [.off, .on, .auto].filter { modes.contains($0) }
    }

    private func handleRuntimeError(_ note: Notification) {
        if let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError {
            log.error("Session runtime error: \(error.localizedDescription, privacy: .public)")
        }
        guard restartAttempts < 1 else {
            statusMessage = "相机出错，请重新打开。The camera hit an error."
            isRunning = false
            return
        }
        restartAttempts += 1
        statusMessage = "相机中断，正在重试。"
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
            let running = self.session.isRunning
            DispatchQueue.main.async {
                self.isRunning = running
                if running { self.statusMessage = nil }
            }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let number = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber,
              let reason = AVCaptureSession.InterruptionReason(rawValue: number.intValue) else {
            statusMessage = "相机已暂停。"
            return
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            statusMessage = nil
        case .videoDeviceInUseByAnotherClient, .audioDeviceInUseByAnotherClient:
            statusMessage = "相机被其他应用占用。"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            statusMessage = "分屏时无法使用相机。"
        case .videoDeviceNotAvailableDueToSystemPressure:
            statusMessage = "系统繁忙，相机已暂停。"
        case .sensitiveContentMitigationActivated:
            statusMessage = "相机已暂停。"
        @unknown default:
            statusMessage = "相机已暂停。"
        }
    }
}
