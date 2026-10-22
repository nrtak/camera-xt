import AVFoundation
import Vision
import CoreImage
import UIKit

// Only fixed event names and numeric measurements are stored: no image data,
// filenames, location, device identifiers or free-form error descriptions.
enum CameraDiagnosticEvent: String {
    case launch, sessionStart, sessionStop, memoryWarning, sample
    case interrupted, interruptionEnded, runtimeError, recoveryAttempt, recoverySucceeded, previewStalled, previewRestart
    case photoMode, videoMode, dualMode, transitionFinished, capture, processing, saving, saved, saveFailed
}

struct CameraDiagnosticHistory: Codable {
    private(set) var entries: [String] = []
    mutating func append(_ entry: String) {
        entries.append(String(entry.prefix(240)))
        entries = Array(entries.suffix(120))
    }
}

final class CameraDiagnostics {
    static let shared = CameraDiagnostics()
    private let queue = DispatchQueue(label: "camera.local.diagnostics", qos: .utility)
    private var history = CameraDiagnosticHistory()
    private var loaded = false
    private var storageAvailable = true
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CameraDiagnostics.json")

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
           let data = try? Data(contentsOf: file),
           let previous = try? JSONDecoder().decode(CameraDiagnosticHistory.self, from: data) {
            for entry in previous.entries.suffix(120) { history.append(entry) }
        }
    }

    func record(_ event: CameraDiagnosticEvent, value: Int? = nil, configuration: CameraDiagnosticConfiguration? = nil) {
        queue.async {
            self.load()
            let memory = Self.memoryBytes().map { String($0 / 1_048_576) } ?? "unknown"
            let metric = value.map { " value=\($0)" } ?? ""
            self.history.append("\(ISO8601DateFormatter().string(from: Date())) \(event.rawValue)\(metric) memoryMB=\(memory) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) \(configuration?.summary ?? "")")
            do {
                try FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(self.history).write(to: self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var url = self.file
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try url.setResourceValues(values)
                self.storageAvailable = true
            } catch { self.storageAvailable = false }
        }
    }

    func report() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                self.load()
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                let header = "Camera XT \(version) (\(build)) · iOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nLocal event history; not a crash report. Sampled memory may miss peaks.\ntransitionFinished and saved values: milliseconds. Error values: numeric codes. Thermal: 0 normal, 1 warm, 2 hot, 3 critical. Session events include temporary pauses for processing.\n"
                let warning = self.storageAvailable ? "" : "History could not be saved to disk; current events may be lost on exit.\n"
                continuation.resume(returning: header + warning + self.history.entries.joined(separator: "\n"))
            }
        }
    }

    func clear() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.loaded = true; self.history = CameraDiagnosticHistory()
                do {
                    if FileManager.default.fileExists(atPath: self.file.path) { try FileManager.default.removeItem(at: self.file) }
                    self.storageAvailable = true
                } catch { self.storageAvailable = false }
                continuation.resume()
            }
        }
    }

    static func memoryBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

enum CameraRecoveryPolicy {
    static func mayAttempt(active: Bool, interrupted: Bool, busy: Bool, attempts: Int,
                           lastAttempt: TimeInterval?, now: TimeInterval) -> Bool {
        active && !interrupted && !busy && attempts < 2 &&
            (lastAttempt.map { now - $0 >= 10 } ?? true)
    }
}

struct CameraDiagnosticConfiguration {
    enum Mode: String { case photo, dualFast, dualDetail, video }
    let mode: Mode
    let width: Int32
    let height: Int32
    let fps: Int32
    var summary: String { "mode=\(mode.rawValue) configured=\(width)x\(height) fps=\(fps)" }
}

struct PreviewHealth {
    private(set) var missedChecks = 0
    private(set) var attempts = 0
    private var lastAttempt: TimeInterval?
    mutating func resetObservation() { missedChecks = 0 }
    mutating func shouldRestart(previewing: Bool, eligible: Bool, now: TimeInterval) -> Bool {
        guard eligible, !previewing else { missedChecks = 0; return false }
        missedChecks += 1
        guard missedChecks >= 5, attempts < 2,
              lastAttempt.map({ now - $0 >= 15 }) ?? true else { return false }
        missedChecks = 0; attempts += 1; lastAttempt = now
        return true
    }
}

enum CaptureLensLabel {
    static func make(name: String, base: Double, factor: Double) -> String {
        let value = base * factor
        guard value.isFinite, value > 0 else { return name }
        return name + " · " + String(format: "%.2f×", value)
    }
}

struct CameraControls: Equatable, Codable {
    var automaticExposure = true
    var iso: Float = 100
    var shutterSeconds = 1.0 / 250
    var automaticWhiteBalance = true
    var temperature: Float = 5500
    var tint: Float = 0
    var automaticFocus = true
    var lensPosition: Float = 0.5
    var facePriority = true
    private var flashValue = AVCaptureDevice.FlashMode.off.rawValue
    var flash: AVCaptureDevice.FlashMode {
        get { AVCaptureDevice.FlashMode(rawValue: flashValue) ?? .off }
        set { flashValue = newValue.rawValue }
    }
}

struct CameraControlChanges {
    let focus: Bool
    let exposure: Bool
    let whiteBalance: Bool
    init(from old: CameraControls, to new: CameraControls) {
        focus = old.automaticFocus != new.automaticFocus || old.lensPosition != new.lensPosition || old.facePriority != new.facePriority
        exposure = old.automaticExposure != new.automaticExposure || old.iso != new.iso || old.shutterSeconds != new.shutterSeconds
        whiteBalance = old.automaticWhiteBalance != new.automaticWhiteBalance || old.temperature != new.temperature || old.tint != new.tint
    }
}

enum ZoomLimits {
    static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double? {
        guard value.isFinite, minimum.isFinite, maximum.isFinite, minimum >= 1, maximum >= minimum else { return nil }
        return min(max(value, minimum), maximum)
    }
}

struct CameraZoom: Codable, Equatable {
    var deviceID = ""
    var value: Double = 1
    var minimum: Double = 1
    var maximum: Double = 1
}

struct VideoQuality: Equatable, Hashable, Identifiable {
    let width: Int32
    let fps: Int32
    var id: String { "\(width)-\(fps)" }
    var label: String { "\(width == 3840 ? "4K" : width == 1920 ? "1080p" : "720p") · \(fps) fps" }
    static func resolve(width: Int32, fps: Int32, from options: [VideoQuality]) -> VideoQuality? {
        selectWidth(width, keepingFPS: fps, from: options) ?? ranked(options).first
    }

    static func selectWidth(_ width: Int32, keepingFPS fps: Int32?, from options: [VideoQuality]) -> VideoQuality? {
        let matches = ranked(options.filter { $0.width == width })
        return matches.first(where: { $0.fps == fps }) ?? matches.first
    }

    static func ranked(_ options: [VideoQuality]) -> [VideoQuality] {
        Array(Set(options)).sorted { $0.width == $1.width ? $0.fps > $1.fps : $0.width > $1.width }
    }
}

enum ShutterOptions {
    static func values(minimum: Double, maximum: Double, requested: Double) -> [Double] {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return [] }
        let standard = [8000.0, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4, 2, 1].map { 1 / $0 }
        let selected = min(maximum, max(minimum, requested.isFinite ? requested : minimum))
        return Array(Set(standard.filter { $0 >= minimum && $0 <= maximum } + [selected])).sorted()
    }
}

struct CameraSnapshot {
    var zooms: [CameraZoom] = []

    var lenses: [CameraLens] = []
    var selectedID: String?
    var resolution = "—"
    var running = false
    var message: String?
    var dualAvailable = false
    var dualEnabled = false
    var dualMode: DualShotMode = .detail
    var dualFocusSupported = [false, false]
    var focusStates = ["Auto focus", "Auto focus"]
    var cooling = false
    var analysisMode = "Off"
    var audioRecording = false
    var focusLocked = false
    var videoMode = false
    var recording = false
    var videoLabel = "Best available"
    var videoQualities: [VideoQuality] = []
    var videoQuality: VideoQuality?
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
    var minimumShutter = 1.0 / 8000
    var maximumShutter = 1.0
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
    private var interfaceOrientation: AVCaptureVideoOrientation = .portrait
    private var sequenceOrientation: AVCaptureVideoOrientation = .portrait
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
    var onCaptureProgress: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    var onMovie: ((Result<URL, Error>) -> Void)?
    private var controls = CameraControls()
    private var meterTimer: DispatchSourceTimer?
    private var burstRunning = false
    private var pendingMemoryFallback = false
    private var pendingMemoryCleanup = false
    private var recoveryPending = false
    private var recoveryAttempts = 0
    private var lastRecoveryAttempt: TimeInterval?
    private var lastDiagnosticSample: TimeInterval = 0
    private var previewHealth = PreviewHealth()
    private var previewFailureReported = false
    var onAnalysis: ((UIImage?, [Double]) -> Void)?
    var onLensWarning: ((Int, Bool) -> Void)?
    private var lensWarningsEnabled = true
    private var lensWarningsSuspended = false
    private let lensMonitor = LensObstructionMonitor()

