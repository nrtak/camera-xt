import XCTest
import AVFoundation
import UIKit
@testable import LocalCamera

final class CaptureStoreTests: XCTestCase {
    func testSceneAdviceRejectsInvalidReadingsAndDoesNotSuggestNightInBrightLight() {
        XCTAssertNil(SceneAdvice.text(shutter: .nan, iso: 100, dual: true, night: false))
        XCTAssertNil(SceneAdvice.text(shutter: 0, iso: 100, dual: false, night: false))
        XCTAssertNil(SceneAdvice.text(shutter: 1.0 / 500, iso: 100, dual: false, night: false))
        XCTAssertNotNil(SceneAdvice.text(shutter: 1.0 / 15, iso: 100, dual: true, night: false))
        XCTAssertNotNil(SceneAdvice.text(shutter: 1.0 / 125, iso: 1600, dual: false, night: false))
    }

    func testNightComparisonPrefersDifferentLensesBeforeReferenceOriginals() {
        XCTAssertEqual(RecentComparison.secondIndex(labels: ["Main · Night 3 frames", "Main · Reference", "Ultra Wide · Night 3 frames", "Ultra Wide · Reference"]), 2)
        XCTAssertEqual(RecentComparison.secondIndex(labels: ["Main · Night 3 frames", "Main · Reference"]), 1)
        XCTAssertEqual(RecentComparison.secondIndex(labels: []), 0)
    }

