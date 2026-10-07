import AVFoundation
import CoreImage
import Vision
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct RescuedPhoto {
    let photo: CapturedPhoto
    let before: UIImage
    let after: UIImage
}

enum PhotoRescueProcessor {
    private static let queue = DispatchQueue(label: "CameraXT.photoRescue", qos: .userInitiated)
    static func process(_ data: Data, strength: Double) async throws -> RescuedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result: Result<RescuedPhoto, Error> = Result {
                    try autoreleasepool { try render(data, strength: strength) }
                }
                continuation.resume(with: result)
            }
        }
    }
    private static func render(_ data: Data, strength: Double) throws -> RescuedPhoto {
        guard data.count <= 100_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 6000,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) else { throw CameraFailure.noPhoto }
        var original = CIImage(cgImage: cg)
        let pixels = original.extent.width * original.extent.height
        let scale = min(1, sqrt(12_000_000 / max(1, pixels)))
        original = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: floor(original.extent.width), height: floor(original.extent.height))
        original = original.cropped(to: bounds)
        let amount = min(1, max(0, strength))
        var adjusted = original
        for filter in original.autoAdjustmentFilters(options: [.enhance: true, .redEye: false]) {
            filter.setValue(adjusted, forKey: kCIInputImageKey)
            adjusted = filter.outputImage ?? adjusted
        }
        adjusted = adjusted.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.015, "inputSharpness": 0.2])
        let blended = original.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: adjusted, kCIInputTimeKey: amount]).cropped(to: bounds)
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let rendered = context.createCGImage(blended, from: bounds, format: .RGBA8, colorSpace: colorSpace) else { throw CameraFailure.noPhoto }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw CameraFailure.noPhoto }
        CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraFailure.noPhoto }
        let previewScale = min(1, 1400 / max(bounds.width, bounds.height))
        let transform = CGAffineTransform(scaleX: previewScale, y: previewScale)
        let before = original.transformed(by: transform)
        let after = blended.transformed(by: transform)
        guard let beforeCG = context.createCGImage(before, from: before.extent),
              let afterCG = context.createCGImage(after, from: after.extent) else { throw CameraFailure.noPhoto }
        return RescuedPhoto(photo: CapturedPhoto(data: output as Data, dimensions: CMVideoDimensions(width: Int32(rendered.width), height: Int32(rendered.height))), before: UIImage(cgImage: beforeCG), after: UIImage(cgImage: afterCG))
    }
}

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
                faceQuality = face.faceCaptureQuality.map { Double($0) }
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
    private let expectsDepth: Bool

    init(expectsDepth: Bool = false, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        self.expectsDepth = expectsDepth
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            let note = expectsDepth ? (photo.depthData == nil ? "Photo saved; depth was unavailable for this scene." : "Photo saved with embedded depth.") : nil
            result = .success(CapturedPhoto(data: data, dimensions: photo.resolvedSettings.photoDimensions, warning: note))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        completion(error.map { .failure($0) } ?? result)
    }
}