    func setLensWarningsEnabled(_ enabled: Bool) {
        queue.async {
            self.lensWarningsEnabled = enabled
            if !enabled { self.lensMonitor.pause() }
        }
    }

    private func updateLensMonitor() {
        guard processor == nil, !dual.busy, !burstRunning, movieProcessor == nil else {
            lensMonitor.pause(); return
        }
        guard wantsRunning, activeSession.isRunning, !activeSession.isInterrupted,
              lensWarningsEnabled, !lensWarningsSuspended, !snapshot.cooling,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              snapshot.analysisMode == "Off", !snapshot.eyeFocusEnabled else {
            lensMonitor.stop(); return
        }
        // Never reconfigure outputs while a capture or recording is in progress.
        let sources = snapshot.dualEnabled ? dual.inputs : [input].compactMap { $0 }
        guard !sources.contains(where: { [.serious, .critical, .shutdown].contains($0.device.systemPressureState.level) }) else {
            lensMonitor.stop(); return
        }
        lensMonitor.update(session: activeSession, inputs: sources) { [weak self] index, warning in
            self?.onLensWarning?(index, warning)
        }
    }
    private let analysisOutput = AVCaptureVideoDataOutput()
    private var analyzer: ViewfinderAnalyzer?
    private let eyeOutput = AVCaptureVideoDataOutput()
    private var eyeTracker: EyeFocusTracker?
    private var eyeGeneration = UUID()
    private var focusRequests: [String: UUID] = [:]
    private var lastEyePoint: CGPoint?
    private var eyeStatus = "Eye AF · searching"

    init() {
        CameraDiagnostics.shared.record(.launch)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                             object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                CameraDiagnostics.shared.record(.memoryWarning)
                self.pendingMemoryCleanup = true
                self.lensWarningsSuspended = true
                self.lensMonitor.pause()
                // Stop optional frame work without reconfiguring an in-flight capture.
                self.analysisOutput.setSampleBufferDelegate(nil, queue: nil)
                self.eyeOutput.setSampleBufferDelegate(nil, queue: nil)
                self.analyzer?.releaseBuffers()
                self.onAnalysis?(nil, [])
                if self.snapshot.dualEnabled && self.dual.busy {
                    self.pendingMemoryFallback = true
                    self.dual.cancelRemainingCapture()
                }
                self.finishMemoryCleanupIfIdle()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                             object: nil, queue: nil) { [weak self] notification in
            self?.queue.async { [weak self] in
                guard let self, notification.object as? AVCaptureSession === self.activeSession else { return }
                CameraDiagnostics.shared.record(.interrupted)
                self.publish(message: "Camera interrupted. It will resume when available.")
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                             object: nil, queue: nil) { [weak self] notification in
            self?.queue.async { [weak self] in
                guard let self, notification.object as? AVCaptureSession === self.activeSession else { return }
                CameraDiagnostics.shared.record(.interruptionEnded)
                self.requestRecovery()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                             object: nil, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.queue.async { [weak self] in
                guard let self = self else { return }
                guard notification.object as? AVCaptureSession === self.activeSession else { return }
                CameraDiagnostics.shared.record(.runtimeError, value: error.map { ($0 as NSError).code })
                if error?.code == .mediaServicesWereReset { self.requestRecovery() }
                self.publish(message: self.activeSession.isRunning ? nil : "Camera stopped. Tap Retry camera.")
            }
        })
    }

    private func finishMemoryCleanupIfIdle() {
        guard pendingMemoryCleanup, !burstRunning, processor == nil, movieProcessor == nil, !dual.busy else { return }
        pendingMemoryCleanup = false
        disableAnalysis()
        disableEyeFocus()
        if snapshot.dualEnabled {
            setDualEnabled(false, reason: "Memory is low · returned to Single Photo.")
        }
    }

