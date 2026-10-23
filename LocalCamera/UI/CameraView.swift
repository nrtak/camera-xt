import SwiftUI
import AVFoundation
import PhotosUI
import CoreImage
import ImageIO
import Darwin

enum CameraAppearance {
    static let selection = Color(red: 0.48, green: 0.80, blue: 1)
}

struct CameraView: View {
    init() { CameraLaunchPreferences.prepareOnce() }
    @StateObject private var model = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var textSize
    @AppStorage("camera.quickAccess") private var quickAccess = false
    @AppStorage("camera.showQuickControls") private var showQuickControls = true
    @AppStorage("camera.adaptiveLayout") private var adaptiveLayout = true
    @AppStorage("camera.sceneHints") private var sceneHints = true
    @AppStorage("camera.lensWarnings") private var lensWarnings = true
    @State private var dismissedLensWarnings: Set<Int> = []
    @AppStorage("camera.advancedTools") private var advancedTools = false
    @AppStorage("camera.rememberSetup") private var rememberSetup = true
    @AppStorage("camera.pin1") private var pin1 = "Exposure"
    @AppStorage("camera.pin2") private var pin2 = "Timer"
    @AppStorage("camera.pin3") private var pin3 = "Shot styles"
    @AppStorage("camera.captureDetails") private var showCaptureDetails = false
    @State private var checkIndex = 0
    @State private var passedChecks: Set<Int> = []
    @State private var diagnosticsBaseline: UInt64?
    @State private var diagnosticsPeak: UInt64 = 0
    @State private var diagnosticsBatteryBaseline: Float?
    @State private var confirmDiscard = false
    @AppStorage("camera.showsGrid") private var showsGrid = true
    @State private var toolPath: [CameraToolPage] = []
    @State private var showsCaptureInfo = false
    @State private var showsZoom = false
    @State private var zoomDismissTask: Task<Void, Never>?
    @State private var lastZoomUpdate = Date.distantPast
    @State private var pinchStart: Double?
    @State private var pinchDeviceID: String?
    @AppStorage("camera.dualLayout") private var dualLayout = -1
    @AppStorage("camera.dualCorner") private var dualCorner = 3
    @AppStorage("camera.showHelp") private var showHelp = false
    @State private var showsRecent = false
    @State private var confirmDuplicateSave = false
    @State private var captureControlsHeight: CGFloat = 205
    @State private var zoomControlsHeight: CGFloat = 88
    @State private var headerHeight: CGFloat = 52
    @State private var brightnessTarget: Int?
    @State private var brightnessDismissTask: Task<Void, Never>?
    @State private var imageFrame = CGRect.zero
    @State private var dualImageFrames = [CGRect.zero, CGRect.zero]
    @State private var manualPage: CameraToolPage = .exposure
    @State private var selectedDualIndex = 0
    @State private var visibleTransition: String?
    private var transitionLabel: String? {
        if let mode = model.preparingMode { return "Preparing \(mode.rawValue)…" }
        return model.configuring ? "Preparing camera…" : nil
    }
    private var panelOpen: Bool { showsCaptureInfo || showsRecent || model.reviewingBurst }
    private var enlargedDualIndex: Int? {
        get { (0...1).contains(dualLayout) ? dualLayout : nil }
        nonmutating set { dualLayout = newValue ?? -1 }
    }
    private var hasAdjustments: Bool {
        model.panoramaSelected || model.captureStyle != "Auto" || model.timerSeconds > 0 || model.burstEnabled ||
        model.camera.dualEnabled || model.camera.depthEnabled || model.camera.eyeFocusEnabled ||
        model.camera.focusLocked || model.camera.analysisMode != "Off" || !model.controls.automaticExposure || !model.controls.automaticFocus ||
        !model.controls.automaticWhiteBalance || abs(model.exposureBias) > 0.05
    }

    private let ink = Color.white
    private var overlayColor: Color { .black.opacity(reduceTransparency ? 1 : contrast == .increased ? 0.85 : 0.72) }
    private var menuBackground: Color { .black.opacity(reduceTransparency ? 1 : contrast == .increased ? 0.92 : 0.78) }
    private var separateControlBands: Bool { textSize.isAccessibilitySize }
    private var previewTopInset: CGFloat { separateControlBands ? headerHeight : 0 }
    private var previewBottomInset: CGFloat { separateControlBands ? captureControlsHeight + 8 : 0 }
    private var chromeShade: Double { reduceTransparency ? 1 : contrast == .increased ? 0.90 : 0.72 }
    private let selection = CameraAppearance.selection

    var body: some View {
        GeometryReader { geometry in
            cameraScreen(landscape: adaptiveLayout && geometry.size.width > geometry.size.height)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func cameraPreviewContent(landscape: Bool) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.permission == .authorized {
                if model.camera.dualEnabled {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            ForEach(0..<2, id: \.self) { index in
                                let inset = enlargedDualIndex != nil && enlargedDualIndex != index
                                let width = inset ? geometry.size.width * 0.38 : enlargedDualIndex == nil && landscape ? (geometry.size.width - 4) / 2 : geometry.size.width
                                let height = enlargedDualIndex == nil ? (landscape ? geometry.size.height : (geometry.size.height - 4) / 2) :
                                    inset ? geometry.size.height * 0.32 : geometry.size.height
                                dualViewfinder(zoomText(zoomState(index).value), index: index,
                                               topInset: !separateControlBands && !inset && (landscape || index == 0 || enlargedDualIndex != nil) ? headerHeight + 8 : 8,
                                               bottomInset: !separateControlBands && !inset && (landscape || index == 1 || enlargedDualIndex != nil) ? captureControlsHeight + 8 : 0)
                                    .frame(width: width, height: height)
                                    .clipShape(RoundedRectangle(cornerRadius: inset ? 12 : 0))
                                    .overlay { RoundedRectangle(cornerRadius: inset ? 12 : 0).strokeBorder(.white.opacity(inset ? 0.25 : 0), lineWidth: 2).allowsHitTesting(false) }
                                    .offset(x: inset ? (dualCorner % 2 == 0 ? 8 : geometry.size.width - width - 8) : enlargedDualIndex == nil && landscape ? CGFloat(index) * (width + 4) : 0,
                                            y: enlargedDualIndex == nil ? (landscape ? 0 : CGFloat(index) * (height + 4)) : inset ? (dualCorner < 2 ? (separateControlBands ? 8 : headerHeight + 8) : max(8, geometry.size.height - height - (separateControlBands ? 8 : captureControlsHeight + 8))) : 0)
                                    .zIndex(inset ? 1 : 0)
                            }
                        }
                    }
                    .padding(.top, previewTopInset).padding(.bottom, previewBottomInset)
                    .allowsHitTesting(!panelOpen)
                    .accessibilityHidden(panelOpen)
                } else {
                    GuidedCameraPreview(guides: model.guides, engine: model.engine, onFocus: model.focus, fillView: false, showsFocusFeedback: model.canConfigure && !panelOpen, focusState: model.camera.focusStates.first ?? "Auto focus", exposureOnly: model.exposurePointOnly, showsGrid: showsGrid && !panelOpen, hidesGuides: panelOpen, onImageFrame: { imageFrame = $0.offsetBy(dx: 0, dy: previewTopInset) }, controlStripHeight: (separateControlBands ? 0 : captureControlsHeight + 8) + (showsZoom ? max(140, zoomControlsHeight) : zoomControlsHeight), topControlStripHeight: (separateControlBands ? 0 : headerHeight) + (brightnessTarget == -1 ? 104 : 0))
                        .accessibilityLabel("Camera viewfinder")
                        .simultaneousGesture(zoomGesture(nil))
                        .allowsHitTesting(!panelOpen)
                        .accessibilityHidden(panelOpen)
                        .overlay(alignment: .top) { lensWarningBadge(0).padding(.top, (separateControlBands ? 8 : headerHeight + 8) + (brightnessTarget == -1 ? 104 : 0)) }
                        .padding(.top, previewTopInset)
                        .padding(.bottom, previewBottomInset)
                }
            }

