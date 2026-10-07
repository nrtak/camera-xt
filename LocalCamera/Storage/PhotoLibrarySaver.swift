import Photos

protocol PhotoSaving {
    func save(_ photo: CapturedPhoto) async throws
    func saveVideo(_ url: URL) async throws
}

struct PhotoLibrarySaver: PhotoSaving {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Allow Add Photos access in Settings, then tap Retry save. Your unsaved capture is kept until you save or discard it. Keep the app open to retain unsaved photos."
        }
    }

    func saveVideo(_ url: URL) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }

    func save(_ photo: CapturedPhoto) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            for captured in [photo] + photo.companions {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: captured.data, options: nil)
            }
        }
    }
}