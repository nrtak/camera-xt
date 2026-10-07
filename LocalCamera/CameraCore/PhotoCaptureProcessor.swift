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
            var bestIndex = 0
            var bestScore = -Double.infinity
            for (index, photo) in photos.enumerated() {
                let value: Double = autoreleasepool { score(photo, context: context) }
                if value > bestScore { bestScore = value; bestIndex = index }
            }
            completion(bestIndex)
        }
    }
    private static func score(_ photo: CapturedPhoto, context: CIContext) -> Double {
        guard let original = CIImage(data: photo.data, options: [.applyOrientationProperty: true]) else { return 0 }
        let longest: CGFloat = max(original.extent.width, original.extent.height)
        guard longest > 0 else { return 0 }
        let scale: CGFloat = min(1, 512 / longest)
        let image = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let detail = detailScore(image, context: context)
        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        var largestArea: CGFloat = 0
        var faceQuality: Double?
        for face in request.results ?? [] {
            let area = face.boundingBox.width * face.boundingBox.height
            if area > largestArea {
                largestArea = area
                faceQuality = face.faceCaptureQuality?.doubleValue
            }
        }
        if let quality = faceQuality { return quality + min(detail, 0.25) }
        return detail
    }
    private static func detailScore(_ image: CIImage, context: CIContext) -> Double {
        let edges = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1])
        let extent = CIVector(cgRect: image.extent)
        let average = edges.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: extent])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            context.render(average, toBitmap: address, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let red = max(0.0, Double(pixel[0]))
        let green = max(0.0, Double(pixel[1]))
        let blue = max(0.0, Double(pixel[2]))
        return (red + green + blue) / 3.0
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
