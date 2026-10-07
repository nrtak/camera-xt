import AVFoundation

struct CapturedPhoto {
    let data: Data
    let dimensions: CMVideoDimensions
    var companions: [CapturedPhoto] = []
    var warning: String?
}

enum CameraFailure: LocalizedError {
    case unavailable, input, output, noPhoto

    var errorDescription: String? {
        switch self {
        case .unavailable: return "No camera is available. Use a physical iPhone to take photos."
        case .input: return "This camera could not be selected."
        case .output: return "Photo capture could not be configured."
        case .noPhoto: return "The camera did not return a photo. Please try again."
        }
    }
}

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private var result: Result<CapturedPhoto, Error> = .failure(CameraFailure.noPhoto)
    private let completion: (Result<CapturedPhoto, Error>) -> Void

    init(completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            result = .success(CapturedPhoto(data: data, dimensions: photo.resolvedSettings.photoDimensions))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(error.map { .failure($0) } ?? result)
    }
}