            VStack(spacing: 12) {
                ZStack(alignment: .trailing) {
                    Color.clear.allowsHitTesting(false)
                    if !panelOpen && (model.permission != .authorized || model.camera.message != nil) {
                        cameraNotice.padding(.horizontal, 24).frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func cameraPresentation(landscape: Bool) -> some View {
        cameraPreviewContent(landscape: landscape)
        .overlay(alignment: .bottom) {
            if !panelOpen && !model.camera.dualEnabled {
                viewfinderControls
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ZoomControlsHeightKey.self, value: geometry.size.height)
                        }
                    }
                    .padding(.bottom, captureControlsHeight + 8)
            }
        }
        .overlay(alignment: .bottom) {
            if showsCaptureInfo || model.reviewingBurst || showsRecent {
                GeometryReader { geometry in
                    let available = model.camera.dualEnabled
                        ? CGRect(x: 0, y: 52, width: geometry.size.width, height: max(0, geometry.size.height - captureControlsHeight - 60))
                        : imageFrame
                    let panelBounds = CGRect(x: 0, y: 0, width: geometry.size.width, height: max(0, geometry.size.height - captureControlsHeight - 8))
                    let panel = PreviewGeometry.panelRect(image: available, bounds: panelBounds, preferredHeight: toolPanelHeight, sidePanel: landscape && !textSize.isAccessibilitySize && showsCaptureInfo)
                    Group {
                        if showsRecent, let recent = model.recent {
                            RecentCaptureLoader(model: model, close: { showsRecent = false }).id(recent.date)
                                .background(menuBackground, in: RoundedRectangle(cornerRadius: 12))
                        } else if model.reviewingBurst {
                            BurstReview(model: model)
                                .background(menuBackground, in: RoundedRectangle(cornerRadius: 12))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else { captureInfo }
                    }
                        .frame(width: panel.width, height: panel.height)
                        .clipped()
                        .contentShape(Rectangle())
                        .background { Rectangle().fill(Color.clear).contentShape(Rectangle()).onTapGesture {} }
                        .position(x: panel.midX, y: panel.midY)
                }
            }
        }
        .overlay(alignment: .top) {
            if !panelOpen {
                captureStatus.fixedSize(horizontal: false, vertical: true)
                    .padding(.top, headerHeight + (model.camera.dualEnabled ? 60 : 8) + (brightnessTarget != nil || (showsZoom && model.camera.dualEnabled) ? 96 : 0))
            }
        }
        .overlay(alignment: .top) {
            if brightnessTarget == -1 && !panelOpen {
                brightnessAdjustment(nil).padding(.horizontal, 16).padding(.top, headerHeight + 8)
            }
        }
        .overlay(alignment: .top) {
            if !panelOpen {
                captureHUD
                    .background {
                        LinearGradient(colors: reduceTransparency || separateControlBands ? [.black, .black] : [.black.opacity(chromeShade), .clear], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .top).allowsHitTesting(false)
                    }
                    .background { GeometryReader { geometry in Color.clear.preference(key: CameraHeaderHeightKey.self, value: geometry.size.height) } }
            }
        }
        .overlay(alignment: .bottom) {
            captureControls(landscape: landscape)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: CaptureControlsHeightKey.self, value: geometry.size.height)
                    }
                }
        }
    }

    private func cameraScreen(landscape: Bool) -> some View {
        cameraPresentation(landscape: landscape)
        .onPreferenceChange(CaptureControlsHeightKey.self) { height in
            if height.isFinite && height > 0 { captureControlsHeight = height }
        }
        .onPreferenceChange(ZoomControlsHeightKey.self) { height in
            if height.isFinite && height > 0 { zoomControlsHeight = height }
        }
        .onPreferenceChange(CameraHeaderHeightKey.self) { height in
            if height.isFinite && height > 0 { headerHeight = height }
        }
        .onChange(of: model.camera.dualEnabled) { _, _ in showsZoom = false; zoomDismissTask?.cancel(); closeBrightness() }
        .onChange(of: model.mode) { _, _ in closeBrightness() }
        .onChange(of: model.panoramaSelected) { _, _ in closeBrightness() }
        .onChange(of: model.camera.selectedID) { _, _ in
            closeBrightness(); showsZoom = false; zoomDismissTask?.cancel()
        }
        .onChange(of: showsZoom) { _, open in
            if open {
                closeBrightness()
                if model.camera.dualEnabled, enlargedDualIndex != nil { enlargedDualIndex = selectedDualIndex }
            }
        }
        .onChange(of: selectedDualIndex) { _, index in
            if showsZoom, enlargedDualIndex != nil { enlargedDualIndex = index }
        }
        .onChange(of: enlargedDualIndex) { _, _ in closeBrightness() }
        .onChange(of: lensWarnings) { _, enabled in model.engine.setLensWarningsEnabled(enabled) }
        .onChange(of: model.lensWarnings) { _, warnings in
            // A dismissal lasts until this obstruction clears, independently per lens.
            dismissedLensWarnings.formIntersection(warnings)
        }
        .task(id: transitionLabel) {
            visibleTransition = nil
            guard let label = transitionLabel else { return }
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard !Task.isCancelled, transitionLabel == label else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { visibleTransition = label }
        }
        .onChange(of: panelOpen) { _, open in
            if open { showsZoom = false; zoomDismissTask?.cancel(); closeBrightness() }
        }
        .onDisappear { zoomDismissTask?.cancel(); closeBrightness(); model.setActive(false) }
        .foregroundStyle(ink)
        .tint(selection)
        .preferredColorScheme(.dark)
        .task {
            model.engine.setLensWarningsEnabled(lensWarnings)
            model.setActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { closeBrightness(); showsZoom = false; zoomDismissTask?.cancel() }
            if $0 == .background { model.enteredBackground() }
            model.setActive($0 == .active)
        }
        .confirmationDialog("This capture may already be saved", isPresented: $confirmDuplicateSave, titleVisibility: .visible) {
            Button("Open Photos to check") {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            }
            Button("Save another copy") { Task { await model.retrySave(confirmPossibleDuplicate: true) } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The previous save was interrupted before its result could be confirmed. Saving again may create a duplicate.") }
        .confirmationDialog("Discard the unsaved capture?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard capture", role: .destructive, action: model.discard)
        }
    }

    @ViewBuilder private func lensWarningBadge(_ index: Int) -> some View {
        if lensWarnings && !panelOpen && scenePhase == .active && model.lensWarnings.contains(index) && !dismissedLensWarnings.contains(index) {
            Button { dismissedLensWarnings.insert(index) } label: {
                HStack(spacing: 8) {
                    Label("Check lens", systemImage: "hand.raised.fill")
                    Image(systemName: "xmark").font(.caption2)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(overlayColor, in: Capsule())
            }.buttonStyle(.plain)
                .accessibilityLabel("Camera \(index + 1): a hand may be covering the lens. Dismiss warning")
        }
    }

    private func dualViewfinder(_ title: String, index: Int, topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let visibleImage = dualImageFrames[index]
        let imageTop = PreviewGeometry.isValid(visibleImage) ? max(topInset, visibleImage.minY + 6) : topInset
        let imageSide = PreviewGeometry.isValid(visibleImage) ? max(6, visibleImage.minX + 6) : 6
        return CameraPreview(engine: model.engine, onFocus: { point, locked in
            guard !panelOpen else { return }
            selectedDualIndex = index
            model.focusDual(at: point, index: index, locked: locked)
        }, fillView: false, secondary: index == 1, showsFocusFeedback: !panelOpen && model.canConfigure &&
            model.camera.dualFocusSupported.indices.contains(index) && model.camera.dualFocusSupported[index],
            focusState: model.camera.focusStates.indices.contains(index) ? model.camera.focusStates[index] : "Auto focus",
            exposureOnly: model.exposurePointOnly,
            onImageFrame: { dualImageFrames[index] = $0 },
            controlStripHeight: bottomInset, topControlStripHeight: imageTop + 48 + (brightnessTarget == index || (showsZoom && selectedDualIndex == index) ? 96 : 0))
        .background(.black)
        .overlay(alignment: .top) {
            lensWarningBadge(index).padding(.top, imageTop + 48 + (brightnessTarget == index || (showsZoom && selectedDualIndex == index) ? 96 : 0))
        }
        .simultaneousGesture(zoomGesture(index))
        .overlay(alignment: .topLeading) {
            if !panelOpen && selectedDualIndex == index && PreviewGeometry.isValid(visibleImage) {
                Rectangle().strokeBorder(selection.opacity(0.8), lineWidth: 1)
                    .frame(width: visibleImage.width, height: visibleImage.height)
                    .offset(x: visibleImage.minX, y: visibleImage.minY)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Button {
                        selectedDualIndex = index
                        zoomDismissTask?.cancel()
                        showsZoom = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(title)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(selectedDualIndex == index ? selection : .white)
                        .frame(minHeight: 44).padding(.horizontal, 8)
                        .background(overlayColor, in: Capsule())
                    }
                    .accessibilityLabel("Adjust camera \(index + 1), \(title)")
                    .accessibilityHint(index == 0 ? "Adjusts the Main lens only" : "Adjusts the Ultra Wide lens only")
                    .accessibilityValue(model.camera.focusStates.indices.contains(index) ? model.camera.focusStates[index] : "Fixed focus")
                    .accessibilityAddTraits(selectedDualIndex == index ? .isSelected : [])
                    Button {
                        enlargedDualIndex = enlargedDualIndex == index ? nil : index
                    } label: {
                        Image(systemName: enlargedDualIndex == index ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .frame(width: 44, height: 44)
                            .background(overlayColor, in: Circle())
                    }
                    .accessibilityLabel(enlargedDualIndex == index ? "Show both cameras equally" : "Enlarge \(title)")
                    if enlargedDualIndex == nil || enlargedDualIndex == index {
                        Spacer(minLength: 0)
                        Button {
                            selectedDualIndex = index
                            openBrightness(index)
                        } label: {
                            Image(systemName: "sun.max").frame(width: 44, height: 44)
                                .background(overlayColor, in: Circle())
                        }
                        .accessibilityLabel("Brightness camera \(index + 1), \(title)")
                    }
                }
                if brightnessTarget == index { brightnessAdjustment(index) }
                if showsZoom && selectedDualIndex == index { zoomSlider }
            }
            .padding(.horizontal, imageSide)
            .padding(.top, imageTop)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {}
            .buttonStyle(.plain)
            .disabled(!model.canConfigure)
            .opacity(panelOpen ? 0 : 1)
            .allowsHitTesting(!panelOpen)
            .accessibilityHidden(panelOpen)
        }
        .accessibilityLabel("\(title) live viewfinder. Tap to focus this camera.")
    }

    private func openTool(_ page: CameraToolPage? = nil) {
        closeBrightness()
        showsZoom = false
        zoomDismissTask?.cancel()
        toolPath = page.map { [$0] } ?? []
        showsRecent = false
        showsCaptureInfo = true
    }

    private func closeBrightness() {
        brightnessDismissTask?.cancel()
        brightnessTarget = nil
    }

    private func openBrightness(_ index: Int?) {
        showsZoom = false
        zoomDismissTask?.cancel()
        brightnessDismissTask?.cancel()
        brightnessTarget = index ?? -1
    }

    private func brightnessAdjustment(_ index: Int?) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(index.map { "Camera \($0 + 1) · Brightness" } ?? "Brightness")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Done", action: closeBrightness).frame(minWidth: 44, minHeight: 44)
            }
            HStack {
                Image(systemName: "sun.max")
                Slider(value: Binding(get: { index.map { model.dualBrightness[$0] } ?? model.exposureBias }, set: { value in
                    if let index { model.setDualBrightness(value, index: index) } else { model.exposureBias = value }
                }), in: -2...2, step: 0.1, onEditingChanged: { editing in
                    brightnessDismissTask?.cancel()
                    if !editing && !UIAccessibility.isVoiceOverRunning {
                        brightnessDismissTask = Task { @MainActor in
                            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                            guard !Task.isCancelled else { return }
                            brightnessTarget = nil
                        }
                    }
                }).accessibilityLabel(index.map { "Camera \($0 + 1) brightness" } ?? "Brightness")
                Text(String(format: "%+.1f", index.map { model.dualBrightness[$0] } ?? model.exposureBias))
                    .font(.caption.monospacedDigit()).frame(width: 36)
            }
        }.padding(.horizontal, 12).padding(.bottom, 8)
            .background(menuBackground, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle()).onTapGesture {}
            .disabled(!model.canConfigure)
    }

    private var captureHUD: some View {
        HStack(spacing: 8) {
            if showQuickControls { viewfinderQuickControls }
            else { Spacer() }
            Button { if showsCaptureInfo { showsCaptureInfo = false } else { openTool() } } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                    .foregroundStyle(showsCaptureInfo ? selection : ink)
                    .padding(.vertical, 4)
                    .background(overlayColor, in: RoundedRectangle(cornerRadius: 12))
            }.accessibilityLabel(showsCaptureInfo ? "Close camera controls" : "Camera controls")
        }
        .disabled(!model.canConfigure)
        .padding(.horizontal, 14)
        .buttonStyle(.plain)
        .contentShape(Rectangle()).onTapGesture {}
        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
    }

    private var captureStatus: some View {
        VStack(spacing: 12) {
            if let label = visibleTransition, transitionLabel != nil {
                HStack(spacing: 8) { ProgressView(); Text(label) }
                    .font(.caption.weight(.medium)).padding(8).background(overlayColor, in: Capsule())
                    .accessibilityElement(children: .combine)
                    .allowsHitTesting(false)
            }
            if !showsCaptureInfo && !showsRecent && !model.reviewingBurst {
                if sceneHints, model.lensWarnings.isEmpty, brightnessTarget == nil, !showsZoom,
                   !model.lowStorage, !model.camera.cooling, model.canConfigure, !model.panoramaSelected,
                   model.mode == .photo, model.message == nil, let advice = model.sceneAdvice {
                    Button { openTool(.shoot) } label: {
                        Label(advice, systemImage: "moon").font(.caption).padding(8).frame(minHeight: 44)
                    }
                    .background(overlayColor, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHint("Opens shot styles. Your camera settings are not changed automatically.")
                }
                LiveHistogram(guides: model.guides, overlayColor: overlayColor)
            }
            if model.camera.recording, let started = model.recordingStarted {
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text(model.busy ? "FINISHING" : "REC").fontWeight(.bold)
                        Text(started, style: .timer).monospacedDigit().fixedSize()
                    }
                    Label(model.camera.audioRecording ? "Sound on" : "No sound", systemImage: model.camera.audioRecording ? "mic.fill" : "mic.slash.fill")
                        .font(.caption)
                }.padding(10).background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
            }
            if model.mode == .photo && model.panoramaSelected {
                VStack(spacing: 4) {
                    if !model.panoramaRunning {
                        HStack(spacing: 8) {
                            ForEach(PanoramaMethod.allCases, id: \.self) { method in
                                Button { model.panoramaMethod = method } label: {
                                    Label(method.rawValue, systemImage: method == .sweep ? "arrow.left.and.right" : "square.stack")
                                        .font(.caption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                                        .foregroundStyle(model.panoramaMethod == method ? selection : .white)
                                        .background(model.panoramaMethod == method ? selection.opacity(0.18) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).disabled(!model.canConfigure)
                                    .accessibilityAddTraits(model.panoramaMethod == method ? .isSelected : [])
                            }
                        }.accessibilityElement(children: .contain).accessibilityLabel("Panorama method")
                    }
                    Button {
                        model.panoramaDirection = model.panoramaDirection == .right ? .left : .right
                    } label: {
                        HStack(spacing: 10) {
                            if model.panoramaDirection == .left { Image(systemName: "arrow.left") }
                            Image(systemName: "iphone").font(.title3)
                            Rectangle().fill(.white.opacity(0.5)).frame(height: 1)
                            Image(systemName: "pano").font(.title3)
                            if model.panoramaDirection == .right { Image(systemName: "arrow.right") }
                        }.frame(height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.panoramaRunning || !model.canConfigure)
                        .accessibilityLabel("Panorama direction: " + model.panoramaDirection.rawValue)
                        .accessibilityHint("Tap to reverse direction before capturing")
                    Text(model.message ?? (model.panoramaRunning ? "Keep level · follow the arrow" : model.panoramaMethod == .sweep ? "Press shutter, then sweep · tap arrow to reverse" : "Capture overlapping photos · tap arrow to reverse"))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    if let reference = model.panoramaReference, model.panoramaRunning {
                        HStack(spacing: 8) {
                            Image(uiImage: reference).resizable().scaledToFit().frame(width: 72, height: 54)
                            Text("Previous photo · overlap at least two-thirds").font(.caption2)
                        }.accessibilityElement(children: .combine)
                    }
                    if model.panoramaRunning {
                        if model.panoramaMethod == .stitch && model.panoramaFrames < 3 {
                            Text("At least 3 overlapping photos needed · \(model.panoramaFrames)/3").font(.caption2)
                        }
                        HStack {
                            Text(model.panoramaMethod == .stitch ? "\(model.panoramaFrames) photos / 36" : "\(model.panoramaFrames) photos · \(model.panoramaElapsed)s / \(model.panoramaMethod.maximumSeconds)s").font(.caption.monospacedDigit())
                            Spacer()
                            if model.panoramaMethod == .stitch {
                                Button("Undo") { model.undoPanorama() }
                                    .frame(minWidth: 44, minHeight: 44).disabled(!model.canUndoPanorama)
                                    .accessibilityLabel("Remove last panorama photo")
                                if model.panoramaFrames < PanoramaPolicy.minimumFrames {
                                    Button("Stop") { model.finishPanorama(automatic: true) }
                                        .frame(minWidth: 60, minHeight: 44)
                                        .accessibilityLabel("Stop panorama and keep captured photos")
                                } else {
                                    Button("Finish") { model.finishPanorama() }
                                        .fontWeight(.semibold).frame(minWidth: 60, minHeight: 44).disabled(!model.canFinishPanorama)
                                }
                            }
                        }
                    }
                }.font(.caption).padding(10).background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.longExposureRunning {
                Button("Finish sequence early") { model.finishLongExposure() }
                    .font(.callout.weight(.semibold)).padding(10)
                    .background(overlayColor, in: RoundedRectangle(cornerRadius: 8))
            }
            if model.countdown > 0 {
                Text("\(model.countdown)").font(.system(size: 64, weight: .bold))
                    .accessibilityLabel("Shutter in \(model.countdown) seconds")
            }
            if model.lowStorage || model.camera.cooling || (!model.panoramaSelected && model.message != nil) || (model.hasPendingCapture && model.canUseRecovery) {
                VStack(spacing: 6) {
                    if model.lowStorage { Text("Low storage · free space before recording").font(.caption) }
                    if model.camera.cooling { Text("iPhone is warm · processing reduced").font(.caption) }
                    if let message = model.message, !model.panoramaSelected {
                        Label(model.busy ? model.captureActivity.rawValue : message, systemImage: model.busy ? "hourglass" : model.hasPendingCapture ? "exclamationmark.triangle" : "info.circle")
                            .font(CameraViewModel.isBriefStatus(message) ? .caption : .callout).accessibilityLabel(message)
                        if model.busy && showHelp { Text(message).font(.caption) }
                    }
                    if model.hasPendingCapture && model.canUseRecovery {
                        ViewThatFits(in: .horizontal) {
                            HStack { saveRecovery }
                            VStack { saveRecovery }
                        }.font(.callout)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(10)
                .background(overlayColor, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 14)
    }

    private var viewfinderQuickControls: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: !quickAccess && model.panoramaSelected && model.mode == .photo ? 1 : 3), spacing: 8) {
            if quickAccess {
                ForEach(Array([pin1, pin2, pin3].enumerated()), id: \.offset) { _, name in
                    if let page = CameraToolPage(rawValue: name) {
                        quickControl(page.rawValue, icon: page.icon, value: "Open") { openTool(page) }
                    }
                }
            } else {
                if model.mode == .photo {
                    if !model.panoramaSelected {
                        quickControl("Flash", icon: model.controls.flash == .off ? "bolt.slash" : "bolt.fill",
                                     value: model.controls.flash == .off ? "Off" : model.controls.flash == .auto ? "Auto" : "On",
                                     active: model.controls.flash != .off) {
                            model.controlBinding.flash.wrappedValue = model.controls.flash == .off ? .auto : model.controls.flash == .auto ? .on : .off
                        }.disabled(!model.camera.flashAvailable || model.camera.dualEnabled)
                    }
                    quickControl("Timer", icon: "timer", value: model.timerSeconds == 0 ? "Off" : "\(model.timerSeconds)s", active: model.timerSeconds > 0) {
                        model.timerSeconds = model.timerSeconds == 0 ? 3 : model.timerSeconds == 3 ? 10 : 0
                    }
                    if !model.panoramaSelected {
                        quickControl("Night", icon: model.captureStyle == "Night" ? "moon.fill" : "moon", value: model.captureStyle == "Night" ? "On" : "Off", active: model.captureStyle == "Night") {
                            model.setNightEnabled(model.captureStyle != "Night")
                        }
                    }
                } else {
                    quickControl("Brightness", icon: "sun.max", value: String(format: "%+.1f EV", model.exposureBias)) { openBrightness(nil) }
                    quickControl("Video quality", icon: "video", value: model.camera.videoLabel) { openTool(.video) }
                    quickControl("Grid", icon: "square.split.3x3", value: showsGrid ? "On" : "Off", active: showsGrid) { showsGrid.toggle() }
                }
            }
        }
        .padding(4)
        .frame(maxWidth: 420)
        .disabled(!model.canConfigure)
    }

    private func quickControl(_ title: String, icon: String, value: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium)).frame(height: 22)
                if value != "Off" && value != "On" {
                    Text(value == "Open" ? title : value).font(.caption2)
                        .lineLimit(textSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
            .background(overlayColor, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? selection : .white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("Touch and hold for the control name and current setting")
        .contextMenu {
            Text(title)
            Text(value == "Open" ? "Opens camera controls" : "Current setting: \(value)")
        }
    }

    private func zoomState(_ index: Int? = nil) -> CameraZoom {
        let target = index ?? 0
        return model.camera.zooms.indices.contains(target) ? model.camera.zooms[target] : CameraZoom()
    }

    private func zoomText(_ value: Double) -> String { String(format: "%.1f×", value) }

    private func zoomGesture(_ index: Int?) -> some Gesture {
        MagnificationGesture().onChanged { scale in
            guard model.canConfigure else { return }
            if pinchStart == nil { pinchStart = zoomState(index).value; pinchDeviceID = zoomState(index).deviceID }
            if let index { selectedDualIndex = index }
            zoomDismissTask?.cancel()
            showsZoom = true
            guard Date().timeIntervalSince(lastZoomUpdate) > 0.05 else { return }
            lastZoomUpdate = Date()
            model.engine.setZoom((pinchStart ?? 1) * Double(scale), deviceID: pinchDeviceID ?? "", dualIndex: index)
        }.onEnded { scale in
            if model.canConfigure, let start = pinchStart, let id = pinchDeviceID {
                model.engine.setZoom(start * Double(scale), deviceID: id, dualIndex: index)
            }
            pinchStart = nil; pinchDeviceID = nil
            dismissZoomLater()
        }
    }

    private var zoomSlider: some View {
        let index: Int? = model.camera.dualEnabled ? selectedDualIndex : nil
        let zoom = zoomState(index)
        return HStack {
            VStack(spacing: 2) {
                if model.camera.dualEnabled { Text(index == 0 ? "Camera 1" : "Camera 2").font(.caption2) }
                Text(zoomText(zoom.value)).monospacedDigit().font(.callout.weight(.semibold))
            }
            if zoom.maximum > zoom.minimum {
                Slider(value: Binding(get: { log(max(zoom.minimum, zoom.value)) }, set: {
                    let value = exp($0)
                    let stops = ([zoom.minimum] + ZoomShortcuts.make(model.camera.lenses).map(\.value)).filter { $0 >= zoom.minimum && $0 <= zoom.maximum }
                    let snapped = stops.first(where: { abs(log(value / $0)) < 0.015 }) ?? value
                    model.engine.setZoom(snapped, deviceID: zoom.deviceID, dualIndex: index)
                }), in: log(zoom.minimum)...log(zoom.maximum), onEditingChanged: { editing in
                    zoomDismissTask?.cancel()
                    if !editing { dismissZoomLater() }
                })
                .accessibilityLabel("Camera zoom")
                .accessibilityValue(zoomText(zoom.value))
                .disabled(!model.canConfigure)
            }
            Button { showsZoom = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("Close zoom slider")
        }.padding(.leading, 12).background(overlayColor, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle()).onTapGesture {}
    }

    private func dismissZoomLater() {
        zoomDismissTask?.cancel()
        guard !UIAccessibility.isVoiceOverRunning else { return }
        zoomDismissTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            showsZoom = false
        }
    }

    private var zoomChoices: some View {
        ForEach(ZoomShortcuts.make(model.camera.lenses).filter { choice in
            model.mode != .video || (choice.value >= zoomState().minimum && choice.value <= zoomState().maximum)
        }) { choice in
            Button { model.selectZoom(choice) } label: {
                Text(choice.value.rounded() == choice.value ? String(format: "%.0f×", choice.value) : zoomText(choice.value))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle((model.mode == .video || choice.lens.id == model.camera.selectedID) && abs(zoomState().value - choice.value) < 0.05 ? selection : .white)
                    .background(overlayColor, in: Capsule())
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(zoomText(choice.value)) zoom")
            .accessibilityHint(model.mode == .video ? "Zooms the current \(model.selectedLens?.name ?? "selected") camera; does not switch lenses" : "Selects this photo perspective")
            .disabled(model.mode == .video ? !model.canConfigure || !model.camera.running : !model.canSwitch)
        }
    }

    private var lensSelector: some View {
        VStack(spacing: 3) {
        HStack(spacing: 4) {
            if model.selectedLens?.isFront == false {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { zoomChoices }.fixedSize(horizontal: true, vertical: false)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 72 : 44))], spacing: 4) { zoomChoices }
                }
            }
            Button { zoomDismissTask?.cancel(); showsZoom.toggle() } label: {
                Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
                    .background(overlayColor, in: Capsule())
                    .contentShape(Rectangle())
            }.accessibilityLabel("Adjust zoom")
        }.buttonStyle(.plain).disabled(!model.canConfigure)
        if model.mode == .video {
            Text("Zoom on \(model.selectedLens?.name ?? "selected") camera")
                .font(.caption2).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .accessibilityHint("To change the physical camera, select a lens in Photo before switching to Video")
        }
        }
    }

    private var cameraNotice: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera").font(.largeTitle)
            if model.permission == .authorized {
                Text(model.camera.message ?? "Camera unavailable.")
                Button("Retry camera") { model.engine.restartPreview() }.disabled(model.busy || model.camera.recording)
            } else {
                Text("Camera access lets you preview and take photos on this iPhone.")
                if model.permission == .notDetermined {
                    Button("Enable camera") { Task { await model.requestCamera() } }
                } else if model.permission == .restricted {
                    Text("Camera access is restricted on this device.")
                } else {
                    Button("Open Settings", action: openSettings)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .background(menuBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private var viewfinderControls: some View {
        lensSelector.disabled(panelOpen).frame(minHeight: 44)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func captureControls(landscape: Bool) -> some View {
        let layout = landscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 6))
        let modeLayout = landscape ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if model.mode == .photo {
                HStack(spacing: 4) {
                    ForEach([false, true], id: \.self) { dual in
                        let selected = model.camera.dualEnabled == dual
                        Button { model.setDualEnabled(dual) } label: {
                            Label(dual ? "Dual" : "Single", systemImage: dual ? "rectangle.on.rectangle" : "rectangle")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(selected ? selection : .white)
                                .background(selected ? selection.opacity(0.20) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .disabled(!model.canConfigure || panelOpen || (dual && !model.camera.dualAvailable))
                        .accessibilityHint(dual && !model.camera.dualAvailable ? "Two-camera capture is unavailable on the selected camera setup" : dual ? "Capture two perspectives" : "Capture one perspective")
                    }
                }.padding(4)
                    .frame(maxWidth: textSize.isAccessibilitySize ? 320 : 260)
                    .frame(width: landscape ? 260 : nil)
                    .background(overlayColor, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .contain).accessibilityLabel("Cameras")
            } else if landscape {
                // Preserve horizontal positions without adding an empty portrait row.
                Color.clear.frame(width: 260, height: 52)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            modeLayout {
                ForEach(0..<3) { index in
                    let selected = model.mode == .video ? index == 2 : index == (model.panoramaSelected ? 1 : 0)
                    Button { showsCaptureInfo = false; showsRecent = false; model.chooseCaptureMode(index) } label: {
                        Text(["PHOTO", "PANORAMA", "VIDEO"][index])
                            .font(.caption.weight(.semibold)).lineLimit(textSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.8)
                            .frame(minWidth: 60, maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selected ? selection : .white)
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .disabled(!model.canConfigure)
                }
            }
            .padding(.horizontal, 8)

            HStack {
                Button {
                    if model.recent != nil { showsCaptureInfo = false; showsRecent = true }
                    else { openPhotos() }
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let thumbnail = model.lastSavedThumbnail {
                                    Image(uiImage: thumbnail).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "photo.on.rectangle").font(.title3)
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 48, height: 48).clipped()
                            .background(.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            if model.lastSavedPhotoCount > 1 {
                                Text("\(model.lastSavedPhotoCount)").font(.caption2.bold()).padding(3)
                                    .foregroundStyle(.black).background(.white, in: RoundedRectangle(cornerRadius: 8))
                            }
                            // Keep the library affordance visible even for a dark thumbnail.
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(4).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                                .frame(width: 48, height: 48, alignment: .bottomLeading)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityLabel(model.lastSavedThumbnail == nil ? "Open Photos" : "Review last saved capture")
                .disabled(!model.canConfigure)
                .frame(maxWidth: .infinity)

                Button { showsCaptureInfo = false; showsRecent = false; model.shutter() } label: {
                    VStack(spacing: 4) {
                    ZStack {
                        Circle().fill(model.mode == .video ? Color.red : Color.white)
                        Circle().strokeBorder(Color.black.opacity(0.65), lineWidth: 2).padding(5)
                        if model.panoramaRunning && model.panoramaMethod == .sweep { RoundedRectangle(cornerRadius: 4).fill(.black).frame(width: 28, height: 28) }
                        else if model.camera.recording { RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 28, height: 28) }
                        else if model.panoramaTakingPhoto || (model.busy && !model.panoramaRunning) || model.configuring { ProgressView().tint(.black) }
                    }
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    Text(model.panoramaRunning ? (model.panoramaMethod == .sweep ? "Finish" : "Add photo") : model.mode == .video ? model.videoButtonTitle : " ")
                        .font(.caption.weight(.semibold)).lineLimit(1)
                        .accessibilityHidden(model.mode != .video && !model.panoramaRunning)
                    }
                }
                .accessibilityLabel(model.panoramaRunning ? (model.panoramaMethod == .sweep ? "Finish panorama" : "Add panorama photo") : model.mode == .photo ? "Take photo" : model.camera.recording ? "Stop recording" : "Start recording")
                .accessibilityValue(model.shutterStatus)
                .disabled(!model.canShutter)
                .opacity(model.canShutter ? 1 : 0.4)

                Button(action: model.flip) {
                    VStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title3)
                        .frame(width: 48, height: 48)

                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Switch front and rear camera")
                .disabled(panelOpen || !model.canSwitch || !model.camera.lenses.contains { $0.isFront != model.selectedLens?.isFront })
            }
            .frame(minWidth: landscape ? 200 : nil)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: reduceTransparency || separateControlBands ? [.black, .black] : [.black.opacity(chromeShade), .black.opacity(chromeShade)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .overlay(alignment: .top) {
            if showsZoom && !model.camera.dualEnabled && !showsCaptureInfo && !showsRecent && !model.reviewingBurst {
                zoomSlider.fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .alignmentGuide(.top) { dimensions in dimensions[.bottom] + 8 }
            }
        }
    }

    @ViewBuilder private var saveRecovery: some View {
        Button(model.saveNeedsConfirmation ? "Check save status" : model.panoramaRecovery?.saved == true ? "Finish cleanup" : model.panoramaRecovery?.readyToSave == false ? "Finish panorama" : "Retry save") {
            if model.saveNeedsConfirmation { confirmDuplicateSave = true }
            else { Task { await model.retrySave() } }
        }
        if model.canSavePanoramaPhoto {
            Button("Save available photo") { Task { await model.saveAvailablePanoramaPhoto() } }
        }
        Button("Settings", action: openSettings)
        Button("Discard", role: .destructive) { confirmDiscard = true }
    }

    private var toolPanelHeight: CGFloat {
        if model.reviewingBurst || textSize.isAccessibilitySize { return .infinity }
        if showsRecent { return model.recent?.isVideo == true ? 400 : .infinity }
        let base: CGFloat
        switch toolPath.last {
        case nil: return (advancedTools ? 510 : 360) + (hasAdjustments && advancedTools ? 44 : 0)
        case .shoot: base = model.camera.dualEnabled ? 370 : 350
        case .preferences:
            base = 510
        case .timer: base = 260
        case .video: base = 460
        case .gallery, .rescue: return .infinity
        default: base = 440
        }
        return base + (showHelp ? 120 : 0)
    }

    private var captureInfo: some View {
        VStack(spacing: 0) {
            HStack {
                if !toolPath.isEmpty {
                    Button { toolPath.removeLast() } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("Back")
                }
                Text(toolPath.last?.rawValue ?? "Camera controls").font(.headline)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer()
                Button { showHelp.toggle() } label: {
                    Image(systemName: showHelp ? "info.circle.fill" : "info.circle").frame(width: 44, height: 44)
                }.accessibilityLabel(showHelp ? "Hide tool explanations" : "Show tool explanations")
                Button { showsCaptureInfo = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Close camera tools")
            }.padding(.horizontal, 12).fixedSize(horizontal: false, vertical: true)
            if let page = toolPath.last {
                toolPage(page)
            } else {
                CompactToolLayout {
                    VStack(alignment: .leading, spacing: 2) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: textSize.isAccessibilitySize ? 2 : 3), spacing: 8) {
                        controlTile("Brightness", icon: "sun.max", value: model.camera.dualEnabled ? "Selected lens" : String(format: "%+.1f EV", model.exposureBias)) { toolPath.append(.exposure) }
                        if model.mode == .photo {
                            controlTile("Timer", icon: "timer", value: model.timerSeconds == 0 ? "Off" : "\(model.timerSeconds)s", selected: model.timerSeconds > 0) {
                                model.timerSeconds = model.timerSeconds == 0 ? 3 : model.timerSeconds == 3 ? 10 : 0
                            }
                            if !model.panoramaSelected {
                                controlTile("Night", icon: "moon", value: model.captureStyle == "Night" ? "On" : "Off", selected: model.captureStyle == "Night") { model.setNightEnabled(model.captureStyle != "Night") }
                                controlTile("Style", icon: "camera", value: model.camera.dualEnabled ? model.camera.dualMode.rawValue : model.captureStyle) { toolPath.append(.shoot) }
                                if !model.camera.dualEnabled {
                                    controlTile("Long exposure", icon: "sparkles", value: model.captureStyle == "Long Exposure" ? "On" : "Off") { toolPath.append(.longExposure) }
                                }
                            }
                        } else {
                            controlTile("Video quality", icon: "video", value: model.camera.videoLabel) { toolPath.append(.video) }
                        }
                        controlTile("Grid", icon: "square.split.3x3", value: showsGrid ? "On" : "Off", selected: showsGrid) { showsGrid.toggle() }
                    }
                    Divider()
                    Button { advancedTools.toggle() } label: {
                        HStack {
                            Label("Advanced", systemImage: "slider.horizontal.3")
                            Spacer()
                            Image(systemName: advancedTools ? "chevron.up" : "chevron.down")
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityValue(advancedTools ? "Expanded" : "Collapsed")
                    if advancedTools {
                        if !model.camera.dualEnabled {
                            Picker("Manual control", selection: $manualPage) {
                                Text("Exposure").tag(CameraToolPage.exposure)
                                Text("Color").tag(CameraToolPage.color)
                                Text("Focus").tag(CameraToolPage.manualFocus)
                            }.pickerStyle(.segmented)
                            ManualCameraControls(model: model, page: manualPage)
                        }
                        toolGrid([.focus, .guides, .details])
                        if hasAdjustments && model.camera.dualEnabled {
                            Button("Reset camera controls", action: model.resetControls)
                                .frame(minHeight: 44).disabled(!model.canConfigure)
                        }
                    }
                    Divider()
                    Button { toolPath.append(.preferences) } label: {
                        HStack {
                            Image(systemName: "gearshape")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("App settings")
                                Text("Memory, layout & vibrations").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    }
                }
            }
        }
        .background(menuBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15), lineWidth: 1).allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func controlTile(_ title: String, icon: String, value: String? = nil, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                if let value { Text(value).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }
            .frame(maxWidth: .infinity, minHeight: 68).padding(6)
            .foregroundStyle(selected ? selection : .white)
            .background(selected ? selection.opacity(0.18) : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toolGrid(_ pages: [CameraToolPage]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: textSize.isAccessibilitySize ? 2 : 3), spacing: 8) {
            ForEach(pages, id: \.self) { page in
                controlTile(page.rawValue, icon: page.icon) { toolPath.append(page) }
            }
        }
    }

    @ViewBuilder private func toolPage(_ page: CameraToolPage) -> some View {
        Group {
            switch page {
            case .panorama:
                CompactToolLayout {
                    Text(model.camera.dualEnabled ? "Two perspectives, one panorama session" : "Choose how to capture").font(.headline)
                    Picker("Panorama method", selection: $model.panoramaMethod) {
                        ForEach(PanoramaMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Sweep direction", selection: $model.panoramaDirection) {
                        ForEach(PanoramaDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Text(model.panoramaMethod.instructions)
                    Text("Beta: saves JPEG panoramas separately for each lens. Capture is limited to 36 photos (45 seconds for Sweep, 3 minutes for Stitch); stitching runs one lens at a time afterward. Up to 32 MP per result, depending on sweep and cropping. Not a 360° capture. Moving subjects, close objects and large turns may show seams.").font(.caption)
                    Text("Accepted shots stay on this iPhone until saved or discarded. In Dual, a failed view keeps a reference photo while the successful panorama is retained.").font(.caption)
                    Button("Use panorama") { model.enablePanorama(); showsCaptureInfo = false }
                        .buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(!model.canConfigure || model.mode != .photo)
                }
            case .longExposure:
                CompactToolLayout {
                    Picker("Long exposure style", selection: $model.longExposureStyle) {
                        ForEach(LongExposureStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu)
                    Text(model.longExposureStyle.explanation).font(.callout)
                    Picker("Total capture time", selection: $model.longExposureSeconds) {
                        ForEach([15.0, 30, 60, 120, 300], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }.pickerStyle(.menu)
                    LabeledContent("Actual shutter / ISO", value: model.camera.exposureLabel)
                    Text("Total time combines separate stills, not one continuous shutter exposure. Up to 90 frames at 12 MP; heat, memory and storage limits may end the sequence early. The combined JPEG and one reference original are saved; intermediate frames are temporary.").font(.caption)
                    Button("Focus & exposure") { toolPath.append(.exposure) }
                    Button("Use long exposure") { model.enableLongExposure(); showsCaptureInfo = false }
                        .buttonStyle(.borderedProminent).foregroundStyle(.black)
                        .disabled(!model.canConfigure || model.camera.dualEnabled || model.mode != .photo || model.panoramaSelected)
                }
            case .rescue:
                PhotoRescueView()
            case .gallery: CameraDesignGallery()
            case .advanced:
                CompactToolLayout {
                    toolGrid([.exposure, .color, .manualFocus, .details])
                    Button("Reset camera controls", action: model.resetControls).buttonStyle(.bordered)
                }
            case .guides:
                CompactToolLayout {
                    Picker("Viewfinder guide", selection: Binding(get: { model.camera.analysisMode }, set: { model.engine.setAnalysis($0) })) {
                        Text("Off").tag("Off"); Text("Peaking").tag("Peaking")
                        Text("Highlights").tag("Highlights"); Text("Histogram").tag("Histogram")
                    }.pickerStyle(.segmented).disabled(!model.canConfigure || model.camera.dualEnabled || model.mode == .video)
                    Text(model.camera.dualEnabled || model.mode == .video ? "Guides need single-camera Photo mode. Switch to Photo and turn off Dual Shot." : "Peaking marks strong edges; highlights mark near-white preview areas. These are approximate guides, not a guarantee of focus or clipping in the saved photo.").font(.footnote)
                    Text("One guide at a time. Eye focus turns off while guides are active. Guides pause when your iPhone is warm and never appear in saved photos.").font(.footnote)
                }
            case .exposure, .color, .manualFocus:
                CompactToolLayout {
                    if model.camera.dualEnabled && page == .exposure {
                        let index = selectedDualIndex
                        Text(index == 0 ? "Main brightness" : "Ultra Wide brightness")
                            .foregroundStyle(selection)
                        Slider(value: Binding(get: { model.dualBrightness[index] }, set: { model.setDualBrightness($0, index: index) }), in: -2...2, step: 0.1)
                            .accessibilityLabel(index == 0 ? "Main brightness" : "Ultra Wide brightness")
                        Text(String(format: "%+.1f EV", model.dualBrightness[index])).monospacedDigit()
                    } else if model.camera.dualEnabled {
                        Text("Manual controls use a single camera.")
                        Button("Switch to single Photo") { model.activate(.automatic) }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                    } else {
                        ManualCameraControls(model: model, page: page)
                    }
                }
            default:
                CompactToolLayout { simpleToolPage(page) }
            }
        }
        .navigationTitle(page.rawValue).navigationBarTitleDisplayMode(.inline)
    }

    private func useTool(_ tool: QuickCaptureTool) {
        model.activate(tool)
        showsCaptureInfo = false
    }

    @ViewBuilder private func simpleToolPage(_ page: CameraToolPage) -> some View {
        switch page {
        case .shoot:
            if showHelp {
                Text("Fast takes both views close together. Detail waits for the main photo to finish before taking the ultra-wide photo. Moving subjects may change position between photos.").font(.footnote)
            }
            if model.camera.dualEnabled {
                Toggle("Night · Beta", isOn: Binding(get: { model.captureStyle == "Night" }, set: model.setNightEnabled))
                    .disabled(!model.canConfigure)
                if model.captureStyle == "Night" {
                    Text("Hold still. Reference originals are saved too.").font(.footnote)
                    if showHelp { Text("Three sequential pairs, aligned separately per lens. Up to 12 MP per frame.").font(.footnote) }
                } else {
                Picker("Dual Shot capture", selection: Binding(get: { model.camera.dualMode }, set: { model.setDualMode($0) })) {
                    ForEach(DualShotMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(!model.canConfigure)
                Text(model.camera.dualMode == .fast ? "For moving subjects and quick moments." : "For still scenes. Hold still until both photos finish.")
                    .font(.footnote)
                if showHelp { Text(model.camera.dualMode == .fast ? "Up to 12 MP per view." : "Photos are taken in sequence. Up to 48 MP where supported.").font(.footnote) }
                Text(model.camera.resolution).font(.caption).monospacedDigit()
                }
            } else {
            if model.mode == .video {
                Text("Selecting a style switches to its compatible Photo setup.").font(.footnote)
            }
            featureButton("Automatic", icon: "camera", detail: "Everyday photos with automatic settings") { useTool(.automatic) }
            featureButton("Action burst", icon: "figure.run", detail: "Fast shutter and 3 photos. Needs good light.") { useTool(.action) }
            featureButton("Night · Beta", icon: "moon", detail: "Align matching frames; preserve a reference original. Best for still scenes.") { useTool(.night) }
            featureButton("Best Shot", icon: "square.stack", detail: "Take 3 photos, then choose your favorite") { useTool(.burst) }
            }
        case .focus:
            Picker("Tap adjusts", selection: $model.exposurePointOnly) {
                Text("Focus").tag(false); Text("Brightness").tag(true)
            }.pickerStyle(.segmented)
            if showHelp { Text("Focus and brightness use separate points. Hold to request a focus lock; the label confirms when the lens is locked, not whether your subject is sharp.").font(.footnote) }
            Button("Unlock and reset focus / exposure") { model.resetControls() }.buttonStyle(.bordered)
            featureButton(model.camera.eyeFocusEnabled ? "Turn off eye focus" : "Eye focus · Beta", icon: "eye", detail: "Experimental. Follows an eye on the largest face in rear Photo mode.") {
                if model.camera.eyeFocusEnabled { model.setEyeFocus(false) } else { useTool(.eye) }
            }
            if model.camera.lenses.contains(where: { $0.name == "Depth" || $0.name == "Front Depth" }) {
                featureButton(model.camera.depthEnabled ? "Turn off depth" : "Depth capture", icon: "square.3.layers.3d", detail: "Switches to a depth-capable camera. Saves depth without adding blur.") {
                    if model.camera.depthEnabled { model.engine.setDepthEnabled(false) } else { useTool(.depth) }
                }
            }
        case .timer:
            Text("Give yourself time to get in the photo.").foregroundStyle(.secondary)
            Picker("Shutter delay", selection: $model.timerSeconds) {
                Text("Off").tag(0); Text("3 sec").tag(3); Text("10 sec").tag(10)
            }.pickerStyle(.segmented)
            Text("The timer turns off after use. Leaving the app cancels an active countdown.").font(.footnote)
            Button("Ready") { showsCaptureInfo = false }.buttonStyle(.borderedProminent).foregroundStyle(.black)
        case .video:
            VideoQualityControls(model: model)
        case .shortcuts:
            Toggle("Show quick controls", isOn: $showQuickControls)
            Toggle("Use custom shortcuts", isOn: $quickAccess)
            if quickAccess {
            shortcutPicker("First", selection: $pin1, excluding: [pin2, pin3])
            shortcutPicker("Second", selection: $pin2, excluding: [pin1, pin3])
            shortcutPicker("Third", selection: $pin3, excluding: [pin1, pin2])
            }
            Text("Standard controls adapt to Photo, Dual Shot and Video. Custom shortcuts replace that row with your three chosen tools. Controls hide while a menu is open.").font(.footnote)
        case .checks:
            Text("iPhone beta checks").font(.headline)
            Button("Restart camera preview") { model.engine.restartPreview() }
                .frame(minHeight: 44).disabled(!model.canConfigure || model.camera.recording)
            Text("Use if the image has frozen. Restart is unavailable during capture or recording.").font(.caption)
            DeviceDiagnosticsView(peak: $diagnosticsPeak, baseline: $diagnosticsBaseline, batteryBaseline: $diagnosticsBatteryBaseline)
            if let value = model.lastCaptureMilliseconds { Text("Last capture processing: \(value) ms").font(.caption) }
            if let value = model.lastSaveMilliseconds { Text("Last save: \(value) ms").font(.caption) }
            Text("Timings stay on this device for this session. Capture processing is not shutter lag; memory and responsiveness need device profiling.").font(.caption)
            Text("\(passedChecks.count) of \(deviceChecks.count) marked passed this session").font(.caption)
            Text(deviceChecks[checkIndex]).fixedSize(horizontal: false, vertical: true)
            Button("Mark passed and next") {
                passedChecks.insert(checkIndex)
                checkIndex = (checkIndex + 1) % deviceChecks.count
            }.buttonStyle(.borderedProminent).foregroundStyle(.black)
            Button("Not passed / skip") {
                passedChecks.remove(checkIndex)
                checkIndex = (checkIndex + 1) % deviceChecks.count
            }.buttonStyle(.bordered)
            Button("Reset checklist") { passedChecks = []; checkIndex = 0 }
            Text("Mark a check only after testing it. No results are uploaded.").font(.footnote)
        case .preferences:
            Label("Camera", systemImage: "camera").font(.subheadline.weight(.semibold))
            Toggle("Rotate layout", isOn: $adaptiveLayout)
            Toggle("Composition grid", isOn: $showsGrid)
            Toggle("Low-light hints", isOn: $sceneHints)
            Toggle("Finger warning", isOn: $lensWarnings)
            Text("Suggests checking the lens when a hand or a blurred obstruction stays near an edge. Detection is best effort and may miss an obstruction or mistake part of the scene for one. Pauses during capture, Low Power Mode or when the phone is warm.").font(.caption).foregroundStyle(.secondary)
            Toggle("Capture vibrations", isOn: $model.haptics)
            Toggle("Remember controls", isOn: $rememberSetup)
            Text("Quality starts at the highest supported preset on each launch. Recording never resumes automatically.").font(.caption).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup("Camera shortcuts") {
                Toggle("Show shortcuts", isOn: $showQuickControls)
                Toggle("Customize shortcuts", isOn: $quickAccess)
                if quickAccess {
                    shortcutPicker("First", selection: $pin1, excluding: [pin2, pin3])
                    shortcutPicker("Second", selection: $pin2, excluding: [pin1, pin3])
                    shortcutPicker("Third", selection: $pin3, excluding: [pin1, pin2])
                }
            }
            DisclosureGroup("Dual preview position") {
                Picker("Small preview", selection: $dualCorner) {
                    Text("Top left").tag(0); Text("Top right").tag(1)
                    Text("Bottom left").tag(2); Text("Bottom right").tag(3)
                }.pickerStyle(.menu)
            }
            DisclosureGroup("Photo history & device checks") {
                Toggle("Photo details", isOn: $showCaptureDetails)
                Button("Clear recent preview") { Task { await model.clearRecent() } }.frame(minHeight: 44)
                Text("Photos and unsaved captures are kept.").font(.caption)
                Button("Device health & testing") { toolPath.append(.checks) }.frame(minHeight: 44)
            }
        case .details:
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
            LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
            Text("The preview shows the entire camera frame without cropping it to fill the screen. Space around it preserves the photo or video’s proportions.").font(.caption)
            Text("Zoom shortcuts follow this phone’s lenses and reported sensor-crop capabilities. Intermediate zoom can crop or enlarge the image; greater magnification does not always mean more detail.").font(.caption)
            LabeledContent("Capture status", value: model.shutterStatus)
            LabeledContent("Mode", value: model.mode.rawValue)
            if model.captureStyle == "Night" { Text("Night is experimental: up to four frames for Single Photo or three pairs for Dual Shot, at up to 12 MP per frame. Changed or blurred frames are rejected. Merged views and reference originals are saved; unsuitable sequences keep originals.").font(.caption) }
            LabeledContent("Lens", value: model.selectedLens?.name ?? "Unavailable")
            LabeledContent("Resolution", value: model.mode == .photo ? model.camera.resolution : model.camera.videoLabel)
            if let recent = model.recent, !recent.photos.isEmpty {
                ForEach(recent.photos.indices, id: \.self) { index in
                    let photo = recent.photos[index]
                    LabeledContent("Last \(photo.label)", value: "\(photo.width) × \(photo.height)")
                }
            }
            if let latency = model.readyMilliseconds { LabeledContent("Camera ready", value: "\(latency) ms after opening") }
            Text("Readiness is measured locally; shutter response still needs a device test.").font(.caption)
            LabeledContent("Exposure", value: model.camera.exposureLabel)
            LabeledContent("Focus", value: model.camera.focusLabel)
        default: EmptyView()
        }
    }

    private func featureButton(_ title: String, icon: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if showHelp { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if featureSelected(title) { Image(systemName: "checkmark").foregroundStyle(selection) }
            }.padding(8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!model.canConfigure).accessibilityHint(detail)
            .accessibilityAddTraits(featureSelected(title) ? .isSelected : [])
    }

    private func featureSelected(_ title: String) -> Bool {
        switch title {
        case "Automatic": return !model.camera.dualEnabled && model.mode == .photo && model.captureStyle == "Auto" && !model.burstEnabled
        case "Action burst": return model.captureStyle == "Action"
        case "Night · Beta": return model.captureStyle == "Night"
        case "Best Shot": return model.burstEnabled && model.captureStyle == "Auto"
        case "Dual Shot": return model.camera.dualEnabled
        default: return title.hasPrefix("Turn off")
        }
    }
    private func shortcutPicker(_ title: String, selection: Binding<String>, excluding: [String]) -> some View {
        LabeledContent(title) {
            Picker(title, selection: selection) {
                ForEach([CameraToolPage.shoot, .focus, .timer, .exposure, .color, .manualFocus, .details, .preferences].filter {
                    !excluding.contains($0.rawValue) || $0.rawValue == selection.wrappedValue
                }, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            }.pickerStyle(.menu).labelsHidden()
        }
    }
    private let deviceChecks = [
        "Endurance: run 10 rounds of Photo → Dual → Panorama → Video → Photo. Take one photo or pair in each photo mode and a 10-second video. Finish each save before switching. Export diagnostics if the preview freezes or the app closes; after relaunch, export before repeating the test.",
        "Recovery: lock and unlock the phone, open Photos and return, and interrupt with a phone call while idle. Repeat during capture and recording. The camera must remain off in the background, must not restart an interrupted recording, and must preserve unsaved captures. Never force-close during a save unless testing recovery with disposable photos.",
        "Quality: use a stationary detailed scene in daylight and low light. From the same position, compare Single, Dual Fast and Dual Detail for both lenses, then Sweep and Stitch panoramas. Check pixel dimensions in Photos, sharpness at equal magnification, color, highlights, seams and ghosting. Repeat each setup three times. Keep original files; a larger pixel count alone is not proof of better quality.",
        "Layout: verify the shutter stays in place when switching Single/Dual, Photo/Video and opening menus. Tapping the selected Photo tab must keep Dual Shot active. Then take 20 Single photos, 20 Fast pairs and 10 Detail pairs; switch modes between groups. Rotate both ways and review each pair. Check for missed captures, mismatched lenses, freezes and save failures.",
        "Resources: open this panel for a baseline, close it, take repeated captures, then reopen it. Compare memory after processing settles. Repeat unplugged for battery/heat checks. Background the app: the camera indicator should turn off, with no active analysis. Use device profiling for capture-time peaks.",
        "Accessibility: use VoiceOver and the largest text sizes in portrait and both landscapes. Check the Single/Dual switch, shutter, timer, each lens, focus lock, all menus and saved-photo comparison. Check Increase Contrast and Reduce Transparency too.",
        "Night: compare fine text, faces, highlights and moving subjects against Single Auto and Apple Camera. Check the saved reference for each lens. Reject results with blur, ghosting or color shifts.",
        "Night: test Single and Dual, interrupt during capture, deny Photos access, and repeat pairs. Verify originals survive interruption and each saved view is correctly labeled.",
        "Framing: place recognizable objects near all four corners. In Photo, Video and both Dual Shot layouts, verify the entire camera frame is visible. Tap near each visible corner and verify focus follows the tap. Compare the preview edges with the saved capture.",
        "Take repeated photos with guides off, then Histogram, Highlights and Focus Peaking. Check responsiveness, warmth and memory in a device profiling session.",
        "Rotate both ways in Single, Dual Fast, Dual Detail, Night and Video. Check upright previews, saved photos/videos, focus targets and guides. Rotate during a Night sequence or recording: its saved orientation must stay fixed. Check rotation lock, larger text and the fixed-layout setting.",
        "Check the zoom row against this phone’s native lens and sensor-crop choices. Test larger text and landscape without clipped controls.",
        "Pinch both Dual Shot previews separately. Confirm the selected border and slider identify the same camera, and hold-versus-tap does not change lenses unexpectedly.",
        "In good light, photograph the same distant subject in Single Photo, Dual Fast, and Dual Detail. Compare main-camera sharpness in Photos at the same scale.",
        "In Dual Shot, tap focus and adjust brightness on each preview. Enlarge each view and move the inset. Confirm focus and brightness stay unchanged.",
        "Take five Fast pairs and five Detail pairs. Confirm both photos save for each successful pair, with correct labels and visible progress.",
        "Repeat at a close distance and in low light. Compare shutter speed and ISO in local photo details; check focus and motion blur separately.",
        "Background the app during Detail capture, then return. Confirm it recovers and clearly reports any partial capture or pending save.",
        "Switch lenses, front/rear, Photo/Video, and Fast/Detail repeatedly. Confirm previews resume without freezes or crashes.",
        "With Photos access denied, capture a photo. Confirm retry/recovery works after restoring permission; ensure no duplicate save.",
        "Try larger text, VoiceOver, and increased contrast. Check every control is reachable and selected states are announced.",
        "During normal extended use, check responsiveness and any warm-device fallback. Do not deliberately overheat the phone."
    ]

    private func openPhotos() {
        guard let url = URL(string: "photos-redirect://") else { return }
        openURL(url) { accepted in
            if !accepted { model.message = "Open Photos from your Home Screen to see your library." }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

private enum CameraToolPage: String, Hashable {
    case shortcuts = "Camera shortcuts", checks = "Device health & testing"
    case guides = "Viewfinder guides"
    case shoot = "Shot styles", focus = "Focus & depth", timer = "Timer", video = "Video quality"
    case panorama = "Panorama", longExposure = "Long exposure", rescue = "Photo Rescue", advanced = "Advanced", preferences = "App settings"
    case exposure = "Exposure", color = "Color", manualFocus = "Manual focus", details = "Info", gallery = "Design Preview"
    var icon: String {
        switch self {
        case .shortcuts: return "pin"
        case .checks: return "checklist"
        case .guides: return "waveform.path"
        case .shoot: return "camera"
        case .focus, .manualFocus: return "viewfinder"
        case .timer: return "timer"
        case .video: return "video"
        case .panorama: return "pano"
        case .longExposure: return "sparkles"
        case .rescue: return "wand.and.stars"
        case .advanced: return "slider.horizontal.3"
        case .preferences: return "gearshape"
        case .exposure: return "sun.max"
        case .color: return "paintpalette"
        case .details: return "info.circle"
        case .gallery: return "photo.on.rectangle"
        }
    }
}

/// Fits normally; preserves every control on small displays and at accessibility text sizes.
private struct CompactToolLayout<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12).frame(maxHeight: .infinity, alignment: .top)
            .controlSize(.regular)
    }
}

// The original reference is bundled locally so design review works offline.
// These images are illustrations, never representations of active camera settings.
private struct PhotoRescueView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PhotoRescueModel()
    @State private var selection: PhotosPickerItem?
    @State private var showsOriginal = false
    var body: some View {
        CompactToolLayout {
            if let result = model.result {
                Image(uiImage: showsOriginal ? result.before : result.after)
                    .resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 240)
                    .accessibilityLabel(showsOriginal ? "Original photo" : "Adjusted preview")
                Toggle("Show original", isOn: $showsOriginal)
                Picker("Look", selection: $model.look) {
                    ForEach(PhotoLook.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(model.busy)
                    .onChange(of: model.look) { _, _ in Task { await model.apply() } }
                HStack {
                    Text("Strength")
                    Slider(value: $model.strength, in: 0...1, step: 0.1, onEditingChanged: { editing in
                        if !editing { Task { await model.apply() } }
                    }).accessibilityLabel("Adjustment strength").disabled(model.busy)
                }
                Button(model.saved ? "Copy saved" : "Save a copy") { Task { await model.save() } }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(model.busy || model.saved)
                    .frame(maxWidth: .infinity)
                Text("Your original stays unchanged.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Improve light, color, and noise on this iPhone.").font(.headline)
            }
            PhotosPicker(selection: $selection, matching: .images) {
                Label(model.result == nil ? "Choose a photo" : "Choose another photo", systemImage: "photo")
            }.buttonStyle(.bordered).disabled(model.busy)
            if model.busy { ProgressView("Working on this iPhone") }
            if let message = model.message { Text(message).font(.caption) }
            DisclosureGroup("About these adjustments") {
                Text("Saves a standard-color JPEG up to 12 MP without location metadata. RAW, HDR, Live Photo, and depth data remain in your original. Cannot recover missed focus or motion detail.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Photo Rescue")
        .onDisappear { model.suspendProcessing() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.suspendProcessing() } }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            showsOriginal = false
            Task { await model.load(item) }
        }
    }
}

private struct VideoQualityControls: View {
    @ObservedObject var model: CameraViewModel
    @Environment(\.dynamicTypeSize) private var textSize
    private var widths: [Int32] { Array(Set(model.camera.videoQualities.map(\.width))).sorted(by: >) }
    private var current: VideoQuality? { model.camera.videoQuality }
    private var rates: [VideoQuality] { model.camera.videoQualities.filter { $0.width == current?.width } }

    var body: some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        VStack(spacing: 14) {
            layout {
                VStack(spacing: 6) {
                    Label("Resolution", systemImage: "viewfinder").font(.caption)
                    ForEach(widths, id: \.self) { width in
                        choice(width == 3840 ? "4K" : width == 1920 ? "1080p" : "720p", selected: current?.width == width) {
                            if let quality = VideoQuality.selectWidth(width, keepingFPS: current?.fps, from: model.camera.videoQualities) {
                                model.selectVideoQuality(quality)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity)
                VStack(spacing: 6) {
                    Label("Frame rate", systemImage: "film").font(.caption)
                    ForEach(rates) { quality in
                        choice("\(quality.fps) fps", selected: current == quality) { model.selectVideoQuality(quality) }
                    }
                }.frame(maxWidth: .infinity)
            }
            Toggle(isOn: Binding(get: { model.stabilization }, set: {
                model.stabilization = $0; model.applyVideoSettings()
            })) { Label("Stabilization", systemImage: "hand.raised") }
            Text("Video zoom stays on the selected lens. To use another lens, choose it in Photo, then switch to Video.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if model.configuring { ProgressView("Applying…").font(.caption) }
        }.disabled(!model.canConfigure)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? CameraAppearance.selection : .white)
                .background(selected ? CameraAppearance.selection.opacity(0.18) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ManualCameraControls: View {
    @ObservedObject var model: CameraViewModel
    let page: CameraToolPage
    private func autoManual(_ title: String, selection: Binding<Bool>) -> some View {
        Picker(title + " control", selection: selection) {
            Text("Auto").tag(true)
            Text("Manual").tag(false)
        }.pickerStyle(.segmented)
    }
    private var shutters: [Double] {
        ShutterOptions.values(minimum: model.camera.minimumShutter, maximum: model.camera.maximumShutter,
                              requested: model.controls.shutterSeconds)
    }
    private var isoSelection: Binding<Float> {
        Binding(get: { min(model.camera.maxISO, max(model.camera.minISO, model.controls.iso)) },
                set: { model.controlBinding.iso.wrappedValue = $0 })
    }
    private var shutterSelection: Binding<Double> {
        Binding(get: {
            min(model.camera.maximumShutter, max(model.camera.minimumShutter, model.controls.shutterSeconds))
        }, set: { model.controlBinding.shutterSeconds.wrappedValue = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if page == .exposure {
                autoManual("Exposure", selection: model.controlBinding.automaticExposure)
                    .disabled(!model.camera.customExposureAvailable)
                if !model.controls.automaticExposure && model.camera.customExposureAvailable {
                    LabeledContent("ISO", value: "\(Int(isoSelection.wrappedValue))")
                    Slider(value: isoSelection, in: model.camera.minISO...max(model.camera.minISO + 1, model.camera.maxISO), step: 1).accessibilityLabel("ISO")
                    Picker("Shutter", selection: shutterSelection) {
                        ForEach(shutters, id: \.self) { seconds in
                            Text(seconds < 1 ? "1/\(Int((1 / seconds).rounded())) s" : String(format: "%.2f s", seconds)).tag(seconds)
                        }
                    }.disabled(shutters.isEmpty)
                }
                LabeledContent("Actual exposure", value: model.camera.exposureLabel)

                if model.controls.automaticExposure {
                    HStack {
                        Text("Brightness")
                        Slider(value: $model.exposureBias, in: -2...2, step: 0.1).accessibilityLabel("Exposure compensation")
                    }
                }
                if model.mode == .photo && model.camera.flashAvailable && !model.panoramaSelected {
                    Picker("Flash", selection: model.controlBinding.flash) {
                        Text("Off").tag(AVCaptureDevice.FlashMode.off); Text("Auto").tag(AVCaptureDevice.FlashMode.auto); Text("On").tag(AVCaptureDevice.FlashMode.on)
                    }.pickerStyle(.segmented)
                }
            } else if page == .color {
                autoManual("Color", selection: model.controlBinding.automaticWhiteBalance)
                    .disabled(!model.camera.whiteBalanceAvailable)
                if !model.controls.automaticWhiteBalance && model.camera.whiteBalanceAvailable {
                    LabeledContent("Temperature", value: "\(Int(model.controls.temperature)) K")
                    Slider(value: model.controlBinding.temperature, in: 2500...10000, step: 100).accessibilityLabel("White balance temperature")
                    LabeledContent("Tint", value: "\(Int(model.controls.tint))")
                    Slider(value: model.controlBinding.tint, in: -100...100, step: 1).accessibilityLabel("White balance tint")
                }

            } else {
                autoManual("Focus", selection: model.controlBinding.automaticFocus)
                    .disabled(!model.camera.manualFocusAvailable)
                if model.controls.automaticFocus {
                    Toggle("Prefer faces", isOn: model.controlBinding.facePriority)
                } else if model.camera.manualFocusAvailable {
                    HStack {
                        Text("Near")
                        Slider(value: model.controlBinding.lensPosition, in: 0...1).accessibilityLabel("Focus distance")
                        Text("Far")
                    }
                }

            }

            Button("Reset camera controls", action: model.resetControls).buttonStyle(.bordered)
        }.disabled(!model.canConfigure)
    }
}

private struct BurstReview: View {
    @ObservedObject var model: CameraViewModel
    @State private var confirmDiscard = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Best Shot").font(.headline)
                Spacer()
                Button("Discard", role: .destructive) { confirmDiscard = true }.frame(minHeight: 44)
            }.padding(.horizontal)
            CompactToolLayout {
                if model.burstPreviews.indices.contains(model.selectedBurstIndex) {
                    Image(uiImage: model.burstPreviews[model.selectedBurstIndex])
                        .resizable().scaledToFit().frame(height: 140)
                        .accessibilityLabel("Selected burst frame \(model.selectedBurstIndex + 1)")
                }
                HStack {
                    ForEach(model.burstPreviews.indices, id: \.self) { index in
                        Button { model.selectedBurstIndex = index } label: {
                            VStack(spacing: 4) {
                                Image(uiImage: model.burstPreviews[index]).resizable().scaledToFit().frame(height: 90)
                                Text(index == model.recommendedBurstIndex ? "Suggested" : "Frame \(index + 1)").font(.caption)
                            }
                            .padding(5)
                            .background(model.selectedBurstIndex == index ? CameraAppearance.selection.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .accessibilityLabel("Frame \(index + 1)\(index == model.recommendedBurstIndex ? ", suggested" : "")")
                    }
                }
                Text(model.recommendedBurstIndex < 0 ? "Automatic ranking paused while your iPhone cools. Compare the frames and choose your favorite." : "The suggestion uses face quality and image detail on this iPhone. Compare the frames and choose your favorite.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Save selected") { Task { await model.saveBurst(all: false) } }
                    Button("Save all \(model.burstPhotos.count)") { Task { await model.saveBurst(all: true) } }
                }.buttonStyle(.borderedProminent).foregroundStyle(.black)
            }
            .padding()
            .navigationTitle("Best Shot")
            .confirmationDialog("Discard all unsaved burst photos?", isPresented: $confirmDiscard) {
                Button("Discard all", role: .destructive, action: model.discard)
            }
            .disabled(model.busy)
        }
    }
}

private struct CameraDesignScreen: Identifiable {
    let id: Int
    let title: String
    let note: String
    let rect: CGRect

    var image: UIImage? {
        guard let source = UIImage(named: "DesignReference")?.cgImage else { return nil }
        let scaleX = CGFloat(source.width) / 1448
        let scaleY = CGFloat(source.height) / 1086
        let crop = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY,
                          width: rect.width * scaleX, height: rect.height * scaleY)
        guard let result = source.cropping(to: crop) else { return nil }
        return UIImage(cgImage: result)
    }

    static let all: [CameraDesignScreen] = [
        .init(id: 0, title: "Photo", note: "Visual target. The working camera supports basic still capture; the format, resolution and HDR values here are examples.", rect: CGRect(x: 24, y: 5, width: 286, height: 535)),
        .init(id: 1, title: "Video", note: "Visual target. The working camera now records video; this mockup illustrates additional controls and layout ideas.", rect: CGRect(x: 329, y: 5, width: 281, height: 535)),
        .init(id: 2, title: "Action", note: "Proposed action mode. Subject tracking and enhanced stabilization are not implemented.", rect: CGRect(x: 618, y: 5, width: 278, height: 535)),
        .init(id: 3, title: "Night", note: "Proposed night mode. Long-exposure processing and RAW controls are not implemented.", rect: CGRect(x: 904, y: 5, width: 274, height: 535)),
        .init(id: 4, title: "Portrait", note: "Proposed portrait mode. Depth effects and lighting controls are not implemented.", rect: CGRect(x: 1188, y: 5, width: 244, height: 535)),
        .init(id: 5, title: "Photo Controls", note: "Proposed photo control drawer. This reference includes future controls beyond the current grid toggle.", rect: CGRect(x: 22, y: 573, width: 286, height: 476)),
        .init(id: 6, title: "Video Controls", note: "Proposed video control drawer. These recording and audio settings are illustrative.", rect: CGRect(x: 327, y: 573, width: 282, height: 476)),
        .init(id: 7, title: "Capture Info", note: "Proposed expanded capture information. The working Capture Info sheet currently shows mode, lens and photo dimensions.", rect: CGRect(x: 616, y: 573, width: 277, height: 476)),
        .init(id: 8, title: "Settings", note: "Proposed settings navigation. These categories are design references, not available features.", rect: CGRect(x: 902, y: 573, width: 280, height: 476)),
        .init(id: 9, title: "Gallery", note: "Proposed gallery and photo details. An in-app gallery and editing tools are not implemented.", rect: CGRect(x: 1184, y: 573, width: 250, height: 476))
    ]
}

private struct CameraDesignGallery: View {
    @State private var selectedScreen: Int?
    @State private var showsCompleteReference = false
    var body: some View {
        VStack(spacing: 8) {
            if selectedScreen != nil || showsCompleteReference {
                Button("Back to design gallery") { selectedScreen = nil; showsCompleteReference = false }
                    .frame(minHeight: 44)
            }
            if let selectedScreen {
                CameraDesignDetail(initialSelection: selectedScreen)
            } else if showsCompleteReference {
                ScrollView {
                    Image("DesignReference").resizable().scaledToFit()
                        .accessibilityLabel("Original Camera XT mockup sheet with ten proposed screens")
                    Text("Design reference only · not a screenshot of the current app").font(.footnote).padding()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Original design mockups").font(.title2.bold())
                        Text("Static design references; the controls and values shown are illustrative.")
                            .font(.subheadline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 16) {
                            ForEach(CameraDesignScreen.all) { screen in
                                Button { selectedScreen = screen.id } label: {
                                    VStack {
                                        CameraDesignImage(screen: screen).frame(height: 180)
                                        Text(screen.title).font(.headline)
                                    }.frame(maxWidth: .infinity).padding(8)
                                }.buttonStyle(.plain)
                            }
                        }
                        Button("View complete reference sheet") { showsCompleteReference = true }.frame(minHeight: 44)
                    }.padding()
                }
            }
        }
    }
}

private struct CameraDesignImage: View {
    let screen: CameraDesignScreen
    var body: some View {
        if let image = screen.image {
            Image(uiImage: image)
                .resizable().scaledToFit()
                .accessibilityLabel("\(screen.title) original mockup")
        } else {
            ContentUnavailableView("Reference unavailable", systemImage: "photo")
        }
    }
}

private struct CameraDesignDetail: View {
    @State private var selection: Int

    init(initialSelection: Int) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("DESIGN PREVIEW · NOT LIVE")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(CameraAppearance.selection.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            TabView(selection: $selection) {
                ForEach(CameraDesignScreen.all) { screen in
                    ScrollView {
                        VStack(spacing: 14) {
                            CameraDesignImage(screen: screen)
                                .frame(maxHeight: 620)
                            Text(screen.note)
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 20).padding(.bottom, 35)
                    }
                    .tag(screen.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack {
                Button("Previous") { selection -= 1 }.disabled(selection == 0)
                Spacer()
                Text("\(selection + 1) of \(CameraDesignScreen.all.count)")
                    .font(.caption).monospacedDigit()
                Spacer()
                Button("Next") { selection += 1 }.disabled(selection == CameraDesignScreen.all.count - 1)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .padding(.top, 12)
        .navigationTitle(CameraDesignScreen.all[selection].title)
        .navigationBarTitleDisplayMode(.inline)
    }
}


private struct RecentCaptureLoader: View {
    @ObservedObject var model: CameraViewModel
    @Environment(\.openURL) private var openURL
    let close: () -> Void
    @State private var record: CaptureStore.Record?
    @State private var failed = false
    @State private var attempt = 0
    var body: some View {
        Group {
            if let record { RecentCaptureView(record: record, close: close) }
            else {
                VStack(spacing: 12) {
                    if failed {
                        Image(systemName: "photo.badge.exclamationmark").font(.title2)
                        Text("Preview unavailable").font(.headline)
                        Text("Try loading it again, or review your saved capture in Photos.").font(.caption)
                        Button("Try again") { failed = false; attempt += 1 }.frame(minHeight: 44)
                        Button("Open Photos") {
                            if let url = URL(string: "photos-redirect://") { openURL(url) }
                        }.frame(minHeight: 44)
                    }
                    else { ProgressView("Loading preview…") }
                    Button("Close", action: close).frame(minHeight: 44)
                }.padding().frame(maxWidth: .infinity, minHeight: 180)
                    .multilineTextAlignment(.center)
            }
        }
        .task(id: attempt) {
            do {
                let loaded = try await model.loadRecentForReview()
                guard !Task.isCancelled else { return }
                record = loaded; failed = loaded == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
        .onDisappear { record = nil }
    }
}

private struct RecentCaptureView: View {
    let record: CaptureStore.Record
    let close: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var selection = 0
    @State private var comparing = true
    @State private var comparisonFirst = 0
    @State private var comparisonSecond = 1
    @AppStorage("camera.captureDetails") private var showDetails = false
    var body: some View {
        Group {
            if record.isVideo || textSize.isAccessibilitySize {
                ScrollView { content }
            } else { content }
        }
    }
    private var content: some View {
        VStack(spacing: 8) {
            HStack {
                Text(record.isVideo ? "Last video" : record.photos.count > 1 ? "Saved photos" : "Last photo").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close recent capture")
            }
            if record.isVideo {
                if let data = record.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 180)
                        .accessibilityLabel("Video thumbnail")
                } else {
                    Image(systemName: "video.fill").font(.largeTitle).frame(maxWidth: .infinity, minHeight: 80)
                    Text("Video preview unavailable").font(.caption)
                }
                Label("Saved in Photos", systemImage: "checkmark.circle").font(.caption)
                Text("Play the full video in Photos.").font(.caption).foregroundStyle(.secondary)
            } else if record.photos.indices.contains(selection) {
                if comparing && record.photos.count >= 2 {
                    let comparisonLayout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 6))
                    comparisonLayout {
                        ForEach([comparisonFirst, comparisonSecond], id: \.self) { index in
                            VStack {
                                ZoomableCapture(data: record.photos[index].data, maxSize: 1500, label: record.photos[index].label)
                                    .id(index)
                                    .frame(minHeight: 180)
                                Button("Enlarge \(record.photos[index].label)") { selection = index; comparing = false }
                                    .font(.caption).frame(minHeight: 44)
                            }
                        }
                    }
                } else { ZoomableCapture(data: record.photos[selection].data, label: record.photos[selection].label).id(selection).frame(minHeight: 220) }
                let photo = record.photos[selection]
                if !comparing || record.photos.count < 2 {
                    Text("\(photo.label) · \(photo.width) × \(photo.height)").font(.caption)
                }
                if showDetails && (!comparing || record.photos.count < 2) {
                    Text(photo.details?.summary ?? "Capture details unavailable for this older photo.").font(.caption)
                    if record.photos.count == 2, let gap = CaptureDetails.gap(record.photos[0].details, record.photos[1].details) {
                        Text(String(format: "Photos taken %.3f s apart", gap)).font(.caption).monospacedDigit()
                    }
                    Text("Details stay with this iPhone’s local recent/recovery copy.").font(.caption2)
                }
                if record.photos.count >= 2 {
                    Button(comparing ? "Show one photo" : "Compare both") { comparing.toggle() }.frame(minHeight: 44)
                }
                if record.photos.count > 2 && comparing {
                    ViewThatFits(in: .horizontal) {
                        HStack { comparisonPickers }
                        VStack { comparisonPickers }
                    }
                } else if record.photos.count > 1 && !comparing {
                    Picker("Photo", selection: $selection) {
                        ForEach(record.photos.indices, id: \.self) { index in
                            Text(record.photos[index].label).tag(index)
                        }
                    }.pickerStyle(.menu).frame(minHeight: 44)
                }
                Text("Pinch or double-tap to inspect. Preview is reduced to protect memory.").font(.caption)
            } else { Text("This preview is unavailable. Open Photos to review the saved capture.").font(.caption) }
            Button(record.isVideo ? "Play in Photos" : "Open Photos") {
                if let url = URL(string: "photos-redirect://") { openURL(url) }
            }.frame(minHeight: 44).buttonStyle(.bordered)
        }.padding(12)
        .onAppear {
            comparisonSecond = RecentComparison.secondIndex(labels: record.photos.map(\.label))
        }
    }

    @ViewBuilder private var comparisonPickers: some View {
        Picker("First photo", selection: $comparisonFirst) {
            ForEach(record.photos.indices.filter { $0 != comparisonSecond }, id: \.self) { index in
                Text(record.photos[index].label).tag(index)
            }
        }.pickerStyle(.menu).frame(minHeight: 44)
        Picker("Second photo", selection: $comparisonSecond) {
            ForEach(record.photos.indices.filter { $0 != comparisonFirst }, id: \.self) { index in
                Text(record.photos[index].label).tag(index)
            }
        }.pickerStyle(.menu).frame(minHeight: 44)
    }
}

enum RecentComparison {
    static func secondIndex(labels: [String]) -> Int {
        guard labels.count > 1 else { return 0 }
        let firstLens = labels[0].components(separatedBy: " · ")[0]
        return labels.indices.dropFirst().first { labels[$0].components(separatedBy: " · ")[0] != firstLens } ?? 1
    }
}

private struct DeviceDiagnosticsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var memory: UInt64?
    @Binding var peak: UInt64
    @Binding var baseline: UInt64?
    @State private var thermal = "Normal"
    @State private var battery: Float = -1
    @Binding var batteryBaseline: Float?
    @State private var previouslyMonitoring = false
    @State private var report: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local device check").font(.subheadline.weight(.semibold))
            Text("Recent camera events stay on this iPhone. No photos, location or audio are included. Share the report after a freeze or after reopening following a crash.")
                .foregroundStyle(.secondary)
            if let report {
                ShareLink(item: report) { Label("Share diagnostic report", systemImage: "square.and.arrow.up") }
                    .frame(minHeight: 44)
            }
            Button("Refresh report") { Task { report = await CameraDiagnostics.shared.report() } }
                .frame(minHeight: 44)
            Button("Clear diagnostic history") {
                Task { await CameraDiagnostics.shared.clear(); report = await CameraDiagnostics.shared.report() }
            }.frame(minHeight: 44)
            Text("Thermal state: \(thermal)")
            if let memory {
                Text("App memory: \(memory / 1_048_576) MB · highest sampled \(peak / 1_048_576) MB")
                if let baseline { Text("Change since first check: \(Int64(memory / 1_048_576) - Int64(baseline / 1_048_576)) MB") }
            } else { Text("App memory unavailable") }
            if battery >= 0 {
                Text("Battery: \(Int((battery * 100).rounded()))%")
                if let batteryBaseline { Text("Battery change: \(Int(((battery - batteryBaseline) * 100).rounded())) percentage points") }
            }
            Text("Open before and after repeated captures to compare this session. Samples only while this panel is active; capture-time peaks can be missed. Battery readings are coarse and can rise while charging. These readings do not prove a memory leak.")
                .foregroundStyle(.secondary)
        }
        .font(.caption).monospacedDigit()
        .onAppear {
            previouslyMonitoring = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = previouslyMonitoring }
        .task { report = await CameraDiagnostics.shared.report() }
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                UIDevice.current.isBatteryMonitoringEnabled = previouslyMonitoring
                return
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            while !Task.isCancelled {
                memory = CameraDiagnostics.memoryBytes()
                if let memory { peak = max(peak, memory); if baseline == nil { baseline = memory } }
                battery = UIDevice.current.batteryLevel
                if batteryBaseline == nil && battery >= 0 { batteryBaseline = battery }
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: thermal = "Normal"
                case .fair: thermal = "Warm"
                case .serious: thermal = "Hot"
                case .critical: thermal = "Critical"
                @unknown default: thermal = "Unknown"
                }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }

}

private struct ZoomableCapture: UIViewRepresentable {
    let data: Data
    var maxSize: Int = 3000
    var label = "Saved photo"
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?
        var decodeTask: Task<Void, Never>?
        @objc func zoomIn(_ action: UIAccessibilityCustomAction) -> Bool {
            guard let scrollView else { return false }
            scrollView.setZoomScale(min(5, scrollView.zoomScale + 1), animated: !UIAccessibility.isReduceMotionEnabled)
            return true
        }
        @objc func zoomOut(_ action: UIAccessibilityCustomAction) -> Bool {
            scrollView?.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled)
            return true
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = imageView.superview as? UIScrollView else { return }
            scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 3, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
    final class ZoomView: UIScrollView {
        weak var picture: UIImageView?
        let loading = UIActivityIndicatorView(style: .medium)
        let previewStatus = UILabel()
        private var previousSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            if previousSize != bounds.size {
                previousSize = bounds.size
                setZoomScale(1, animated: false)
                contentOffset = .zero
            }
            if zoomScale == 1 { picture?.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size }
            loading.center = CGPoint(x: bounds.midX, y: bounds.midY - 18)
            previewStatus.frame = CGRect(x: bounds.minX + 12, y: bounds.midY + 4, width: max(0, bounds.width - 24), height: 70)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ZoomView {
        let view = ZoomView()
        view.minimumZoomScale = 1; view.maximumZoomScale = 5
        view.delegate = context.coordinator
        context.coordinator.scrollView = view
        let image = context.coordinator.imageView
        context.coordinator.decodeTask = Task { @MainActor [weak image, weak view] in
            let decoded = await CapturePreviewDecoder.image(data, maxSize: maxSize)
            guard !Task.isCancelled else { return }
            image?.image = decoded
            view?.loading.stopAnimating()
            view?.previewStatus.text = decoded == nil ? "Preview unavailable. Open Photos to view the original." : nil
            view?.previewStatus.isHidden = decoded != nil
            image?.isAccessibilityElement = decoded != nil
        }
        image.contentMode = .scaleAspectFit
        image.isUserInteractionEnabled = true
        image.isAccessibilityElement = true
        image.accessibilityLabel = label
        image.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Zoom in", target: context.coordinator, selector: #selector(Coordinator.zoomIn(_:))),
            UIAccessibilityCustomAction(name: "Fit photo", target: context.coordinator, selector: #selector(Coordinator.zoomOut(_:)))
        ]
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2; image.addGestureRecognizer(tap)
        view.addSubview(image); view.picture = image
        view.loading.color = .white
        view.loading.hidesWhenStopped = true
        view.previewStatus.text = "Loading photo…"
        view.previewStatus.font = .preferredFont(forTextStyle: .caption1)
        view.previewStatus.adjustsFontForContentSizeCategory = true
        view.previewStatus.textColor = .white
        view.previewStatus.textAlignment = .center
        view.previewStatus.numberOfLines = 0
        view.previewStatus.isUserInteractionEnabled = false
        view.addSubview(view.loading); view.addSubview(view.previewStatus)
        view.loading.startAnimating()
        return view
    }
    static func dismantleUIView(_ view: ZoomView, coordinator: Coordinator) {
        coordinator.decodeTask?.cancel()
        coordinator.decodeTask = nil
        coordinator.imageView.image = nil
        view.loading.stopAnimating()
        view.delegate = nil
    }
    func updateUIView(_ uiView: ZoomView, context: Context) {}
}

private struct HistogramGuide: View {
    let bins: [Double]
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width / CGFloat(max(1, bins.count))
                for (index, value) in bins.enumerated() {
                    let height = geometry.size.height * value
                    path.addRect(CGRect(x: CGFloat(index) * width, y: geometry.size.height - height, width: max(1, width - 1), height: height))
                }
            }.fill(.white.opacity(0.8))
        }.allowsHitTesting(false)
    }
}

private struct GuidedCameraPreview: View {
    @ObservedObject var guides: ViewfinderGuideState
    let engine: CaptureSessionManager
    var onFocus: (CGPoint, Bool) -> Void
    var fillView: Bool
    var showsFocusFeedback: Bool
    var focusState: String
    var exposureOnly: Bool
    var showsGrid: Bool
    var hidesGuides: Bool
    var onImageFrame: ((CGRect) -> Void)? = nil
    var controlStripHeight: CGFloat = 0
    var topControlStripHeight: CGFloat = 0
    var body: some View {
        CameraPreview(engine: engine, onFocus: onFocus, fillView: fillView, showsFocusFeedback: showsFocusFeedback,
                      focusState: focusState, exposureOnly: exposureOnly, showsGrid: showsGrid,
                      guideImage: hidesGuides ? nil : guides.image, onImageFrame: onImageFrame, controlStripHeight: controlStripHeight, topControlStripHeight: topControlStripHeight)
    }
}

private struct LiveHistogram: View {
    @ObservedObject var guides: ViewfinderGuideState
    let overlayColor: Color
    var body: some View {
        if !guides.histogram.isEmpty {
            HistogramGuide(bins: guides.histogram).frame(width: 128, height: 44)
                .padding(6).background(overlayColor, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Live brightness histogram, darkest tones on the left")
        }
    }
}

private struct ZoomControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 88
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct CameraHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 52
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct CaptureControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