    deinit {
        meterTimer?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        queue.async {
            if !self.wantsRunning { self.previewHealth = PreviewHealth(); self.previewFailureReported = false }
            if !self.wantsRunning { CameraDiagnostics.shared.record(.sessionStart) }
            self.wantsRunning = true
            self.lensWarningsSuspended = false
            do {
                if self.input == nil { try self.configure() }
                else if !self.snapshot.dualEnabled { try self.restoreSingleCamera() }
                self.finishMemoryCleanupIfIdle()
                self.connectPreview()
                if let analyzer = self.analyzer { self.analysisOutput.setSampleBufferDelegate(analyzer, queue: analyzer.queue) }
                if let tracker = self.eyeTracker { self.eyeOutput.setSampleBufferDelegate(tracker, queue: tracker.queue) }
                if !self.activeSession.isRunning { self.activeSession.startRunning() }
                self.startMetering()
                self.publish(message: self.activeSession.isRunning ? nil : "Camera unavailable. Tap Retry camera.")
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    func stop() {
        queue.async {
            CameraDiagnostics.shared.record(.sessionStop)
            self.wantsRunning = false
            self.lensMonitor.pause()
            self.recoveryPending = false
            self.analysisOutput.setSampleBufferDelegate(nil, queue: nil)
            self.eyeOutput.setSampleBufferDelegate(nil, queue: nil)
            self.analyzer?.releaseBuffers()
            self.onAnalysis?(nil, [])
            self.dual.cancelRemainingCapture()
            self.meterTimer?.cancel()
            self.meterTimer = nil
            if self.movieProcessor != nil { self.stopMovieWhenStarted = true }
            if self.movie.isRecording { self.movie.stopRecording() }
            if self.activeSession.isRunning { self.activeSession.stopRunning() }
            self.publish()
        }
    }

    // Session queue only. Never restart through a capture, recording or interruption.
    private func requestRecovery() {
        guard wantsRunning else { return }
        if !recoveryPending { recoveryAttempts = 0; lastRecoveryAttempt = nil }
        recoveryPending = true
        recoverIfIdle()
    }

    private func recoverIfIdle() {
        guard recoveryPending else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard CameraRecoveryPolicy.mayAttempt(active: wantsRunning, interrupted: activeSession.isInterrupted,
            busy: burstRunning || processor != nil || movieProcessor != nil || dual.busy,
            attempts: recoveryAttempts, lastAttempt: lastRecoveryAttempt, now: now) else { return }
        if activeSession.isRunning { recoveryPending = false; publish(); return }
        recoveryAttempts += 1; lastRecoveryAttempt = now
        CameraDiagnostics.shared.record(.recoveryAttempt, value: recoveryAttempts)
        activeSession.startRunning()
        if activeSession.isRunning {
            recoveryPending = false
            CameraDiagnostics.shared.record(.recoverySucceeded)
        }
        publish(message: activeSession.isRunning ? nil : "Camera stopped. Tap Retry camera.")
    }

    private var diagnosticConfiguration: CameraDiagnosticConfiguration {
        let size = output.maxPhotoDimensions
        let video = snapshot.videoQuality
        return CameraDiagnosticConfiguration(mode: snapshot.videoMode ? .video : snapshot.dualEnabled ? (snapshot.dualMode == .detail ? .dualDetail : .dualFast) : .photo,
            width: snapshot.videoMode ? video?.width ?? 0 : snapshot.dualEnabled ? dual.outputs.first?.maxPhotoDimensions.width ?? 0 : size.width,
            height: snapshot.videoMode ? (video?.width ?? 0) * 9 / 16 : snapshot.dualEnabled ? dual.outputs.first?.maxPhotoDimensions.height ?? 0 : size.height,
            fps: snapshot.videoMode ? video?.fps ?? 0 : 0)
    }

    func restartPreview() {
        queue.async {
            guard self.wantsRunning, !self.activeSession.isInterrupted, !self.burstRunning,
                  self.processor == nil, self.movieProcessor == nil, !self.dual.busy else { return }
            guard self.input != nil else { self.start(); return }
            self.previewHealth = PreviewHealth(); self.previewFailureReported = false
            self.restartIdlePreview()
        }
    }

    private func restartIdlePreview() {
        recoveryPending = false
        CameraDiagnostics.shared.record(.previewRestart, configuration: diagnosticConfiguration)
        activeSession.stopRunning()
        disconnectPreviews(); connectPreview()
        activeSession.startRunning()
        startMetering()
        publish(message: activeSession.isRunning ? nil : "Camera stopped. Tap Retry camera.")
    }

    private func checkPreviewHealth() {
        let layers = [preview, snapshot.dualEnabled ? secondaryPreview : nil].compactMap { $0 }
        let expected = snapshot.dualEnabled ? 2 : 1
        let eligible = wantsRunning && activeSession.isRunning && !activeSession.isInterrupted &&
            !burstRunning && processor == nil && movieProcessor == nil && !dual.busy && layers.count == expected
        if previewHealth.shouldRestart(previewing: layers.allSatisfy(\.isPreviewing), eligible: eligible,
                                       now: ProcessInfo.processInfo.systemUptime) {
            CameraDiagnostics.shared.record(.previewStalled, configuration: diagnosticConfiguration)
            restartIdlePreview()
        } else if eligible, previewHealth.attempts >= 2, previewHealth.missedChecks >= 5, !previewFailureReported {
            previewFailureReported = true
            publish(message: "Preview unavailable. Tap Retry camera.")
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

    func select(_ id: String, zoom: Double = 1) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, self.movieProcessor == nil, !self.snapshot.videoMode, !self.dual.busy, !self.snapshot.dualEnabled, let oldInput = self.input,
                  let device = self.devices.first(where: { $0.uniqueID == id }) else { return }
            if oldInput.device.uniqueID == device.uniqueID {
                do { try self.applyZoom(zoom, to: device); self.publish() }
                catch { self.publish(message: error.localizedDescription) }
                return
            }
            self.disableAnalysis()
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
                    try self.applyZoom(zoom, to: device)
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

    private func applyZoom(_ factor: Double, to device: AVCaptureDevice) throws {
        guard factor.isFinite else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        guard let value = ZoomLimits.clamp(factor, minimum: Double(device.minAvailableVideoZoomFactor), maximum: Double(device.maxAvailableVideoZoomFactor)) else { return }
        if abs(Double(device.videoZoomFactor) - value) > 0.0001 { device.videoZoomFactor = CGFloat(value) }
    }

    func setZoom(_ displayed: Double, deviceID: String, dualIndex: Int? = nil) {
        queue.async {
            guard displayed.isFinite, !self.burstRunning, self.processor == nil,
                  self.movieProcessor == nil, !self.dual.busy else { return }
            let device: AVCaptureDevice
            if self.snapshot.dualEnabled {
                guard let index = dualIndex, self.dual.inputs.indices.contains(index) else { return }
                device = self.dual.inputs[index].device
            } else {
                guard dualIndex == nil, let current = self.input?.device else { return }
                device = current
            }
            guard device.uniqueID == deviceID else { return }
            let base = self.snapshot.lenses.first(where: { $0.id == device.uniqueID })?.zoomFactor ?? 1
            guard let target = ZoomLimits.clamp(displayed / base, minimum: Double(device.minAvailableVideoZoomFactor), maximum: Double(device.maxAvailableVideoZoomFactor)),
                  abs(Double(device.videoZoomFactor) - target) > 0.0001 else { return }
            do {
                try self.applyZoom(target, to: device)
                self.publish()
            } catch { self.onWarning?(error.localizedDescription) }
        }
    }

    private func configureDimensions(_ device: AVCaptureDevice) {
        output.isDepthDataDeliveryEnabled = output.isDepthDataDeliverySupported
        snapshot.depthAvailable = output.isDepthDataDeliverySupported
        if !snapshot.depthAvailable { snapshot.depthEnabled = false }
        // Single photos use the largest native size exposed by this format.
        let sizes = device.activeFormat.supportedMaxPhotoDimensions.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        if let size = sizes.last {
            output.maxPhotoDimensions = size
            snapshot.resolution = "Up to \(size.width) × \(size.height)"
        }
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported { connection.videoOrientation = interfaceOrientation }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }

    func capture(speed: Bool = false, night: Bool = false, panorama: Bool = false, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        queue.async {
            self.lensMonitor.pause()
            let orientation = self.burstRunning ? self.sequenceOrientation : self.interfaceOrientation
            if self.snapshot.dualEnabled {
                self.dual.setOrientation(orientation)
                self.dual.onProgress = self.onCaptureProgress
                self.dual.capture(night: night, panorama: panorama) { [weak self] result in
                    if let self, self.pendingMemoryFallback {
                        self.pendingMemoryFallback = false
                        self.setDualEnabled(false, reason: "Memory is low · returned to Single Photo. Your capture can still be saved.")
                    }
                    completion(result)
                }
                return
            }
            guard self.session.isRunning, !self.session.isInterrupted, !self.snapshot.videoMode, self.processor == nil else {
                completion(.failure(CameraFailure.unavailable))
                return
            }
            if let connection = self.output.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
            let codec: AVVideoCodecType = self.output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            if night || panorama || speed {
                guard let device = self.input?.device,
                      let size = NightCapturePolicy.photoSize(device.activeFormat.supportedMaxPhotoDimensions,
                                                             maximum: self.output.maxPhotoDimensions) else {
                    completion(.failure(CameraFailure.unavailable)); return
                }
                settings.maxPhotoDimensions = size
            } else { settings.maxPhotoDimensions = self.output.maxPhotoDimensions }
            settings.photoQualityPrioritization = panorama ? .speed : night ? .quality : speed || self.input?.device.exposureMode == .custom ? .speed : .quality
            settings.isDepthDataDeliveryEnabled = !night && !panorama && self.snapshot.depthEnabled && self.output.isDepthDataDeliveryEnabled
            settings.embedsDepthDataInPhoto = settings.isDepthDataDeliveryEnabled
            if !night && !panorama && self.input?.device.isFlashAvailable == true && self.output.supportedFlashModes.contains(self.controls.flash) { settings.flashMode = self.controls.flash }
            let lensLabel = self.snapshot.lenses.first(where: { $0.id == self.snapshot.selectedID })?.name ?? "Camera"
            let processor = PhotoCaptureProcessor(expectsDepth: settings.isDepthDataDeliveryEnabled) { [weak self] result in
                guard let self = self else { return }
                self.queue.async {
                    self.processor = nil
                    self.finishMemoryCleanupIfIdle()
                    completion(result.map { original in
                        var photo = original
                        photo.lensLabel = lensLabel
                        return photo
                    })
                }
            }
            self.processor = processor
            self.output.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func publish(message: String? = nil) {
        updateMeter()
        let zoomDevices = snapshot.dualEnabled ? dual.inputs.map(\.device) : [input?.device].compactMap { $0 }
        snapshot.zooms = zoomDevices.map { device in
            let base = snapshot.lenses.first(where: { $0.id == device.uniqueID })?.zoomFactor ?? 1
            return CameraZoom(deviceID: device.uniqueID, value: Double(device.videoZoomFactor) * base,
                              minimum: Double(device.minAvailableVideoZoomFactor) * base,
                              maximum: Double(device.maxAvailableVideoZoomFactor) * base)
        }
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

    func setAnalysis(_ mode: String) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, self.movieProcessor == nil else { return }
            self.disableAnalysis()
            guard mode != "Off", ["Peaking", "Highlights", "Histogram"].contains(mode),
                  !self.snapshot.dualEnabled, !self.snapshot.videoMode else { self.publish(); return }
            self.disableEyeFocus()
            self.session.beginConfiguration()
            guard self.session.canAddOutput(self.analysisOutput) else {
                self.session.commitConfiguration()
                self.publish(message: "This viewfinder guide is unavailable with the current camera.")
                return
            }
            self.analysisOutput.alwaysDiscardsLateVideoFrames = true
            self.analysisOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.session.addOutput(self.analysisOutput)
            if let connection = self.analysisOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported { connection.videoOrientation = self.interfaceOrientation }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
                }
            }
            let analyzer = ViewfinderAnalyzer(mode: mode) { [weak self] image, bins in
                self?.queue.async { [weak self] in
                    guard let self, self.wantsRunning, self.session.isRunning, self.snapshot.analysisMode == mode else { return }
                    self.onAnalysis?(image, bins)
                }
            }
            self.analyzer = analyzer
            self.analysisOutput.setSampleBufferDelegate(analyzer, queue: analyzer.queue)
            self.session.commitConfiguration()
            self.snapshot.analysisMode = mode
            self.publish()
        }
    }

    private func disableAnalysis() {
        analysisOutput.setSampleBufferDelegate(nil, queue: nil)
        if session.outputs.contains(analysisOutput) {
            session.beginConfiguration(); session.removeOutput(analysisOutput); session.commitConfiguration()
        }
        analyzer = nil; snapshot.analysisMode = "Off"; onAnalysis?(nil, [])
    }

    func setEyeFocus(_ enabled: Bool) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, self.movieProcessor == nil else { return }
            self.disableAnalysis()
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
            tracker.setOrientation(self.interfaceOrientation)
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
        guard eyeTracker != nil || snapshot.eyeFocusEnabled || session.outputs.contains(eyeOutput) else { return }
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
        lensMonitor.stop()
        for layer in [preview, secondaryPreview].compactMap({ $0 }) {
            if let connection = layer.connection { layer.session?.removeConnection(connection) }
            layer.session = nil
        }
    }

    private func connectPreview() {
        previewHealth.resetObservation()
        let sources: [(AVCaptureVideoPreviewLayer?, AVCaptureDeviceInput?)] = [
            (preview, snapshot.dualEnabled ? dual.inputs.first : input),
            (secondaryPreview, snapshot.dualEnabled && dual.inputs.count > 1 ? dual.inputs[1] : nil)
        ]
        for (layer, source) in sources {
            guard let layer else { continue }
            let port = source?.ports.first(where: { $0.mediaType == .video })
            if let port, layer.session === activeSession,
               let connection = layer.connection, connection.inputPorts.contains(where: { $0 === port }) {
                continue
            }
            if let connection = layer.connection { layer.session?.removeConnection(connection) }
            layer.session = nil
            guard let port else { continue }
            layer.setSessionWithNoConnection(activeSession)
            let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            guard activeSession.canAddConnection(connection) else { continue }
            activeSession.addConnection(connection)
            if connection.isVideoOrientationSupported { connection.videoOrientation = interfaceOrientation }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }

    func setInterfaceOrientation(_ orientation: AVCaptureVideoOrientation, completion: @escaping () -> Void) {
        queue.async {
            defer { DispatchQueue.main.async(execute: completion) }
            guard self.interfaceOrientation != orientation else { return }
            self.interfaceOrientation = orientation
            for layer in [self.preview, self.secondaryPreview].compactMap({ $0 }) {
                if let connection = layer.connection, connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
            }
            if let connection = self.analysisOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
                self.onAnalysis?(nil, [])
            }
            self.eyeTracker?.setOrientation(orientation)
            // Capture outputs change only at the start of a shot/sequence/recording.
        }
    }

    // Stop and detach the single-camera graph before changing shared sensor formats.
    private func suspendSingleCamera() {
        session.beginConfiguration()
        if session.outputs.contains(output) { session.removeOutput(output) }
        if let input, session.inputs.contains(input) { session.removeInput(input) }
        session.commitConfiguration()
    }

    private func restoreSingleCamera() throws {
        guard let input else { throw CameraFailure.input }
        if session.inputs.contains(input), session.outputs.contains(output) { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        if !session.inputs.contains(input) {
            guard session.canAddInput(input) else { throw CameraFailure.input }
            session.addInput(input)
        }
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw CameraFailure.output }
            session.addOutput(output)
        }
        configureDimensions(input.device)
    }

    func setDualEnabled(_ enabled: Bool, reason: String? = nil, mode: DualShotMode? = nil,
                        resumeSingleCamera: Bool = true) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, self.movieProcessor == nil, !self.snapshot.videoMode, !self.dual.busy, enabled != self.snapshot.dualEnabled || (enabled && mode != nil && mode != self.snapshot.dualMode) else { return }
            self.recoveryPending = false
            let transitionStarted = ProcessInfo.processInfo.systemUptime
            CameraDiagnostics.shared.record(enabled ? .dualMode : .photoMode)
            defer { CameraDiagnostics.shared.record(.transitionFinished, value: Int((ProcessInfo.processInfo.systemUptime - transitionStarted) * 1000), configuration: self.diagnosticConfiguration) }
            self.disableAnalysis()
            self.disableEyeFocus()
            self.activeSession.stopRunning()
            self.disconnectPreviews()
            do {
                if enabled {
                    self.suspendSingleCamera()
                    self.dual.reset()
                    let selectedMode = mode ?? self.snapshot.dualMode
                    try self.dual.configure(mode: selectedMode)
                    self.snapshot.dualMode = selectedMode
                    self.snapshot.dualEnabled = true
                    self.snapshot.selectedID = self.dual.inputs.first?.device.uniqueID
                    self.snapshot.resolution = self.dual.resolution
                } else {
                    self.dual.reset()
                    self.snapshot.dualEnabled = false
                    self.snapshot.dualMode = .fast
                    self.snapshot.selectedID = self.input?.device.uniqueID
                    try self.restoreSingleCamera()
                }
                self.connectPreview()
                if enabled && self.dual.session.hardwareCost > 1 { throw DualPhotoCamera.Failure.overloaded }
                if enabled {
                    // Paired capture uses automatic metering independently for each sensor.
                    for input in self.dual.inputs { try self.applyControls(to: input.device, automatic: true) }
                } else if let device = self.input?.device { try self.applyControls(to: device) }
                // A transition to video will start the single session after configuring it.
                if self.wantsRunning && (enabled || resumeSingleCamera) { self.activeSession.startRunning() }
                self.snapshot.focusLocked = !enabled && !self.controls.automaticFocus
                self.publish()
                if let reason { self.onWarning?(reason) }
            } catch {
                self.disconnectPreviews()
                self.dual.reset()
                self.snapshot.dualEnabled = false
                self.snapshot.dualMode = .fast
                self.snapshot.selectedID = self.input?.device.uniqueID
                do {
                    try self.restoreSingleCamera()
                    self.connectPreview()
                    if self.wantsRunning { self.session.startRunning() }
                    self.publish(message: error.localizedDescription)
                } catch {
                    self.publish(message: "Camera could not restart. Tap Retry camera.")
                }
            }
        }
    }

