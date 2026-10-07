import AVFoundation
import SwiftUIimport UIKit

enum CaptureMode: String, CaseIterable { case photo = "Photo", video = "Video" }

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var camera = CameraSnapshot()
    @Published private(set) var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var busy = false
    @Published private(set) var pendingPhoto: CapturedPhoto?
    @Published var message: String?
    @Published private(set) var mode: CaptureMode = .photo
    @Published private(set) var pendingVideo: URL?
    @Published var videoWidth: Int32 = 1920
    @Published var videoFPS: Int32 = 30
    @Published var stabilization = true
    @Published var timerSeconds = 0
    @Published private(set) var countdown = 0
    private var timerTask: Task<Void, Never>?
    private var recordingRequested = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var hasPendingCapture: Bool { pendingPhoto != nil || pendingVideo != nil }
    var canShutter: Bool { camera.recording || (camera.running && !busy && !configuring && !hasPendingCapture) }

    func selectMode(_ selected: CaptureMode) {
        guard !busy, !configuring, !hasPendingCapture, !camera.recording, !camera.dualEnabled else { return }
        configuring = true
        engine.setVideoMode(selected == .video, width: videoWidth, fps: videoFPS, stabilized: stabilization)
    }
    func applyVideoSettings() { selectMode(.video) }
    func shutter() {
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
    private var requestingPermission = false
    private var lastRearLensID: String?
    @Published private(set) var configuring = false
    @Published var exposureBias: Float = 0 {
        didSet { engine.setExposureBias(exposureBias) }
    }
    func setDualEnabled(_ enabled: Bool) {
        guard !busy, !configuring, !hasPendingCapture, mode == .photo, enabled != camera.dualEnabled else { return }
        configuring = true
        engine.setDualEnabled(enabled)
    }
    func focus(at point: CGPoint, locked: Bool) {
        guard camera.running, !busy, !configuring else { return }
        engine.focus(at: point, locked: locked)
    }

    init(saver: PhotoSaving = PhotoLibrarySaver()) {
        self.saver = saver
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

    func setActive(_ value: Bool) {
        active = value
        if !value && countdown > 0 {
            timerTask?.cancel(); timerTask = nil; countdown = 0; busy = false
        }
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        if active && permission == .authorized { engine.start() } else { engine.stop() }
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
            message = photo.warning ?? (photo.companions.isEmpty ? "Saved · \(photo.dimensions.width) × \(photo.dimensions.height)" : "Saved 2 photos · Main + Ultra Wide")
        } catch { message = error.localizedDescription }
    }

    func discard() {
        guard !busy else { return }
        pendingPhoto = nil
        if let video = pendingVideo { try? FileManager.default.removeItem(at: video) }
        pendingVideo = nil
        message = "Unsaved capture discarded."
    }
}