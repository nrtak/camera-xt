import AVFoundation

struct CameraSnapshot {
    var lenses: [CameraLens] = []
    var selectedID: String?
    var resolution = "—"
    var running = false
    var message: String?
    var dualAvailable = false
    var dualEnabled = false
    var focusLocked = false
    var videoMode = false
    var recording = false
    var videoLabel = "1080p · 30 fps"
    var stabilized = false
}

/// All session/device mutations and delegate ownership stay on this serial queue.
/// The UI only attaches the session to a preview layer and receives value snapshots.
final class CaptureSessionManager {
    let session = AVCaptureSession()
    var onChange: ((CameraSnapshot) -> Void)?
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
    private var activeSession: AVCaptureSession { snapshot.dualEnabled ? dual.session : session }
    private let movie = AVCaptureMovieFileOutput()
    private var movieProcessor: MovieCaptureProcessor?
    private var audioInput: AVCaptureDeviceInput?
    private var stopMovieWhenStarted = false
    var onMovie: ((Result<URL, Error>) -> Void)?

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

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func start() {
        queue.async {
            self.wantsRunning = true
            do {
                if self.input == nil { try self.configure() }
                self.connectPreview()
                if !self.activeSession.isRunning { self.activeSession.startRunning() }
                self.publish(message: self.activeSession.isRunning ? nil : "Camera unavailable. Tap Retry camera.")
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    func stop() {
        queue.async {
            self.wantsRunning = false
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
        snapshot.lenses = devices.map(CameraDeviceCatalog.lens)
        snapshot.selectedID = device.uniqueID
        snapshot.dualAvailable = DualPhotoCamera.isSupported
    }

    func select(_ id: String) {
        queue.async {
            guard self.processor == nil, self.movieProcessor == nil, !self.snapshot.videoMode, !self.dual.busy, !self.snapshot.dualEnabled, let oldInput = self.input,
                  let device = self.devices.first(where: { $0.uniqueID == id }) else { return }
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
                    self.connectPreview()
                    self.snapshot.focusLocked = false
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

    func capture(completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
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
            settings.photoQualityPrioritization = .quality
            let processor = PhotoCaptureProcessor { [weak self] result in
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
        snapshot.running = activeSession.isRunning && !activeSession.isInterrupted
        snapshot.message = message
        onChange?(snapshot)
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        queue.async {
            self.preview = layer
            self.connectPreview()
        }
    }

    private func connectPreview() {
        guard let preview else { return }
        if let connection = preview.connection { preview.session?.removeConnection(connection) }
        preview.setSessionWithNoConnection(activeSession)
        let source = snapshot.dualEnabled ? dual.inputs.first : input
        guard let port = source?.ports.first(where: { $0.mediaType == .video }) else { return }
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
        guard activeSession.canAddConnection(connection) else { return }
        activeSession.addConnection(connection)
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = source?.device.position == .front
        }
    }

    func setDualEnabled(_ enabled: Bool) {
        queue.async {
            guard self.processor == nil, self.movieProcessor == nil, !self.snapshot.videoMode, !self.dual.busy, enabled != self.snapshot.dualEnabled else { return }
            self.activeSession.stopRunning()
            if let connection = self.preview?.connection { self.preview?.session?.removeConnection(connection) }
            self.preview?.session = nil
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
                if self.wantsRunning { self.activeSession.startRunning() }
                self.snapshot.focusLocked = false
                self.publish()
            } catch {
                if let connection = self.preview?.connection { self.preview?.session?.removeConnection(connection) }
                self.preview?.session = nil
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

    func focus(at point: CGPoint, locked: Bool) {
        queue.async {
            guard self.processor == nil, !self.dual.busy else { return }
            let devices = self.snapshot.dualEnabled ? self.dual.inputs.map(\.device) : [self.input?.device].compactMap { $0 }
            do {
                for device in devices {
                    try device.lockForConfiguration()
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
            guard self.processor == nil, !self.dual.busy else { return }
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
            guard self.processor == nil, self.movieProcessor == nil, !self.dual.busy, !self.snapshot.dualEnabled,
                  let device = self.input?.device else { self.publish(); return }
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
                    var photos = (0..<2).compactMap { try? self.results[$0]?.get() }
                    guard var first = photos.first else {
                        completion(.failure(CameraFailure.noPhoto)); self.results.removeAll(); return
                    }
                    photos.removeFirst()
                    first.companions = photos
                    if photos.isEmpty { first.warning = "Only one lens captured successfully. The available photo was kept." }
                    self.results.removeAll()
                    completion(.success(first))
                }
            }
            processors[index] = processor
            output.capturePhoto(with: settings, delegate: processor)
        }
    }
}