    func focus(at point: CGPoint, locked: Bool, dualIndex: Int? = nil, exposureOnly: Bool = false) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, !self.dual.busy else { return }
            if !exposureOnly {
                if self.snapshot.eyeFocusEnabled { self.disableEyeFocus() }
                self.controls.automaticFocus = true; self.controls.facePriority = false
            } else { self.controls.automaticExposure = true }
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
                    if exposureOnly {
                        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
                        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                    } else {
                        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
                        let focus: AVCaptureDevice.FocusMode = locked ? .autoFocus : .continuousAutoFocus
                        if device.isFocusModeSupported(focus) { device.focusMode = focus }
                    }
                    device.unlockForConfiguration()
                    if !exposureOnly {
                        let request = UUID()
                        self.focusRequests[device.uniqueID] = request
                        if locked { self.finishFocusLock(device, request: request, attempts: 0) }
                    }
                }
                self.publish()
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    private func finishFocusLock(_ device: AVCaptureDevice, request: UUID, attempts: Int) {
        queue.asyncAfter(deadline: .now() + 0.15) {
            guard self.focusRequests[device.uniqueID] == request, self.wantsRunning,
                  (self.snapshot.dualEnabled ? self.dual.inputs.map(\.device) : [self.input?.device].compactMap { $0 }).contains(device) else { return }
            if attempts < 3 || device.isAdjustingFocus {
                if attempts < 25 { self.finishFocusLock(device, request: request, attempts: attempts + 1) }
                else { self.publish(message: "Focus did not settle. Tap again or use manual focus.") }
                return
            }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                device.unlockForConfiguration()
                self.publish()
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    func setExposureBias(_ value: Float, dualIndex: Int? = nil) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, !self.dual.busy else { return }
            var devices = self.snapshot.dualEnabled ? self.dual.inputs.map(\.device) : [self.input?.device].compactMap { $0 }
            if let index = dualIndex {
                guard self.snapshot.dualEnabled, devices.indices.contains(index) else { return }
                devices = [devices[index]]
            }
            do {
                for device in devices {
                    try device.lockForConfiguration()
                    device.setExposureTargetBias(min(device.maxExposureTargetBias, max(device.minExposureTargetBias, value)))
                    device.unlockForConfiguration()
                }
            } catch { self.publish(message: error.localizedDescription) }
        }
    }

    private func videoQualities(for device: AVCaptureDevice) -> [VideoQuality] {
        VideoQuality.ranked(device.formats.flatMap { format -> [VideoQuality] in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard [Int32(3840), 1920, 1280].contains(size.width), size.width * 9 == size.height * 16,
                  CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return [] }
            return [Int32(240), 120, 60, 30, 24].compactMap { rate in
                format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(rate) && $0.maxFrameRate >= Double(rate) }
                    ? VideoQuality(width: size.width, fps: rate) : nil
            }
        })
    }

    func setVideoMode(_ enabled: Bool, width: Int32 = 0, fps: Int32 = 0, stabilized: Bool = true,
                      completion: ((CameraSnapshot) -> Void)? = nil) {
        queue.async {
            defer { completion?(self.snapshot) }
            guard !self.burstRunning, self.processor == nil, self.movieProcessor == nil, !self.dual.busy, !self.snapshot.dualEnabled,
                  let device = self.input?.device else { self.publish(); return }
            self.recoveryPending = false
            let transitionStarted = ProcessInfo.processInfo.systemUptime
            CameraDiagnostics.shared.record(enabled ? .videoMode : .photoMode)
            defer { CameraDiagnostics.shared.record(.transitionFinished, value: Int((ProcessInfo.processInfo.systemUptime - transitionStarted) * 1000), configuration: self.diagnosticConfiguration) }
            // Reapplying a format (including a stabilization-only edit) does not
            // require stopping the preview or rebuilding camera outputs.
            if enabled && self.snapshot.videoMode,
               let quality = self.snapshot.videoQuality,
               quality.width == width && quality.fps == fps,
               let connection = self.movie.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = stabilized ? .auto : .off
                    self.snapshot.stabilized = stabilized
                } else { self.snapshot.stabilized = false }
                self.publish()
                return
            }
            if !enabled && !self.snapshot.videoMode {
                if self.wantsRunning && !self.session.isRunning { self.session.startRunning() }
                self.publish()
                return
            }
            self.disableAnalysis()
            self.disableEyeFocus()
            self.session.stopRunning()
            self.lensMonitor.stop()
            self.session.beginConfiguration()
            var failure: Error?
            do {
                if enabled {
                    let qualities = self.videoQualities(for: device)
                    guard let quality = VideoQuality.resolve(width: width, fps: fps, from: qualities) else { throw VideoFailure.unsupported }
                    let width = quality.width, fps = quality.fps
                    let height = width * 9 / 16
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
                    if self.audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                       let microphone = AVCaptureDevice.default(for: .audio),
                       let audio = try? AVCaptureDeviceInput(device: microphone), self.session.canAddInput(audio) {
                        self.session.addInput(audio)
                        self.audioInput = audio
                    }
                    self.snapshot.videoQualities = qualities
                    self.snapshot.videoQuality = quality
                    self.snapshot.videoLabel = quality.label
                    self.snapshot.stabilized = false
                    if let connection = self.movie.connection(with: .video) {
                        if connection.isVideoOrientationSupported { connection.videoOrientation = self.interfaceOrientation }
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
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized, let audio = self.audioInput {
                self.session.beginConfiguration(); self.session.removeInput(audio); self.session.commitConfiguration()
                self.audioInput = nil
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
            if let connection = self.movie.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = self.interfaceOrientation
            }
            self.stopMovieWhenStarted = false
            let processor = MovieCaptureProcessor(started: { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.snapshot.audioRecording = self.movie.connection(with: .audio)?.isEnabled == true && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
            self.lensMonitor.pause()
            self.movie.startRecording(to: url, recordingDelegate: processor)
        }
    }

    func stopRecording() {
        queue.async {
            self.stopMovieWhenStarted = true
            if self.movie.isRecording { self.movie.stopRecording() }
        }
    }

    func setControls(_ value: CameraControls, changedOnly: Bool = false, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, !self.dual.busy, !self.snapshot.dualEnabled,
                  let device = self.input?.device else { completion?(false); return }
            let previous = self.controls
            do {
                let changes = CameraControlChanges(from: previous, to: value)
                self.controls = value
                try self.applyControls(to: device, changes: changedOnly ? changes : nil)
                if !value.automaticFocus && (!changedOnly || changes.focus) { self.disableEyeFocus() }
                self.publish()
                completion?(true)
            } catch {
                self.controls = previous
                self.publish(message: error.localizedDescription)
                completion?(false)
            }
        }
    }

    private func applyControls(to device: AVCaptureDevice, automatic: Bool = false, changes: CameraControlChanges? = nil) throws {
        let updateFocus = automatic || changes?.focus != false
        let updateExposure = automatic || changes?.exposure != false
        let updateWhiteBalance = automatic || changes?.whiteBalance != false
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if updateFocus { focusRequests[device.uniqueID] = nil }
        if automatic {
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
        }
        if updateFocus && device.isFocusModeSupported(.continuousAutoFocus) {
            device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
            device.isFaceDrivenAutoFocusEnabled = controls.facePriority && !snapshot.eyeFocusEnabled
            if controls.automaticFocus || automatic || !device.isLockingFocusWithCustomLensPositionSupported {
                device.focusMode = .continuousAutoFocus
            } else if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: min(1, max(0, controls.lensPosition)), completionHandler: nil)
            }
        }
        if updateExposure {
            if controls.automaticExposure || automatic || !device.isExposureModeSupported(.custom) {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            } else if device.isExposureModeSupported(.custom) {
                var maximum = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
                if snapshot.videoMode { maximum = min(maximum, CMTimeGetSeconds(device.activeVideoMaxFrameDuration)) }
                let seconds = max(CMTimeGetSeconds(device.activeFormat.minExposureDuration), min(maximum, controls.shutterSeconds))
                device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                                             iso: min(device.activeFormat.maxISO, max(device.activeFormat.minISO, controls.iso)), completionHandler: nil)
            }
        }
        if updateWhiteBalance {
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
        }
        if updateFocus {
            snapshot.focusLocked = !controls.automaticFocus && !automatic && device.isLockingFocusWithCustomLensPositionSupported
        }
    }

    private func startMetering() {
        guard meterTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.recoverIfIdle()
            guard self.activeSession.isRunning else { return }
            self.checkPreviewHealth()
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastDiagnosticSample >= 15 {
                self.lastDiagnosticSample = now
                CameraDiagnostics.shared.record(.sample, configuration: self.diagnosticConfiguration)
            }
            self.finishMemoryCleanupIfIdle()
            self.updateMeter()
            self.updateLensMonitor()
            if self.snapshot.cooling && (self.snapshot.analysisMode != "Off" || self.snapshot.eyeFocusEnabled) {
                self.disableAnalysis()
                self.disableEyeFocus()
                self.publish()
                self.onWarning?("Camera is warm · optional guides and eye tracking paused.")
            }
            if self.snapshot.dualEnabled, !self.dual.busy,
               self.snapshot.cooling || self.dual.inputs.contains(where: { [.serious, .critical, .shutdown].contains($0.device.systemPressureState.level) }) {
                self.setDualEnabled(false, reason: "Dual Shot paused to cool the camera. Single-camera Photo is ready.")
            }
            self.onMeter?(self.snapshot)
        }
        meterTimer = timer
        timer.resume()
    }

    private func updateMeter() {
        let thermal = ProcessInfo.processInfo.thermalState
        snapshot.cooling = thermal == .serious || thermal == .critical
        let activeDevices = snapshot.dualEnabled ? dual.inputs.map(\.device) : [input?.device].compactMap { $0 }
        snapshot.focusStates = activeDevices.map { $0.isAdjustingFocus ? "Focusing…" : $0.focusMode == .locked ? "Focus locked" : "Auto focus" }
        snapshot.focusLocked = activeDevices.contains { $0.focusMode == .locked }
        guard let device = snapshot.dualEnabled ? dual.inputs.first?.device : input?.device else { return }
        let seconds = CMTimeGetSeconds(device.exposureDuration)
        let shutter = seconds > 0 && seconds < 1 ? "1/\(Int((1 / seconds).rounded()))" : String(format: "%.1f s", seconds)
        snapshot.exposureLabel = "\(shutter) · ISO \(Int(device.iso.rounded()))"
        snapshot.currentISO = device.iso
        snapshot.currentShutter = seconds
        snapshot.minimumShutter = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        snapshot.maximumShutter = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        if snapshot.videoMode {
            snapshot.maximumShutter = min(snapshot.maximumShutter, CMTimeGetSeconds(device.activeVideoMaxFrameDuration))
        }
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

    func beginPanorama(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, !self.dual.busy,
                  !self.snapshot.videoMode, self.snapshot.running, self.wantsRunning else { completion(false); return }
            self.sequenceOrientation = self.interfaceOrientation
            self.burstRunning = true
            completion(true)
        }
    }

    func beginLongExposure(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, !self.snapshot.dualEnabled,
                  !self.snapshot.videoMode, self.session.isRunning, self.wantsRunning else { completion(false); return }
            self.burstRunning = true
            self.sequenceOrientation = self.interfaceOrientation
            completion(true)
        }
    }
    func endLongExposure() { queue.async { self.burstRunning = false } }

    func captureNight(cancellation: NightWorkCancellation, completion: @escaping (Result<[CapturedPhoto], Error>) -> Void) {
        queue.async {
            guard !self.burstRunning, self.processor == nil, !self.dual.busy,
                  !self.snapshot.videoMode, self.wantsRunning else {
                completion(.failure(CameraFailure.unavailable)); return
            }
            self.sequenceOrientation = self.interfaceOrientation
            self.burstRunning = true
            let paired = self.snapshot.dualEnabled
            self.nightFrame(photos: [], remaining: paired ? 3 : 4, paired: paired, cancellation: cancellation) { result in
                self.burstRunning = false
                completion(result)
            }
        }
    }

    private func nightFrame(photos: [CapturedPhoto], remaining: Int, paired: Bool, cancellation: NightWorkCancellation,
                            focusWindow: FocusSettlingWindow? = nil,
                            completion: @escaping (Result<[CapturedPhoto], Error>) -> Void) {
        let bytes = photos.reduce(0) { $0 + $1.data.count }
        guard !cancellation.cancelled, wantsRunning, activeSession.isRunning, !activeSession.isInterrupted,
              snapshot.dualEnabled == paired, bytes < NightCapturePolicy.byteLimit,
              ![.serious, .critical].contains(ProcessInfo.processInfo.thermalState) else {
            completion(photos.isEmpty ? .failure(CameraFailure.unavailable) : .success(photos)); return
        }
        if !paired, let device = input?.device {
            guard ![.serious, .critical, .shutdown].contains(device.systemPressureState.level) else {
                completion(photos.isEmpty ? .failure(CameraFailure.unavailable) : .success(photos)); return
            }
            let now = ProcessInfo.processInfo.systemUptime
            var window = focusWindow ?? FocusSettlingWindow(startedAt: now)
            switch window.update(adjusting: device.isAdjustingFocus || device.isAdjustingExposure, now: now) {
            case .wait:
                queue.asyncAfter(deadline: .now() + 0.05) { [weak self, window] in
                    self?.nightFrame(photos: photos, remaining: remaining, paired: paired, cancellation: cancellation,
                                     focusWindow: window, completion: completion)
                }
                return
            case .timedOut:
                completion(photos.isEmpty ? .failure(CameraFailure.unavailable) : .success(photos)); return
            case .ready: break
            }
        }
        onCaptureProgress?("Night · hold still · capture \((paired ? 3 : 4) - remaining + 1) of \(paired ? 3 : 4)")
        capture(night: true) { result in
            switch result {
            case .success(var photo):
                let companions = photo.companions
                photo.companions = []
                let collected = photos + [photo] + companions
                let partialPair = paired && companions.count != 1
                if remaining > 1 && !partialPair {
                    self.nightFrame(photos: collected, remaining: remaining - 1, paired: paired, cancellation: cancellation, completion: completion)
                } else { completion(.success(collected)) }
            case .failure(let error):
                completion(photos.isEmpty ? .failure(error) : .success(photos))
            }
        }
    }

    func captureBurst(completion: @escaping (Result<[CapturedPhoto], Error>) -> Void) {
        queue.async {
            guard !self.burstRunning, !self.snapshot.dualEnabled, !self.snapshot.videoMode,
                  self.processor == nil, self.session.isRunning else { completion(.failure(CameraFailure.unavailable)); return }
            self.sequenceOrientation = self.interfaceOrientation
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
    private var orientation: AVCaptureVideoOrientation = .portrait
    func setOrientation(_ value: AVCaptureVideoOrientation) {
        queue.async { self.orientation = value; self.misses = 0 }
    }
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
                try VNImageRequestHandler(ciImage: image, orientation: CameraOrientation.vision(orientation), options: [:]).perform([request])
                guard let face = request.results?.filter({ $0.confidence >= 0.6 }).max(by: {
                    $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
                }), let eye = face.landmarks?.leftEye ?? face.landmarks?.rightEye,
                      !eye.normalizedPoints.isEmpty else { missed(); return }
                let points = eye.normalizedPoints
                let x = points.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(points.count)
                let y = points.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(points.count)
                let uprightX = face.boundingBox.minX + x * face.boundingBox.width
                let uprightY = face.boundingBox.minY + y * face.boundingBox.height
                let point = CameraOrientation.sensorPoint(x: uprightX, y: uprightY, orientation: orientation)
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
        case unsupported, overloaded, focusUnsettled
        var errorDescription: String? {
            switch self {
            case .focusUnsettled: return "Focus is still adjusting. Tap your subject, move back if close, then try again."
            case .unsupported: return "Main + Ultra Wide capture is unavailable on this camera configuration. Single photo is ready."
            case .overloaded: return "Dual Shot needs more camera resources than are currently available. Use Single Photo or let the iPhone cool before retrying."
            }
        }
    }
    let session = AVCaptureMultiCamSession()
    private let queue: DispatchQueue
    private(set) var inputs: [AVCaptureDeviceInput] = []
    private(set) var outputs: [AVCapturePhotoOutput] = []
    private var originals: [(AVCaptureDevice, AVCaptureDevice.Format, CMTime, CMTime, CGFloat)] = []
    private var processors: [Int: PhotoCaptureProcessor] = [:]
    private var results: [Int: Result<CapturedPhoto, Error>] = [:]
    private(set) var busy = false
    private var mode: DualShotMode = .fast
    private var nightCapture = false
    private var panoramaCapture = false
    private var captureMode: DualShotMode { panoramaCapture ? .fast : nightCapture ? .detail : mode }
    var onProgress: ((String) -> Void)?
    private var cancelRemaining = false
    private(set) var resolution = "—"

    init(queue: DispatchQueue) { self.queue = queue }

    func setOrientation(_ orientation: AVCaptureVideoOrientation) {
        guard !busy else { return }
        for output in outputs {
            if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }
    }

    private static var pair: [AVCaptureDevice]? {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { return nil }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera], mediaType: .video, position: .back)
        guard let main = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }),
              let ultra = discovery.devices.first(where: { $0.deviceType == .builtInUltraWideCamera }),
              discovery.supportedMultiCamDeviceSets.contains(where: { $0.contains(main) && $0.contains(ultra) }) else { return nil }
        return [main, ultra]
    }
    static var isSupported: Bool { pair != nil }

    func configure(mode: DualShotMode) throws {
        self.mode = mode
        guard inputs.isEmpty else { return }
        guard let pair = Self.pair else { throw Failure.unsupported }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        var labels: [String] = []
        for device in pair {
            // Keep the sensor's preview workload modest while preserving native still dimensions.
            let formats = device.formats.filter {
                let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return $0.isMultiCamSupported &&
                    (device.deviceType != .builtInWideAngleCamera || $0.autoFocusSystem != .none) && size.width <= 1920 && size.height <= 1440 &&
                    DualCaptureLimits.photoSize(in: $0.supportedMaxPhotoDimensions, mode: mode) != nil && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            }
            guard let format = formats.max(by: {
                if mode == .detail {
                    let a = DualCaptureLimits.photoSize(in: $0.supportedMaxPhotoDimensions, mode: mode)!
                    let b = DualCaptureLimits.photoSize(in: $1.supportedMaxPhotoDimensions, mode: mode)!
                    let areaA = Int64(a.width) * Int64(a.height), areaB = Int64(b.width) * Int64(b.height)
                    if areaA != areaB { return areaA < areaB }
                }
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return Int64(a.width) * Int64(a.height) < Int64(b.width) * Int64(b.height)
            }) else { throw Failure.unsupported }
            originals.append((device, device.activeFormat, device.activeVideoMinFrameDuration, device.activeVideoMaxFrameDuration, device.videoZoomFactor))
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw Failure.unsupported }
            session.addInputWithNoConnections(input)
            inputs.append(input)
            try device.lockForConfiguration()
            device.activeFormat = format
            device.videoZoomFactor = device.minAvailableVideoZoomFactor
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            let output = AVCapturePhotoOutput()
            guard session.canAddOutput(output) else { throw Failure.unsupported }
            session.addOutputWithNoConnections(output)
            outputs.append(output)
            guard let port = input.ports.first(where: { $0.mediaType == .video }) else { throw Failure.unsupported }
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { throw Failure.unsupported }
            session.addConnection(connection)
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            output.maxPhotoQualityPrioritization = mode == .detail ? .quality : .speed
            guard device.activeFormat.isMultiCamSupported,
                  let size = DualCaptureLimits.photoSize(in: device.activeFormat.supportedMaxPhotoDimensions, mode: mode) else { throw Failure.unsupported }
            output.maxPhotoDimensions = size
            labels.append(String(format: "%.1f MP", Double(size.width) * Double(size.height) / 1_000_000))
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
        for (device, format, minimum, maximum, zoom) in originals {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                if let restored = ZoomLimits.clamp(Double(zoom), minimum: Double(device.minAvailableVideoZoomFactor), maximum: Double(device.maxAvailableVideoZoomFactor)) {
                    device.videoZoomFactor = CGFloat(restored)
                }
                device.activeVideoMinFrameDuration = minimum
                device.activeVideoMaxFrameDuration = maximum
                device.unlockForConfiguration()
            } catch { /* The parent rebuilds single-camera configuration before resuming. */ }
        }
        originals.removeAll()
    }

    func capture(night: Bool = false, panorama: Bool = false, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        guard session.isRunning, !session.isInterrupted, !busy, outputs.count == 2 else {
            completion(.failure(CameraFailure.unavailable)); return
        }
        guard inputs.allSatisfy({ $0.device.systemPressureState.level != .serious && $0.device.systemPressureState.level != .critical && $0.device.systemPressureState.level != .shutdown }) else {
            completion(.failure(Failure.overloaded)); return
        }
        // Validate both requests before submitting either one. AVFoundation rejects invalid
        // dimensions/codecs with an exception, which Swift do/catch cannot recover from.
        guard inputs.count == outputs.count, session.hardwareCost <= 1 else {
            completion(.failure(Failure.overloaded)); return
        }
        nightCapture = night
        panoramaCapture = panorama
        var requests: [AVCapturePhotoSettings] = []
        for (index, output) in outputs.enumerated() {
            let device = inputs[index].device
            guard device.activeFormat.isMultiCamSupported,
                  DualCaptureLimits.accepts(output.maxPhotoDimensions, supported: device.activeFormat.supportedMaxPhotoDimensions, mode: mode),
                  let connection = output.connection(with: .video), connection.isEnabled, connection.isActive,
                  let codec = [AVVideoCodecType.hevc, .jpeg].first(where: { output.availablePhotoCodecTypes.contains($0) }) else {
                completion(.failure(Failure.unsupported)); return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            if night || panorama {
                guard let size = NightCapturePolicy.photoSize(device.activeFormat.supportedMaxPhotoDimensions,
                                                             maximum: output.maxPhotoDimensions) else {
                    completion(.failure(Failure.unsupported)); return
                }
                settings.maxPhotoDimensions = size
            } else { settings.maxPhotoDimensions = output.maxPhotoDimensions }
            settings.photoQualityPrioritization = panorama ? .speed : night ? output.maxPhotoQualityPrioritization : captureMode == .detail ? .quality : .speed
            requests.append(settings)
        }
        results.removeAll()
        busy = true
        cancelRemaining = false
        onProgress?(captureMode == .detail ? "Hold still · focusing photo 1 of 2" : "Capturing both views…")
        for index in captureMode.initialCaptureIndices {
            submit(index, requests: requests, completion: completion)
        }
    }

    func cancelRemainingCapture() { cancelRemaining = true }

    private func submit(_ index: Int, requests: [AVCapturePhotoSettings],
                        completion: @escaping (Result<CapturedPhoto, Error>) -> Void,
                        focusWindow: FocusSettlingWindow? = nil) {
        // Check again after the first Detail photo: the app may have backgrounded,
        // or iOS may have reported pressure while its processing was in flight.
        guard !cancelRemaining, session.isRunning, !session.isInterrupted,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical,
              inputs.allSatisfy({ ![.serious, .critical, .shutdown].contains($0.device.systemPressureState.level) }),
              let connection = outputs[index].connection(with: .video), connection.isEnabled, connection.isActive else {
            receive(.failure(Failure.overloaded), index: index, requests: requests, completion: completion)
            return
        }
        if captureMode == .detail {
            let now = ProcessInfo.processInfo.systemUptime
            var window = focusWindow ?? FocusSettlingWindow(startedAt: now)
            switch window.update(adjusting: inputs[index].device.isAdjustingFocus, now: now) {
            case .wait:
                queue.asyncAfter(deadline: .now() + 0.05) { [weak self, window] in
                    self?.submit(index, requests: requests, completion: completion, focusWindow: window)
                }
                return
            case .timedOut:
                receive(.failure(Failure.focusUnsettled), index: index, requests: requests, completion: completion)
                return
            case .ready: break
            }
        }
        let processor = PhotoCaptureProcessor { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.processors[index] = nil
                self.receive(result, index: index, requests: requests, completion: completion)
            }
        }
        processors[index] = processor
        if captureMode == .detail { onProgress?("Hold still · photo \(index + 1) of 2") }
        outputs[index].capturePhoto(with: requests[index], delegate: processor)
    }

    private func receive(_ result: Result<CapturedPhoto, Error>, index: Int,
                         requests: [AVCapturePhotoSettings],
                         completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        results[index] = result
        if let next = captureMode.nextCaptureIndex(after: index) {
            onProgress?("Hold still · focusing photo 2 of 2")
            submit(next, requests: requests, completion: completion)
            return
        }
        guard results.count == 2 else { return }
        let successful = (0..<2).compactMap { index -> (Int, CapturedPhoto)? in
            guard var photo = try? results[index]?.get() else { return nil }
            let device = inputs[index].device
            let base = CameraDeviceCatalog.lens(for: device).zoomFactor ?? (index == 0 ? 1 : 0.5)
            photo.lensLabel = CaptureLensLabel.make(name: index == 0 ? "Main" : "Ultra Wide",
                                                   base: base, factor: Double(device.videoZoomFactor))
            return (index, photo)
        }
        let failure = results.values.compactMap { result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }.first
        results.removeAll()
        busy = false
        guard var first = successful.first?.1 else {
            completion(.failure(failure ?? CameraFailure.noPhoto)); return
        }
        first.companions = successful.dropFirst().map { $0.1 }
        first.warning = successful.count == 2 ? "Both photos saved" :
            "Only \(successful[0].0 == 0 ? "Main" : "Ultra Wide") photo saved. \(failure?.localizedDescription ?? "The other camera did not capture a photo.")"
        completion(.success(first))
    }

}


