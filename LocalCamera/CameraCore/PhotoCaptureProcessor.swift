import AVFoundation
import CoreImage
import Vision
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Heavy still-image work shares one lane; live preview, video and session configuration stay independent.
enum PhotoProcessingScheduler {
    static let queue = DispatchQueue(label: "CameraXT.stillProcessing", qos: .userInitiated, autoreleaseFrequency: .workItem)
}

struct RescuedPhoto {
    let photo: CapturedPhoto
    let before: UIImage
    let after: UIImage
}

enum PhotoLook: String, CaseIterable { case natural = "Natural", warm = "Warm", mono = "Mono" }

enum PhotoRescueProcessor {
    private static let queue = PhotoProcessingScheduler.queue
    static func process(_ data: Data, strength: Double, look: PhotoLook = .natural, cancellation: NightWorkCancellation? = nil) async throws -> RescuedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result: Result<RescuedPhoto, Error> = Result {
                    try autoreleasepool { try render(data, strength: strength, look: look, cancellation: cancellation) }
                }
                continuation.resume(with: result)
            }
        }
    }
    private static func render(_ data: Data, strength: Double, look: PhotoLook, cancellation: NightWorkCancellation?) throws -> RescuedPhoto {
        if cancellation?.cancelled == true { throw CancellationError() }
        guard data.count <= 100_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 6000,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) else { throw CameraFailure.noPhoto }
        var original = CIImage(cgImage: cg)
        if cancellation?.cancelled == true { throw CancellationError() }
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
        if look == .warm {
            adjusted = adjusted.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 7000, y: 0)])
        } else if look == .mono {
            adjusted = adjusted.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        }
        let blended = original.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: adjusted, kCIInputTimeKey: amount]).cropped(to: bounds)
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        if cancellation?.cancelled == true { throw CancellationError() }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let rendered = context.createCGImage(blended, from: bounds, format: .RGBA8, colorSpace: colorSpace) else { throw CameraFailure.noPhoto }
        if cancellation?.cancelled == true { throw CancellationError() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw CameraFailure.noPhoto }
        CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraFailure.noPhoto }
        if cancellation?.cancelled == true { throw CancellationError() }
        let previewScale = min(1, 1400 / max(bounds.width, bounds.height))
        let transform = CGAffineTransform(scaleX: previewScale, y: previewScale)
        let before = original.transformed(by: transform)
        let after = blended.transformed(by: transform)
        guard let beforeCG = context.createCGImage(before, from: before.extent),
              let afterCG = context.createCGImage(after, from: after.extent) else { throw CameraFailure.noPhoto }
        return RescuedPhoto(photo: CapturedPhoto(data: output as Data, dimensions: CMVideoDimensions(width: Int32(rendered.width), height: Int32(rendered.height))), before: UIImage(cgImage: beforeCG), after: UIImage(cgImage: afterCG))
    }
}

/// The same centered rectangle drives the live composition and the saved photo.
/// Full never decodes or rewrites the camera's original file.
enum PhotoAspectRatio: String, CaseIterable, Codable {
    case full = "Full", square = "1:1", wide = "16:9"

    /// Keep the persisted "Full" value compatible with existing setups and recovery files.
    /// The interface names the actual native ratio, independent of device orientation.
    func label(nativeDimensions: [CMVideoDimensions]) -> String {
        guard self == .full else { return rawValue }
        guard !nativeDimensions.isEmpty else { return "Original" }
        var labels: [String] = []
        for size in nativeDimensions {
            guard size.width > 0, size.height > 0 else { return "Original" }
            let width = Int(max(size.width, size.height)), height = Int(min(size.width, size.height))
            var a = width, b = height
            while b != 0 { let remainder = a % b; a = b; b = remainder }
            let horizontal = width / a, vertical = height / a
            guard horizontal <= 32, vertical <= 32 else { return "Original" }
            labels.append("\(horizontal):\(vertical)")
        }
        return Set(labels).count == 1 ? labels[0] : "Original"
    }

    func cropRect(in bounds: CGRect) -> CGRect {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        guard self != .full else { return bounds }
        let ratio: CGFloat = self == .square ? 1 : bounds.width < bounds.height ? 9.0 / 16 : 16.0 / 9
        let width = min(bounds.width, bounds.height * ratio)
        let height = min(bounds.height, bounds.width / ratio)
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    func pixelCropRect(width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0 else { return nil }
        if self == .full { return CGRect(x: 0, y: 0, width: width, height: height) }
        let horizontal = self == .square ? 1 : width < height ? 9 : 16
        let vertical = self == .square ? 1 : width < height ? 16 : 9
        let units = min(width / horizontal, height / vertical)
        guard units > 0 else { return nil }
        let w = horizontal * units, h = vertical * units
        return CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
    }
}

struct CapturedPhoto {
    let data: Data
    let dimensions: CMVideoDimensions
    var companions: [CapturedPhoto] = []
    var warning: String?
    var lensLabel: String?
    var details: CaptureDetails?
    var aspectRatio: PhotoAspectRatio = .full

