import Photos

protocol PhotoSaving {
    func save(_ photo: CapturedPhoto) async throws
}

struct PhotoLibrarySaver: PhotoSaving {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Allow Add Photos access in Settings, then tap Retry save. Your photo is held in memory until saved or discarded."
        }
    }

    func save(_ photo: CapturedPhoto) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: photo.data, options: nil)
        }
    }
}
