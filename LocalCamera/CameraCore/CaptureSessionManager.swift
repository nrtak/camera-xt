import AVFoundation

struct CameraSnapshot {
    var lenses: [CameraLens] = []
    var selectedID: String?
    var resolution = "—"
    var running = false
    var message: String?
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

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                             object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.publish(message: "Camera interrupted. It will resume when available.")
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                             object: session, queue: nil) { [weak self] _ in
            self?.resume()
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                             object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.queue.async { [weak self] in
                guard let self = self else { return }
                if error?.code == .mediaServicesWereReset, self.wantsRunning {
                    self.session.startRunning()
                }
                self.publish(message: self.session.isRunning ? nil : "Camera stopped. Tap Retry camera.")
            }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func start() {
        queue.async {
            self.wantsRunning = true
            do {
                if self.input == nil { try self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                self.publish(message: self.session.isRunning ? nil : "Camera unavailable. Tap Retry camera.")
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    func stop() {
        queue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
            self.publish()
        }
    }

    private func resume() {
        queue.async {
            if self.wantsRunning && !self.session.isRunning { self.session.startRunning() }
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
    }

    func select(_ id: String) {
        queue.async {
            guard self.processor == nil, let oldInput = self.input,
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
            guard self.session.isRunning, !self.session.isInterrupted, self.processor == nil else {
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
        snapshot.running = session.isRunning && !session.isInterrupted
        snapshot.message = message
        onChange?(snapshot)
    }
}