    func framed(aspect: PhotoAspectRatio) -> CapturedPhoto {
        var result = self
        result.aspectRatio = aspect
        result.companions = companions.map { $0.framed(aspect: aspect) }
        return result
    }
}

enum PhotoAspectRenderer {
    enum CropError: LocalizedError {
        case unavailable, memoryPressure
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The selected crop could not be prepared. The original capture is kept for retry."
            case .memoryPressure: return "Cropping stopped because this iPhone is low on memory. The original capture is kept for retry."
            }
        }
    }

    static func render(_ photo: CapturedPhoto, cancellation: NightWorkCancellation = NightWorkCancellation()) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            PhotoProcessingScheduler.queue.async {
                do {
                    // Process each lens on the existing serial lane, releasing decoded
                    // pixels before the next lens. Never upscale a selected crop.
                    var result = try autoreleasepool { try renderOne(photo, cancellation: cancellation) }
                    var companions: [CapturedPhoto] = []
                    for companion in photo.companions {
                        companions.append(try autoreleasepool { try renderOne(companion, cancellation: cancellation) })
                    }
                    result.companions = companions
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func renderOne(_ photo: CapturedPhoto, cancellation: NightWorkCancellation) throws -> CapturedPhoto {
        guard photo.aspectRatio != .full else { return photo }
        guard !cancellation.cancelled else { throw CropError.memoryPressure }
        guard let source = CGImageSourceCreateWithData(photo.data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              let crop = photo.aspectRatio.pixelCropRect(width: width, height: height) else { throw CropError.unavailable }
        if Int(crop.width) == width && Int(crop.height) == height { return photo }
        guard !cancellation.cancelled else { throw CropError.memoryPressure }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let cropped = image.cropping(to: crop) else { throw CropError.unavailable }
        guard !cancellation.cancelled else { throw CropError.memoryPressure }
        let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        let sourceType = CGImageSourceGetType(source).map { $0 as String } ?? UTType.jpeg.identifier
        let type = supported.contains(sourceType) ? sourceType : UTType.jpeg.identifier
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw CropError.unavailable }
        var metadata = properties
        metadata[kCGImagePropertyPixelWidth as String] = cropped.width
        metadata[kCGImagePropertyPixelHeight as String] = cropped.height
        metadata[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = cropped.width
        exif[kCGImagePropertyExifPixelYDimension as String] = cropped.height
        metadata[kCGImagePropertyExifDictionary as String] = exif
        // Preserve EXIF orientation and color metadata; crop in source-pixel axes.
        CGImageDestinationAddImage(destination, cropped, metadata as CFDictionary)
        guard !cancellation.cancelled else { throw CropError.memoryPressure }
        guard CGImageDestinationFinalize(destination) else { throw CropError.unavailable }
        guard !cancellation.cancelled else { throw CropError.memoryPressure }
        return CapturedPhoto(data: data as Data,
            dimensions: CMVideoDimensions(width: Int32(cropped.width), height: Int32(cropped.height)),
            warning: photo.warning, lensLabel: photo.lensLabel, details: photo.details, aspectRatio: photo.aspectRatio)
    }
}

/// Compares a small burst on-device. Originals remain available for the user's choice.
enum PhotoRanker {
    private static let queue = PhotoProcessingScheduler.queue
    static func recommend(_ photos: [CapturedPhoto], completion: @escaping (Int) -> Void) {
        queue.async {
            if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { completion(-1); return }
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
        guard var original = CIImage(data: photo.data, options: [.applyOrientationProperty: true]) else { return 0 }
        original = original.cropped(to: photo.aspectRatio.cropRect(in: original.extent))
        original = original.transformed(by: CGAffineTransform(translationX: -original.extent.minX, y: -original.extent.minY))
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
        PhotoProcessingScheduler.queue.async { [self] in
            autoreleasepool {
                if let error = error {
                    result = .failure(error)
                } else if let data = photo.fileDataRepresentation() {
                    let note = expectsDepth ? (photo.depthData == nil ? "Photo saved; depth was unavailable for this scene." : "Photo saved with embedded depth.") : nil
                    let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
                    let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
                    let exposure = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
                    let time = CMTimeGetSeconds(photo.timestamp)
                    let details = CaptureDetails(iso: iso, exposureSeconds: exposure, timestamp: time.isFinite ? time : nil)
                    result = .success(CapturedPhoto(data: data, dimensions: photo.resolvedSettings.photoDimensions, warning: note, details: details))
                }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        PhotoProcessingScheduler.queue.async { [self] in
            completion(error.map { .failure($0) } ?? result)
        }
    }
}

/// Numeric capture facts only. Stored with local recovery/recent photos, never transmitted.
struct CaptureDetails: Codable, Equatable {
    let iso: Double?
    let exposureSeconds: Double?
    let timestamp: Double?
    var summary: String {
        let isoText = iso.map { String(format: "ISO %.0f", $0) } ?? "ISO unavailable"
        let shutter = exposureSeconds.map { String(format: "%.4f s", $0) } ?? "Shutter unavailable"
        return "\(isoText) · \(shutter)"
    }
    static func gap(_ a: CaptureDetails?, _ b: CaptureDetails?) -> Double? {
        guard let a = a?.timestamp, let b = b?.timestamp, a.isFinite, b.isFinite else { return nil }
        return abs(b - a)
    }
}


/// Night uses bounded stills, not concurrent full-resolution image stacks.
enum NightCapturePolicy {
    static let byteLimit = 64_000_000
    static let pixelLimit: Int64 = 12_500_000
    static func photoSize(_ sizes: [CMVideoDimensions], maximum: CMVideoDimensions) -> CMVideoDimensions? {
        sizes.filter { $0.width > 0 && $0.height > 0 && $0.width <= maximum.width && $0.height <= maximum.height &&
            Int64($0.width) * Int64($0.height) <= pixelLimit }
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    }
    static func acceptsMotion(meanDifference: Double, changedFraction: Double) -> Bool {
        meanDifference.isFinite && changedFraction.isFinite && meanDifference >= 0 && changedFraction >= 0 &&
            meanDifference <= 0.035 && changedFraction <= 0.025
    }
}

// Cancellation state is lock-protected; the observer is owned for the instance lifetime.
final class NightWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                          object: nil, queue: nil) { [weak self] _ in self?.cancel() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool {
        lock.lock(); let value = stopped; lock.unlock()
        return value || [.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
    }
}

/// Conservative prototype: align one lens at a time, reject changed scenes, retain a reference.
enum NightPhotoProcessor {
    private static let queue = PhotoProcessingScheduler.queue
    static func process(_ frames: [CapturedPhoto], cancellation: NightWorkCancellation) async -> CapturedPhoto? {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = autoreleasepool { render(frames, cancellation: cancellation) }
                continuation.resume(returning: result)
            }
        }
    }
    static func references(_ frames: [CapturedPhoto]) -> [CapturedPhoto] {
        var seen = Set<String>()
        return frames.filter { seen.insert($0.lensLabel ?? "Camera").inserted }.map { frame in
            var photo = frame; photo.companions = []; return photo
        }
    }
    private static func render(_ frames: [CapturedPhoto], cancellation: NightWorkCancellation) -> CapturedPhoto? {
        guard !frames.isEmpty else { return nil }
        let labels = references(frames).map { $0.lensLabel ?? "Camera" }
        var outputs: [CapturedPhoto] = []
        var mergedLenses = 0
        for label in labels {
            let group = frames.filter { ($0.lensLabel ?? "Camera") == label }
            let result = autoreleasepool { merge(group, cancellation: cancellation) }
            outputs += result.photos
            if result.merged { mergedLenses += 1 }
        }
        guard var first = outputs.first else { return nil }
        first.companions = Array(outputs.dropFirst())
        first.warning = mergedLenses > 0
            ? "Night saved · \(mergedLenses) view(s) merged; reference originals also saved."
            : "Night saved original(s) · frames were unsuitable for a reliable merge."
        if labels.count == 1 && frames.contains(where: { $0.warning?.hasPrefix("Only ") == true }) {
            first.warning = "Night saved one camera only. The other camera did not complete."
        }
        return first
    }
    private static func decode(_ data: Data, maxSize: Int) -> CIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return CIImage(cgImage: image)
    }
    private static func luminance(_ image: CIImage, context: CIContext, side: Int = 96) -> [Double] {
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(side) / image.extent.width,
                                                             y: CGFloat(side) / image.extent.height))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1])
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(scaled, toBitmap: bytes.baseAddress!, rowBytes: side * 4,
                           bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        var values = [Double](repeating: 0, count: side * side)
        for i in values.indices {
            let offset = i * 4
            let red = Double(pixels[offset]) * 0.2126
            let green = Double(pixels[offset + 1]) * 0.7152
            let blue = Double(pixels[offset + 2]) * 0.0722
            values[i] = (red + green + blue) / 255.0
        }
        return values
    }
    private static func sharpness(_ pixels: [Double], side: Int = 96) -> Double {
        guard pixels.count == side * side else { return 0 }
        var sum = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                sum += abs(pixels[i - 1] - pixels[i + 1]) + abs(pixels[i - side] - pixels[i + side])
            }
        }
        return sum / Double(pixels.count)
    }
    private static func difference(_ a: [Double], _ b: [Double]) -> (mean: Double, changed: Double) {
        guard a.count == b.count, !a.isEmpty else { return (.infinity, 1) }
        let values = zip(a, b).map { abs($0 - $1) }
        return (values.reduce(0, +) / Double(values.count), Double(values.filter { $0 > 0.12 }.count) / Double(values.count))
    }
    private static func merge(_ frames: [CapturedPhoto], cancellation: NightWorkCancellation) -> (photos: [CapturedPhoto], merged: Bool) {
        guard let first = frames.first else { return ([], false) }
        guard frames.count >= 2, !cancellation.cancelled,
              frames.reduce(0, { $0 + $1.data.count }) <= NightCapturePolicy.byteLimit else { return ([first], false) }
        let color = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.cacheIntermediates: false,
                                         .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
        defer { context.clearCaches() }
        var bestIndex = 0
        var bestScore = -Double.infinity
        for (index, frame) in frames.enumerated() {
            if cancellation.cancelled { return ([first], false) }
            let score: Double = autoreleasepool {
                guard let image = decode(frame.data, maxSize: 512) else { return -.infinity }
                return sharpness(luminance(image, context: context))
            }
            if score > bestScore { bestIndex = index; bestScore = score }
        }
        let reference = frames[bestIndex]
        guard let base = decode(reference.data, maxSize: 4096),
              base.extent.width * base.extent.height <= CGFloat(NightCapturePolicy.pixelLimit),
              let registrationBase = decode(reference.data, maxSize: 512) else { return ([reference], false) }
        let bounds = base.extent
        let referencePixels = luminance(registrationBase, context: context)
        var accumulated = base
        var accepted = 1
        for (index, frame) in frames.enumerated() where index != bestIndex {
            if cancellation.cancelled { return ([reference], false) }
            let next: CIImage? = autoreleasepool {
                guard let small = decode(frame.data, maxSize: 512), small.extent == registrationBase.extent else { return nil }
                let request = VNTranslationalImageRegistrationRequest(targetedCIImage: small, options: [:])
                guard (try? VNImageRequestHandler(ciImage: registrationBase, options: [:]).perform([request])) != nil,
                      let alignment = request.results?.first, alignment.confidence >= 0.4 else { return nil }
                let transform = alignment.alignmentTransform
                guard transform.tx.isFinite, transform.ty.isFinite,
                      abs(transform.tx) < small.extent.width * 0.05,
                      abs(transform.ty) < small.extent.height * 0.05 else { return nil }
                // Verify the registration against actual pixels, including transform direction.
                let candidates = [transform, transform.inverted()]
                var selected: CGAffineTransform?
                var smallest = Double.infinity
                for candidate in candidates {
                    let aligned = small.transformed(by: candidate).cropped(to: registrationBase.extent)
                    let values = luminance(aligned, context: context)
                    let delta = difference(referencePixels, values)
                    if NightCapturePolicy.acceptsMotion(meanDifference: delta.mean, changedFraction: delta.changed),
                       sharpness(values) >= bestScore * 0.8, delta.mean < smallest {
                        selected = candidate; smallest = delta.mean
                    }
                }
                guard let selected, let image = decode(frame.data, maxSize: 4096), image.extent == bounds else { return nil }
                let scale = bounds.width / small.extent.width
                let offset = CGAffineTransform(translationX: selected.tx * scale, y: selected.ty * scale)
                let moved = image.transformed(by: offset)
                let overlap = moved.extent.intersection(bounds)
                guard overlap.width * overlap.height >= bounds.width * bounds.height * 0.92 else { return nil }
                // Use the reference outside the overlap rather than generating empty borders.
                let covered = moved.cropped(to: overlap).composited(over: base).cropped(to: bounds)
                let blended = accumulated.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: covered, kCIInputTimeKey: 1.0 / Double(accepted + 1)
                ]).cropped(to: bounds)
                guard let rendered = context.createCGImage(blended, from: bounds, format: .RGBA8, colorSpace: color) else { return nil }
                return CIImage(cgImage: rendered)
            }
            if let next { accumulated = next; accepted += 1 }
        }
        guard accepted >= 2, !cancellation.cancelled,
              let rendered = context.createCGImage(accumulated, from: bounds, format: .RGBA8, colorSpace: color) else { return ([reference], false) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return ([reference], false) }
        CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: 0.98,
                                                        kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return ([reference], false) }
        var output = CapturedPhoto(data: data as Data, dimensions: CMVideoDimensions(width: Int32(rendered.width), height: Int32(rendered.height)))
        output.lensLabel = "\(reference.lensLabel ?? "Camera") · Night \(accepted) frames"
        var original = reference
        original.warning = nil
        original.lensLabel = "\(reference.lensLabel ?? "Camera") · Reference"
        return ([output, original], true)
    }
}
