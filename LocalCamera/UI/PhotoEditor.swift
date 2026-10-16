import SwiftUI
import PhotosUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

struct PhotoAdjustments: Equatable {
    var exposure = 0.0, highlights = 1.0, shadows = 0.0, contrast = 1.0
    var whites = 0.0, blacks = 0.0, temperature = 6500.0, tint = 0.0
    var vibrance = 0.0, saturation = 1.0, sharpening = 0.0, noise = 0.0
    var enhance = 0.0, angle = 0.0, crop = 0.0, turns = 0
    var perspectiveX = 0.0, perspectiveY = 0.0
    var localExposure = 0.0, localX = 0.5, localY = 0.5, localRadius = 0.3
    var colorBand = 0, colorStrength = 0.0
}

enum PhotoEditError: LocalizedError {
    case unsupported, render
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Choose a still image up to 60 megapixels and 100 MB. Your original is unchanged."
        case .render: return "This image could not be rendered. Your original is unchanged."
        }
    }
}

/// Serial rendering bounds concurrent image buffers; adjustment history contains no bitmaps.
enum PhotoEditRenderer {
    private static let queue = PhotoProcessingScheduler.queue
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static func render(_ data: Data, edits: PhotoAdjustments, preview: Bool, cancellation: NightWorkCancellation) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try autoreleasepool {
                        defer { context.clearCaches() }
                        if cancellation.cancelled { throw CancellationError() }
                        let image = try decode(data, maximum: preview ? 1400 : nil)
                        let adjusted = apply(edits, to: image)
                        if cancellation.cancelled { throw CancellationError() }
                        let color = CGColorSpace(name: CGColorSpace.sRGB)!
                        guard let cg = context.createCGImage(adjusted, from: adjusted.extent.integral,
                                                            format: .RGBA8, colorSpace: color) else { throw PhotoEditError.render }
                        if cancellation.cancelled { throw CancellationError() }
                        let output = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw PhotoEditError.render }
                        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: preview ? 0.9 : 0.98,
                                                                    kCGImagePropertyOrientation: 1] as CFDictionary)
                        guard CGImageDestinationFinalize(destination) else { throw PhotoEditError.render }
                        return output as Data
                    }
                })
            }
        }
    }
    static func decode(_ data: Data, maximum: Int?) throws -> CIImage {
        guard data.count <= 100_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 60_000_000,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum ?? max(width, height),
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) else { throw PhotoEditError.unsupported }
        return CIImage(cgImage: cg)
    }
    static func apply(_ e: PhotoAdjustments, to source: CIImage) -> CIImage {
        var image = source
        if e.enhance > 0 {
            var automatic = source
            for filter in source.autoAdjustmentFilters(options: [.enhance: true, .redEye: false]) {
                filter.setValue(automatic, forKey: kCIInputImageKey)
                automatic = filter.outputImage ?? automatic
            }
            image = image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: automatic, kCIInputTimeKey: e.enhance])
        }
        image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: e.exposure])
            .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": e.highlights, "inputShadowAmount": e.shadows])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: e.contrast, kCIInputSaturationKey: e.saturation])
            .applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: e.temperature, y: e.tint)])
            .applyingFilter("CIVibrance", parameters: ["inputAmount": e.vibrance])
        if e.whites != 0 || e.blacks != 0 {
            let scale = 1 + e.whites - e.blacks
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputBiasVector": CIVector(x: e.blacks, y: e.blacks, z: e.blacks, w: 0)])
        }
        if e.colorStrength != 0 { image = selectiveColor(image, band: e.colorBand, strength: e.colorStrength) }
        if e.noise > 0 { image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": e.noise, "inputSharpness": 0.2]) }
        if e.sharpening > 0 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: e.sharpening]) }
        let bounds = image.extent
        if e.localExposure != 0 {
            let center = CIVector(x: bounds.minX + bounds.width * e.localX, y: bounds.minY + bounds.height * (1 - e.localY))
            let radius = max(bounds.width, bounds.height) * e.localRadius
            let mask = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": center, "inputRadius0": 0,
                "inputRadius1": radius, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: bounds)
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: e.localExposure])
                .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
        }
        if e.perspectiveX != 0 || e.perspectiveY != 0 {
            let x = bounds.width * abs(e.perspectiveX) * 0.15, y = bounds.height * abs(e.perspectiveY) * 0.15
            image = image.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": CIVector(x: e.perspectiveX > 0 ? x : 0, y: bounds.height - (e.perspectiveY > 0 ? y : 0)),
                "inputTopRight": CIVector(x: bounds.width - (e.perspectiveX > 0 ? x : 0), y: bounds.height - (e.perspectiveY < 0 ? y : 0)),
                "inputBottomLeft": CIVector(x: e.perspectiveX < 0 ? x : 0, y: e.perspectiveY > 0 ? y : 0),
                "inputBottomRight": CIVector(x: bounds.width - (e.perspectiveX < 0 ? x : 0), y: e.perspectiveY < 0 ? y : 0)])
        }
        if e.turns % 4 != 0 { image = image.oriented([.up, .right, .down, .left][e.turns % 4]) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if e.angle != 0 {
            let b = image.extent, radians = e.angle * .pi / 180
            let transform = CGAffineTransform(translationX: -b.midX, y: -b.midY)
                .concatenating(CGAffineTransform(rotationAngle: radians))
                .concatenating(CGAffineTransform(translationX: b.midX, y: b.midY))
            let scale = 1 / (abs(cos(radians)) + max(b.width / b.height, b.height / b.width) * abs(sin(radians)))
            let crop = CGRect(x: b.midX - b.width * scale / 2, y: b.midY - b.height * scale / 2, width: b.width * scale, height: b.height * scale)
            image = image.transformed(by: transform).cropped(to: crop)
        }
        if e.crop > 0 {
            let b = image.extent
            let ratio = b.width < b.height ? 1 / e.crop : e.crop
            let width = min(b.width, b.height * ratio), height = min(b.height, b.width / ratio)
            image = image.cropped(to: CGRect(x: b.midX - width / 2, y: b.midY - height / 2, width: width, height: height))
        }
        let integral = image.extent.insetBy(dx: 0.5, dy: 0.5).integral.intersection(image.extent)
        return image.cropped(to: integral).transformed(by: CGAffineTransform(translationX: -integral.minX, y: -integral.minY))
    }
    private static func selectiveColor(_ image: CIImage, band: Int, strength: Double) -> CIImage {
        let size = 24
        let hues = [0.0, 1.0 / 6, 1.0 / 3, 0.5, 2.0 / 3, 5.0 / 6]
        let target = hues[min(5, max(0, band))]
        var cube = [Float](); cube.reserveCapacity(size * size * size * 4)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let color = UIColor(red: CGFloat(r) / CGFloat(size - 1), green: CGFloat(g) / CGFloat(size - 1), blue: CGFloat(b) / CGFloat(size - 1), alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            let distance = min(abs(Double(h) - target), 1 - abs(Double(h) - target))
            let weight = max(0, 1 - distance / (1.0 / 6))
            let adjusted = UIColor(hue: h, saturation: min(1, max(0, s * (1 + strength * weight))), brightness: v, alpha: 1)
            var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0
            adjusted.getRed(&rr, green: &gg, blue: &bb, alpha: &a)
            cube.append(contentsOf: [Float(rr), Float(gg), Float(bb), 1])
        } } }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        return image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": size, "inputCubeData": data])
    }
}

