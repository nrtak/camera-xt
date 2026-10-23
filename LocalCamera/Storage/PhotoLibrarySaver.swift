import Photos
import AVFoundation
import UIKit

protocol PhotoSaving {
    func save(_ photo: CapturedPhoto) async throws
    func saveVideo(_ url: URL) async throws
}

struct PhotoLibrarySaver: PhotoSaving {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Allow Add Photos access in Settings, then tap Retry save."
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

/// One recoverable capture and one recent capture, stored locally without cloud backup.
actor CaptureStore {
    struct Photo: Codable {
        var data: Data
        var fileName: String?
        let width: Int32
        let height: Int32
        let label: String
        let details: CaptureDetails?
        init(_ photo: CapturedPhoto, index: Int) {
            data = photo.data; width = photo.dimensions.width; height = photo.dimensions.height
            details = photo.details
            label = photo.lensLabel ?? "Photo \(index + 1)"
        }
        var captured: CapturedPhoto {
            CapturedPhoto(data: data, dimensions: CMVideoDimensions(width: width, height: height), lensLabel: label, details: details)
        }
    }
    struct Record: Codable {
        var captureID: String?
        var saveAttempted: Bool?
        var photos: [Photo]
        var videoName: String?
        var thumbnail: Data?
        var warning: String?
        var saved = false
        var date = Date()
        var isVideo: Bool { videoName != nil }
        var captured: CapturedPhoto? {
            guard var first = photos.first?.captured else { return nil }
            first.companions = photos.dropFirst().map(\.captured)
            first.warning = warning
            return first
        }
    }
    private let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CaptureRecovery", isDirectory: true)) {
        self.root = root
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private func write(_ record: Record, name: String) throws {
        try prepare()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(record).write(to: root.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private struct SaveReceipt: Codable {
        let captureID: String
        let saved: Bool
    }
    func load(_ name: String, includingPhotos: Bool = true) throws -> Record? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var record = try PropertyListDecoder().decode(Record.self, from: Data(contentsOf: url))
        let receiptURL = root.appendingPathComponent("save-receipt.plist")
        if name == "pending.plist", FileManager.default.fileExists(atPath: receiptURL.path) {
            let receipt = try PropertyListDecoder().decode(SaveReceipt.self, from: Data(contentsOf: receiptURL))
            if receipt.captureID == record.captureID {
                record.saved = record.saved || receipt.saved
                record.saveAttempted = true
            }
        }
        for index in record.photos.indices {
            if includingPhotos, let file = record.photos[index].fileName {
                guard validPhotoName(file) else { throw CocoaError(.fileReadCorruptFile) }
                record.photos[index].data = try Data(contentsOf: root.appendingPathComponent(file), options: .mappedIfSafe)
            } else if !includingPhotos { record.photos[index].data = Data() }
        }
        return record
    }
    func stage(_ photo: CapturedPhoto) throws {
        try prepare()
        let id = UUID().uuidString
        var photos = ([photo] + photo.companions).enumerated().map { Photo($0.element, index: $0.offset) }
        var written: [URL] = []
        do {
            for index in photos.indices {
                let name = "\(id)-\(index).photo"
                let url = root.appendingPathComponent(name)
                try photos[index].data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                written.append(url)
                photos[index].data = Data(); photos[index].fileName = name
            }
            try write(Record(captureID: id, photos: photos, warning: photo.warning), name: "pending.plist")
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        cleanupPhotoFiles()
    }
    func stageVideo(_ source: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else { throw CocoaError(.fileReadNoSuchFile) }
        try prepare()
        let destination = root.appendingPathComponent("pending.mov")
        if source.standardizedFileURL != destination.standardizedFileURL {
            // Commit the movie before the journal; an interrupted copy never replaces the source.
            let temporary = root.appendingPathComponent("copy.mov")
            try? FileManager.default.removeItem(at: temporary)
            try FileManager.default.copyItem(at: source, to: temporary)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        }
        try write(Record(captureID: UUID().uuidString, photos: [], videoName: "pending.mov"), name: "pending.plist")
        return destination
    }
    func videoURL() throws -> URL {
        let url = root.appendingPathComponent("pending.mov")
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        return url
    }
    func finish(thumbnail: Data?) throws -> Record? {
        guard var record = try load("pending.plist", includingPhotos: false) else { return nil }
        // Legacy journals embed originals. Preserve them when finishing an older recovery.
        if record.photos.contains(where: { $0.fileName == nil }), let full = try load("pending.plist") { record = full }
        record.saved = true
        record.thumbnail = thumbnail
        // Mark saved before touching the optional recent cache, avoiding a duplicate retry.
        try write(record, name: "pending.plist")
        try write(record, name: "recent.plist")
        try discard()
        return record
    }
    func beginSave() throws {
        guard var record = try load("pending.plist", includingPhotos: false) else { throw CocoaError(.fileReadNoSuchFile) }
        if record.captureID == nil {
            guard let full = try load("pending.plist") else { throw CocoaError(.fileReadNoSuchFile) }
            record = full; record.captureID = UUID().uuidString
            try write(record, name: "pending.plist")
        }
        guard let id = record.captureID else { throw CocoaError(.fileReadCorruptFile) }
        try writeReceipt(id: id, saved: false)
    }
    func markSaved() throws {
        guard let id = try load("pending.plist", includingPhotos: false)?.captureID else { throw CocoaError(.fileReadNoSuchFile) }
        try writeReceipt(id: id, saved: true)
    }
    private func writeReceipt(id: String, saved: Bool) throws {
        try prepare()
        try PropertyListEncoder().encode(SaveReceipt(captureID: id, saved: saved)).write(
            to: root.appendingPathComponent("save-receipt.plist"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func validPhotoName(_ name: String) -> Bool {
        name.hasSuffix(".photo") && !name.contains("/") && !name.contains("\\") && !name.contains("..")
    }
    private func cleanupPhotoFiles() {
        // Never delete images if either journal cannot be read.
        do {
            let records = try [load("pending.plist", includingPhotos: false), load("recent.plist", includingPhotos: false)].compactMap { $0 }
            let keep = Set(records.flatMap { $0.photos.compactMap(\.fileName) })
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where validPhotoName(url.lastPathComponent) && !keep.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        } catch { }
    }
    func discard() throws {
        for name in ["pending.plist", "pending.mov", "copy.mov", "save-receipt.plist"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        cleanupPhotoFiles()
    }
    func clearRecent() throws {
        let url = root.appendingPathComponent("recent.plist")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        cleanupPhotoFiles()
    }
    func availableBytes() -> Int64? {
        try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }
    static func videoThumbnail(_ url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8)
    }
}
