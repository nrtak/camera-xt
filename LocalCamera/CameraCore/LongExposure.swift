import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

enum LongExposureStyle: String, CaseIterable {
    case sky = "Sky stack", trails = "Star Trails", motion = "Smooth Motion"
    var explanation: String {
        switch self {
        case .sky: return "Beta: aligns small shifts and averages frames. Use a tripod and a dark, still sky. Field rotation and moving foregrounds are not corrected."
        case .trails: return "Combines bright pixels across the sequence. Use a fixed tripod. Gaps between still captures may appear in trails. Longer sessions reveal more star movement."
        case .motion: return "Averages a sequence for smoother water and movement. Use a tripod; moving people may appear translucent."
        }
    }
}

enum LongExposureLimits {
    static let diskBytes = 256_000_000
    static let frameCount = 90
    static func duration(_ value: Double) -> Double { value.isFinite ? min(300, max(15, value)) : 30 }
}

/// Reads a single source frame at a time and materializes each blend to avoid an ever-growing image graph.
enum LongExposureRenderer {
    private static let queue = DispatchQueue(label: "CameraXT.longExposure", qos: .userInitiated)
    static func process(_ files: [URL], style: LongExposureStyle, cancellation: NightWorkCancellation) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try autoreleasepool {
                        guard files.count >= 2, !cancellation.cancelled else { throw CancellationError() }
                        let context = CIContext(options: [.cacheIntermediates: false,
                            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
                        defer { context.clearCaches() }
                        let first = try Data(contentsOf: files[0], options: .mappedIfSafe)
                        let base = try PhotoEditRenderer.decode(first, maximum: 4096)
                        let smallBase = try PhotoEditRenderer.decode(first, maximum: 512)
                        let bounds = base.extent, color = CGColorSpace(name: CGColorSpace.sRGB)!
                        var accumulation = base, accepted = 1
                        for file in files.dropFirst() {
                            if cancellation.cancelled { throw CancellationError() }
                            let next: CIImage? = try autoreleasepool {
                                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                                var image = try PhotoEditRenderer.decode(data, maximum: 4096)
                                guard image.extent.size == bounds.size else { return nil }
                                if style == .sky {
                                    let small = try PhotoEditRenderer.decode(data, maximum: 512)
                                    let request = VNTranslationalImageRegistrationRequest(targetedCIImage: small, options: [:])
                                    try VNImageRequestHandler(ciImage: smallBase, options: [:]).perform([request])
                                    guard let observation = request.results?.first, observation.confidence >= 0.5 else { return nil }
                                    let t = observation.alignmentTransform
                                    guard t.tx.isFinite, t.ty.isFinite, abs(t.tx) < small.extent.width * 0.03,
                                          abs(t.ty) < small.extent.height * 0.03 else { return nil }
                                    let scale = bounds.width / small.extent.width
                                    image = image.transformed(by: CGAffineTransform(translationX: t.tx * scale, y: t.ty * scale))
                                        .cropped(to: bounds).composited(over: base).cropped(to: bounds)
                                }
                                let blend: CIImage
                                if style == .trails {
                                    blend = image.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: accumulation])
                                } else {
                                    blend = accumulation.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image,
                                                                                                        kCIInputTimeKey: 1.0 / Double(accepted + 1)])
                                }
                                guard let cg = context.createCGImage(blend, from: bounds, format: .RGBA8, colorSpace: color) else { throw PhotoEditError.render }
                                return CIImage(cgImage: cg)
                            }
                            if let next { accumulation = next; accepted += 1 }
                        }
                        guard accepted >= 2, !cancellation.cancelled else { throw PhotoEditError.render }
                        guard let cg = context.createCGImage(accumulation, from: bounds, format: .RGBA8, colorSpace: color) else { throw PhotoEditError.render }
                        let data = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw PhotoEditError.render }
                        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.98,
                                                                    kCGImagePropertyOrientation: 1] as CFDictionary)
                        guard CGImageDestinationFinalize(destination) else { throw PhotoEditError.render }
                        var photo = CapturedPhoto(data: data as Data, dimensions: CMVideoDimensions(width: Int32(cg.width), height: Int32(cg.height)))
                        photo.lensLabel = "\(style.rawValue) · \(accepted) frames"
                        photo.warning = "Combined \(accepted) of \(files.count) frames. Reference original saved separately."
                        return photo
                    }
                })
            }
        }
    }
}
