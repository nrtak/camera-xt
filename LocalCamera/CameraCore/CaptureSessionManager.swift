import AVFoundation
import Vision
import CoreImage

struct CameraControls: Equatable {
    var automaticExposure = true
    var iso: Float = 100
    var shutterSeconds = 1.0 / 250
    var automaticWhiteBalance = true
    var temperature: Float = 5500
    var tint: Float = 0
    var automaticFocus = true
    var lensPosition: Float = 0.5
    var facePriority = true
    var flash: AVCaptureDevice.FlashMode = .off
}

struct CameraSnapshot {
    var lenses: [CameraLens] = []
    var selectedID: String?
    var resolution = "—"
    var running = false
    var message: String?
    var dualAvailable = false
    var dualEnabled = false
    var dualFocusSupported = [false, false]
    var focusLocked = false
    var videoMode = false
    var recording = false
    var videoLabel = "1080p · 30 fps"
    var stabilized = false
    var exposureLabel = ""
    var focusLabel = "Auto focus"
    var minISO: Float = 25
    var maxISO: Float = 1600
    var customExposureAvailable = false
    var manualFocusAvailable = false
    var whiteBalanceAvailable = false
    var flashAvailable = false
    var currentISO: Float = 100
    var currentShutter = 1.0 / 250
    var depthAvailable = false
    var depthEnabled = false
    var eyeFocusEnabled = false
    var eyeFocusAvailable = false
}