/// Optional, low-resolution guides. These never modify a captured photo.
private final class ViewfinderAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    func releaseBuffers() {
        queue.async { [weak self] in
            self?.pixels = []; self?.luma = []; self?.context.clearCaches()
        }
    }
    let queue = DispatchQueue(label: "CameraXT.viewfinderGuides", qos: .utility)
    let mode: String
    let report: (UIImage?, [Double]) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    // Accessed only on the serial guide queue; reuse scratch storage between frames.
    private var pixels: [UInt8] = []
    private var luma: [Int] = []
    private var lastTime = -Double.infinity
    init(mode: String, report: @escaping (UIImage?, [Double]) -> Void) { self.mode = mode; self.report = report }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard time.isFinite, time - lastTime >= 0.2 else { return }
        lastTime = time
        guard ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { report(nil, []); return }
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer)
            let scale = 180 / max(source.extent.width, source.extent.height)
            let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let width = max(1, Int(image.extent.width)), height = max(1, Int(image.extent.height))
            if pixels.count != width * height * 4 { pixels = [UInt8](repeating: 0, count: width * height * 4) }
            pixels.withUnsafeMutableBytes { bytes in
                context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                               bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                               colorSpace: colorSpace)
            }
            if luma.count != width * height { luma = [Int](repeating: 0, count: width * height) }
            var bins = mode == "Histogram" ? [Double](repeating: 0, count: 32) : []
            for index in luma.indices {
                let p = index * 4
                luma[index] = (Int(pixels[p]) * 54 + Int(pixels[p + 1]) * 183 + Int(pixels[p + 2]) * 19) / 256
                if mode == "Histogram" { bins[min(31, luma[index] / 8)] += 1 }
            }
            if mode == "Histogram" {
                let peak = max(1, bins.max() ?? 1)
                report(nil, bins.map { $0 / peak }); return
            }
            var overlay = [UInt8](repeating: 0, count: pixels.count)
            guard width > 2, height > 2 else { return }
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let index = y * width + x, p = index * 4
                    let show = mode == "Highlights" ? luma[index] >= 245 && (x + y) % 6 < 3 :
                        abs(luma[index + 1] - luma[index - 1]) + abs(luma[index + width] - luma[index - width]) > 95
                    if show {
                        overlay[p] = mode == "Highlights" ? 255 : 0
                        overlay[p + 1] = mode == "Highlights" ? 60 : 255
                        overlay[p + 2] = mode == "Highlights" ? 60 : 255
                        overlay[p + 3] = 255
                    }
                }
            }
            guard let provider = CGDataProvider(data: Data(overlay) as CFData),
                  let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: colorSpace,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
            report(UIImage(cgImage: cg), [])
        }
    }
}

