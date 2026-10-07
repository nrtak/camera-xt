import AVFoundation
import CoreImage
import Vision

struct CapturedPhoto {
    let data: Data
    let dimensions: CMVideoDimensions
    var companions: [CapturedPhoto] = []
    var warning: String?
}

/// Compares a small burst on-device. Originals remain available for the user's choice.
enum PhotoRanker {
    private static let queue = DispatchQueue(label: "CameraXT.photoRanking", qos: .userInitiated)
    static func recommend(_ photos: [CapturedPhoto], completion: @escaping (Int) -> Void) {
        queue.async {
            let context = CIContext(options: [.cacheIntermediates: false])
            let scores = photos.map { photo -> Double in
                autoreleasepool {
                    guard let original = CIImage(data: photo.data, options: [.applyOrientationProperty: true]) else { return 0 }
                    let scale = min(1, 512 / max(original.extent.width, original.extent.height))
                    let image = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    let edges = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1])
                    let average = edges.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
                    var pixel = [Float](repeating: 0, count: 4)
                    pixel.withUnsafeMutableBytes { bytes in
                        if let address = bytes.baseAddress {
                            context.render(average, toBitmap: address, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())
                        }
                    }
                    let detail = Double(max(0, pixel[0]) + max(0, pixel[1]) + max(0, pixel[2])) / 3
                    let request = VNDetectFaceCaptureQualityRequest()
                    try? VNImageRequestHandler(ciImage: image).perform([request])
                    let faces = request.results ?? []
                    let largest = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
                    let faceQuality = largest?.faceCaptureQuality?.doubleValue
                    return faceQuality.map { $0 + min(detail, 0.25) } ?? detail
                }
            }
            completion(scores.indices.max(by: { scores[$0] < scores[$1] }) ?? 0)
        }
    }
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
