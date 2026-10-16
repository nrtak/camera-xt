import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

enum PanoramaMethod: String, CaseIterable {
    case sweep = "Sweep", stitch = "Stitch"
    var maximumSeconds: Int { self == .sweep ? 45 : 180 }
    var instructions: String {
        self == .sweep
            ? "Move slowly in the arrow direction. Tap the shutter again to finish."
            : "Take overlapping photos in the arrow direction, keeping at least two-thirds of the scene shared. Tap Finish to combine them."
    }
}

enum PanoramaDirection: String, CaseIterable {
    case right = "Right", left = "Left"
    var sign: CGFloat { self == .right ? 1 : -1 }
    var symbol: String { self == .right ? "arrow.right" : "arrow.left" }
}

enum PanoramaFailure: LocalizedError {
    case alignment, stationary, tooShort, changedCamera, limit
    var errorDescription: String? {
        switch self {
        case .stationary: return "Move slowly in the arrow direction."
        case .alignment: return "Not enough matching detail. Keep the phone level and sweep slowly across a still scene."
        case .tooShort: return "The sweep was too short to make a panorama."
        case .changedCamera: return "The camera changed during the sweep."
        case .limit: return "Panorama size limit reached."
        }
    }
}

struct PanoramaUpdate {
    let frames: Int
    let progress: Double
    let hint: String
}

enum PanoramaPolicy {
    static let maximumDimension = 12000
    static let maximumPixels = 32_000_000
    static let maximumDiskBytes = 256_000_000
    static let sourceDimension = 3072
    static let maximumFrames = 36
    static let maximumSeconds = 45.0
    static func accepts(_ offset: CGAffineTransform, size: CGSize, direction: PanoramaDirection) -> Bool {
        offset.tx.isFinite && offset.ty.isFinite && size.width > 0 && size.height > 0 &&
        offset.tx * direction.sign >= size.width * 0.015 && abs(offset.tx) <= size.width * 0.45 &&
        abs(offset.ty) <= size.height * 0.08
    }
}

/// Each lens has an independent stitch. Only the current canvas and previous frame stay decoded.
final class PanoramaStitcher {
    private struct Strip {
        var canvas: CGImage
        var previous: CIImage
        var origin: CGPoint
        var bounds: CGRect
        var commonY: CGRect
        var label: String
        var frames: Int
    }
    private static let queue = PhotoProcessingScheduler.queue
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let color = CGColorSpace(name: CGColorSpace.sRGB)!
    private var strips: [Strip] = []
    private let direction: PanoramaDirection
    init(direction: PanoramaDirection) { self.direction = direction }

