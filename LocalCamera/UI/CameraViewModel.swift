import AVFoundation
import SwiftUI
import UIKit
import ImageIO
import PhotosUI

@MainActor
final class PhotoRescueModel: ObservableObject {
    @Published private(set) var result: RescuedPhoto?
    @Published private(set) var busy = false
    @Published private(set) var saved = false
    @Published var strength = 0.5
    @Published var look: PhotoLook = .natural
    @Published var message: String?
    private var source: Data?

    func load(_ item: PhotosPickerItem) async {
        guard !busy else { return }
        busy = true
        result = nil
        source = nil
        saved = false
        message = "Loading photo…"
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CameraFailure.noPhoto }
            source = data
            message = "Adjusting on this iPhone…"
            result = try await PhotoRescueProcessor.process(data, strength: strength, look: look)
            message = nil
        } catch { message = "Could not prepare this photo. \(error.localizedDescription)" }
        busy = false
    }
    func apply() async {
        guard !busy, let source else { return }
        busy = true
        message = "Adjusting on this iPhone…"
        do {
            result = try await PhotoRescueProcessor.process(source, strength: strength, look: look)
            saved = false
            message = nil
        } catch { message = error.localizedDescription }
        busy = false
    }
    func save() async {
        guard !busy, !saved, let result else { return }
        busy = true
        do {
            try await PhotoLibrarySaver().save(result.photo)
            saved = true
            message = "Edited copy saved. Your original is unchanged."
        } catch { message = error.localizedDescription }
        busy = false
    }
}

enum CaptureMode: String, CaseIterable { case photo = "Photo", video = "Video" }
enum QuickCaptureTool: Equatable { case action, night, dual, depth, eye, burst, automatic }

@MainActor
final class ViewfinderGuideState: ObservableObject {
    @Published var image: UIImage?
    @Published var histogram: [Double] = []
}

// Serial decoding bounds concurrent image memory and keeps ImageIO off the UI thread.
enum CapturePreviewDecoder {
    private static let queue = DispatchQueue(label: "camera.preview.decode", qos: .userInitiated)

