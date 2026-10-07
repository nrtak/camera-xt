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
            result = try await PhotoRescueProcessor.process(data, strength: strength)
            message = nil
        } catch { message = "Could not prepare this photo. \(error.localizedDescription)" }
        busy = false
    }
    func apply() async {
        guard !busy, let source else { return }
        busy = true
        message = "Adjusting on this iPhone…"
        do {
            result = try await PhotoRescueProcessor.process(source, strength: strength)
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
final class CameraViewModel: ObservableObject {
    @Published private(set) var camera = CameraSnapshot()
    @Published private(set) var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var busy = false
    @Published private(set) var pendingPhoto: CapturedPhoto?
    private var messageTask: Task<Void, Never>?
    @Published var message: String? {
        didSet {
            messageTask?.cancel()
            guard let message, message.hasPrefix("Saved") || message == "Video saved" else { return }
            messageTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
                self?.message = nil
            }
        }
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
    var hasPendingCapture: Bool { pendingPhoto != nil || pendingVideo != nil || !burstPhotos.isEmpty }
    var canShutter: Bool { camera.recording || (camera.running && !busy && !configuring && !hasPendingCapture && !resetOnReturn) }

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
    func focus(at point: CGPoint, locked: Bool) {
        guard camera.running, !busy, !configuring else { return }
        controls.automaticFocus = true
        controls.automaticExposure = true
        controls.facePriority = false
        if !camera.dualEnabled { engine.setControls(controls) }
        engine.focus(at: point, locked: locked)
    }

    func focusDual(at point: CGPoint, index: Int) {
        guard camera.dualEnabled, camera.running, !busy, !configuring, !hasPendingCapture else { return }
        engine.focus(at: point, locked: false, dualIndex: index)
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
        engine.setEyeFocus(false)
        controls = CameraControls()
        exposureBias = 0
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
        message = "Action ready"
    }

    func nightPreset() {
        guard mode == .photo, camera.customExposureAvailable, !camera.dualEnabled,
              !busy, !configuring, !hasPendingCapture else { return }
        controls.iso = min(camera.maxISO, max(camera.minISO, camera.currentISO * Float(camera.currentShutter * 4)))
        controls.shutterSeconds = 0.25
        controls.automaticExposure = false
        controls.automaticFocus = true
        controls.facePriority = true
        controls.flash = .off
        timerSeconds = 3
        burstEnabled = true
        applyControls()
        captureStyle = "Night"
        message = "Hold still"
    }

    var canConfigure: Bool { !busy && !configuring && !hasPendingCapture && !camera.recording }

    func activate(_ tool: QuickCaptureTool) {
        guard canConfigure else { return }
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
        } else if (tool == .action || tool == .night) && !camera.customExposureAvailable || tool == .eye && !camera.eyeFocusAvailable {
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
        case .night:
            if camera.customExposureAvailable { nightPreset() }
            else { message = "Night needs a camera with manual exposure support." }
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

    func enteredBackground() { resetOnReturn = true }

    init(saver: PhotoSaving = PhotoLibrarySaver()) {
        self.saver = saver
        engine.onMeter = { [weak self] meter in
            Task { @MainActor [weak self] in
                self?.camera.exposureLabel = meter.exposureLabel
                self?.camera.focusLabel = meter.focusLabel
                self?.camera.currentISO = meter.currentISO
                self?.camera.currentShutter = meter.currentShutter
                if let self, self.resetOnReturn, self.active, self.canConfigure {
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

    func requestCamera() async {
        guard !requestingPermission else { return }
        requestingPermission = true
        _ = await AVCaptureDevice.requestAccess(for: .video)
        requestingPermission = false
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        if active && permission == .authorized { engine.start() }
    }

    func select(_ lens: CameraLens) {
        guard canSwitch else { return }
        if !lens.isFront {
            lastRearLensID = lens.id
            UserDefaults.standard.set(lens.id, forKey: "camera.preferredRearLens")
        }
        engine.select(lens.id)
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
        if burstEnabled && !camera.dualEnabled {
            message = "Capturing burst…"
            engine.captureBurst { [weak self] result in
                switch result {
                case .failure(let error):
                    Task { @MainActor [weak self] in self?.busy = false; self?.message = error.localizedDescription }
                case .success(let photos):
                    PhotoRanker.recommend(photos) { index in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.burstPhotos = photos
                            self.burstPreviews = photos.map { Self.preview($0.data) }
                            self.selectedBurstIndex = index
                            self.recommendedBurstIndex = index
                            self.busy = false
                            self.message = "Choose your favorite"
                            self.reviewingBurst = true
                        }
                    }
                }
            }
            return
        }
        message = "Capturing…"
        engine.capture { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch result {
                case .success(let photo):
                    self.pendingPhoto = photo
                    await self.savePending()
                case .failure(let error):
                    self.message = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    private static func preview(_ data: Data) -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { return UIImage() }
        return UIImage(cgImage: image)
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
        await savePending()
    }

    private func savePending() async {
        if let video = pendingVideo {
            busy = true
            message = "Saving video…"
            defer { busy = false }
            do {
                try await saver.saveVideo(video)
                pendingVideo = nil
                try? FileManager.default.removeItem(at: video)
                message = "Video saved"
            } catch { message = error.localizedDescription }
            return
        }
        guard let photo = pendingPhoto else { return }
        busy = true
        message = "Saving…"
        defer { busy = false }
        do {
            try await saver.save(photo)
            pendingPhoto = nil
            message = photo.warning ?? (photo.companions.isEmpty ? "Saved" : "Saved 2 photos")
        } catch { message = error.localizedDescription }
    }

    func discard() {
        guard !busy else { return }
        pendingPhoto = nil
        burstPhotos = []
        burstPreviews = []
        reviewingBurst = false
        if let video = pendingVideo { try? FileManager.default.removeItem(at: video) }
        pendingVideo = nil
        message = "Unsaved capture discarded."
        if active { engine.start() }
    }
}
