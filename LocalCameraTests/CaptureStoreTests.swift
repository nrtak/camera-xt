import XCTest
import AVFoundation
import UIKit
@testable import LocalCamera

final class CaptureStoreTests: XCTestCase {
    func testPreviewControlsNeverBecomeFocusTaps() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 520)
        // Reject the entire strip, including gaps between controls.
        for x in stride(from: 0, through: 389, by: 17) {
            for y in [476, 490, 519] {
                XCTAssertFalse(PreviewGeometry.acceptsFocus(at: CGPoint(x: x, y: y), bounds: bounds, controlStripHeight: 44))
            }
        }
        XCTAssertTrue(PreviewGeometry.acceptsFocus(at: CGPoint(x: 195, y: 475), bounds: bounds, controlStripHeight: 44))
        XCTAssertFalse(PreviewGeometry.acceptsFocus(at: CGPoint(x: 195, y: 400), bounds: bounds, controlStripHeight: 140))
        XCTAssertFalse(PreviewGeometry.acceptsFocus(at: CGPoint(x: CGFloat.nan, y: 20), bounds: bounds, controlStripHeight: 44))
        XCTAssertFalse(PreviewGeometry.acceptsFocus(at: .zero, bounds: .zero, controlStripHeight: 44))
    }

    func testPreviewRecoveryWaitsForFiveChecksAndDoesNotInterruptCapture() {
        var health = PreviewHealth()
        for time in 0..<4 { XCTAssertFalse(health.shouldRestart(previewing: false, eligible: true, now: Double(time))) }
        XCTAssertFalse(health.shouldRestart(previewing: false, eligible: false, now: 4))
        for time in 5..<9 { XCTAssertFalse(health.shouldRestart(previewing: false, eligible: true, now: Double(time))) }
        XCTAssertTrue(health.shouldRestart(previewing: false, eligible: true, now: 9))
        XCTAssertFalse(health.shouldRestart(previewing: true, eligible: true, now: 10))
        XCTAssertEqual(health.missedChecks, 0)
    }

    func testPreviewRecoveryHasCooldownAndStopsAfterTwoAttempts() {
        var health = PreviewHealth()
        var restarts: [Int] = []
        for time in 0..<60 {
            if health.shouldRestart(previewing: false, eligible: true, now: Double(time)) { restarts.append(time) }
        }
        XCTAssertEqual(restarts, [4, 19])
        XCTAssertEqual(health.attempts, 2)
    }

    func testCaptureLabelsUseActualZoomAndRejectInvalidValues() {
        XCTAssertEqual(CaptureLensLabel.make(name: "Main", base: 1, factor: 2), "Main · 2.00×")
        XCTAssertEqual(CaptureLensLabel.make(name: "Ultra Wide", base: 0.5, factor: 1.5), "Ultra Wide · 0.75×")
        XCTAssertEqual(CaptureLensLabel.make(name: "Main", base: 1, factor: .nan), "Main")
    }

    func testRecentSummaryDoesNotKeepPhotoBytesButReviewLoadsOriginals() async throws {
        let store = CaptureStore(root: root)
        try await store.stage(photo())
        _ = try await store.finish(thumbnail: Data([7]))
        let summary = try await store.load("recent.plist", includingPhotos: false)
        XCTAssertEqual(summary?.photos.first?.data.count, 0)
        XCTAssertNotNil(summary?.photos.first?.fileName)
        XCTAssertEqual(summary?.thumbnail, Data([7]))
        let full = try await store.load("recent.plist")
        XCTAssertEqual(full?.photos.first?.data, Data([1, 2, 3]))
    }

    func testUncertainSaveAndConfirmedSaveSurviveRelaunch() async throws {
        let store = CaptureStore(root: root)
        try await store.stage(photo())
        try await store.beginSave()
        let attempted = try await CaptureStore(root: root).load("pending.plist")
        XCTAssertEqual(attempted?.saveAttempted, true)
        XCTAssertEqual(attempted?.saved, false)
        try await store.markSaved()
        let saved = try await CaptureStore(root: root).load("pending.plist")
        XCTAssertEqual(saved?.saved, true)
        XCTAssertEqual(saved?.photos.first?.data, Data([1, 2, 3]))
    }

    func testSavedReceiptCannotMarkADifferentCaptureSaved() async throws {
        let store = CaptureStore(root: root)
        try await store.stage(photo())
        try await store.beginSave(); try await store.markSaved()
        try await store.stage(photo("Next", bytes: [9]))
        let pending = try await CaptureStore(root: root).load("pending.plist")
        XCTAssertEqual(pending?.saved, false)
        XCTAssertNotEqual(pending?.saveAttempted, true)
        XCTAssertEqual(pending?.photos.first?.data, Data([9]))
    }

    func testCorruptReceiptDoesNotOfferBlindRetry() async throws {
        let store = CaptureStore(root: root)
        try await store.stage(photo())
        try Data([1, 2]).write(to: root.appendingPathComponent("save-receipt.plist"))
        do { _ = try await store.load("pending.plist"); XCTFail("Unreadable save outcome must not be ignored") }
        catch { }
    }

    func testLegacyEmbeddedPhotoRecoveryCanStillBeFinished() async throws {
        let legacy = CaptureStore.Record(photos: [CaptureStore.Photo(photo(), index: 0)])
        try PropertyListEncoder().encode(legacy).write(to: root.appendingPathComponent("pending.plist"))
        let store = CaptureStore(root: root)
        let recovered = try await store.load("pending.plist")
        XCTAssertEqual(recovered?.photos.first?.data, Data([1, 2, 3]))
        try await store.beginSave(); try await store.markSaved()
        _ = try await store.finish(thumbnail: Data([7]))
        let recent = try await store.load("recent.plist")
        XCTAssertEqual(recent?.photos.first?.data, Data([1, 2, 3]))
        XCTAssertEqual(recent?.saved, true)
    }

    func testClearingRecentDeletesOnlyItsOriginalFiles() async throws {
        let store = CaptureStore(root: root)
        try await store.stage(photo())
        _ = try await store.finish(thumbnail: nil)
        try await store.stage(photo("Pending", bytes: [9]))
        try await store.clearRecent()
        let pending = try await store.load("pending.plist")
        XCTAssertEqual(pending?.photos.first?.data, Data([9]))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".photo") }
        XCTAssertEqual(files.count, 1)
    }
    func testDiagnosticHistoryIsBoundedAndSurvivesEncoding() throws {
        var history = CameraDiagnosticHistory()
        for index in 0..<150 { history.append("event-\(index)") }
        XCTAssertEqual(history.entries.count, 120)
        XCTAssertEqual(history.entries.first, "event-30")
        XCTAssertEqual(history.entries.last, "event-149")
        history.append(String(repeating: "x", count: 1000))
        XCTAssertEqual(history.entries.last?.count, 240)
        let restored = try JSONDecoder().decode(CameraDiagnosticHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored.entries, history.entries)
    }

    func testRecoveryNeverRestartsDuringCaptureInterruptionOrBackground() {
        XCTAssertFalse(CameraRecoveryPolicy.mayAttempt(active: false, interrupted: false, busy: false, attempts: 0, lastAttempt: nil, now: 100))
        XCTAssertFalse(CameraRecoveryPolicy.mayAttempt(active: true, interrupted: true, busy: false, attempts: 0, lastAttempt: nil, now: 100))
        XCTAssertFalse(CameraRecoveryPolicy.mayAttempt(active: true, interrupted: false, busy: true, attempts: 0, lastAttempt: nil, now: 100))
        XCTAssertTrue(CameraRecoveryPolicy.mayAttempt(active: true, interrupted: false, busy: false, attempts: 0, lastAttempt: nil, now: 100))
    }

    func testRecoveryBackoffAndRetryLimit() {
        XCTAssertFalse(CameraRecoveryPolicy.mayAttempt(active: true, interrupted: false, busy: false, attempts: 1, lastAttempt: 95, now: 100))
        XCTAssertTrue(CameraRecoveryPolicy.mayAttempt(active: true, interrupted: false, busy: false, attempts: 1, lastAttempt: 90, now: 100))
        XCTAssertFalse(CameraRecoveryPolicy.mayAttempt(active: true, interrupted: false, busy: false, attempts: 2, lastAttempt: 80, now: 100))
    }

    func testPanoramaGuidancePrioritizesMotionAndRejectsInvalidSamples() {
        XCTAssertNil(PanoramaPolicy.motionWarning(speed: 0.1, tilt: 0.1))
        XCTAssertEqual(PanoramaPolicy.motionWarning(speed: 0.4, tilt: 0.3), "Slow down")
        XCTAssertEqual(PanoramaPolicy.motionWarning(speed: 0.1, tilt: 0.3), "Keep level")
        XCTAssertNotNil(PanoramaPolicy.motionWarning(speed: .nan, tilt: 0))
        XCTAssertNotNil(PanoramaPolicy.motionWarning(speed: 0, tilt: .infinity))
    }

    func testShutterChoicesRespectVideoFrameDurationAndKeepSelectionValid() {
        let choices = ShutterOptions.values(minimum: 1.0 / 8000, maximum: 1.0 / 120, requested: 1)
        XCTAssertTrue(choices.allSatisfy { $0 >= 1.0 / 8000 && $0 <= 1.0 / 120 })
        XCTAssertTrue(choices.contains(1.0 / 120))
        XCTAssertEqual(Set(choices).count, choices.count)
        XCTAssertTrue(ShutterOptions.values(minimum: 0, maximum: 1, requested: 1).isEmpty)
        XCTAssertTrue(ShutterOptions.values(minimum: 1, maximum: 0.5, requested: 1).isEmpty)
        XCTAssertTrue(ShutterOptions.values(minimum: 0.001, maximum: 1, requested: .nan).allSatisfy { $0.isFinite })
    }

    func testVideoPresetRecoversAfterSwitchingToLessCapableLens() {
        let options = [VideoQuality(width: 1920, fps: 60), VideoQuality(width: 1920, fps: 30)]
        XCTAssertEqual(VideoQuality.resolve(width: 3840, fps: 120, from: options), options[0])
        XCTAssertEqual(VideoQuality.resolve(width: 1920, fps: 120, from: options), options[0])
        XCTAssertEqual(VideoQuality.resolve(width: 1920, fps: 30, from: options), options[1])
        XCTAssertEqual(VideoQuality.resolve(width: 0, fps: 0, from: options), options[0])
        XCTAssertNil(VideoQuality.resolve(width: 3840, fps: 60, from: []))
    }

    func testResolutionChangePreservesCompatibleRateAndFallsBackSafely() {
        let options = [VideoQuality(width: 3840, fps: 60), VideoQuality(width: 3840, fps: 30),
                       VideoQuality(width: 1920, fps: 120), VideoQuality(width: 1920, fps: 30)]
        XCTAssertEqual(VideoQuality.selectWidth(3840, keepingFPS: 30, from: options)?.fps, 30)
        XCTAssertEqual(VideoQuality.selectWidth(3840, keepingFPS: 120, from: options)?.fps, 60)
        XCTAssertEqual(VideoQuality.selectWidth(1920, keepingFPS: nil, from: options)?.fps, 120)
        XCTAssertNil(VideoQuality.selectWidth(1280, keepingFPS: 30, from: options))
        XCTAssertNil(VideoQuality.selectWidth(3840, keepingFPS: 60, from: []))
    }

    func testAdaptiveToolPanelLeavesPreviewVisibleAndAvoidsShutterArea() {
        let bounds = CGRect(x: 0, y: 0, width: 820, height: 280)
        let image = CGRect(x: 40, y: 0, width: 740, height: 402)
        let side = PreviewGeometry.panelRect(image: image, bounds: bounds, preferredHeight: 460, sidePanel: true)
        XCTAssertTrue(image.intersection(bounds).contains(side))
        XCTAssertLessThanOrEqual(side.width, 340)
        XCTAssertGreaterThan(side.minX, image.midX)
        XCTAssertEqual(side.maxY, bounds.maxY - 10)
        let portrait = PreviewGeometry.panelRect(image: image, bounds: bounds, preferredHeight: 120)
        XCTAssertEqual(portrait.maxY, bounds.maxY - 10)
        XCTAssertEqual(portrait.height, 120)
    }

    func testVideoQualityPrefersResolutionThenFrameRate() {
        let options = [VideoQuality(width: 1920, fps: 240), VideoQuality(width: 3840, fps: 30),
                       VideoQuality(width: 3840, fps: 120), VideoQuality(width: 3840, fps: 120)]
        let ranked = VideoQuality.ranked(options)
        XCTAssertEqual(ranked.first, VideoQuality(width: 3840, fps: 120))
        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(VideoQuality.ranked([VideoQuality(width: 1280, fps: 30)]).first?.width, 1280)
        XCTAssertTrue(VideoQuality.ranked([]).isEmpty)
    }

    func testToolPanelStaysInsideVisibleImageAcrossOrientations() {
        for bounds in [CGRect(x: 0, y: 0, width: 402, height: 820), CGRect(x: 0, y: 0, width: 820, height: 402)] {
            let image = bounds.insetBy(dx: 20, dy: 80)
            for height in [CGFloat(360), 620, .infinity] {
                let panel = PreviewGeometry.panelRect(image: image, bounds: bounds, preferredHeight: height)
                XCTAssertTrue(PreviewGeometry.isValid(panel))
                XCTAssertTrue(image.contains(panel), "Menus must not extend into letterboxing")
                XCTAssertLessThanOrEqual(panel.height, image.height - 20)
            }
        }
    }

    func testToolPanelHandlesCameraStartupAndInvalidFrames() {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 820)
        for image in [CGRect.zero, CGRect.null, CGRect(x: 900, y: 900, width: 100, height: 100)] {
            let panel = PreviewGeometry.panelRect(image: image, bounds: bounds, preferredHeight: 360)
            XCTAssertTrue(PreviewGeometry.isValid(panel))
            XCTAssertTrue(bounds.contains(panel))
        }
        XCTAssertEqual(PreviewGeometry.panelRect(image: .zero, bounds: .zero, preferredHeight: 360), .zero)
    }

    @MainActor
    func testFocusThenShutterShareOneControlAcknowledgment() {
        let waiters = ControlUpdateWaiters()
        var revision = 1
        var actions: [String] = []
        // A scheduled settings update may already be in flight before either tap.
        XCTAssertTrue(waiters.begin(revision: revision, completion: nil))
        XCTAssertFalse(waiters.begin(revision: revision) { applied in
            if applied { actions.append("focus A"); revision += 1 }
        })
        XCTAssertFalse(waiters.begin(revision: revision) { applied in
            if applied { actions.append("focus B"); revision += 1 }
        })
        XCTAssertFalse(waiters.begin(revision: revision) { applied in
            if applied { actions.append("shutter") }
        })
        waiters.finish(revision: 1, applied: true)
        XCTAssertEqual(actions, ["focus A", "focus B", "shutter"],
                       "Focus changes must not discard later actions waiting on the same update")
        waiters.finish(revision: 1, applied: true)
        XCTAssertEqual(actions.count, 3, "An acknowledgment must not repeat actions")
    }

    @MainActor
    func testRejectedControlsReleaseWaitersAndAllowRetry() {
        let waiters = ControlUpdateWaiters()
        var results: [Bool] = []
        XCTAssertTrue(waiters.begin(revision: 1) { results.append($0) })
        XCTAssertFalse(waiters.begin(revision: 1) { results.append($0) })
        waiters.finish(revision: 1, applied: false)
        XCTAssertEqual(results, [false, false])
        XCTAssertTrue(waiters.begin(revision: 1) { results.append($0) })
        waiters.finish(revision: 1, applied: true)
        XCTAssertEqual(results, [false, false, true])
    }

    @MainActor
    func testOldControlAcknowledgmentDoesNotDrainNewerActions() {
        let waiters = ControlUpdateWaiters()
        var actions: [String] = []
        XCTAssertTrue(waiters.begin(revision: 1) { applied in
            if applied { actions.append("old") }
        })
        XCTAssertTrue(waiters.begin(revision: 2) { applied in
            if applied { actions.append("new") }
        })
        waiters.finish(revision: 1, applied: false)
        XCTAssertTrue(actions.isEmpty)
        waiters.finish(revision: 2, applied: true)
        XCTAssertEqual(actions, ["new"])
    }

    @MainActor
    func testPanoramaModeCannotBeReplacedByPhotoStyles() async throws {
        let model = CameraViewModel()
        for _ in 0..<200 {
            if !model.restoring { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.restoring, "Recovery loading must complete before testing mode changes")
        XCTAssertTrue(model.canConfigure)
        model.enablePanorama()
        XCTAssertTrue(model.panoramaSelected)
        model.exposureBias = 1
        model.chooseCaptureMode(1)
        XCTAssertEqual(model.exposureBias, 1, "Selecting the current mode must not reset adjustments")
        model.setNightEnabled(true)
        model.enableLongExposure()
        XCTAssertTrue(model.panoramaSelected)
        XCTAssertEqual(model.captureStyle, "Auto")
        model.chooseCaptureMode(0)
        XCTAssertFalse(model.panoramaSelected)
        model.enableLongExposure()
        XCTAssertEqual(model.captureStyle, "Long Exposure")
        model.setDualEnabled(true)
        XCTAssertEqual(model.captureStyle, "Auto")
        model.setActive(false)
    }

    @MainActor
    func testPanoramaGuidanceDoesNotLeakAcrossModes() async throws {
        let model = CameraViewModel()
        for _ in 0..<200 {
            if !model.restoring { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.restoring)
        for method in PanoramaMethod.allCases {
            model.panoramaMethod = method
            model.enablePanorama()
            XCTAssertTrue(model.panoramaSelected)
            XCTAssertNil(model.message, "Idle instructions must not enter the shared status banner")
            model.message = method.instructions
            model.chooseCaptureMode(0)
            XCTAssertFalse(model.panoramaSelected)
            XCTAssertNil(model.message)
            model.enablePanorama()
            model.message = method.instructions
            // Photo-to-Video uses this reset before asynchronous camera reconfiguration.
            model.resetTemporarySettings()
            XCTAssertFalse(model.panoramaSelected)
            XCTAssertNil(model.message)
        }
        model.setActive(false)
    }

    @MainActor
    func testControlEditsSurviveInterruptionAndPreserveLongExposure() async throws {
        let model = CameraViewModel()
        for _ in 0..<200 {
            if !model.restoring { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.restoring)
        model.controlBinding.flash.wrappedValue = .on
        XCTAssertTrue(model.controlsNeedApply, "A shortcut must schedule the camera update without a settings panel")
        model.setActive(false)
        XCTAssertTrue(model.controlsNeedApply, "An interruption must retain the unapplied edit")
        let applied = await withCheckedContinuation { continuation in
            model.flushPendingControls { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(applied, "An unconfigured camera must reject the update")
        XCTAssertTrue(model.controlsNeedApply, "A rejected edit must remain pending for retry")
        XCTAssertEqual(model.controls.flash, .on)
        model.enableLongExposure()
        model.controlBinding.lensPosition.wrappedValue = 0.7
        model.controlBinding.automaticFocus.wrappedValue = false
        model.applyControls()
        XCTAssertEqual(model.captureStyle, "Long Exposure")
        XCTAssertTrue(model.controlsNeedApply, "An update stays pending until acknowledged")
        model.controlBinding.iso.wrappedValue = 200
        XCTAssertTrue(model.controlsNeedApply)
        model.resetControls()
        XCTAssertTrue(model.controlsNeedApply, "Reset must also wait for camera acknowledgment")
        XCTAssertEqual(model.controls, CameraControls(), "Reset must supersede the prior values")
        model.setActive(false)
    }

    @MainActor
    func testRetryingPresetDoesNotReplaceNightStyle() async throws {
        let model = CameraViewModel()
        for _ in 0..<200 {
            if !model.restoring { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.restoring)
        model.setNightEnabled(true)
        XCTAssertEqual(model.captureStyle, "Night")
        let applied = await withCheckedContinuation { continuation in
            model.flushPendingControls { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(applied)
        XCTAssertTrue(model.controlsNeedApply)
        XCTAssertEqual(model.captureStyle, "Night", "Retrying settings must not change the selected capture style")
        model.setActive(false)
    }

    func testStitchFinishRequiresEnoughCompletedPhotos() {
        XCTAssertFalse(PanoramaPolicy.canFinish(frames: 0, takingPhoto: false))
        XCTAssertFalse(PanoramaPolicy.canFinish(frames: 2, takingPhoto: false))
        XCTAssertFalse(PanoramaPolicy.canFinish(frames: 3, takingPhoto: true))
        XCTAssertTrue(PanoramaPolicy.canFinish(frames: 3, takingPhoto: false))
    }

    func testPanoramaStopNoticeSurvivesRecoveryAndOldJournalsDecode() throws {
        let old = Data(#"{"files":[],"labels":[],"direction":"Right","readyToSave":false,"saved":false}"#.utf8)
        var journal = try JSONDecoder().decode(PanoramaFileStore.Journal.self, from: old)
        XCTAssertNil(journal.stopNotice)
        journal.stopNotice = "Capture stopped at the storage limit."
        let restored = try JSONDecoder().decode(PanoramaFileStore.Journal.self, from: JSONEncoder().encode(journal))
        XCTAssertEqual(restored.stopNotice, journal.stopNotice)
    }

    func testUnrelatedControlChangesDoNotReapplyFocus() {
        let original = CameraControls()
        var updated = original; updated.flash = .on
        var changes = CameraControlChanges(from: original, to: updated)
        XCTAssertFalse(changes.focus)
        XCTAssertFalse(changes.exposure)
        XCTAssertFalse(changes.whiteBalance)
        updated = original; updated.temperature = 6200
        changes = CameraControlChanges(from: original, to: updated)
        XCTAssertTrue(changes.whiteBalance)
        XCTAssertFalse(changes.focus)
        XCTAssertFalse(changes.exposure)
        updated = original; updated.iso = 800
        changes = CameraControlChanges(from: original, to: updated)
        XCTAssertTrue(changes.exposure)
        XCTAssertFalse(changes.focus)
        updated = original; updated.automaticFocus = false
        XCTAssertTrue(CameraControlChanges(from: original, to: updated).focus)
    }

    @MainActor
    func testRecoveryActionsAreUnavailableDuringStartup() async throws {
        let model = CameraViewModel()
        XCTAssertTrue(model.restoring)
        XCTAssertFalse(model.canUseRecovery)
        model.discard()
        XCTAssertFalse(model.busy, "Discard must not start while recovery is loading")
        await model.retrySave()
        XCTAssertFalse(model.recoveryActionRunning, "Retry must not overlap startup recovery")
        for _ in 0..<200 {
            if !model.restoring { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.restoring)
        model.setActive(false)
    }

    func testPanoramaDoesNotRecommendUnavailableNightMode() {
        XCTAssertNil(SceneAdvice.text(shutter: 0.1, iso: 1600, dual: false, night: false, panorama: true))
        XCTAssertNil(SceneAdvice.text(shutter: 0.1, iso: 1600, dual: true, night: false, panorama: true))
        XCTAssertNotNil(SceneAdvice.text(shutter: 0.1, iso: 1600, dual: false, night: false))
    }

    func testAbandonedStackCleanupLeavesUnrelatedFilesAndRecoveryIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let abandoned = root.appendingPathComponent("camera-xt-stack-" + UUID().uuidString, isDirectory: true)
        let unrelated = root.appendingPathComponent("camera-xt-stack-not-a-session", isDirectory: true)
        let recovery = root.appendingPathComponent("CaptureRecovery", isDirectory: true)
        for directory in [abandoned, unrelated, recovery] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("frame.image"))
        }
        await PanoramaFileStore.cleanupAbandonedStacks(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertEqual(try Data(contentsOf: unrelated.appendingPathComponent("frame.image")), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent("frame.image")), Data([1, 2, 3]))
    }

    func testPanoramaPreferencesRoundTripAndOlderSettingsDecode() throws {
        var setup = SavedCameraSetup(lensID: nil, video: false, dual: true, dualMode: "Fast",
            style: "Auto", controls: CameraControls(), bias: 0, dualBrightness: [0, 0], zooms: [],
            timer: 0, burst: false, videoWidth: 1920, videoFPS: 30, stabilization: true,
            depth: false, eye: false, analysis: "Off", exposurePointOnly: false)
        setup.panorama = true; setup.panoramaMethod = "Stitch"; setup.panoramaDirection = "Left"
        setup.longExposureStyle = LongExposureStyle.trails.rawValue; setup.longExposureSeconds = 120
        let data = try JSONEncoder().encode(setup)
        let restored = try JSONDecoder().decode(SavedCameraSetup.self, from: data)
        XCTAssertEqual(restored.panorama, true)
        XCTAssertEqual(restored.panoramaMethod, "Stitch")
        XCTAssertEqual(restored.panoramaDirection, "Left")
        XCTAssertEqual(restored.longExposureStyle, LongExposureStyle.trails.rawValue)
        XCTAssertEqual(restored.longExposureSeconds, 120)
        XCTAssertEqual(restored, setup)
        var changed = restored; changed.longExposureSeconds = 300
        XCTAssertNotEqual(changed, setup, "Preference comparisons must notice duration edits")
        changed = restored; changed.controls.iso += 1
        XCTAssertNotEqual(changed, setup, "Preference comparisons must notice manual control edits")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["panorama", "panoramaMethod", "panoramaDirection", "longExposureStyle", "longExposureSeconds"] { old.removeValue(forKey: key) }
        old["style"] = "Panorama"
        let legacy = try JSONDecoder().decode(SavedCameraSetup.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.panorama)
        XCTAssertNil(legacy.longExposureStyle)
        XCTAssertNil(legacy.longExposureSeconds)
        XCTAssertEqual(legacy.style, "Panorama")
    }

    func testPanoramaJournalRetainsAcceptedFilesAndCommitsUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { PanoramaFileStore.remove(directory) }
        let first = try await PanoramaFileStore.write([Data([1, 2]), Data([3, 4])], directory: directory, frame: 0)
        let second = try await PanoramaFileStore.write([Data([5, 6]), Data([7, 8])], directory: directory, frame: 1)
        var journal = PanoramaFileStore.Journal(files: [[first[0].lastPathComponent, second[0].lastPathComponent],
            [first[1].lastPathComponent, second[1].lastPathComponent]], labels: ["Main", "Ultra Wide"], direction: "Right")
        try await PanoramaFileStore.checkpoint(journal, directory: directory)
        let restored = try await PanoramaFileStore.load(directory: directory)
        XCTAssertEqual(restored?.files, journal.files)
        journal.files = journal.files.map { Array($0.dropLast()) }
        try await PanoramaFileStore.checkpoint(journal, directory: directory)
        PanoramaFileStore.deleteFiles(second)
        let undone = try await PanoramaFileStore.load(directory: directory)
        XCTAssertEqual(undone?.files.first?.count, 1)
        XCTAssertEqual(try Data(contentsOf: first[0]), Data([1, 2]))
        journal.readyToSave = true
        try await PanoramaFileStore.checkpoint(journal, directory: directory)
        let ready = try await PanoramaFileStore.load(directory: directory)
        XCTAssertEqual(ready?.readyToSave, true)
        journal.saved = true
        try await PanoramaFileStore.checkpoint(journal, directory: directory)
        let saved = try await PanoramaFileStore.load(directory: directory)
        XCTAssertEqual(saved?.saved, true, "Keep the committed marker until both recovery stores are cleaned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try await PanoramaFileStore.clear(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPanoramaJournalLoadsWhenOneLensFrameIsMissing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { PanoramaFileStore.remove(directory) }
        let pair = try await PanoramaFileStore.write([Data([1]), Data([2])], directory: directory, frame: 0)
        let journal = PanoramaFileStore.Journal(files: [[pair[0].lastPathComponent], [pair[1].lastPathComponent]],
            labels: ["Main", "Ultra Wide"], direction: "Right")
        try await PanoramaFileStore.checkpoint(journal, directory: directory)
        try FileManager.default.removeItem(at: pair[0])
        let restored = try await PanoramaFileStore.load(directory: directory)
        XCTAssertEqual(restored?.files, journal.files, "Preserve lens ordering and allow recovery of the intact camera")
        XCTAssertEqual(try Data(contentsOf: pair[1]), Data([2]))
    }

    func testPanoramaRecoveryRejectsUnsafePaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { PanoramaFileStore.remove(directory) }
        let journal = PanoramaFileStore.Journal(files: [["../outside.image"]], labels: ["Main"], direction: "Right")
        try await PanoramaFileStore.checkpoint(journal, directory: directory)
        do {
            _ = try await PanoramaFileStore.load(directory: directory)
            XCTFail("Recovery must reject paths outside its own directory")
        } catch { XCTAssertTrue(error is PanoramaFailure) }
    }

    func testPanoramaPolicyRejectsReverseFastAndVerticalMovement() {
        let size = CGSize(width: 512, height: 384)
        XCTAssertTrue(PanoramaPolicy.accepts(CGAffineTransform(translationX: 80, y: 2), size: size, direction: .right))
        XCTAssertTrue(PanoramaPolicy.accepts(CGAffineTransform(translationX: -80, y: 2), size: size, direction: .left))
        XCTAssertFalse(PanoramaPolicy.accepts(CGAffineTransform(translationX: -80, y: 0), size: size, direction: .right))
        XCTAssertFalse(PanoramaPolicy.accepts(CGAffineTransform(translationX: 300, y: 0), size: size, direction: .right))
        XCTAssertFalse(PanoramaPolicy.accepts(CGAffineTransform(translationX: 80, y: 90), size: size, direction: .right))
        XCTAssertFalse(PanoramaPolicy.accepts(CGAffineTransform(translationX: .nan, y: 0), size: size, direction: .right))
    }

    func testPanoramaStitchesBothDirectionsAndSeparateLensOutputs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let scene = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 384), format: format).image { context in
            for y in stride(from: 0, to: 384, by: 8) {
                for x in stride(from: 0, to: 800, by: 8) {
                    let horizontal: Int = x * 73
                    let vertical: Int = y * 137
                    let mixed: Int = x * y * 11
                    let value: CGFloat = CGFloat((horizontal + vertical + mixed) % 251) / 251.0
                    UIColor(hue: value, saturation: 0.65, brightness: 0.3 + 0.7 * value, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        let full = try XCTUnwrap(scene.cgImage)
        var files: [URL] = []
        for offset in [0, 80, 160, 240] {
            let crop = try XCTUnwrap(full.cropping(to: CGRect(x: offset, y: 0, width: 512, height: 384)))
            let data = try XCTUnwrap(UIImage(cgImage: crop).pngData())
            let file = directory.appendingPathComponent("\(offset).png"); try data.write(to: file); files.append(file)
        }
        let next = try Data(contentsOf: files[1])
        let same = try Data(contentsOf: files[0])
        let accepted = try await PanoramaStitcher.checkOverlap(previous: [files[0], files[0]], next: [next, next], direction: .right, cancellation: NightWorkCancellation())
        XCTAssertTrue(accepted)
        let oneStationary = try await PanoramaStitcher.checkOverlap(previous: [files[0], files[0]], next: [next, same], direction: .right, cancellation: NightWorkCancellation())
        XCTAssertFalse(oneStationary, "Both lenses must overlap and move before accepting the pair")
        let reversed = try await PanoramaStitcher.checkOverlap(previous: [files[0]], next: [next], direction: .left, cancellation: NightWorkCancellation())
        XCTAssertFalse(reversed)
        let staged = try await PanoramaFileStore.write([next, same], directory: directory.appendingPathComponent("staged"), frame: 1)
        XCTAssertEqual(try Data(contentsOf: staged[0]), next)
        XCTAssertEqual(try Data(contentsOf: staged[1]), same)
        let thumbnail = try await PanoramaFileStore.thumbnail(next)
        XCTAssertLessThanOrEqual(try XCTUnwrap(UIImage(data: thumbnail)).size.width, 240)
        for direction in PanoramaDirection.allCases {
            let ordered = direction == .right ? files : Array(files.reversed())
            let result = try await PanoramaStitcher.process(files: [ordered, ordered], labels: ["Main", "Ultra Wide"], direction: direction, cancellation: NightWorkCancellation())
            XCTAssertEqual(result.companions.count, 1)
            XCTAssertTrue(result.lensLabel?.contains("Main") == true)
            XCTAssertTrue(result.companions[0].lensLabel?.contains("Ultra Wide") == true)
            XCTAssertGreaterThan(result.dimensions.width, 700)
            XCTAssertLessThanOrEqual(result.dimensions.width, 760)
            XCTAssertGreaterThan(result.dimensions.height, 370)
            XCTAssertEqual(result.dimensions.width, result.companions[0].dimensions.width)
        }
        let partial = try await PanoramaStitcher.process(files: [files, [files[0]]], labels: ["Main", "Ultra Wide"], direction: .right, cancellation: NightWorkCancellation())
        XCTAssertGreaterThan(partial.dimensions.width, 700)
        XCTAssertEqual(partial.companions.count, 1)
        XCTAssertTrue(partial.companions[0].lensLabel?.contains("Reference") == true)
        XCTAssertEqual(partial.warning, "One panorama saved; the other camera kept as a photo.")
        let missing = directory.appendingPathComponent("missing.image")
        let corrupt = directory.appendingPathComponent("corrupt.image")
        try Data([0, 1, 2]).write(to: corrupt)
        let salvaged = try await PanoramaStitcher.process(files: [files + [missing, corrupt]], labels: ["Main"], direction: .right, cancellation: NightWorkCancellation())
        XCTAssertGreaterThan(salvaged.dimensions.width, 700)
        XCTAssertTrue(salvaged.warning?.contains("coverage may be incomplete") == true,
            "The saved message must retain missing/corrupt frame warnings")
        let missingLens = try await PanoramaStitcher.process(files: [[missing], files], labels: ["Main", "Ultra Wide"], direction: .right, cancellation: NightWorkCancellation())
        XCTAssertGreaterThan(missingLens.dimensions.width, 700)
        XCTAssertTrue(missingLens.lensLabel?.contains("Ultra Wide") == true)
        XCTAssertTrue(missingLens.warning?.contains("other camera could not be recovered") == true)
        let fallbackAfterMissing = try await PanoramaStitcher.process(files: [files, [missing, files[0]]], labels: ["Main", "Ultra Wide"], direction: .right, cancellation: NightWorkCancellation())
        XCTAssertEqual(fallbackAfterMissing.companions.count, 1,
            "Reference fallback must search beyond a missing first frame")
        XCTAssertTrue(fallbackAfterMissing.companions[0].lensLabel?.contains("Reference") == true)
        let reversedPartial = try await PanoramaStitcher.process(files: [[files[0]], files], labels: ["Main", "Ultra Wide"], direction: .right, cancellation: NightWorkCancellation())
        XCTAssertGreaterThan(reversedPartial.companions[0].dimensions.width, 700)
        do {
            _ = try await PanoramaStitcher.process(files: [[files[0]]], labels: ["Main"], direction: .right, cancellation: NightWorkCancellation())
            XCTFail("A single frame must not be labeled a panorama")
        } catch { XCTAssertTrue(error is PanoramaFailure) }
        let cancellation = NightWorkCancellation(); cancellation.cancel()
        do {
            _ = try await PanoramaStitcher.process(files: [files], labels: ["Main"], direction: .right, cancellation: cancellation)
            XCTFail("Cancelled panorama must not render")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEditorPreservesDimensionsAndOriginalBytes() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 80), format: format).image { context in
            UIColor(white: 0.3, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
        }
        let source = try XCTUnwrap(image.jpegData(compressionQuality: 1)), copy = source
        var edits = PhotoAdjustments(); edits.exposure = 1
        let data = try await PhotoEditRenderer.render(source, edits: edits, preview: false, cancellation: NightWorkCancellation())
        let result = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(result.width, 60); XCTAssertEqual(result.height, 80)
        XCTAssertEqual(source, copy)
        edits.crop = 1
        let cropped = try await PhotoEditRenderer.render(source, edits: edits, preview: false, cancellation: NightWorkCancellation())
        let square = try XCTUnwrap(UIImage(data: cropped)?.cgImage)
        XCTAssertEqual(square.width, square.height); XCTAssertEqual(square.width, 60)
        edits.crop = 0; edits.turns = 1
        let rotated = try await PhotoEditRenderer.render(source, edits: edits, preview: false, cancellation: NightWorkCancellation())
        let turned = try XCTUnwrap(UIImage(data: rotated)?.cgImage)
        XCTAssertEqual(turned.width, 80); XCTAssertEqual(turned.height, 60)
    }

    func testEditorRejectsInvalidInputAndCancellation() async {
        do {
            _ = try await PhotoEditRenderer.render(Data([0, 1]), edits: PhotoAdjustments(), preview: false, cancellation: NightWorkCancellation())
            XCTFail("Invalid input must not export")
        } catch {}
        let cancelled = NightWorkCancellation(); cancelled.cancel()
        do {
            _ = try await PhotoEditRenderer.render(Data(), edits: PhotoAdjustments(), preview: true, cancellation: cancelled)
            XCTFail("Cancelled work must not render")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLongExposureLimitsAndSequentialComposite() async throws {
        XCTAssertEqual(LongExposureLimits.duration(.nan), 30)
        XCTAssertEqual(LongExposureLimits.duration(-5), 15)
        XCTAssertEqual(LongExposureLimits.duration(1000), 300)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var files: [URL] = []
        for value in [CGFloat(0.2), CGFloat(0.8)] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60), format: format).image { context in
                UIColor(white: value, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            }
            let file = directory.appendingPathComponent("\(files.count).jpg")
            try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: file); files.append(file)
        }
        for style in [LongExposureStyle.motion, .trails] {
            let output = try await LongExposureRenderer.process(files, style: style, cancellation: NightWorkCancellation())
            XCTAssertEqual(output.dimensions.width, 80); XCTAssertEqual(output.dimensions.height, 60)
            let image = try XCTUnwrap(UIImage(data: output.data)?.cgImage)
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            let brightness = Double(pixel[0]) / 255
            if style == .trails { XCTAssertEqual(brightness, 0.8, accuracy: 0.04) }
            else { XCTAssertGreaterThan(brightness, 0.4); XCTAssertLessThan(brightness, 0.7) }

            XCTAssertTrue(output.lensLabel?.contains("2 frames") == true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path))
        }
    }

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
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".photo") }.count, 2)
        XCTAssertEqual(files.filter { !$0.hasSuffix(".photo") }, ["recent.plist"])
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
        XCTAssertTrue(CameraViewModel.isBriefStatus("Panorama saved."))
        XCTAssertTrue(CameraViewModel.isBriefStatus("Both panoramas saved."))
        XCTAssertFalse(CameraViewModel.isBriefStatus("Both panoramas saved. Main: coverage may be incomplete."))
        XCTAssertFalse(CameraViewModel.isBriefStatus("One panorama saved; the other camera kept as a photo."))
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
    func testFocusMarkerStaysWithinLetterboxedPhoto() {
        let photo = CGRect(x: 0, y: 120, width: 390, height: 520)
        for point in [CGPoint(x: 1, y: 121), CGPoint(x: 389, y: 121),
                      CGPoint(x: 1, y: 639), CGPoint(x: 389, y: 639)] {
            guard let marker = PreviewGeometry.focusRect(at: point, in: photo) else {
                XCTFail("Visible photo corners must accept focus"); continue
            }
            XCTAssertTrue(photo.contains(marker))
            XCTAssertEqual(marker.width, 64)
        }
        XCTAssertNil(PreviewGeometry.focusRect(at: CGPoint(x: 100, y: 20), in: photo))
        XCTAssertNil(PreviewGeometry.focusRect(at: .zero, in: .zero))
        XCTAssertNil(PreviewGeometry.focusRect(at: CGPoint(x: CGFloat.nan, y: 200), in: photo))
        let inset = CGRect(x: 30, y: 40, width: 40, height: 50)
        XCTAssertEqual(PreviewGeometry.focusRect(at: CGPoint(x: 35, y: 45), in: inset), inset)
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
