import XCTest
import AVFoundation
import UIKit
@testable import LocalCamera

final class CaptureStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        root = nil
    }
    private func photo(_ label: String = "Main", bytes: [UInt8] = [1, 2, 3]) -> CapturedPhoto {
        CapturedPhoto(data: Data(bytes), dimensions: CMVideoDimensions(width: 4032, height: 3024), lensLabel: label)
    }
    func testPairedCaptureSurvivesStoreRecreation() async throws {
        var first = photo()
        first.companions = [photo("Ultra Wide", bytes: [4, 5, 6])]
        first.warning = "Keep both frames"
        try await CaptureStore(root: root).stage(first)
        let restored = try await CaptureStore(root: root).load("pending.plist")
        XCTAssertEqual(restored?.photos.map(\.data), [Data([1, 2, 3]), Data([4, 5, 6])])
        XCTAssertEqual(restored?.photos.map(\.label), ["Main", "Ultra Wide"])
        XCTAssertEqual(restored?.captured?.companions.first?.dimensions.width, 4032)
        XCTAssertEqual(restored?.warning, first.warning)
        XCTAssertEqual(restored?.saved, false)
    }
    func testFinishMovesCaptureToRecentWithoutPendingRetry() async throws {
        let store = CaptureStore(root: root)
        try await store.stage(photo())
        let finished = try await store.finish(thumbnail: Data([7]))
        let pending = try await store.load("pending.plist")
        let recent = try await CaptureStore(root: root).load("recent.plist")
        XCTAssertNil(pending)
        XCTAssertEqual(finished?.saved, true)
        XCTAssertEqual(recent?.thumbnail, Data([7]))
        XCTAssertEqual(recent?.photos.first?.data, Data([1, 2, 3]))
    }
    func testRecentCacheFailureRetainsSavedMarker() async throws {
        let store = CaptureStore(root: root)
        try await store.stage(photo())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recent.plist"), withIntermediateDirectories: false)
        do { _ = try await store.finish(thumbnail: nil); XCTFail("Expected cache write failure") }
        catch { }
        let pending = try await CaptureStore(root: root).load("pending.plist")
        XCTAssertEqual(pending?.saved, true)
        XCTAssertEqual(pending?.photos.first?.data, Data([1, 2, 3]))
    }
    func testCorruptRecoveryIsNotSilentlyDiscarded() async throws {
        let file = root.appendingPathComponent("pending.plist")
        let invalid = Data("invalid capture journal".utf8)
        try invalid.write(to: file)
        do { _ = try await CaptureStore(root: root).load("pending.plist"); XCTFail("Expected decoding failure") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }
    func testClearingRecentKeepsUnsavedCapture() async throws {
        let store = CaptureStore(root: root)
        try await store.stage(photo())
        _ = try await store.finish(thumbnail: nil)
        try await store.stage(photo("Next", bytes: [9]))
        try await store.clearRecent()
        let recent = try await store.load("recent.plist")
        let pending = try await store.load("pending.plist")
        XCTAssertNil(recent)
        XCTAssertEqual(pending?.photos.first?.data, Data([9]))
    }
    func testVideoCopySurvivesSourceRemovalAndCanBeRetried() async throws {
        let source = root.appendingPathComponent("original.mov")
        let data = Data([10, 20, 30])
        try data.write(to: source)
        let store = CaptureStore(root: root)
        let protected = try await store.stageVideo(source)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: protected), data)
        let retried = try await store.stageVideo(protected)
        XCTAssertEqual(retried, protected)
        let restored = try await CaptureStore(root: root).load("pending.plist")
        XCTAssertEqual(restored?.isVideo, true)
    }
    func testMissingVideoDoesNotReplacePhotoRecovery() async throws {
        let store = CaptureStore(root: root)
        try await store.stage(photo())
        do { _ = try await store.stageVideo(root.appendingPathComponent("missing.mov")); XCTFail("Expected missing file") }
        catch { }
        let pending = try await store.load("pending.plist")
        XCTAssertEqual(pending?.photos.first?.data, Data([1, 2, 3]))
    }
    func testPreviewDecoderBoundsPixelsAndPreservesOrientation() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let rotated = UIImage(cgImage: try XCTUnwrap(image.cgImage), scale: 1, orientation: .right)
        let data = try XCTUnwrap(rotated.jpegData(compressionQuality: 0.9))
        let decoded = await CapturePreviewDecoder.image(data, maxSize: 200)
        let preview = try XCTUnwrap(decoded)
        XCTAssertLessThanOrEqual(max(preview.size.width, preview.size.height), 200)
        XCTAssertGreaterThan(preview.size.height, preview.size.width)
        let invalid = await CapturePreviewDecoder.image(Data([0]), maxSize: 200)
        XCTAssertNil(invalid)
    }
    func testDualCaptureRejectsOversizedOnlyFormats() {
        let huge = CMVideoDimensions(width: 8064, height: 6048)
        XCTAssertNil(DualCaptureLimits.photoSize(in: [huge]))
        XCTAssertFalse(DualCaptureLimits.accepts(huge, supported: [huge]))
    }
    func testDualCaptureRequiresExactSupportedDimensions() {
        let small = CMVideoDimensions(width: 1920, height: 1080)
        let native = CMVideoDimensions(width: 4032, height: 3024)
        let huge = CMVideoDimensions(width: 8064, height: 6048)
        XCTAssertEqual(DualCaptureLimits.photoSize(in: [huge, small, native])?.width, 4032)
        XCTAssertTrue(DualCaptureLimits.accepts(native, supported: [small, native]))
        XCTAssertFalse(DualCaptureLimits.accepts(native, supported: [small]))
        XCTAssertNil(DualCaptureLimits.photoSize(in: [CMVideoDimensions(width: 0, height: 3024)]))
    }
    func testPreviewRejectsInvalidTransitionGeometry() {
        XCTAssertFalse(PreviewGeometry.isValid(.null))
        XCTAssertFalse(PreviewGeometry.isValid(.infinite))
        XCTAssertFalse(PreviewGeometry.isValid(.zero))
        XCTAssertFalse(PreviewGeometry.isValid(CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)))
        XCTAssertFalse(PreviewGeometry.isValid(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)))
        XCTAssertTrue(PreviewGeometry.isValid(CGRect(x: 0, y: 20, width: 390, height: 520)))
    }

    func testDetailAllowsSupported48MPButRejectsLargerAndUnsupportedSizes() {
        let native = CMVideoDimensions(width: 8064, height: 6048)
        let tooLarge = CMVideoDimensions(width: 10000, height: 10000)
        XCTAssertTrue(DualCaptureLimits.accepts(native, supported: [native], mode: .detail))
        XCTAssertFalse(DualCaptureLimits.accepts(native, supported: [], mode: .detail))
        XCTAssertNil(DualCaptureLimits.photoSize(in: [tooLarge], mode: .detail))
        XCTAssertNil(DualCaptureLimits.photoSize(in: [native], mode: .fast))
    }
    func testDetailStartsOnlyMainAndSchedulesUltraAfterMainFinishes() {
        XCTAssertEqual(DualShotMode.detail.initialCaptureIndices, [0])
        XCTAssertEqual(DualShotMode.detail.nextCaptureIndex(after: 0), 1)
        XCTAssertNil(DualShotMode.detail.nextCaptureIndex(after: 1))
        XCTAssertEqual(DualShotMode.fast.initialCaptureIndices, [0, 1])
        XCTAssertNil(DualShotMode.fast.nextCaptureIndex(after: 0))
        XCTAssertNil(DualShotMode.fast.nextCaptureIndex(after: 1))
    }

    func testFocusWaitRestartsAfterLensMovesAgain() {
        var window = FocusSettlingWindow(startedAt: 0)
        XCTAssertEqual(window.update(adjusting: false, now: 0), .wait)
        XCTAssertEqual(window.update(adjusting: true, now: 0.08), .wait)
        XCTAssertEqual(window.update(adjusting: false, now: 0.12), .wait)
        XCTAssertEqual(window.update(adjusting: false, now: 0.18), .wait)
        XCTAssertEqual(window.update(adjusting: false, now: 0.23), .ready)
    }
    func testFocusHuntingHasBoundedWait() {
        var window = FocusSettlingWindow(startedAt: 5)
        XCTAssertEqual(window.update(adjusting: true, now: 5.9), .wait)
        XCTAssertEqual(window.update(adjusting: true, now: 6), .timedOut)
    }

}
