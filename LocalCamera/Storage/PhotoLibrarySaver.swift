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
        let data: Data
        let width: Int32
        let height: Int32
        let label: String
        init(_ photo: CapturedPhoto, index: Int) {
            data = photo.data; width = photo.dimensions.width; height = photo.dimensions.height
            label = photo.lensLabel ?? "Photo \(index + 1)"
        }
        var captured: CapturedPhoto {
            CapturedPhoto(data: data, dimensions: CMVideoDimensions(width: width, height: height), lensLabel: label)
        }
    }
    struct Record: Codable {
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
    func load(_ name: String) throws -> Record? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try PropertyListDecoder().decode(Record.self, from: Data(contentsOf: url))
    }
    func stage(_ photo: CapturedPhoto) throws {
        let photos = ([photo] + photo.companions).enumerated().map { Photo($0.element, index: $0.offset) }
        try write(Record(photos: photos, warning: photo.warning), name: "pending.plist")
    }
    func stageVideo(_ source: URL) throws -> URL {
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
        try write(Record(photos: [], videoName: "pending.mov"), name: "pending.plist")
        return destination
    }
    func videoURL() -> URL { root.appendingPathComponent("pending.mov") }
    func finish(thumbnail: Data?) throws -> Record? {
        guard var record = try load("pending.plist") else { return nil }
        record.saved = true
        record.thumbnail = thumbnail
        // Mark saved before touching the optional recent cache, avoiding a duplicate retry.
        try write(record, name: "pending.plist")
        try write(record, name: "recent.plist")
        try discard()
        return record
    }
    func discard() throws {
        for name in ["pending.plist", "pending.mov", "copy.mov"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    func clearRecent() throws {
        let url = root.appendingPathComponent("recent.plist")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
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
