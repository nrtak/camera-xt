import AVFoundation
import SwiftUI

enum CaptureMode: String, CaseIterable { case photo = "Photo", video = "Video" }

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var camera = CameraSnapshot()
    @Published private(set) var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var busy = false
    @Published private(set) var pendingPhoto: CapturedPhoto?
    @Published var message: String?
    @Published var mode: CaptureMode = .photo
    let engine = CaptureSessionManager()
    private let saver: PhotoSaving
    private var active = false
    private var requestingPermission = false
    private var lastRearLensID: String?

    init(saver: PhotoSaving = PhotoLibrarySaver()) {
        self.saver = saver
        engine.onChange = { [weak self] snapshot in
            Task { @MainActor [weak self] in self?.camera = snapshot }
        }
    }

    var selectedLens: CameraLens? { camera.lenses.first { $0.id == camera.selectedID } }
    var canCapture: Bool { camera.running && !busy && pendingPhoto == nil && mode == .photo }
    var canSwitch: Bool { camera.running && !busy && pendingPhoto == nil }

    func setActive(_ value: Bool) {
        active = value
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
        guard let photo = pendingPhoto else { return }
        busy = true
        message = "Saving…"
        defer { busy = false }
        do {
            try await saver.save(photo)
            pendingPhoto = nil
            message = "Saved · \(photo.dimensions.width) × \(photo.dimensions.height)"
        } catch { message = error.localizedDescription }
    }

    func discard() {
        guard !busy else { return }
        pendingPhoto = nil
        message = "Unsaved photo discarded."
    }
}