    static func process(files: [[URL]], labels: [String], direction: PanoramaDirection,
                        cancellation: NightWorkCancellation) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    var results: [CapturedPhoto] = []
                    for (index, lensFiles) in files.enumerated() {
                        let result: CapturedPhoto = try autoreleasepool {
                            let stitcher = PanoramaStitcher(direction: direction)
                            defer { stitcher.context.clearCaches() }
                            var rejected = 0
                            for file in lensFiles {
                                if cancellation.cancelled { throw CancellationError() }
                                do {
                                    try autoreleasepool {
                                        let data = try Data(contentsOf: file, options: .mappedIfSafe)
                                        try stitcher.append(data, label: labels.indices.contains(index) ? labels[index] : "Camera")
                                    }
                                    rejected = 0
                                } catch PanoramaFailure.limit { break }
                                catch PanoramaFailure.stationary { continue }
                                catch PanoramaFailure.alignment {
                                    rejected += 1
                                    if rejected >= 3 { break }
                                }
                            }
                            var photo = try stitcher.finish()
                            if rejected > 0 { photo.warning = "Sweep ended before unmatched frames. " + (photo.warning ?? "") }
                            return photo
                        }
                        results.append(result)
                    }
                    guard var first = results.first else { throw PanoramaFailure.tooShort }
                    first.companions = Array(results.dropFirst()); return first
                })
            }
        }
    }

    private func append(_ data: Data, label: String) throws {
        let image = try PhotoEditRenderer.decode(data, maximum: PanoramaPolicy.sourceDimension)
        let small = try PhotoEditRenderer.decode(data, maximum: 512)
        if let previous = strips.first { strips = [try extend(previous, image: image, small: small)] }
        else {
            guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: color) else { throw PhotoEditError.render }
            strips = [Strip(canvas: cg, previous: small, origin: .zero, bounds: image.extent,
                commonY: image.extent, label: label, frames: 1)]
        }
    }

    private func extend(_ strip: Strip, image: CIImage, small: CIImage) throws -> Strip {
        guard small.extent == strip.previous.extent else { throw PanoramaFailure.changedCamera }
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: small, options: [:])
        try VNImageRequestHandler(ciImage: strip.previous, options: [:]).perform([request])
        guard let result = request.results?.first, result.confidence >= 0.3 else { throw PanoramaFailure.alignment }
        let proposed = result.alignmentTransform
        guard proposed.tx.isFinite, proposed.ty.isFinite else { throw PanoramaFailure.alignment }
        if abs(proposed.tx) < small.extent.width * 0.015 && abs(proposed.ty) < small.extent.height * 0.02 { throw PanoramaFailure.stationary }
        let candidates = [proposed, proposed.inverted()]
        let scored = candidates.map { ($0, error(small, reference: strip.previous, transform: $0)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 0.12,
              PanoramaPolicy.accepts(best.0, size: small.extent.size, direction: direction) else { throw PanoramaFailure.alignment }
        let scale = image.extent.width / small.extent.width
        let origin = CGPoint(x: strip.origin.x + best.0.tx * scale, y: strip.origin.y + best.0.ty * scale)
        let moved = image.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        let union = strip.bounds.union(moved.extent).integral
        guard union.width <= CGFloat(PanoramaPolicy.maximumDimension), union.height <= CGFloat(PanoramaPolicy.sourceDimension) * 1.3,
              union.width * union.height <= CGFloat(PanoramaPolicy.maximumPixels) else { throw PanoramaFailure.limit }
        let low = max(strip.commonY.minY, moved.extent.minY), high = min(strip.commonY.maxY, moved.extent.maxY)
        guard high - low >= image.extent.height * 0.8 else { throw PanoramaFailure.alignment }
        let old = CIImage(cgImage: strip.canvas).transformed(by: CGAffineTransform(translationX: strip.bounds.minX, y: strip.bounds.minY))
        let overlap = strip.bounds.intersection(moved.extent)
        let start = direction == .right ? overlap.minX : overlap.maxX
        let end = direction == .right ? overlap.maxX : overlap.minX
        guard let mask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: start, y: 0), "inputPoint1": CIVector(x: end, y: 0),
            "inputColor0": CIColor.black, "inputColor1": CIColor.white])?.outputImage else { throw PhotoEditError.render }
        let blend = moved.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: old, kCIInputMaskImageKey: mask]).cropped(to: union)
        guard let canvas = context.createCGImage(blend, from: union, format: .RGBA8, colorSpace: color) else { throw PhotoEditError.render }
        return Strip(canvas: canvas, previous: small, origin: origin, bounds: union,
            commonY: CGRect(x: 0, y: low, width: image.extent.width, height: high - low), label: strip.label, frames: strip.frames + 1)
    }

    private func error(_ image: CIImage, reference: CIImage, transform: CGAffineTransform) -> Float {
        let moved = image.transformed(by: transform)
        let overlap = reference.extent.intersection(moved.extent).insetBy(dx: 8, dy: 8)
        guard overlap.width > reference.extent.width * 0.4, overlap.height > reference.extent.height * 0.7 else { return .infinity }
        let mean = moved.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: reference])
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: overlap)])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { context.render(mean, toBitmap: $0.baseAddress!, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: color) }
        return (pixel[0] + pixel[1] + pixel[2]) / 3
    }

    private func finish() throws -> CapturedPhoto {
        guard let strip = strips.first, strip.frames >= 3,
              strip.bounds.width > strip.commonY.width * 1.2 else { throw PanoramaFailure.tooShort }
        let crop = CGRect(x: 0, y: ceil(strip.commonY.minY - strip.bounds.minY),
            width: CGFloat(strip.canvas.width), height: floor(strip.commonY.height) - 1)
        let image = CIImage(cgImage: strip.canvas)
        guard let cg = context.createCGImage(image, from: crop, format: .RGBA8, colorSpace: color) else { throw PhotoEditError.render }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw PhotoEditError.render }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.98, kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoEditError.render }
        var photo = CapturedPhoto(data: data as Data, dimensions: CMVideoDimensions(width: Int32(cg.width), height: Int32(cg.height)))
        photo.lensLabel = strip.label + " · Panorama"
        photo.warning = "Panorama beta · \(strip.frames) frames · \(cg.width) × \(cg.height). Moving subjects and close foregrounds may show seams."
        return photo
    }
}