    static func image(_ data: Data, maxSize: Int) async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                let image: UIImage? = autoreleasepool {
                    guard let source = CGImageSourceCreateWithData(data as CFData,
                            [kCGImageSourceShouldCache: false] as CFDictionary),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: maxSize
                          ] as CFDictionary) else { return nil }
                    return UIImage(cgImage: cg)
                }
                continuation.resume(returning: image)
            }
        }
    }

    static func thumbnail(_ data: Data) async -> Data? {
        guard let image = await image(data, maxSize: 256) else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: autoreleasepool { image.jpegData(compressionQuality: 0.85) })
            }
        }
    }
}

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var camera = CameraSnapshot()
    @Published private(set) var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var busy = false
    @Published private(set) var restoring = true
    @Published private(set) var recent: CaptureStore.Record?
    @Published private(set) var recordingStarted: Date?
    @Published private(set) var readyMilliseconds: Int?
    @Published private(set) var lastCaptureMilliseconds: Int?
    @Published private(set) var lastSaveMilliseconds: Int?
    @Published private(set) var lowStorage = false
    @Published private(set) var recoveryProtected = false
    @Published var haptics = UserDefaults.standard.bool(forKey: "camera.haptics") {
        didSet { UserDefaults.standard.set(haptics, forKey: "camera.haptics") }
    }
    let guides = ViewfinderGuideState()
    @Published var exposurePointOnly = false
    @Published var dualBrightness: [Float] = [0, 0]
    private let store = CaptureStore()
    private var recoveryReadFailed = false
    private var launchTime = Date()
    private var storageTask: Task<Void, Never>?
    @Published private(set) var pendingPhoto: CapturedPhoto?
    @Published private(set) var lastSavedThumbnail: UIImage?
    @Published private(set) var lastSavedPhotoCount = 0
    private var messageTask: Task<Void, Never>?
    private var nightWork: NightWorkCancellation?
    @Published var message: String? {
        didSet {
            messageTask?.cancel()
            guard let message, Self.isBriefStatus(message) else { return }
            messageTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
                self?.message = nil
            }
        }
    }
    nonisolated static func isBriefStatus(_ message: String) -> Bool {
        if ["Saved", "Video saved", "Both photos saved", "Depth capture ready", "Eye focus ready",
            "Ready to aim and shoot", "Unsaved capture discarded."].contains(message) { return true }
        let words = message.split(separator: " ")
        return words.count == 3 && words[0] == "Saved" && Int(words[1]).map { $0 > 0 } == true && words[2] == "photos"
    }

    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var pendingVideo: URL?
    @Published var videoWidth: Int32 = 1920
    @Published var videoFPS: Int32 = 30
    @Published var stabilization = true
    @Published var timerSeconds = 0
    @Published private(set) var countdown = 0
    private var timerTask: Task<Void, Never>?
    private var controlsTask: Task<Void, Never>?
    private var recordingRequested = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @Published var controls = CameraControls()
    @Published var burstEnabled = false
    @Published var reviewingBurst = false
    @Published private(set) var burstPhotos: [CapturedPhoto] = []
    @Published private(set) var burstPreviews: [UIImage] = []
    @Published var selectedBurstIndex = 0
    @Published private(set) var recommendedBurstIndex = 0
    var hasPendingCapture: Bool { restoring || recoveryReadFailed || pendingPhoto != nil || pendingVideo != nil || !burstPhotos.isEmpty }
    var canShutter: Bool { camera.recording || (camera.running && !busy && !configuring && !hasPendingCapture && !resetOnReturn) }

    var shutterStatus: String {
        if camera.recording { return "Recording" }
        if countdown > 0 { return "Timer: \(countdown) seconds" }
        if busy { return "Capture in progress" }
        if hasPendingCapture { return "Finish saving or reviewing this capture" }
        if configuring { return "Preparing camera" }
        return canShutter ? "Ready" : "Camera unavailable"
    }

    func selectMode(_ selected: CaptureMode) {
        guard !busy, !configuring, !hasPendingCapture, !camera.recording else { return }
        if camera.dualEnabled {
            modeAfterDual = selected
            setDualEnabled(false)
            return
        }
        if selected != mode { resetTemporarySettings() }
        configuring = true
        engine.setVideoMode(selected == .video, width: videoWidth, fps: videoFPS, stabilized: stabilization)
    }
    func applyVideoSettings() { selectMode(.video) }
    func shutter() {
        guard canShutter else { return }
        if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        if controlsTask != nil {
            controlsTask?.cancel()
            controlsTask = nil
            applyControls()
        }
        if camera.recording {
            busy = true
            engine.stopRecording()
        } else if mode == .video {
            guard canShutter else { return }
            busy = true
            recordingRequested = true
            Task {
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
                guard active else { busy = false; recordingRequested = false; return }
                message = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "Recording…" : "Recording without sound · microphone access is off"
                backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                    self?.engine.stopRecording()
                    self?.endBackgroundTask()
                }
                engine.startRecording()
            }
        } else if timerSeconds > 0 {
            guard canCapture else { return }
            busy = true
            countdown = timerSeconds
            timerSeconds = 0
            timerTask = Task { [weak self] in
                guard let self else { return }
                while self.countdown > 0 {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    self.countdown -= 1
                }
                self.busy = false
                if self.active { self.capture() }
            }
        } else { capture() }
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    let engine = CaptureSessionManager()
    private let saver: PhotoSaving
    private var active = false
    private var editingPhoto = false
    private var requestingPermission = false
    private var lastRearLensID: String?
    private var restoredLens = false
    private var resetOnReturn = false
    private var pendingTool: QuickCaptureTool?
    private var expectingCaptureProgress = false
    private var modeAfterDual: CaptureMode?
    @Published private(set) var captureStyle = "Auto"
    @Published private(set) var configuring = false
    @Published var exposureBias: Float = 0 {
        didSet { engine.setExposureBias(exposureBias) }
    }
    func setDualEnabled(_ enabled: Bool) {
        guard !busy, !configuring, !hasPendingCapture, mode == .photo, enabled != camera.dualEnabled else { return }
        configuring = true
        if enabled { burstEnabled = false }
        engine.setDualEnabled(enabled)
    }
    func setDualMode(_ mode: DualShotMode) {
        guard canConfigure, camera.dualEnabled, mode != camera.dualMode else { return }
        configuring = true
        engine.setDualEnabled(true, mode: mode)
    }
    func focus(at point: CGPoint, locked: Bool) {
        guard camera.running, !busy, !configuring else { return }
        if !exposurePointOnly { controls.automaticFocus = true; controls.facePriority = false }
        else { controls.automaticExposure = true }
        engine.focus(at: point, locked: locked, exposureOnly: exposurePointOnly)
    }

    func focusDual(at point: CGPoint, index: Int, locked: Bool = false) {
        guard camera.dualEnabled, camera.running, !busy, !configuring, !hasPendingCapture else { return }
        engine.focus(at: point, locked: locked, dualIndex: index, exposureOnly: exposurePointOnly)
    }

    func applyControls() {
        guard !busy, !configuring, !hasPendingCapture, !camera.dualEnabled else { return }
        captureStyle = "Auto"
        engine.setControls(controls)
    }

    func scheduleControls() {
        controlsTask?.cancel()
        controlsTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            self?.applyControls()
            self?.controlsTask = nil
        }
    }
    func resetControls() {
        captureStyle = "Auto"
        engine.setAnalysis("Off")
        engine.setEyeFocus(false)
        controls = CameraControls()
        exposureBias = 0
        dualBrightness = [0, 0]
        exposurePointOnly = false
        if camera.dualEnabled {
            for index in 0..<2 { engine.focus(at: CGPoint(x: 0.5, y: 0.5), locked: false, dualIndex: index) }
        }
        applyControls()
    }
    func actionPreset() {
        guard mode == .photo, camera.customExposureAvailable, !camera.dualEnabled, !busy, !configuring, !hasPendingCapture else { return }
        controls.iso = min(camera.maxISO, max(camera.minISO, camera.currentISO * Float(camera.currentShutter * 500)))
        controls.shutterSeconds = 1.0 / 500
        controls.automaticExposure = false
        controls.automaticFocus = true
        controls.facePriority = true
        controls.flash = .off
        burstEnabled = true
        timerSeconds = 0
        applyControls()
        captureStyle = "Action"
        message = "Action · 3 shots at 1/500 s. Dim light may look noisy or dark."
    }

    func nightPreset() { setNightEnabled(true) }

    func setNightEnabled(_ enabled: Bool) {
        guard canConfigure, mode == .photo else { return }
        timerSeconds = 0
        burstEnabled = false
        if !camera.dualEnabled {
            controls = CameraControls()
            exposureBias = 0
            engine.setControls(controls)
            engine.setDepthEnabled(false)
            engine.setAnalysis("Off")
            setEyeFocus(false)
        }
        if enabled && camera.dualEnabled { setDualMode(.detail) }
        captureStyle = enabled ? "Night" : "Auto"
        message = enabled ? "Night · Beta. Hold still. Matching frames are combined; a reference original is retained." : nil
    }

    var canConfigure: Bool { !busy && !configuring && !hasPendingCapture && !camera.recording }

    func activate(_ tool: QuickCaptureTool) {
        guard canConfigure else { return }
        if tool == .night && camera.dualEnabled { setNightEnabled(true); return }
        if camera.dualEnabled && tool != .dual { message = "Switching from Dual Shot to single-camera Photo for this feature." }
        else if camera.videoMode { message = "Switching from Video to Photo for this feature." }
        else if tool == .dual && (burstEnabled || camera.eyeFocusEnabled || camera.analysisMode != "Off") {
            message = "Dual Shot turns off burst, eye tracking, and viewfinder guides."
        }
        pendingTool = tool
        continueTool()
    }

    private func continueTool() {
        guard let tool = pendingTool, !configuring else { return }
        if camera.videoMode {
            configuring = true
            engine.setVideoMode(false)
            return
        }
        if camera.dualEnabled {
            configuring = true
            engine.setDualEnabled(false)
            return
        }
        var requiredLens: CameraLens?
        if tool == .depth && !camera.depthAvailable {
            requiredLens = camera.lenses.first { $0.name == "Depth" } ?? camera.lenses.first { $0.name == "Front Depth" }
        } else if tool == .action && !camera.customExposureAvailable || tool == .eye && !camera.eyeFocusAvailable {
            requiredLens = camera.lenses.first { !$0.isFront && $0.name == "Wide" }
        }
        if let lens = requiredLens, lens.id != camera.selectedID {
            configuring = true
            engine.select(lens.id)
            return
        }
        pendingTool = nil
        if tool != .eye && tool != .depth { resetTemporarySettings() }
        else if tool == .depth && captureStyle != "Auto" { resetTemporarySettings() }
        switch tool {
        case .action:
            if camera.customExposureAvailable { actionPreset() }
            else { message = "Action needs a camera with manual exposure support." }
        case .night: nightPreset()
        case .dual:
            if camera.dualAvailable { setDualEnabled(true) }
            else { message = "Dual Shot is unavailable on this device." }
        case .depth:
            if camera.depthAvailable { engine.setDepthEnabled(true); message = "Depth capture ready" }
            else { message = "Depth is unavailable with this camera format." }
        case .eye:
            if camera.eyeFocusAvailable { setEyeFocus(true); message = "Eye focus ready" }
            else { message = "Eye focus is unavailable with this camera." }
        case .burst: burstEnabled = true; message = "Three photos, then choose your favorite."
        case .automatic: message = "Ready to aim and shoot"
        }
    }

    func resetTemporarySettings() {
        timerSeconds = 0
        burstEnabled = false
        captureStyle = "Auto"
        resetControls()
        engine.setDepthEnabled(false)
    }

    func enteredBackground() { resetOnReturn = true; nightWork?.cancel() }

    init(saver: PhotoSaving = PhotoLibrarySaver()) {
        self.saver = saver
        engine.onCaptureProgress = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.expectingCaptureProgress else { return }
                self.message = progress
            }
        }
        engine.onWarning = { [weak self] warning in Task { @MainActor [weak self] in self?.message = warning } }
        engine.onAnalysis = { [weak self] image, bins in
            Task { @MainActor [weak self] in self?.guides.image = image; self?.guides.histogram = bins }
        }
        Task { await restoreCaptures() }
        engine.onMeter = { [weak self] meter in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var updated = self.camera
                updated.exposureLabel = meter.exposureLabel
                updated.focusLabel = meter.focusLabel
                updated.currentISO = meter.currentISO
                updated.currentShutter = meter.currentShutter
                updated.focusLocked = meter.focusLocked
                updated.focusStates = meter.focusStates
                updated.cooling = meter.cooling
                self.camera = updated
                if self.resetOnReturn, self.active, self.canConfigure {
                    self.resetOnReturn = false
                    self.resetTemporarySettings()
                }
            }
        }
        engine.onMovie = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordingRequested = false
                switch result {
                case .success(let url): self.pendingVideo = url; await self.savePending()
                case .failure(let error): self.message = error.localizedDescription; self.busy = false
                }
                self.endBackgroundTask()
            }
        }
        engine.onChange = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                if let self {
                    if snapshot.running && self.readyMilliseconds == nil {
                        self.readyMilliseconds = Int(Date().timeIntervalSince(self.launchTime) * 1000)
                    }
                    if snapshot.recording && self.recordingStarted == nil { self.recordingStarted = Date() }
                    if !snapshot.recording { self.recordingStarted = nil }
                }
                self?.camera = snapshot
                self?.configuring = false
                self?.mode = snapshot.videoMode ? .video : .photo
                if let self {
                    if let failure = snapshot.message, self.modeAfterDual != nil {
                        self.modeAfterDual = nil
                        self.message = failure
                    }
                    if let selected = self.modeAfterDual, !snapshot.dualEnabled {
                        self.modeAfterDual = nil
                        self.selectMode(selected)
                        return
                    }
                    if !self.restoredLens && !snapshot.lenses.isEmpty {
                        self.restoredLens = true
                        if let id = UserDefaults.standard.string(forKey: "camera.preferredRearLens"),
                           snapshot.lenses.contains(where: { $0.id == id && !$0.isFront }), id != snapshot.selectedID {
                            self.configuring = true
                            self.engine.select(id)
                            return
                        }
                    }
                    if let failure = snapshot.message, self.pendingTool != nil {
                        self.pendingTool = nil
                        self.message = failure
                    } else { self.continueTool() }
                }
                if snapshot.recording && self?.recordingRequested == true {
                    self?.busy = false
                    self?.recordingRequested = false
                }
            }
        }
    }

    var selectedLens: CameraLens? { camera.lenses.first { $0.id == camera.selectedID } }
    var canCapture: Bool { camera.running && !busy && !configuring && !hasPendingCapture && mode == .photo }
    var canSwitch: Bool { camera.running && !busy && !configuring && !hasPendingCapture && !camera.dualEnabled && !camera.videoMode }

    func setEyeFocus(_ enabled: Bool) {
        guard !busy, !configuring, !hasPendingCapture else { return }
        if enabled {
            controls.automaticFocus = true
            engine.setControls(controls)
        }
        engine.setEyeFocus(enabled)
    }

    func setPhotoEditorActive(_ value: Bool) {
        editingPhoto = value
        if value { engine.stop() }
        else if active && permission == .authorized { engine.start() }
    }

    func setActive(_ value: Bool) {
        active = value
        storageTask?.cancel()
        if value {
            storageTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshStorage()
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                }
            }
        }
        if value && resetOnReturn && canConfigure {
            resetOnReturn = false
            resetTemporarySettings()
        }
        if !value && countdown > 0 {
            timerTask?.cancel(); timerTask = nil; countdown = 0; busy = false
        }
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        if active && permission == .authorized && !editingPhoto { engine.start() } else { engine.stop() }
    }

    private func refreshStorage() async {
        let bytes = await store.availableBytes()
        guard active, !Task.isCancelled else { return }
        lowStorage = bytes.map { $0 < 500_000_000 } ?? false
        if lowStorage && camera.recording && (bytes ?? .max) < 150_000_000 {
            engine.stopRecording()
            message = "Recording stopped to protect the remaining storage."
        }
    }

    func requestCamera() async {
        guard !requestingPermission else { return }
        requestingPermission = true
        _ = await AVCaptureDevice.requestAccess(for: .video)
        requestingPermission = false
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        if active && permission == .authorized { engine.start() }
    }

    func select(_ lens: CameraLens, zoom: Double = 1) {
        guard canSwitch else { return }
        if !lens.isFront {
            lastRearLensID = lens.id
            UserDefaults.standard.set(lens.id, forKey: "camera.preferredRearLens")
        }
        configuring = true
        engine.select(lens.id, zoom: zoom)
    }

    func flip() {
        guard canSwitch, let selected = selectedLens else { return }
        if !selected.isFront { lastRearLensID = selected.id }
        let candidates = camera.lenses.filter { $0.isFront != selected.isFront }
        // Return to the rear lens the user was using before switching to the front.
        guard let next = candidates.first(where: { $0.id == lastRearLensID })
                ?? candidates.first else { return }
        select(next)
    }

    func capture() {
        guard canCapture else { return }
        busy = true
        if captureStyle == "Night" { captureNight(); return }
        if burstEnabled && !camera.dualEnabled {
            message = "Capturing burst…"
            engine.captureBurst { [weak self] result in
                switch result {
                case .failure(let error):
                    Task { @MainActor [weak self] in self?.busy = false; self?.message = error.localizedDescription }
                case .success(let photos):
                    Task { @MainActor [weak self] in
                        guard let self, var recovery = photos.first else { return }
                        recovery.companions = Array(photos.dropFirst())
                        recovery.warning = "Recovered burst: saving keeps every frame."
                        do { try await self.store.stage(recovery); self.recoveryProtected = true }
                        catch { self.recoveryProtected = false }
                        PhotoRanker.recommend(photos) { index in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.burstPhotos = photos
                            var previews: [UIImage] = []
                            for photo in photos {
                                previews.append(await CapturePreviewDecoder.image(photo.data, maxSize: 1200) ?? UIImage())
                            }
                            self.burstPreviews = previews
                            self.selectedBurstIndex = max(0, index)
                            self.recommendedBurstIndex = index
                            self.busy = false
                            self.message = self.recoveryProtected ? "Choose your favorite" : "Keep Camera XT open: these frames could not be protected on disk. Free storage, then save."
                            self.reviewingBurst = true
                        }
                        }
                    }
                }
            }
            return
        }
        message = "Capturing…"
        expectingCaptureProgress = true
        let captureStarted = ProcessInfo.processInfo.systemUptime
        engine.capture { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch result {
                case .success(let photo):
                    self.expectingCaptureProgress = false
                    self.lastCaptureMilliseconds = Int((ProcessInfo.processInfo.systemUptime - captureStarted) * 1000)
                    self.pendingPhoto = photo
                    await self.savePending()
                case .failure(let error):
                    self.expectingCaptureProgress = false
                    self.message = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    private func captureNight() {
        let started = ProcessInfo.processInfo.systemUptime
        let work = NightWorkCancellation()
        nightWork = work
        expectingCaptureProgress = true
        message = "Night · hold still"
        engine.captureNight(cancellation: work) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.expectingCaptureProgress = false
                defer { self.nightWork = nil }
                switch result {
                case .failure(let error):
                    self.busy = false
                    self.message = error.localizedDescription
                case .success(let frames):
                    let references = NightPhotoProcessor.references(frames)
                    guard var protected = references.first else {
                        self.busy = false; self.message = "Night did not return a photo."; return
                    }
                    protected.companions = Array(references.dropFirst())
                    protected.warning = "Night reference original(s) recovered."
                    self.pendingPhoto = protected
                    do {
                        try await self.store.stage(protected)
                        self.recoveryProtected = true
                    } catch {
                        self.busy = false
                        self.message = "Night originals could not be protected. Keep the app open and retry saving."
                        return
                    }
                    // Release live camera work while the bounded image merge runs.
                    self.engine.stop()
                    if !self.active { work.cancel() }
                    self.message = "Night · checking alignment and preserving detail…"
                    if let photo = await NightPhotoProcessor.process(frames, cancellation: work) {
                        self.pendingPhoto = photo
                    }
                    self.lastCaptureMilliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    await self.savePending()
                    if self.active { self.engine.start() }
                }
            }
        }
    }

    func saveBurst(all: Bool) async {
        guard !busy, burstPhotos.indices.contains(selectedBurstIndex) else { return }
        var photo = burstPhotos[selectedBurstIndex]
        if all {
            photo.companions = burstPhotos.enumerated().filter { $0.offset != selectedBurstIndex }.map(\.element)
            photo.warning = "Saved \(burstPhotos.count) burst photos"
        }
        pendingPhoto = photo
        burstPhotos = []
        burstPreviews = []
        reviewingBurst = false
        await savePending()
        if active { engine.start() }
    }

    func retrySave() async {
        guard !busy else { return }
        if recoveryReadFailed { restoring = true; await restoreCaptures(); return }
        await savePending()
    }

    private func savePending() async {
        guard pendingVideo != nil || pendingPhoto != nil else { return }
        busy = true
        message = "Saving · protecting a local recovery copy…"
        defer { busy = false }
        do {
            if let video = pendingVideo {
                let protected = try await store.stageVideo(video)
                pendingVideo = protected
                if video != protected { try? FileManager.default.removeItem(at: video) }
            } else if let photo = pendingPhoto { try await store.stage(photo) }
            recoveryProtected = true
        } catch {
            recoveryProtected = false
            message = "Could not protect this capture on disk. Keep Camera XT open, free storage, then retry. \(error.localizedDescription)"
            return
        }
        message = "Saving to Photos…"
        let saveStarted = ProcessInfo.processInfo.systemUptime
        do {
            let thumbnail: Data?
            let savedMessage: String
            if let video = pendingVideo {
                thumbnail = await CaptureStore.videoThumbnail(video)
                try await saver.saveVideo(video)
                savedMessage = "Video saved"
            } else if let photo = pendingPhoto {
                thumbnail = await CapturePreviewDecoder.thumbnail(photo.data)
                try await saver.save(photo)
                savedMessage = photo.warning ?? (photo.companions.isEmpty ? "Saved" : "Saved \(1 + photo.companions.count) photos")
            } else { return }
            lastSaveMilliseconds = Int((ProcessInfo.processInfo.systemUptime - saveStarted) * 1000)
            // Photos has committed. Cache failures must never offer an automatic duplicate save.
            pendingPhoto = nil; pendingVideo = nil
            do {
                recent = try await store.finish(thumbnail: thumbnail)
                await updateRecentThumbnail()
                message = savedMessage
            } catch {
                message = "Saved to Photos, but local history could not be updated."
            }
            recoveryProtected = false
            if haptics { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        } catch {
            message = "Not saved to Photos. A recovery copy is on this iPhone. \(error.localizedDescription)"
            if haptics { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
    }

    private func restoreCaptures() async {
        defer { restoring = false }
        recent = try? await store.load("recent.plist")
        await updateRecentThumbnail()
        do {
            recoveryReadFailed = false
            if let record = try await store.load("pending.plist") {
                if record.saved { try await store.discard() }
                else {
                    pendingPhoto = record.captured
                    if record.isVideo { pendingVideo = try await store.videoURL() }
                    recoveryProtected = true
                    message = "Recovered an unfinished save. Check Photos before retrying to avoid a duplicate."
                }
            }
        } catch { recoveryReadFailed = true; message = "Capture recovery could not be read. Keep this app installed and free storage before trying again." }
    }

    private func updateRecentThumbnail() async {
        guard let record = recent else {
            lastSavedThumbnail = nil; lastSavedPhotoCount = 0
            return
        }
        let data = record.thumbnail ?? record.photos.first?.data
        let image = if let data { await CapturePreviewDecoder.image(data, maxSize: 256) } else { nil as UIImage? }
        guard recent?.date == record.date else { return }
        lastSavedThumbnail = image
        lastSavedPhotoCount = record.photos.count
    }

    func clearRecent() async {
        do {
            try await store.clearRecent()
            recent = nil; lastSavedThumbnail = nil; lastSavedPhotoCount = 0
        } catch { message = "Could not clear the local recent preview." }
    }

    func setDualBrightness(_ value: Float, index: Int) {
        guard canConfigure, dualBrightness.indices.contains(index) else { return }
        dualBrightness[index] = value
        engine.setExposureBias(value, dualIndex: index)
    }

    func discard() {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await store.discard()
                pendingPhoto = nil; burstPhotos = []; burstPreviews = []; reviewingBurst = false
                pendingVideo = nil; recoveryProtected = false; recoveryReadFailed = false
                message = "Unsaved capture discarded."
            } catch { message = "Could not discard the recovery copy. Try again." }
            busy = false
            if active { engine.start() }
        }
    }
}