/// All session/device mutations and delegate ownership stay on this serial queue.
/// The UI only attaches the session to a preview layer and receives value snapshots.
final class CaptureSessionManager {
    let session = AVCaptureSession()
    var onChange: ((CameraSnapshot) -> Void)?
    var onMeter: ((CameraSnapshot) -> Void)?
    private let queue = DispatchQueue(label: "LocalCamera.capture", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var devices: [AVCaptureDevice] = []
    private var input: AVCaptureDeviceInput?
    private var processor: PhotoCaptureProcessor?
    private var observers: [NSObjectProtocol] = []
    private var wantsRunning = false
    private var snapshot = CameraSnapshot()
    private lazy var dual = DualPhotoCamera(queue: queue)
    private weak var preview: AVCaptureVideoPreviewLayer?
    private weak var secondaryPreview: AVCaptureVideoPreviewLayer?
    private final class PreviewReference {
        weak var layer: AVCaptureVideoPreviewLayer?
        init(_ layer: AVCaptureVideoPreviewLayer) { self.layer = layer }
    }
    private var previews: [PreviewReference] = []
    private var activeSession: AVCaptureSession { snapshot.dualEnabled ? dual.session : session }
    private let movie = AVCaptureMovieFileOutput()
    private var movieProcessor: MovieCaptureProcessor?
    private var audioInput: AVCaptureDeviceInput?
    private var stopMovieWhenStarted = false
    var onMovie: ((Result<URL, Error>) -> Void)?
    private var controls = CameraControls()
    private var meterTimer: DispatchSourceTimer?
    private var burstRunning = false
    private let eyeOutput = AVCaptureVideoDataOutput()
    private var eyeTracker: EyeFocusTracker?
    private var eyeGeneration = UUID()
    private var lastEyePoint: CGPoint?
    private var eyeStatus = "Eye AF · searching"

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                             object: nil, queue: nil) { [weak self] notification in
            self?.queue.async { [weak self] in
                guard let self, notification.object as? AVCaptureSession === self.activeSession else { return }
                self.publish(message: "Camera interrupted. It will resume when available.")
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                             object: nil, queue: nil) { [weak self] _ in
            self?.resume()
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                             object: nil, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.queue.async { [weak self] in
                guard let self = self else { return }
                guard notification.object as? AVCaptureSession === self.activeSession else { return }
                if error?.code == .mediaServicesWereReset, self.wantsRunning {
                    self.activeSession.startRunning()
                }
                self.publish(message: self.activeSession.isRunning ? nil : "Camera stopped. Tap Retry camera.")
            }
        })
    }

    deinit {
        meterTimer?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        queue.async {
            self.wantsRunning = true
            do {
                if self.input == nil { try self.configure() }
                self.connectPreview()
                if !self.activeSession.isRunning { self.activeSession.startRunning() }
                self.startMetering()
                self.publish(message: self.activeSession.isRunning ? nil : "Camera unavailable. Tap Retry camera.")
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    func stop() {
        queue.async {
            self.wantsRunning = false
            self.meterTimer?.cancel()
            self.meterTimer = nil
            if self.movieProcessor != nil { self.stopMovieWhenStarted = true }
            if self.movie.isRecording { self.movie.stopRecording() }
            if self.activeSession.isRunning { self.activeSession.stopRunning() }
            self.publish()
        }
    }

    private func resume() {
        queue.async {
            if self.wantsRunning && !self.activeSession.isRunning { self.activeSession.startRunning() }
            self.publish()
        }
    }

    private func configure() throws {
        devices = CameraDeviceCatalog.discover()
        if let frontDepth = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
            devices.removeAll { $0.position == .front }
            devices.append(frontDepth)
        }
        if let rearDepth = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
            devices.append(rearDepth)
        }
        guard let device = devices.first(where: {
            $0.position == .back && $0.deviceType == .builtInWideAngleCamera
        }) ?? devices.first else { throw CameraFailure.unavailable }
        let newInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        guard session.canAddInput(newInput) else { throw CameraFailure.input }
        session.addInput(newInput)
        guard session.canAddOutput(output) else {
            session.removeInput(newInput)
            throw CameraFailure.output
        }
        session.addOutput(output)
        input = newInput
        output.maxPhotoQualityPrioritization = .quality
        configureDimensions(device)
        snapshot.lenses = devices.map { device in
            if device.deviceType == .builtInDualCamera { return CameraLens(id: device.uniqueID, name: "Depth", isFront: false) }
            if device.deviceType == .builtInTrueDepthCamera { return CameraLens(id: device.uniqueID, name: "Front Depth", isFront: true) }
            return CameraDeviceCatalog.lens(for: device)
        }
        snapshot.selectedID = device.uniqueID
        snapshot.dualAvailable = DualPhotoCamera.isSupported
        try applyControls(to: device)
    }

    func select(_ id: String) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, self.movieProcessor == nil, !self.snapshot.videoMode, !self.dual.busy, !self.snapshot.dualEnabled, let oldInput = self.input,
                  let device = self.devices.first(where: { $0.uniqueID == id }) else { return }
            self.disableEyeFocus()
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.removeInput(oldInput)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.input = newInput
                    self.configureDimensions(device)
                    self.snapshot.selectedID = id
                    self.session.commitConfiguration()
                    try self.applyControls(to: device)
                    self.connectPreview()
                    self.publish()
                } else {
                    self.session.addInput(oldInput)
                    self.session.commitConfiguration()
                    throw CameraFailure.input
                }
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    private func configureDimensions(_ device: AVCaptureDevice) {
        output.isDepthDataDeliveryEnabled = output.isDepthDataDeliverySupported
        snapshot.depthAvailable = output.isDepthDataDeliverySupported
        if !snapshot.depthAvailable { snapshot.depthEnabled = false }
        // A modest native photo size keeps this first build responsive.
        let sizes = device.activeFormat.supportedMaxPhotoDimensions.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        if let size = sizes.last(where: { Int64($0.width) * Int64($0.height) <= 12_500_000 }) ?? sizes.first {
            output.maxPhotoDimensions = size
            snapshot.resolution = "Up to \(size.width) × \(size.height)"
        }
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }

    func capture(speed: Bool = false, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        queue.async {
            if self.snapshot.dualEnabled {
                self.dual.capture(completion: completion)
                return
            }
            guard self.session.isRunning, !self.session.isInterrupted, !self.snapshot.videoMode, self.processor == nil else {
                completion(.failure(CameraFailure.unavailable))
                return
            }
            let codec: AVVideoCodecType = self.output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            settings.maxPhotoDimensions = self.output.maxPhotoDimensions
            settings.photoQualityPrioritization = speed || self.input?.device.exposureMode == .custom ? .speed : .quality
            settings.isDepthDataDeliveryEnabled = self.snapshot.depthEnabled && self.output.isDepthDataDeliveryEnabled
            settings.embedsDepthDataInPhoto = settings.isDepthDataDeliveryEnabled
            if self.input?.device.isFlashAvailable == true && self.output.supportedFlashModes.contains(self.controls.flash) { settings.flashMode = self.controls.flash }
            let processor = PhotoCaptureProcessor(expectsDepth: settings.isDepthDataDeliveryEnabled) { [weak self] result in
                guard let self = self else { return }
                self.queue.async {
                    self.processor = nil
                    completion(result)
                }
            }
            self.processor = processor
            self.output.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func publish(message: String? = nil) {
        updateMeter()
        snapshot.depthAvailable = !snapshot.dualEnabled && !snapshot.videoMode && output.isDepthDataDeliveryEnabled
        if !snapshot.depthAvailable { snapshot.depthEnabled = false }
        snapshot.dualFocusSupported = snapshot.dualEnabled ? dual.inputs.map {
            $0.device.isFocusPointOfInterestSupported && $0.device.isFocusModeSupported(.continuousAutoFocus)
        } : [false, false]
        snapshot.running = activeSession.isRunning && !activeSession.isInterrupted
        snapshot.message = message
        onChange?(snapshot)
    }

    func setDepthEnabled(_ enabled: Bool) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, self.movieProcessor == nil,
                  self.snapshot.depthAvailable else { return }
            self.snapshot.depthEnabled = enabled
            self.publish()
        }
    }

    func setEyeFocus(_ enabled: Bool) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, self.movieProcessor == nil else { return }
            self.disableEyeFocus()
            guard enabled, self.snapshot.eyeFocusAvailable, let device = self.input?.device else { self.publish(); return }
            self.session.beginConfiguration()
            guard self.session.canAddOutput(self.eyeOutput) else {
                self.session.commitConfiguration()
                self.publish(message: "Eye focus is unavailable with this camera configuration.")
                return
            }
            self.eyeOutput.alwaysDiscardsLateVideoFrames = true
            self.eyeOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            self.session.addOutput(self.eyeOutput)
            if let connection = self.eyeOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported { connection.videoOrientation = .landscapeRight }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
            let generation = self.eyeGeneration
            let tracker = EyeFocusTracker { [weak self] point, paused in
                self?.queue.async { [weak self] in
                    guard let self, self.eyeGeneration == generation, self.snapshot.eyeFocusEnabled,
                          self.session.isRunning, !self.burstRunning, self.processor == nil else { return }
                    self.eyeStatus = paused ? "Eye AF · cooling" : point == nil ? "Eye AF · searching" : "Eye-priority AF"
                    guard !paused else { return }
                    let target = point ?? CGPoint(x: 0.5, y: 0.5)
                    if let previous = self.lastEyePoint, hypot(target.x - previous.x, target.y - previous.y) < 0.035 { return }
                    do {
                        try device.lockForConfiguration()
                        device.focusPointOfInterest = target
                        device.focusMode = .continuousAutoFocus
                        device.unlockForConfiguration()
                        self.lastEyePoint = target
                    } catch { self.eyeStatus = "Eye AF · unavailable" }
                }
            }
            self.eyeTracker = tracker
            self.eyeOutput.setSampleBufferDelegate(tracker, queue: tracker.queue)
            self.session.commitConfiguration()
            self.snapshot.eyeFocusEnabled = true
            self.controls.automaticFocus = true
            do { try self.applyControls(to: device); self.publish() }
            catch { self.disableEyeFocus(); self.publish(message: error.localizedDescription) }
        }
    }

    private func disableEyeFocus() {
        eyeGeneration = UUID()
        eyeOutput.setSampleBufferDelegate(nil, queue: nil)
        if session.outputs.contains(eyeOutput) {
            session.beginConfiguration()
            session.removeOutput(eyeOutput)
            session.commitConfiguration()
        }
        eyeTracker = nil
        lastEyePoint = nil
        snapshot.eyeFocusEnabled = false
        if let device = input?.device { try? applyControls(to: device) }
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer, secondary: Bool = false) {
        queue.async {
            if secondary {
                if let old = self.secondaryPreview {
                    if let connection = old.connection { old.session?.removeConnection(connection) }
                    old.session = nil
                }
                self.secondaryPreview = layer
                self.connectPreview()
                return
            }
            if let connection = self.preview?.connection { self.preview?.session?.removeConnection(connection) }
            self.preview?.session = nil
            self.previews.removeAll { $0.layer == nil || $0.layer === layer }
            self.previews.append(PreviewReference(layer))
            self.preview = layer
            self.connectPreview()
        }
    }

    func detachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        queue.async {
            if self.secondaryPreview === layer { self.secondaryPreview = nil }
            self.previews.removeAll { $0.layer == nil || $0.layer === layer }
            if let connection = layer.connection { layer.session?.removeConnection(connection) }
            layer.session = nil
            if self.preview === layer {
                self.preview = self.previews.last?.layer
                self.connectPreview()
            }
        }
    }

    private func disconnectPreviews() {
        for layer in [preview, secondaryPreview].compactMap({ $0 }) {
            if let connection = layer.connection { layer.session?.removeConnection(connection) }
            layer.session = nil
        }
    }

    private func connectPreview() {
        disconnectPreviews()
        let sources: [(AVCaptureVideoPreviewLayer?, AVCaptureDeviceInput?)] = [
            (preview, snapshot.dualEnabled ? dual.inputs.first : input),
            (secondaryPreview, snapshot.dualEnabled && dual.inputs.count > 1 ? dual.inputs[1] : nil)
        ]
        for (layer, source) in sources {
            guard let layer, let source,
                  let port = source.ports.first(where: { $0.mediaType == .video }) else { continue }
            layer.setSessionWithNoConnection(activeSession)
            let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            guard activeSession.canAddConnection(connection) else { continue }
            activeSession.addConnection(connection)
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = source.device.position == .front
            }
        }
    }

    func setDualEnabled(_ enabled: Bool) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, self.movieProcessor == nil, !self.snapshot.videoMode, !self.dual.busy, enabled != self.snapshot.dualEnabled else { return }
            self.disableEyeFocus()
            self.activeSession.stopRunning()
            self.disconnectPreviews()
            do {
                if enabled {
                    try self.dual.configure()
                    self.snapshot.dualEnabled = true
                    self.snapshot.selectedID = self.dual.inputs.first?.device.uniqueID
                    self.snapshot.resolution = self.dual.resolution
                } else {
                    self.dual.reset()
                    self.snapshot.dualEnabled = false
                    self.snapshot.selectedID = self.input?.device.uniqueID
                    self.session.beginConfiguration()
                    if self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
                    if let device = self.input?.device { self.configureDimensions(device) }
                    self.session.commitConfiguration()
                }
                self.connectPreview()
                if enabled && self.dual.session.hardwareCost > 1 { throw DualPhotoCamera.Failure.overloaded }
                if enabled {
                    // Paired capture uses automatic metering independently for each sensor.
                    for input in self.dual.inputs { try self.applyControls(to: input.device, automatic: true) }
                } else if let device = self.input?.device { try self.applyControls(to: device) }
                if self.wantsRunning { self.activeSession.startRunning() }
                self.snapshot.focusLocked = !enabled && !self.controls.automaticFocus
                self.publish()
            } catch {
                self.disconnectPreviews()
                self.dual.reset()
                self.snapshot.dualEnabled = false
                self.snapshot.selectedID = self.input?.device.uniqueID
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                if let device = self.input?.device { self.configureDimensions(device) }
                self.session.commitConfiguration()
                self.connectPreview()
                if self.wantsRunning { self.session.startRunning() }
                self.publish(message: error.localizedDescription)
            }
        }
    }

    func focus(at point: CGPoint, locked: Bool, dualIndex: Int? = nil) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, !self.dual.busy else { return }
            self.disableEyeFocus()
            let devices: [AVCaptureDevice]
            if self.snapshot.dualEnabled {
                guard let index = dualIndex, self.dual.inputs.indices.contains(index) else { return }
                devices = [self.dual.inputs[index].device]
            } else { devices = [self.input?.device].compactMap { $0 } }
            do {
                for device in devices {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
                        device.isFaceDrivenAutoFocusEnabled = false
                    }
                    if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
                    if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
                    let focus: AVCaptureDevice.FocusMode = locked ? .autoFocus : .continuousAutoFocus
                    let exposure: AVCaptureDevice.ExposureMode = locked ? .autoExpose : .continuousAutoExposure
                    if device.isFocusModeSupported(focus) { device.focusMode = focus }
                    if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
                    device.unlockForConfiguration()
                }
                self.snapshot.focusLocked = locked
                self.publish()
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    func setExposureBias(_ value: Float) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, !self.dual.busy else { return }
            let devices = self.snapshot.dualEnabled ? self.dual.inputs.map(\.device) : [self.input?.device].compactMap { $0 }
            do {
                for device in devices {
                    try device.lockForConfiguration()
                    device.setExposureTargetBias(min(device.maxExposureTargetBias, max(device.minExposureTargetBias, value)))
                    device.unlockForConfiguration()
                }
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    func setVideoMode(_ enabled: Bool, width: Int32 = 1920, fps: Int32 = 30, stabilized: Bool = true) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, self.movieProcessor == nil, !self.dual.busy, !self.snapshot.dualEnabled,
                  let device = self.input?.device else { self.publish(); return }
            self.disableEyeFocus()
            self.session.stopRunning()
            self.session.beginConfiguration()
            var failure: Error?
            do {
                if enabled {
                    let height: Int32 = width == 3840 ? 2160 : 1080
                    guard let format = device.formats.first(where: {
                        let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                        return size.width == width && size.height == height &&
                            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
                            $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }
                    }) else { throw VideoFailure.unsupported }
                    if !self.session.outputs.contains(self.movie) {
                        self.session.sessionPreset = .high
                        guard self.session.canAddOutput(self.movie) else { throw VideoFailure.unsupported }
                        self.session.addOutput(self.movie)
                    }
                    try device.lockForConfiguration()
                    device.activeFormat = format
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
                    if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
                    device.unlockForConfiguration()
                    self.snapshot.videoMode = true
                    self.snapshot.videoLabel = "\(width == 3840 ? "4K" : "1080p") · \(fps) fps"
                    self.snapshot.stabilized = false
                    if let connection = self.movie.connection(with: .video) {
                        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
                        if connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = stabilized ? .auto : .off
                            self.snapshot.stabilized = stabilized
                        }
                        if self.movie.availableVideoCodecTypes.contains(.hevc) {
                            self.movie.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                        }
                    }
                } else {
                    if self.session.outputs.contains(self.movie) { self.session.removeOutput(self.movie) }
                    if let audio = self.audioInput { self.session.removeInput(audio); self.audioInput = nil }
                    self.session.sessionPreset = .photo
                    self.configureDimensions(device)
                    self.snapshot.videoMode = false
                    self.snapshot.stabilized = false
                }
            } catch {
                failure = error
                if !self.snapshot.videoMode {
                    if self.session.outputs.contains(self.movie) { self.session.removeOutput(self.movie) }
                    self.session.sessionPreset = .photo
                    self.configureDimensions(device)
                }
            }
            self.session.commitConfiguration()
            do { try self.applyControls(to: device) } catch { failure = error }
            self.connectPreview()
            if self.wantsRunning { self.session.startRunning() }
            self.publish(message: failure?.localizedDescription)
        }
    }

    func startRecording() {
        queue.async {
            guard self.snapshot.videoMode, self.session.isRunning, !self.session.isInterrupted, self.movieProcessor == nil else {
                self.onMovie?(.failure(CameraFailure.unavailable)); return
            }
            if self.audioInput == nil && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                do {
                    if let microphone = AVCaptureDevice.default(for: .audio) {
                        let audio = try AVCaptureDeviceInput(device: microphone)
                        self.session.beginConfiguration()
                        if self.session.canAddInput(audio) { self.session.addInput(audio); self.audioInput = audio }
                        self.session.commitConfiguration()
                    }
                } catch { self.onMovie?(.failure(error)); return }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            self.stopMovieWhenStarted = false
            let processor = MovieCaptureProcessor(started: { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.snapshot.recording = true
                    if self.stopMovieWhenStarted || !self.wantsRunning { self.movie.stopRecording() }
                    self.publish()
                }
            }) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    self.movieProcessor = nil
                    self.snapshot.recording = false
                    self.publish()
                    self.onMovie?(result)
                }
            }
            self.movieProcessor = processor
            self.movie.minFreeDiskSpaceLimit = 100 * 1024 * 1024
            self.movie.startRecording(to: url, recordingDelegate: processor)
        }
    }

    func stopRecording() {
        queue.async {
            self.stopMovieWhenStarted = true
            if self.movie.isRecording { self.movie.stopRecording() }
        }
    }

    func setControls(_ value: CameraControls) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, !self.dual.busy, !self.snapshot.dualEnabled,
                  let device = self.input?.device else { return }
            do {
                self.controls = value
                if !value.automaticFocus { self.disableEyeFocus() }
                try self.applyControls(to: device)
                self.publish()
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    private func applyControls(to device: AVCaptureDevice, automatic: Bool = false) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
            device.isFaceDrivenAutoFocusEnabled = controls.facePriority && !snapshot.eyeFocusEnabled
            if controls.automaticFocus || automatic || !device.isLockingFocusWithCustomLensPositionSupported {
                device.focusMode = .continuousAutoFocus
            } else if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: min(1, max(0, controls.lensPosition)), completionHandler: nil)
            }
        }
        if controls.automaticExposure || automatic || !device.isExposureModeSupported(.custom) {
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        } else if device.isExposureModeSupported(.custom) {
            var maximum = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
            if snapshot.videoMode { maximum = min(maximum, CMTimeGetSeconds(device.activeVideoMaxFrameDuration)) }
            let seconds = max(CMTimeGetSeconds(device.activeFormat.minExposureDuration), min(maximum, controls.shutterSeconds))
            device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                                         iso: min(device.activeFormat.maxISO, max(device.activeFormat.minISO, controls.iso)), completionHandler: nil)
        }
        if controls.automaticWhiteBalance || automatic || !device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        } else if device.isWhiteBalanceModeSupported(.locked) {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: controls.temperature, tint: controls.tint)
            var gains = device.deviceWhiteBalanceGains(for: values)
            gains.redGain = min(device.maxWhiteBalanceGain, max(1, gains.redGain))
            gains.greenGain = min(device.maxWhiteBalanceGain, max(1, gains.greenGain))
            gains.blueGain = min(device.maxWhiteBalanceGain, max(1, gains.blueGain))
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
        snapshot.focusLocked = !controls.automaticFocus && !automatic && device.isLockingFocusWithCustomLensPositionSupported
    }

    private func startMetering() {
        guard meterTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.activeSession.isRunning else { return }
            self.updateMeter()
            self.onMeter?(self.snapshot)
        }
        meterTimer = timer
        timer.resume()
    }

    private func updateMeter() {
        guard let device = snapshot.dualEnabled ? dual.inputs.first?.device : input?.device else { return }
        let seconds = CMTimeGetSeconds(device.exposureDuration)
        let shutter = seconds > 0 && seconds < 1 ? "1/\(Int((1 / seconds).rounded()))" : String(format: "%.1f s", seconds)
        snapshot.exposureLabel = "\(shutter) · ISO \(Int(device.iso.rounded()))"
        snapshot.currentISO = device.iso
        snapshot.currentShutter = seconds
        snapshot.focusLabel = device.isAdjustingFocus ? "Focusing" : device.focusMode == .locked ? "Focus locked" : controls.facePriority ? "Face-priority AF" : "Auto focus"
        if snapshot.eyeFocusEnabled { snapshot.focusLabel = eyeStatus }
        snapshot.eyeFocusAvailable = !snapshot.dualEnabled && !snapshot.videoMode && device.position == .back && device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.continuousAutoFocus)
        snapshot.minISO = device.activeFormat.minISO
        snapshot.maxISO = device.activeFormat.maxISO
        snapshot.customExposureAvailable = device.isExposureModeSupported(.custom)
        snapshot.manualFocusAvailable = device.isLockingFocusWithCustomLensPositionSupported
        snapshot.whiteBalanceAvailable = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        snapshot.flashAvailable = device.hasFlash && device.isFlashAvailable
    }

    func captureBurst(completion: @escaping (Result<[CapturedPhoto], Error>) -> Void) {
        queue.async {
            guard !self.burstRunning, !self.snapshot.dualEnabled, !self.snapshot.videoMode,
                  self.processor == nil, self.session.isRunning else { completion(.failure(CameraFailure.unavailable)); return }
            self.burstRunning = true
            let flash = self.controls.flash
            self.controls.flash = .off
            self.captureBurstFrame(photos: [], remaining: 3) { result in
                self.controls.flash = flash
                self.burstRunning = false
                completion(result)
            }
        }
    }

    private func captureBurstFrame(photos: [CapturedPhoto], remaining: Int,
                                   completion: @escaping (Result<[CapturedPhoto], Error>) -> Void) {
        capture(speed: true) { result in
            switch result {
            case .success(let photo):
                let collected = photos + [photo]
                if remaining > 1 && self.wantsRunning {
                    self.captureBurstFrame(photos: collected, remaining: remaining - 1, completion: completion)
                } else { completion(.success(collected)) }
            case .failure(let error):
                completion(photos.isEmpty ? .failure(error) : .success(photos))
            }
        }
    }
}