/// Keep paired still captures within a strict per-sensor memory budget.
enum DualCaptureLimits {
    static func photoSize(in sizes: [CMVideoDimensions], mode: DualShotMode = .fast) -> CMVideoDimensions? {
        sizes.filter { $0.width > 0 && $0.height > 0 && Int64($0.width) * Int64($0.height) <= mode.pixelLimit }
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    }
    static func accepts(_ size: CMVideoDimensions, supported: [CMVideoDimensions], mode: DualShotMode = .fast) -> Bool {
        photoSize(in: [size], mode: mode) != nil && supported.contains { $0.width == size.width && $0.height == size.height }
    }
}

/// Fast submits both requests together; Detail waits for didFinishCapture before the second.
enum DualShotMode: String, CaseIterable {
    case fast = "Fast", detail = "Detail"
    var pixelLimit: Int64 { self == .fast ? 12_500_000 : 49_000_000 }
    var initialCaptureIndices: [Int] { self == .fast ? [0, 1] : [0] }
    func nextCaptureIndex(after index: Int) -> Int? { self == .detail && index == 0 ? 1 : nil }
}

/// Requires a short uninterrupted idle period; never stalls the capture queue.
struct FocusSettlingWindow {
    enum Decision: Equatable { case wait, ready, timedOut }
    let startedAt: TimeInterval
    private var idleSince: TimeInterval?
    init(startedAt: TimeInterval) { self.startedAt = startedAt }
    mutating func update(adjusting: Bool, now: TimeInterval) -> Decision {
        if adjusting { idleSince = nil }
        else if idleSince == nil { idleSince = now }
        if let idleSince, now - idleSince >= 0.1 { return .ready }
        if now - startedAt >= 1 { return .timedOut }
        return .wait
    }
}