@MainActor final class PhotoEditorModel: ObservableObject {
    @Published var edits = PhotoAdjustments() {
        didSet {
            guard edits != oldValue else { return }
            if !restoring { undoValues.append(oldValue); if undoValues.count > 60 { undoValues.removeFirst() }; redoValues = [] }
            saved = false; exportedCount = 0; updatePreview()
        }
    }
    @Published private(set) var preview: UIImage?
    @Published private(set) var original: UIImage?
    @Published private(set) var busy = false
    @Published private(set) var saved = false
    @Published private(set) var undoValues: [PhotoAdjustments] = []
    @Published private(set) var redoValues: [PhotoAdjustments] = []
    @Published var message: String?
    private var sources: [Data] = []
    private var exportedCount = 0
    private var restoring = false
    private var work: NightWorkCancellation?
    private var previewTask: Task<Void, Never>?
    private var revision = 0
    var loaded: Bool { !sources.isEmpty }
    var count: Int { sources.count }
    func load(_ data: [Data]) async {
        guard !busy else { return }
        suspend(); busy = true; message = nil; preview = nil; original = nil
        sources = []; restoring = true; edits = PhotoAdjustments(); restoring = false
        undoValues = []; redoValues = []; saved = false; exportedCount = 0
        let token = NightWorkCancellation(); work = token
        do {
            guard let first = data.first, data.count <= 2, data.allSatisfy({ $0.count <= 100_000_000 }) else { throw PhotoEditError.unsupported }
            let rendered = try await PhotoEditRenderer.render(first, edits: edits, preview: true, cancellation: token)
            guard !token.cancelled else { throw CancellationError() }
            original = UIImage(data: rendered); preview = original; sources = data
        } catch { message = error is CancellationError ? "Editing paused. Choose the photo again." : error.localizedDescription }
        busy = false
    }
    func undo() {
        guard let previous = undoValues.popLast() else { return }
        redoValues.append(edits); restoring = true; edits = previous; restoring = false
    }
    func redo() {
        guard let next = redoValues.popLast() else { return }
        undoValues.append(edits); restoring = true; edits = next; restoring = false
    }
    func suspend() { revision += 1; work?.cancel(); previewTask?.cancel(); previewTask = nil }
    func resume() { if loaded && !busy { updatePreview() } }
    private func updatePreview() {
        suspend()
        guard let source = sources.first, !busy else { return }
        let value = edits, id = revision, token = NightWorkCancellation(); work = token
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let rendered = try await PhotoEditRenderer.render(source, edits: value, preview: true, cancellation: token)
                guard let self, self.revision == id, !token.cancelled else { return }
                self.preview = UIImage(data: rendered)
            } catch is CancellationError {} catch { if self?.revision == id { self?.message = error.localizedDescription } }
        }
    }
    func save() async {
        guard loaded, !busy else { return }
        suspend(); busy = true; message = "Rendering full-resolution copies…"
        let value = edits, token = NightWorkCancellation(); work = token
        var completed = exportedCount
        do {
            for source in sources.dropFirst(exportedCount) {
                let data = try await PhotoEditRenderer.render(source, edits: value, preview: false, cancellation: token)
                guard !token.cancelled else { throw CancellationError() }
                guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw PhotoEditError.render }
                try await PhotoLibrarySaver().save(CapturedPhoto(data: data, dimensions: CMVideoDimensions(width: Int32(width), height: Int32(height))))
                completed += 1; exportedCount = completed
            }
            saved = true; message = "Saved \(completed) edited \(completed == 1 ? "copy" : "copies"). Originals unchanged."
        } catch { message = "Saved \(completed) of \(sources.count). \(error is CancellationError ? "Export paused." : error.localizedDescription) Originals unchanged." }
        busy = false
    }
}