    func testRepeatedPairsLeaveOnlyLatestRecentAndNoPendingCapture() async throws {
        let store = CaptureStore(root: root)
        for value in UInt8(0)..<20 {
            var pair = photo("Main", bytes: [value])
            pair.companions = [photo("Ultra Wide", bytes: [value, 1])]
            try await store.stage(pair)
            _ = try await store.finish(thumbnail: nil)
            let pending = try await store.load("pending.plist")
            XCTAssertNil(pending)
        }
        let recent = try await CaptureStore(root: root).load("recent.plist")
        XCTAssertEqual(recent?.photos.map(\.data), [Data([19]), Data([19, 1])])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["recent.plist"])
    }

    func testEyeFocusCoordinatesReturnToSensorSpaceForEveryOrientation() {
        // Same off-center sensor location viewed with each supported rotation.
        let samples: [(AVCaptureVideoOrientation, CGPoint)] = [
            (.landscapeRight, CGPoint(x: 0.2, y: 0.7)),
            (.landscapeLeft, CGPoint(x: 0.8, y: 0.3)),
            (.portrait, CGPoint(x: 0.7, y: 0.8)),
            (.portraitUpsideDown, CGPoint(x: 0.3, y: 0.2))
        ]
        for (orientation, eye) in samples {
            let point = CameraOrientation.sensorPoint(x: eye.x, y: eye.y, orientation: orientation)
            XCTAssertEqual(point.x, 0.2, accuracy: 0.0001)
            XCTAssertEqual(point.y, 0.3, accuracy: 0.0001)
        }
    }

    func testInterfaceOrientationKeepsLandscapeDirectionsAndUnknownUsesPortrait() {
        XCTAssertEqual(CameraOrientation.capture(.landscapeLeft), .landscapeLeft)
        XCTAssertEqual(CameraOrientation.capture(.landscapeRight), .landscapeRight)
        XCTAssertEqual(CameraOrientation.capture(.unknown), .portrait)
    }

    func testPhotoRescueStopsBeforeDecodingWhenCancelled() async {
        let work = NightWorkCancellation(); work.cancel()
        do {
            _ = try await PhotoRescueProcessor.process(Data([1]), strength: 0.5, cancellation: work)
            XCTFail("Cancelled processing must not continue")
        } catch is CancellationError { }
        catch { XCTFail("Expected cancellation, received \(error)") }
    }
    func testLaunchDefaultsResetCameraSettingsButPreservePolicyAndOtherData() throws {
        let name = "CameraXT.launch-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: CameraLaunchPreferences.policyKey)
        defaults.set(true, forKey: "camera.showsGrid")
        defaults.set(Data([1, 2]), forKey: CameraLaunchPreferences.setupKey)
        defaults.set("keep", forKey: "unrelated")
        CameraLaunchPreferences.prepare(defaults)
        XCTAssertNil(defaults.object(forKey: "camera.showsGrid"))
        XCTAssertNil(defaults.data(forKey: CameraLaunchPreferences.setupKey))
        XCTAssertEqual(defaults.object(forKey: CameraLaunchPreferences.policyKey) as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }
    func testRememberPolicyPreservesSettings() throws {
        let name = "CameraXT.remember-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: CameraLaunchPreferences.policyKey)
        defaults.set("Night", forKey: "camera.testStyle")
        CameraLaunchPreferences.prepare(defaults)
        XCTAssertEqual(defaults.string(forKey: "camera.testStyle"), "Night")
    }
    func testManualControlsRoundTripIncludesFlash() throws {
        var controls = CameraControls()
        controls.automaticExposure = false; controls.iso = 640; controls.shutterSeconds = 0.02
        controls.automaticFocus = false; controls.lensPosition = 0.7
        controls.automaticWhiteBalance = false; controls.temperature = 4200
        controls.flash = .auto
        let decoded = try JSONDecoder().decode(CameraControls.self, from: JSONEncoder().encode(controls))
        XCTAssertEqual(decoded, controls)
        XCTAssertEqual(decoded.flash, .auto)
    }
    func testNightDimensionsRespectBothMemoryAndOutputLimits() {
        let small = CMVideoDimensions(width: 4032, height: 3024)
        let large = CMVideoDimensions(width: 8064, height: 6048)
        let choice = NightCapturePolicy.photoSize([large, small], maximum: large)
        XCTAssertEqual(choice?.width, small.width)
        XCTAssertNil(NightCapturePolicy.photoSize([large], maximum: large))
        XCTAssertNil(NightCapturePolicy.photoSize([small], maximum: CMVideoDimensions(width: 1920, height: 1080)))
    }
    func testNightRejectsMotionAndInvalidMeasurements() {
        XCTAssertTrue(NightCapturePolicy.acceptsMotion(meanDifference: 0.01, changedFraction: 0.01))
        XCTAssertFalse(NightCapturePolicy.acceptsMotion(meanDifference: 0.05, changedFraction: 0))
        XCTAssertFalse(NightCapturePolicy.acceptsMotion(meanDifference: 0.01, changedFraction: 0.10))
        XCTAssertFalse(NightCapturePolicy.acceptsMotion(meanDifference: .nan, changedFraction: 0))
        XCTAssertFalse(NightCapturePolicy.acceptsMotion(meanDifference: 0, changedFraction: -.infinity))
    }
    func testCancelledNightPreservesBothLensOriginals() async throws {
        let main = CapturedPhoto(data: Data([1]), dimensions: CMVideoDimensions(width: 1, height: 1), lensLabel: "Main")
        let wide = CapturedPhoto(data: Data([2]), dimensions: CMVideoDimensions(width: 1, height: 1), lensLabel: "Ultra Wide")
        let cancellation = NightWorkCancellation(); cancellation.cancel()
        let result = await NightPhotoProcessor.process([main, wide, main, wide], cancellation: cancellation)
        let photo = try XCTUnwrap(result)
        XCTAssertEqual(photo.data, main.data)
        XCTAssertEqual(photo.companions.count, 1)
        XCTAssertEqual(photo.companions.first?.data, wide.data)
        XCTAssertTrue(photo.warning?.contains("original") == true)
    }
    @MainActor func testNightMergesMatchingFramesAndRetainsReference() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { renderer in
            for y in 0..<32 {
                for x in 0..<32 {
                    let horizontal: Int = x * 73
                    let vertical: Int = y * 131
                    let mixed: Int = x * y * 17
                    let value: Int = (horizontal + vertical + mixed) % 200 + 20
                    let shade: CGFloat = CGFloat(value) / 255.0
                    UIColor(white: shade, alpha: 1).setFill()
                    renderer.fill(CGRect(x: x * 8, y: y * 8, width: 8, height: 8))
                }
            }
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.98))
        let frame = CapturedPhoto(data: data, dimensions: CMVideoDimensions(width: 256, height: 256), lensLabel: "Main")
        let result = await NightPhotoProcessor.process([frame, frame, frame], cancellation: NightWorkCancellation())
        let photo = try XCTUnwrap(result)
        XCTAssertEqual(photo.dimensions.width, 256)
        XCTAssertEqual(photo.companions.count, 1)
        XCTAssertEqual(photo.companions.first?.data, data)
        XCTAssertTrue(photo.lensLabel?.contains("3 frames") == true)
        XCTAssertNotNil(UIImage(data: photo.data))
    }

    func testNightDecodeFailureKeepsReference() async throws {
        let frame = CapturedPhoto(data: Data([9, 8, 7]), dimensions: CMVideoDimensions(width: 1, height: 1), lensLabel: "Main")
        let result = await NightPhotoProcessor.process([frame, frame], cancellation: NightWorkCancellation())
        XCTAssertEqual(result?.data, frame.data)
        XCTAssertEqual(result?.companions.count, 0)
    }

    func testRoutineStatusDismissalPreservesWarnings() {
        XCTAssertTrue(CameraViewModel.isBriefStatus("Saved"))
        XCTAssertTrue(CameraViewModel.isBriefStatus("Saved 2 photos"))
        XCTAssertTrue(CameraViewModel.isBriefStatus("Depth capture ready"))
        XCTAssertFalse(CameraViewModel.isBriefStatus("Saved to Photos, but local history could not be updated."))
        XCTAssertFalse(CameraViewModel.isBriefStatus("Only Main photo saved. The other camera did not capture a photo."))
        XCTAssertFalse(CameraViewModel.isBriefStatus("Not saved to Photos. A recovery copy is on this iPhone."))
        XCTAssertFalse(CameraViewModel.isBriefStatus("Saving to Photos…"))
    }

    func testZoomRestorationClampsToChangedFormatLimits() {
        XCTAssertEqual(ZoomLimits.clamp(8, minimum: 1, maximum: 4), 4)
        XCTAssertEqual(ZoomLimits.clamp(0.5, minimum: 1, maximum: 4), 1)
        XCTAssertEqual(ZoomLimits.clamp(2.3, minimum: 1, maximum: 4), 2.3)
    }
    func testZoomRejectsInvalidValuesAndRanges() {
        XCTAssertNil(ZoomLimits.clamp(.nan, minimum: 1, maximum: 4))
        XCTAssertNil(ZoomLimits.clamp(.infinity, minimum: 1, maximum: 4))
        XCTAssertNil(ZoomLimits.clamp(2, minimum: 4, maximum: 1))
        XCTAssertNil(ZoomLimits.clamp(2, minimum: 0, maximum: 4))
    }
    func testZoomShortcutsMatchCapabilitySets() {
        let ultra = CameraLens(id: "u", name: "Ultra Wide", isFront: false, zoomFactor: 0.5, maximumZoom: 16)
        let miniMain = CameraLens(id: "m", name: "Wide", isFront: false, zoomFactor: 1, maximumZoom: 16)
        XCTAssertEqual(ZoomShortcuts.make([ultra, miniMain]).map(\.value), [0.5, 1])
        let proMain = CameraLens(id: "m", name: "Wide", isFront: false, zoomFactor: 1, maximumZoom: 16, secondaryZooms: [2])
        let tele = CameraLens(id: "t", name: "Telephoto", isFront: false, zoomFactor: 5, maximumZoom: 16)
        XCTAssertEqual(ZoomShortcuts.make([tele, proMain, ultra]).map(\.value), [0.5, 1, 2, 5])
        let tele3 = CameraLens(id: "t", name: "Telephoto", isFront: false, zoomFactor: 3, maximumZoom: 16)
        XCTAssertEqual(ZoomShortcuts.make([ultra, proMain, tele3]).map(\.value), [0.5, 1, 2, 3])
    }
    func testZoomShortcutsPreferPhysicalLensAndRejectInvalidStops() {
        let main = CameraLens(id: "m", name: "Wide", isFront: false, zoomFactor: 1, maximumZoom: 4, secondaryZooms: [2, 2, .nan, 8])
        let tele = CameraLens(id: "t", name: "Telephoto", isFront: false, zoomFactor: 2, maximumZoom: 4)
        let choices = ZoomShortcuts.make([main, tele])
        XCTAssertEqual(choices.map(\.value), [1, 2])
        XCTAssertEqual(choices.last?.lens.id, "t")
    }
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

    func testLocalPhotoDetailsSurviveRecoveryAndLegacyFilesStillDecode() async throws {
        var original = photo()
        original.details = CaptureDetails(iso: 125, exposureSeconds: 0.008, timestamp: 10.5)
        try await CaptureStore(root: root).stage(original)
        let restored = try await CaptureStore(root: root).load("pending.plist")
        XCTAssertEqual(restored?.captured?.details, original.details)
        let encoded = try PropertyListEncoder().encode(CaptureStore.Photo(original, index: 0))
        var legacy = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        legacy.removeValue(forKey: "details")
        let data = try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
        let decoded = try PropertyListDecoder().decode(CaptureStore.Photo.self, from: data)
        XCTAssertNil(decoded.details)
        XCTAssertEqual(decoded.data, original.data)
    }
    func testPairTimingUsesCaptureTimestampsAndHandlesMissingData() {
        let first = CaptureDetails(iso: nil, exposureSeconds: nil, timestamp: 10)
        let second = CaptureDetails(iso: nil, exposureSeconds: nil, timestamp: 10.25)
        XCTAssertEqual(CaptureDetails.gap(first, second), 0.25)
        XCTAssertEqual(CaptureDetails.gap(second, first), 0.25)
        XCTAssertNil(CaptureDetails.gap(first, nil))
    }

}