/// Low-rate, local landmark detection. Coordinates return to the unmirrored sensor space.
private final class EyeFocusTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "CameraXT.eyeFocus", qos: .utility)
    private let report: (CGPoint?, Bool) -> Void
    private var lastTime = -Double.infinity
    private var misses = 0
    init(report: @escaping (CGPoint?, Bool) -> Void) { self.report = report }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard time.isFinite, time - lastTime >= 0.4 else { return }
        lastTime = time
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious && thermal != .critical else { report(nil, true); return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            let raw = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 640 / max(raw.extent.width, raw.extent.height))
            let image = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let request = VNDetectFaceLandmarksRequest()
            do {
                try VNImageRequestHandler(ciImage: image, orientation: .right, options: [:]).perform([request])
                guard let face = request.results?.filter({ $0.confidence >= 0.6 }).max(by: {
                    $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
                }), let eye = face.landmarks?.leftEye ?? face.landmarks?.rightEye,
                      !eye.normalizedPoints.isEmpty else { missed(); return }
                let points = eye.normalizedPoints
                let x = points.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(points.count)
                let y = points.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(points.count)
                let uprightX = face.boundingBox.minX + x * face.boundingBox.width
                let uprightY = face.boundingBox.minY + y * face.boundingBox.height
                // Undo Vision's clockwise portrait orientation and bottom-left origin.
                let point = CGPoint(x: 1 - uprightY, y: 1 - uprightX)
                guard (0...1).contains(point.x), (0...1).contains(point.y) else { missed(); return }
                misses = 0
                report(point, false)
            } catch { missed() }
        }
    }
    private func missed() {
        misses += 1
        if misses >= 3 { report(nil, false) }
    }
}