/// Conservative edge-hand hint, not a promise that an uncovered lens is clear.
struct LensWarningEvidence {
    private(set) var warning = false
    private var hits = 0
    private var misses = 0
    mutating func observe(_ candidate: Bool) -> Bool {
        hits = candidate ? hits + 1 : 0
        misses = candidate ? 0 : misses + 1
        if hits >= 2 { warning = true }
        if misses >= 2 { warning = false }
        return warning
    }
    static func edgeHand(_ points: [CGPoint]) -> Bool {
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let left = xs.min(), let right = xs.max(), let bottom = ys.min(), let top = ys.max() else { return false }
        // Ignore small/distant hands and hands intentionally centered in a scene.
        return max(right - left, top - bottom) >= 0.22 &&
            (left < 0.08 || right > 0.92 || bottom < 0.08 || top > 0.92)
    }
}

/// Session-queue ownership. Optional outputs never alter capture format or dimensions.
private final class LensObstructionMonitor {
    private weak var session: AVCaptureSession?
    private var sourceIDs: [String] = []
    private var outputs: [AVCaptureVideoDataOutput] = []
    private var samplers: [LensObstructionSampler] = []
    private var attempted = false
    private let worker = DispatchQueue(label: "LocalCamera.lensWarning", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])

    func pause() {
        outputs.forEach { $0.setSampleBufferDelegate(nil, queue: nil) }
        samplers.forEach { $0.cancel() }
        samplers.removeAll()
    }
    func stop() {
        pause()
        if let session, !outputs.isEmpty {
            session.beginConfiguration()
            for output in outputs where session.outputs.contains(output) { session.removeOutput(output) }
            session.commitConfiguration()
        }
        outputs.removeAll(); sourceIDs.removeAll(); session = nil; attempted = false
    }
    func update(session: AVCaptureSession, inputs: [AVCaptureDeviceInput], report: @escaping (Int, Bool) -> Void) {
        let ids = inputs.map { $0.device.uniqueID }
        if self.session !== session || sourceIDs != ids {
            stop(); self.session = session; sourceIDs = ids
        }
        guard !inputs.isEmpty else { return }
        if !attempted {
            attempted = true
            session.beginConfiguration()
            for input in inputs {
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                guard session.canAddOutput(output), let port = input.ports.first(where: { $0.mediaType == .video }) else { break }
                session.addOutputWithNoConnections(output)
                let connection = AVCaptureConnection(inputPorts: [port], output: output)
                guard session.canAddConnection(connection) else { session.removeOutput(output); break }
                session.addConnection(connection)
                if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
                outputs.append(output)
            }
            // Optional hints must not push a paired-camera session over its budget.
            let overBudget = (session as? AVCaptureMultiCamSession).map { $0.hardwareCost > 0.9 || $0.systemPressureCost > 0.9 } ?? false
            if outputs.count != inputs.count || overBudget {
                outputs.forEach { session.removeOutput($0) }; outputs.removeAll()
            }
            session.commitConfiguration()
        }
        guard samplers.isEmpty else { return }
        for (index, output) in outputs.enumerated() {
            let sampler = LensObstructionSampler(context: context, report: { report(index, $0) })
            samplers.append(sampler)
            output.setSampleBufferDelegate(sampler, queue: worker)
        }
    }
}

