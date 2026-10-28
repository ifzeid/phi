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
    private var rotationObservation: NSKeyValueObservation?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var notificationTokens: [NSObjectProtocol] = []
    private var restartAttempts = 0
    private var currentInput: AVCaptureDeviceInput?
    private var manualISO: Float?
    private var manualDuration: CMTime?
    private var supportedFlashModes: [AVCaptureDevice.FlashMode] = []
    /// Session-queue copy of the auto/manual choice. The published flag is for SwiftUI.
    private var exposureIsAuto = true
    private var cachedAspect = "—"
    private var lensStops: [FocalStop] = []

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
        rotationObservation?.invalidate()
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
            do {
                if let target = AVCaptureDevice(uniqueID: stop.deviceID) {
                    try self.switchInput(to: target)
                }
                try self.applyZoom(stop.zoomFactor, ramp: false)
                if !self.exposureIsAuto {
                    try self.lockCustomExposure()
                }
                self.publishManualRanges()
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "焦段没有切过去。Couldn't change zoom."
                }
            }
        }
    }

    func setManualISO(_ iso: Float) {
        manualISOValue = iso
        autoExposure = false
        sessionQueue.async {
            self.exposureIsAuto = false
            self.manualISO = iso
            self.applyCustomOrExplain()
        }
    }

    func setManualShutter(_ seconds: Double) {
        manualShutterSeconds = seconds
        autoExposure = false
        sessionQueue.async {
            self.exposureIsAuto = false
            self.manualDuration = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            self.applyCustomOrExplain()
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
        sessionQueue.async {
            try? self.lockDevice { device in
                let point = CGPoint(x: min(max(devicePoint.x, 0), 1), y: min(max(devicePoint.y, 0), 1))
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                } else if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if self.exposureIsAuto {
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = point
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
            }
            DispatchQueue.main.async {
                self.focusLocked = false
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
        sessionQueue.async {
            self.exposureIsAuto = enabled
            self.applyExposureMode(enabled: enabled, ev: ev)
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

    func capturePhoto(
        delegate: AVCapturePhotoCaptureDelegate,
        note: @escaping (_ usingRaw: Bool, _ codec: String) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        let flash = flashMode
        sessionQueue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async {
                    self.statusMessage = "相机还没准备好。Camera isn't ready."
                    completion(false)
                }
                return
            }
            let prepared = self.makeSettings(flash: flash)
            note(prepared.usingRaw, prepared.codecName)
            self.photoOutput.capturePhoto(with: prepared.settings, delegate: delegate)
            DispatchQueue.main.async {
                completion(true)
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
        installRotation(for: device)
        observeMeter(device)
        let discovery = discover(device)
        cachedAspect = discovery.aspect
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
        }
    }

    private struct Discovery {
        var label: String
        var aspect: String
        var raw: Bool
        var range: ClosedRange<Double>
        var manual: Bool
        var flashModes: [AVCaptureDevice.FlashMode]
        var flashAvailable: Bool
    }

    private func discover(_ device: AVCaptureDevice) -> Discovery {
        let raw = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let codec = processedPhotoCodec().name
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions
        let largest = dimensions.max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        let aspect = largest.map { AspectLabel.photo(width: Int($0.width), height: Int($0.height)) } ?? "—"
        let lower = max(-2, Double(device.minExposureTargetBias))
        let upper = min(2, Double(device.maxExposureTargetBias))
        let range: ClosedRange<Double> = lower < upper ? lower...upper : 0...0
        let ordered = Self.orderedFlash(photoOutput.supportedFlashModes)
        let manual = supportsCustomExposure(device) || Self.backCameras().contains { $0.isExposureModeSupported(.custom) }
        return Discovery(
            label: "\(raw ? "RAW" : codec) · \(aspect)",
            aspect: aspect,
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

    private func installRotation(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async {
                guard let connection = self?.photoOutput.connection(with: .video),
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
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
        let bayer = photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let processedCodec = processedPhotoCodec()
        let processed: [String: Any] = [AVVideoCodecKey: processedCodec.codec]
        let settings: AVCapturePhotoSettings
        if let bayer {
            settings = AVCapturePhotoSettings(rawPixelFormatType: bayer, processedFormat: processed)
        } else {
            settings = AVCapturePhotoSettings(format: processed)
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
        let label = "\(usingRaw ? "RAW" : codecName) · \(cachedAspect)"
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
            let zoom = min(max(CGFloat(factor), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            guard zoom.isFinite else { return }
            if abs(device.videoZoomFactor - zoom) < 0.01 { return }
            if ramp, device.isRampingVideoZoom == false {
                device.ramp(toVideoZoomFactor: zoom, withRate: 3.5)
            } else {
                device.videoZoomFactor = zoom
            }
        }
    }

    private func switchInput(to newDevice: AVCaptureDevice) throws {
        if device?.uniqueID == newDevice.uniqueID { return }
        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        let input = try AVCaptureDeviceInput(device: newDevice)
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
        session.commitConfiguration()
        installRotation(for: newDevice)
        observeMeter(newDevice)
        let deviceID = newDevice.uniqueID
        DispatchQueue.main.async {
            self.activeDeviceID = deviceID
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
        let constituent = device.constituentDevices.first { $0.deviceType == .builtInWideAngleCamera && $0.isExposureModeSupported(.custom) }
            ?? device.constituentDevices.first { $0.isExposureModeSupported(.custom) }
        let fallback = Self.backCameras().first { $0.deviceType == .builtInWideAngleCamera && $0.isExposureModeSupported(.custom) }
            ?? Self.backCameras().first { $0.isExposureModeSupported(.custom) }
        guard let target = constituent ?? fallback else { return }
        try switchInput(to: target)
        if let native = lensStops.first(where: { $0.deviceID == target.uniqueID && abs($0.zoomFactor - 1) < 0.01 }) {
            DispatchQueue.main.async { self.selectedStopID = native.id }
        }
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
        let isos = ExposureStops.isos(min: format.minISO, max: format.maxISO)
        let shutters = ExposureStops.shutters(
            min: CMTimeGetSeconds(format.minExposureDuration),
            max: CMTimeGetSeconds(format.maxExposureDuration)
        )
        DispatchQueue.main.async {
            self.isoChoices = isos
            self.shutterChoices = shutters
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
        @unknown default:
            statusMessage = "相机已暂停。"
        }
    }
}