private enum VideoFailure: LocalizedError {
    case unsupported
    var errorDescription: String? { "This lens does not support the selected video format. Choose another resolution or frame rate." }
}

private final class MovieCaptureProcessor: NSObject, AVCaptureFileOutputRecordingDelegate {
    let started: () -> Void
    let completion: (Result<URL, Error>) -> Void
    init(started: @escaping () -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.started = started
        self.completion = completion
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) { started() }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        if let error = error as NSError?, error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
            try? FileManager.default.removeItem(at: outputFileURL)
            completion(.failure(error))
        } else { completion(.success(outputFileURL)) }
    }
}

/// Owns only the paired still-photo pipeline. All access uses the parent's session queue.
private final class DualPhotoCamera {
    enum Failure: LocalizedError {
        case unsupported, overloaded
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Main + Ultra Wide capture is unavailable on this camera configuration. Single photo is ready."
            case .overloaded: return "Dual Shot needs more camera resources than are currently available. Use Single Photo or let the iPhone cool before retrying."
            }
        }
    }
    let session = AVCaptureMultiCamSession()
    private let queue: DispatchQueue
    private(set) var inputs: [AVCaptureDeviceInput] = []
    private var outputs: [AVCapturePhotoOutput] = []
    private var originals: [(AVCaptureDevice, AVCaptureDevice.Format, CMTime, CMTime)] = []
    private var processors: [Int: PhotoCaptureProcessor] = [:]
    private var results: [Int: Result<CapturedPhoto, Error>] = [:]
    var busy: Bool { !processors.isEmpty }
    private(set) var resolution = "—"

    init(queue: DispatchQueue) { self.queue = queue }

    private static var pair: [AVCaptureDevice]? {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return nil }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera], mediaType: .video, position: .back)
        guard let main = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }),
              let ultra = discovery.devices.first(where: { $0.deviceType == .builtInUltraWideCamera }),
              discovery.supportedMultiCamDeviceSets.contains(where: { $0.contains(main) && $0.contains(ultra) }) else { return nil }
        return [main, ultra]
    }
    static var isSupported: Bool { pair != nil }

    func configure() throws {
        guard inputs.isEmpty else { return }
        guard let pair = Self.pair else { throw Failure.unsupported }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        var labels: [String] = []
        for device in pair {
            // Keep the sensor's preview workload modest while preserving native still dimensions.
            let formats = device.formats.filter {
                let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return $0.isMultiCamSupported && size.width <= 1920 && size.height <= 1440 &&
                    !$0.supportedMaxPhotoDimensions.isEmpty && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            }
            guard let format = formats.max(by: {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return Int64(a.width) * Int64(a.height) < Int64(b.width) * Int64(b.height)
            }) else { throw Failure.unsupported }
            originals.append((device, device.activeFormat, device.activeVideoMinFrameDuration, device.activeVideoMaxFrameDuration))
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw Failure.unsupported }
            session.addInputWithNoConnections(input)
            inputs.append(input)
            let output = AVCapturePhotoOutput()
            guard session.canAddOutput(output) else { throw Failure.unsupported }
            session.addOutputWithNoConnections(output)
            outputs.append(output)
            guard let port = input.ports.first(where: { $0.mediaType == .video }) else { throw Failure.unsupported }
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { throw Failure.unsupported }
            session.addConnection(connection)
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            output.maxPhotoQualityPrioritization = .speed
            let sizes = format.supportedMaxPhotoDimensions.sorted { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
            guard let size = sizes.last(where: { Int64($0.width) * Int64($0.height) <= 12_500_000 }) ?? sizes.first else { throw Failure.unsupported }
            output.maxPhotoDimensions = size
            labels.append("\(size.width) × \(size.height)")
        }
        resolution = labels.joined(separator: " + ")
    }

    func reset() {
        session.stopRunning()
        session.beginConfiguration()
        session.connections.forEach { session.removeConnection($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.inputs.forEach { session.removeInput($0) }
        session.commitConfiguration()
        inputs.removeAll()
        outputs.removeAll()
        for (device, format, minimum, maximum) in originals {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.activeVideoMinFrameDuration = minimum
                device.activeVideoMaxFrameDuration = maximum
                device.unlockForConfiguration()
            } catch { /* The parent rebuilds single-camera configuration before resuming. */ }
        }
        originals.removeAll()
    }

    func capture(completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        guard session.isRunning, !session.isInterrupted, !busy, outputs.count == 2 else {
            completion(.failure(CameraFailure.unavailable)); return
        }
        guard inputs.allSatisfy({ $0.device.systemPressureState.level != .serious && $0.device.systemPressureState.level != .critical && $0.device.systemPressureState.level != .shutdown }) else {
            completion(.failure(Failure.overloaded)); return
        }
        results.removeAll()
        // Each output receives its own settings and retained delegate. Requests are issued
        // back-to-back on one queue; independent sensors do not guarantee identical exposure times.
        for (index, output) in outputs.enumerated() {
            let codec: AVVideoCodecType = output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            settings.photoQualityPrioritization = .speed
            let processor = PhotoCaptureProcessor { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    self.results[index] = result
                    self.processors[index] = nil
                    guard self.results.count == 2 else { return }
                    let successful = (0..<2).compactMap { index -> (Int, CapturedPhoto)? in
                        guard let photo = try? self.results[index]?.get() else { return nil }
                        return (index, photo)
                    }
                    guard var first = successful.first?.1 else {
                        completion(.failure(CameraFailure.noPhoto)); self.results.removeAll(); return
                    }
                    first.companions = successful.dropFirst().map { $0.1 }
                    first.warning = successful.count == 2 ? "Both photos saved" :
                        "Only \(successful[0].0 == 0 ? "Main" : "Ultra Wide") photo saved. The other camera did not capture a photo."
                    self.results.removeAll()
                    completion(.success(first))
                }
            }
            processors[index] = processor
            output.capturePhoto(with: settings, delegate: processor)
        }
    }
}