struct PhotoEditorView: View {
    let initialPhotos: [Data]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PhotoEditorModel()
    @State private var selection: PhotosPickerItem?
    @State private var category = "Light"
    @State private var tool = "Exposure"
    @State private var compare = false
    @State private var confirmClose = false
    private let categories = ["Crop", "Light", "Color", "Detail", "Local"]
    private var tools: [String] {
        switch category {
        case "Crop": return ["Aspect", "Straighten", "Vertical", "Horizontal"]
        case "Color": return ["Temperature", "Tint", "Vibrance", "Saturation", "Color range"]
        case "Detail": return ["Sharpen", "Noise"]
        case "Local": return ["Brightness", "Position X", "Position Y", "Size"]
        default: return ["Exposure", "Highlights", "Shadows", "Contrast", "Whites", "Blacks", "Auto Enhance"]
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if let photo = compare ? model.original : model.preview {
                    Image(uiImage: photo).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(compare ? "Original photo" : "Edited preview")
                } else { ContentUnavailableView("Photo editor", systemImage: "slider.horizontal.3", description: Text("Improve light, color and detail on this iPhone.")) }
                if model.loaded {
                    HStack {
                        Button("Undo", systemImage: "arrow.uturn.backward", action: model.undo).disabled(model.undoValues.isEmpty)
                        Button("Redo", systemImage: "arrow.uturn.forward", action: model.redo).disabled(model.redoValues.isEmpty)
                        Spacer()
                        Toggle("Before", isOn: $compare).toggleStyle(.button)
                    }.font(.caption).disabled(model.busy)
                    Picker("Category", selection: $category) { ForEach(categories, id: \.self) { Text($0) } }.pickerStyle(.segmented)
                        .onChange(of: category) { _, _ in tool = tools[0] }
                    HStack {
                        Picker("Adjustment", selection: $tool) { ForEach(tools, id: \.self) { Text($0) } }.pickerStyle(.menu)
                        Spacer()
                        if category == "Crop" { Button("Rotate", systemImage: "rotate.right") { model.edits.turns = (model.edits.turns + 1) % 4 } }
                        Button("Reset") { model.edits = PhotoAdjustments() }
                    }
                    adjustment.frame(minHeight: 58)
                    if category == "Local" { Text("A feathered circular adjustment. Position is measured before crop and rotation.").font(.caption2) }
                    Text("Full-resolution JPEG copies · sRGB · no location metadata. Crop reduces dimensions. RAW/HDR originals stay unchanged.").font(.caption2).foregroundStyle(.secondary)
                    Button(model.saved ? "Copies saved" : model.count == 2 ? "Save both copies" : "Save a copy") { Task { await model.save() } }
                        .buttonStyle(.borderedProminent).disabled(model.busy || model.saved)
                }
                PhotosPicker(selection: $selection, matching: .images) { Label(model.loaded ? "Choose another photo" : "Choose a photo", systemImage: "photo") }.disabled(model.busy)
                if model.busy { ProgressView("Working on this iPhone") }
                if let message = model.message { Text(message).font(.caption).accessibilityAddTraits(.updatesFrequently) }
            }.padding(12).background(.black).foregroundStyle(.white).disabled(model.busy)
                .navigationTitle("Edit photo").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { if model.loaded && !model.saved && model.edits != PhotoAdjustments() { confirmClose = true } else { dismiss() } }.disabled(model.busy)
                } }
                .confirmationDialog("Discard unsaved adjustments?", isPresented: $confirmClose) {
                    Button("Discard adjustments", role: .destructive) { dismiss() }
                }
                .task { if !initialPhotos.isEmpty { await model.load(initialPhotos) } }
                .task(id: selection) {
                    guard let selection else { return }
                    do { if let data = try await selection.loadTransferable(type: Data.self) { try Task.checkCancellation(); await model.load([data]) } }
                    catch { model.message = error.localizedDescription }
                }
                .interactiveDismissDisabled(model.busy || (model.loaded && !model.saved && model.edits != PhotoAdjustments()))
                .onDisappear { model.suspend() }
                .onChange(of: scenePhase) { _, phase in if phase != .active { model.suspend() } else { model.resume() } }
                .tint(CameraAppearance.selection).preferredColorScheme(.dark)
        }
    }
    @ViewBuilder private var adjustment: some View {
        if tool == "Aspect" {
            Picker("Crop aspect", selection: $model.edits.crop) {
                Text("Original").tag(0.0); Text("Square").tag(1.0); Text("4:3").tag(4.0 / 3); Text("3:2").tag(1.5); Text("16:9").tag(16.0 / 9)
            }.pickerStyle(.segmented)
        } else if tool == "Color range" {
            VStack {
                Picker("Color", selection: $model.edits.colorBand) {
                    ForEach(Array(["Red", "Yellow", "Green", "Cyan", "Blue", "Magenta"].enumerated()), id: \.offset) { index, name in Text(name).tag(index) }
                }.pickerStyle(.menu)
                slider(\PhotoAdjustments.colorStrength, -1...1)
            }
        } else {
            switch tool {
            case "Exposure": slider(\.exposure, -3...3)
            case "Highlights": slider(\.highlights, 0...1)
            case "Shadows": slider(\.shadows, -1...1)
            case "Contrast": slider(\.contrast, 0.5...1.5)
            case "Whites": slider(\.whites, -0.2...0.2)
            case "Blacks": slider(\.blacks, -0.2...0.2)
            case "Temperature": slider(\.temperature, 2500...10000)
            case "Tint": slider(\.tint, -100...100)
            case "Vibrance": slider(\.vibrance, -1...1)
            case "Saturation": slider(\.saturation, 0...2)
            case "Sharpen": slider(\.sharpening, 0...1)
            case "Noise": slider(\.noise, 0...0.08)
            case "Straighten": slider(\.angle, -15...15)
            case "Vertical": slider(\.perspectiveX, -1...1)
            case "Horizontal": slider(\.perspectiveY, -1...1)
            case "Brightness": slider(\.localExposure, -2...2)
            case "Position X": slider(\.localX, 0...1)
            case "Position Y": slider(\.localY, 0...1)
            case "Size": slider(\.localRadius, 0.05...1)
            default: slider(\.enhance, 0...1)
            }
        }
    }
    private func slider(_ key: WritableKeyPath<PhotoAdjustments, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%.2f", model.edits[keyPath: key])).font(.caption.monospacedDigit())
            Slider(value: Binding(get: { model.edits[keyPath: key] }, set: { model.edits[keyPath: key] = $0; compare = false }), in: range)
                .accessibilityLabel(tool).disabled(model.busy)
        }
    }
}