/// Detects a broad, smooth, warm-colored region entering from an image edge.
/// Requires surrounding scene detail: color or darkness alone never triggers a hint.
struct NearLensObstruction {
    static let side = 64
    static func candidate(rgba: [UInt8]) -> Bool {
        guard rgba.count == side * side * 4 else { return false }
        struct Tile { var warm = 0.0; var texture = 0.0; var red = 0.0 }
        var tiles = Array(repeating: Tile(), count: 64)
        func color(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * side + x) * 4
            return (Double(rgba[i]) / 255, Double(rgba[i + 1]) / 255, Double(rgba[i + 2]) / 255)
        }
        for y in 0..<side {
            for x in 0..<side {
                let (r, g, b) = color(x, y)
                let l = (r + g + b) / 3
                let i = (y / 8) * 8 + x / 8
                tiles[i].red += (r - b) / 64
                if r > g * 1.08 && g > b * 1.04 && r - b > 0.06 && l > 0.035 && l < 0.9 { tiles[i].warm += 1 / 64.0 }
                // Compare within each tile so its boundary does not count as texture.
                if x % 8 < 7 && y % 8 < 7 {
                    let a = color(x + 1, y), c = color(x, y + 1)
                    let horizontal: Double = abs(r - a.0) + abs(g - a.1) + abs(b - a.2)
                    let vertical: Double = abs(r - c.0) + abs(g - c.1) + abs(b - c.2)
                    tiles[i].texture += (horizontal + vertical) / 294.0
                }
            }
        }
        let eligible = tiles.map { $0.warm >= 0.8 && $0.texture < 0.025 }
        var visited = Set<Int>()
        for start in 0..<64 where eligible[start] && !visited.contains(start) {
            var component = [start]; visited.insert(start)
            var cursor = 0
            while cursor < component.count {
                let i = component[cursor]; cursor += 1
                let neighbors = [(i % 8 > 0 ? i - 1 : -1), (i % 8 < 7 ? i + 1 : -1), (i >= 8 ? i - 8 : -1), (i < 56 ? i + 8 : -1)]
                for n in neighbors where n >= 0 && eligible[n] && !visited.contains(n) { visited.insert(n); component.append(n) }
            }
            guard component.count >= 8 && component.count <= 48,
                  component.filter({ $0 % 8 == 0 || $0 % 8 == 7 || $0 < 8 || $0 >= 56 }).count >= 3 else { continue }
            let region = Set(component)
            let other = (0..<64).filter { !region.contains($0) }
            let texture = component.reduce(0.0) { $0 + tiles[$1].texture } / Double(component.count)
            let detailed = other.filter { tiles[$0].texture > max(0.012, texture * 2.5) }
            let redness = component.reduce(0.0) { $0 + tiles[$1].red } / Double(component.count)
            let backgroundRed = other.reduce(0.0) { $0 + tiles[$1].red } / Double(other.count)
            if detailed.count >= 6 && redness - backgroundRed > 0.035 { return true }
        }
        return false
    }
}

private final class LensObstructionSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var active = true
    private var lastSample = -Double.infinity
    private var evidence = LensWarningEvidence()
    private let report: (Bool) -> Void
    private let context: CIContext
    private var pixels = [UInt8](repeating: 0, count: NearLensObstruction.side * NearLensObstruction.side * 4)
    init(context: CIContext, report: @escaping (Bool) -> Void) { self.context = context; self.report = report }
    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func cancel() {
        lock.lock(); active = false; lock.unlock()
        DispatchQueue.main.async { [report] in report(false) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard isActive, now - lastSample >= 1.0,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSample = now
        autoreleasepool {
            let input = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 320 / max(input.extent.width, input.extent.height))
            let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let image = context.createCGImage(small, from: small.extent), isActive else { return }
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 2
            let dimension = CGFloat(NearLensObstruction.side)
            let probe = input.transformed(by: CGAffineTransform(scaleX: dimension / input.extent.width, y: dimension / input.extent.height))
            pixels.withUnsafeMutableBytes { bytes in
                if let address = bytes.baseAddress {
                    context.render(probe, toBitmap: address, rowBytes: NearLensObstruction.side * 4,
                                   bounds: CGRect(x: 0, y: 0, width: dimension, height: dimension), format: .RGBA8,
                                   colorSpace: CGColorSpaceCreateDeviceRGB())
                }
            }
            var candidate = NearLensObstruction.candidate(rgba: pixels)
            do {
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                for hand in request.results ?? [] {
                    let points = try hand.recognizedPoints(.all).values.filter { $0.confidence >= 0.5 }.map(\.location)
                    candidate = candidate || LensWarningEvidence.edgeHand(points)
                }
            } catch { /* Keep independent near-lens evidence if hand pose fails. */ }
            let old = evidence.warning
            let warning = evidence.observe(candidate)
            guard old != warning else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive else { return }
                self.report(warning)
            }
        }
    }
}
