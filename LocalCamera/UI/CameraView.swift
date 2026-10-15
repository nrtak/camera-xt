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
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var textSize
    @AppStorage("camera.quickAccess") private var quickAccess = false
    @AppStorage("camera.showQuickControls") private var showQuickControls = true
    @AppStorage("camera.adaptiveLayout") private var adaptiveLayout = true
    @AppStorage("camera.sceneHints") private var sceneHints = true
    @AppStorage("camera.advancedTools") private var advancedTools = false
    @AppStorage("camera.rememberSetup") private var rememberSetup = true
    @AppStorage("camera.pin1") private var pin1 = "Exposure"
    @AppStorage("camera.pin2") private var pin2 = "Timer"
    @AppStorage("camera.pin3") private var pin3 = "Shot styles"
    @AppStorage("camera.captureDetails") private var showCaptureDetails = false
    @State private var preferencesSection = 0
    @State private var checkIndex = 0
    @State private var passedChecks: Set<Int> = []
    @State private var diagnosticsBaseline: UInt64?
    @State private var diagnosticsPeak: UInt64 = 0
    @State private var diagnosticsBatteryBaseline: Float?
    @State private var confirmDiscard = false
    @AppStorage("camera.fullFrame") private var fullFrame = false
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
    @State private var selectedDualIndex = 0
    @State private var showsDualAdjustments = false
    private var panelOpen: Bool { showsCaptureInfo || showsRecent || model.reviewingBurst }
    private var enlargedDualIndex: Int? {
        get { (0...1).contains(dualLayout) ? dualLayout : nil }
        nonmutating set { dualLayout = newValue ?? -1 }
    }
    private var hasAdjustments: Bool {
        model.captureStyle != "Auto" || model.timerSeconds > 0 || model.burstEnabled ||
        model.camera.dualEnabled || model.camera.depthEnabled || model.camera.eyeFocusEnabled ||
        model.camera.focusLocked || model.camera.analysisMode != "Off" || !model.controls.automaticExposure || !model.controls.automaticFocus ||
        !model.controls.automaticWhiteBalance || abs(model.exposureBias) > 0.05
    }

    private let ink = Color.white
    private var overlayColor: Color { .black.opacity(reduceTransparency ? 1 : contrast == .increased ? 0.75 : 0.55) }
    private var menuBackground: Color { .black.opacity(reduceTransparency ? 1 : contrast == .increased ? 0.92 : 0.78) }
    private let selection = CameraAppearance.selection

    var body: some View {
        GeometryReader { geometry in
            cameraScreen(landscape: adaptiveLayout && geometry.size.width > geometry.size.height)
        }
    }

    private func cameraScreen(landscape: Bool) -> some View {
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
                                dualViewfinder(zoomText(zoomState(index).value), index: index)
                                    .frame(width: width, height: height)
                                    .clipShape(RoundedRectangle(cornerRadius: inset ? 12 : 0))
                                    .overlay { RoundedRectangle(cornerRadius: inset ? 12 : 0).strokeBorder(.white.opacity(inset ? 0.25 : 0), lineWidth: 2).allowsHitTesting(false) }
                                    .offset(x: inset ? (dualCorner % 2 == 0 ? 8 : geometry.size.width - width - 8) : enlargedDualIndex == nil && landscape ? CGFloat(index) * (width + 4) : 0,
                                            y: enlargedDualIndex == nil ? (landscape ? 0 : CGFloat(index) * (height + 4)) : inset ? (dualCorner < 2 ? 8 : geometry.size.height - height - 8) : 0)
                                    .zIndex(inset ? 1 : 0)
                            }
                        }
                    }
                    .allowsHitTesting(!panelOpen)
                    .accessibilityHidden(panelOpen)
                } else {
                    GuidedCameraPreview(guides: model.guides, engine: model.engine, onFocus: model.focus, fillView: !fullFrame, showsFocusFeedback: model.canConfigure && !panelOpen, focusState: model.camera.focusStates.first ?? "Auto focus", exposureOnly: model.exposurePointOnly, showsGrid: showsGrid && !panelOpen, hidesGuides: panelOpen)
                        .accessibilityLabel("Camera viewfinder")
                        .simultaneousGesture(zoomGesture(nil))
                        .allowsHitTesting(!panelOpen)
                        .accessibilityHidden(panelOpen)
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
        .overlay(alignment: .bottom) {
            if showsCaptureInfo || model.reviewingBurst || showsRecent {
                GeometryReader { geometry in
                    Group {
                        if showsRecent, let recent = model.recent {
                            RecentCaptureView(record: recent, close: { showsRecent = false })
                                .background(menuBackground, in: RoundedRectangle(cornerRadius: 12))
                        } else if model.reviewingBurst {
                            BurstReview(model: model)
                                .background(menuBackground, in: RoundedRectangle(cornerRadius: 12))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else { captureInfo }
                    }
                        .frame(height: min(geometry.size.height * (toolPath.isEmpty && advancedTools ? 0.96 : 0.82), toolPanelHeight))
                        .contentShape(Rectangle())
                        .background { Rectangle().fill(Color.clear).contentShape(Rectangle()).onTapGesture {} }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .overlay(alignment: .top) {
            if !panelOpen { captureStatus.fixedSize(horizontal: false, vertical: true).padding(.top, 8) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                captureHUD
                if !panelOpen && showQuickControls {
                    viewfinderQuickControls.padding(.horizontal, 12).padding(.bottom, 6)
                }
            }.background(Color.black)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { captureControls(landscape: landscape) }
        .onChange(of: model.camera.dualEnabled) { _, _ in showsDualAdjustments = false; showsZoom = false; zoomDismissTask?.cancel() }
        .onChange(of: panelOpen) { _, open in
            if open { showsDualAdjustments = false; showsZoom = false; zoomDismissTask?.cancel() }
        }
        .onDisappear { zoomDismissTask?.cancel(); model.setActive(false) }
        .foregroundStyle(ink)
        .tint(selection)
        .preferredColorScheme(.dark)
        .task { model.setActive(scenePhase == .active) }
        .onChange(of: scenePhase) {
            if $0 == .background { model.enteredBackground() }
            model.setActive($0 == .active)
        }
        .confirmationDialog("Discard the unsaved capture?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard capture", role: .destructive, action: model.discard)
        }
    }

    private func dualViewfinder(_ title: String, index: Int) -> some View {
        CameraPreview(engine: model.engine, onFocus: { point, locked in
            guard !panelOpen else { return }
            selectedDualIndex = index
            showsDualAdjustments = true
            model.focusDual(at: point, index: index, locked: locked)
        }, fillView: !fullFrame, secondary: index == 1, showsFocusFeedback: !panelOpen && model.canConfigure &&
            model.camera.dualFocusSupported.indices.contains(index) && model.camera.dualFocusSupported[index],
            focusState: model.camera.focusStates.indices.contains(index) ? model.camera.focusStates[index] : "Auto focus",
            exposureOnly: model.exposurePointOnly)
        .background(.black)
        .simultaneousGesture(zoomGesture(index))
        .overlay { Rectangle().strokeBorder(!panelOpen && selectedDualIndex == index ? selection.opacity(0.8) : .clear, lineWidth: 1).allowsHitTesting(false) }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Button {
                        showsDualAdjustments = selectedDualIndex != index || !showsDualAdjustments
                        selectedDualIndex = index
                    } label: {
                        HStack(spacing: 4) {
                            Text(title)
                            if selectedDualIndex == index { Image(systemName: "checkmark.circle.fill").accessibilityHidden(true) }
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(selectedDualIndex == index ? selection : .white)
                        .frame(minHeight: 44).padding(.horizontal, 8)
                    }
                    .accessibilityLabel("Adjust camera \(index + 1), \(title)")
                    .accessibilityValue(model.camera.focusStates.indices.contains(index) ? model.camera.focusStates[index] : "Fixed focus")
                    .accessibilityAddTraits(selectedDualIndex == index ? .isSelected : [])
                    Button {
                        enlargedDualIndex = enlargedDualIndex == index ? nil : index
                    } label: {
                        Image(systemName: enlargedDualIndex == index ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(enlargedDualIndex == index ? "Show both cameras equally" : "Enlarge \(title)")
                }
                if model.camera.focusStates.indices.contains(index),
                   model.camera.focusStates[index] == "Focus locked" || model.camera.focusStates[index] == "Focusing…" {
                    Label(model.camera.focusStates[index], systemImage: model.camera.focusStates[index] == "Focus locked" ? "lock.fill" : "viewfinder")
                        .font(.caption2).foregroundStyle(selection)
                }
                if showsDualAdjustments && selectedDualIndex == index {
                    let sizes = model.camera.resolution.components(separatedBy: " + ")
                    if sizes.indices.contains(index) { Text(sizes[index]).font(.caption2).monospacedDigit() }
                    Text(model.camera.dualFocusSupported.indices.contains(index) && model.camera.dualFocusSupported[index] && model.camera.focusStates.indices.contains(index) ? model.camera.focusStates[index] : "Fixed focus")
                        .font(.caption2)
                    Button("Zoom") { selectedDualIndex = index; zoomDismissTask?.cancel(); showsZoom.toggle() }.frame(minHeight: 44)
                    Button("Brightness") { openTool(.exposure) }
                        .font(.caption).frame(minHeight: 44).disabled(!model.canConfigure)
                }
            }
            .padding(.horizontal, 6)
            .background(overlayColor, in: RoundedRectangle(cornerRadius: 8)).padding(6)
            .opacity(panelOpen ? 0 : 1)
            .allowsHitTesting(!panelOpen)
            .accessibilityHidden(panelOpen)
        }
        .accessibilityLabel("\(title) live viewfinder. Tap to focus this camera.")
    }

    private func openTool(_ page: CameraToolPage? = nil) {
        showsDualAdjustments = false
        showsZoom = false
        zoomDismissTask?.cancel()
        toolPath = page.map { [$0] } ?? []
        showsRecent = false
        showsCaptureInfo = true
    }

    private var captureHUD: some View {
        HStack(spacing: 8) {
            if model.mode == .photo {
                Button {
                    showsCaptureInfo = false; showsRecent = false
                    model.setDualEnabled(!model.camera.dualEnabled)
                } label: {
                    Label(model.camera.dualEnabled ? "Dual" : "Single", systemImage: model.camera.dualEnabled ? "camera.on.rectangle.fill" : "camera")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(model.camera.dualEnabled ? selection : ink)
                        .frame(minHeight: 44)
                }
                .disabled(!model.camera.dualAvailable && !model.camera.dualEnabled)
                .accessibilityLabel(model.camera.dualEnabled ? "Switch to Single Shot" : "Switch to Dual Shot")
                .accessibilityValue(model.camera.dualEnabled ? "Dual Shot" : "Single Shot")
                .accessibilityHint(model.camera.dualAvailable ? "Changes camera mode with one tap" : "Dual Shot is unavailable on this device")
            } else {
                Button("Video") { openTool(.details) }.frame(minHeight: 44)
            }
            Spacer(minLength: 8)
            Button { fullFrame.toggle() } label: {
                Image(systemName: fullFrame ? "viewfinder" : "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(fullFrame ? selection : ink).frame(width: 44, height: 44)
            }
            .accessibilityLabel(fullFrame ? "Fill preview area" : "Show full camera frame")
            .accessibilityValue(fullFrame ? "Full frame" : "Fill screen")
            Button { openTool() } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }.accessibilityLabel("Camera tools")
            Button { openTool(.preferences) } label: {
                Image(systemName: "gearshape").frame(width: 44, height: 44)
            }.accessibilityLabel("Camera preferences")
        }
        .disabled(!model.canConfigure)
        .padding(.horizontal, 14)
        .background(Color.black)
        .buttonStyle(.plain)
    }

    private var captureStatus: some View {
        VStack(spacing: 12) {
            if let preparing = model.preparingMode {
                HStack { ProgressView(); Text("Preparing \(preparing.rawValue)…") }
                    .font(.callout).padding(8).background(overlayColor, in: RoundedRectangle(cornerRadius: 8))
            }
            if !showsCaptureInfo && !showsRecent && !model.reviewingBurst {
                if sceneHints, model.canConfigure, model.mode == .photo, model.message == nil, let advice = model.sceneAdvice {
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
            if model.countdown > 0 {
                Text("\(model.countdown)").font(.system(size: 64, weight: .bold))
                    .accessibilityLabel("Shutter in \(model.countdown) seconds")
            }
            VStack(spacing: 6) {
                if model.lowStorage { Text("Low storage · free space before recording").font(.caption) }
                if model.camera.cooling { Text("iPhone is warm · processing reduced").font(.caption) }
                if let message = model.message {
                    Label(model.busy ? model.captureActivity.rawValue : message, systemImage: model.busy ? "hourglass" : model.hasPendingCapture ? "exclamationmark.triangle" : "info.circle")
                        .font(.callout).accessibilityLabel(message)
                    if model.busy && showHelp { Text(message).font(.caption) }
                }
                if model.hasPendingCapture && !model.busy {
                    ViewThatFits(in: .horizontal) {
                        HStack { saveRecovery }
                        VStack { saveRecovery }
                    }.font(.callout)
                }
            }
            .multilineTextAlignment(.center)
            .padding(model.message != nil || model.lowStorage || model.camera.cooling || model.hasPendingCapture ? 10 : 0)
            .background(overlayColor, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 14)
    }

    private var viewfinderQuickControls: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: textSize.isAccessibilitySize ? 2 : (quickAccess || model.mode == .video ? 3 : 4)), spacing: 4) {
            if quickAccess {
                ForEach(Array([pin1, pin2, pin3].enumerated()), id: \.offset) { _, name in
                    if let page = CameraToolPage(rawValue: name) {
                        quickControl(page.rawValue, icon: page.icon, value: "Open") { openTool(page) }
                    }
                }
            } else {
                quickControl("Brightness", icon: "sun.max", value: model.camera.dualEnabled ? "Both views" : String(format: "%+.1f EV", model.exposureBias)) { openTool(.exposure) }
                if model.mode == .photo {
                    quickControl("Night", icon: model.captureStyle == "Night" ? "moon.fill" : "moon", value: model.captureStyle == "Night" ? "On · Beta" : "Off", active: model.captureStyle == "Night") {
                        model.setNightEnabled(model.captureStyle != "Night")
                    }
                    quickControl("Timer", icon: "timer", value: model.timerSeconds == 0 ? "Off" : "\(model.timerSeconds)s", active: model.timerSeconds > 0) {
                        model.timerSeconds = model.timerSeconds == 0 ? 3 : model.timerSeconds == 3 ? 10 : 0
                    }
                    if model.camera.dualEnabled {
                        quickControl("Dual style", icon: "camera.on.rectangle", value: model.captureStyle == "Night" ? "Night" : model.camera.dualMode.rawValue) {
                            if model.captureStyle == "Night" { openTool(.shoot) }
                            else { model.setDualMode(model.camera.dualMode == .fast ? .detail : .fast) }
                        }
                    } else {
                        quickControl("Style", icon: "camera", value: model.burstEnabled && model.captureStyle == "Auto" ? "Burst" : model.captureStyle) { openTool(.shoot) }
                    }
                } else {
                    quickControl("Video", icon: "video", value: model.camera.videoLabel) { openTool(.video) }
                    quickControl("Grid", icon: "grid", value: showsGrid ? "On" : "Off", active: showsGrid) { showsGrid.toggle() }
                }
            }
        }
        .padding(4)
        .frame(maxWidth: 420)
        .disabled(!model.canConfigure)
    }

    private func quickControl(_ title: String, icon: String, value: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.body)
                    if value != "Open" { Text(value).font(.caption.monospacedDigit()) }
                }
                Text(title).font(.caption2).foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? selection : .white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
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
    }

    private func zoomButtonGesture(tap: @escaping () -> Void) -> some Gesture {
        LongPressGesture().exclusively(before: TapGesture()).onEnded { result in
            switch result {
            case .first: zoomDismissTask?.cancel(); showsZoom = true
            case .second: tap()
            }
        }
    }

    private func dismissZoomLater() {
        zoomDismissTask?.cancel()
        zoomDismissTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            showsZoom = false
        }
    }

    private var zoomChoices: some View {
        ForEach(ZoomShortcuts.make(model.camera.lenses)) { choice in
            Button { model.select(choice.lens, zoom: choice.multiplier) } label: {
                Text(choice.value.rounded() == choice.value ? String(format: "%.0f×", choice.value) : zoomText(choice.value))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(choice.lens.id == model.camera.selectedID && abs(zoomState().value - choice.value) < 0.05 ? selection : .white)
            }
            .highPriorityGesture(zoomButtonGesture { model.select(choice.lens, zoom: choice.multiplier) })
            .accessibilityLabel("\(zoomText(choice.value)) zoom")
            .disabled(!model.canSwitch)
        }
    }

    private var lensSelector: some View {
        HStack(spacing: 4) {
            if model.selectedLens?.isFront == false {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { zoomChoices }.fixedSize(horizontal: true, vertical: false)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 72 : 44))], spacing: 4) { zoomChoices }
                }
            }
            Button { zoomDismissTask?.cancel(); showsZoom.toggle() } label: {
                Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
            }.accessibilityLabel("Adjust zoom")
        }.buttonStyle(.plain).disabled(!model.canConfigure)
    }

    private var compositionGrid: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                    let x = geometry.size.width * fraction
                    let y = geometry.size.height * fraction
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.30), lineWidth: 0.5)
        }
    }

    private var cameraNotice: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera").font(.largeTitle)
            if model.permission == .authorized {
                Text(model.camera.message ?? "Camera unavailable.")
                Button("Retry camera") { model.engine.start() }.disabled(model.busy)
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

    private func captureControls(landscape: Bool) -> some View {
        let layout = landscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 6))
        let modeLayout = landscape ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if !showsCaptureInfo && !showsRecent && !model.reviewingBurst && !model.camera.dualEnabled {
                lensSelector
            }
            modeLayout {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    Button { model.selectMode(mode) } label: {
                        Text(mode.rawValue.uppercased())
                            .font(.caption.weight(.semibold))
                            .frame(minWidth: 80, minHeight: 44)
                            .foregroundStyle(model.mode == mode ? selection : .white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                }

            }
            .fixedSize(horizontal: landscape, vertical: false)
            .disabled(model.busy || model.configuring || model.hasPendingCapture || model.camera.recording)

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
                                }
                            }
                            .frame(width: 48, height: 48).clipped()
                            .background(.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            if model.lastSavedPhotoCount > 1 {
                                Text("\(model.lastSavedPhotoCount)").font(.caption2.bold()).padding(3)
                                    .foregroundStyle(.black).background(.white, in: RoundedRectangle(cornerRadius: 8))
                            }
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
                        if model.camera.recording { RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 28, height: 28) }
                        else if model.busy || model.configuring { ProgressView().tint(.black) }
                    }
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    if model.mode == .video {
                        Text(model.videoButtonTitle).font(.caption.weight(.semibold))
                    }
                    }
                }
                .accessibilityLabel(model.mode == .photo ? "Take photo" : model.camera.recording ? "Stop recording" : "Start recording")
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
                .disabled(!model.canSwitch || !model.camera.lenses.contains { $0.isFront != model.selectedLens?.isFront })
            }
            .frame(minWidth: landscape ? 200 : nil)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if showsZoom && !showsCaptureInfo && !showsRecent && !model.reviewingBurst {
                zoomSlider.fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .alignmentGuide(.top) { dimensions in dimensions[.bottom] + 8 }
            }
        }
        .background(Color.black.ignoresSafeArea(edges: .bottom))
    }

    @ViewBuilder private var saveRecovery: some View {
        Button("Retry save") { Task { await model.retrySave() } }
        Button("Settings", action: openSettings)
        Button("Discard", role: .destructive) { confirmDiscard = true }
    }

    private var toolPanelHeight: CGFloat {
        if showsRecent || model.reviewingBurst || textSize.isAccessibilitySize { return .infinity }
        let base: CGFloat
        switch toolPath.last {
        case nil: return (advancedTools ? 560 : 290) + (hasAdjustments ? 44 : 0)
        case .shoot: base = model.camera.dualEnabled ? 370 : 350
        case .preferences:
            base = preferencesSection == 0 ? 320 : preferencesSection == 1 ? (showQuickControls && quickAccess ? 510 : 360) : 450
        case .timer: base = 260
        case .video: base = 350
        case .gallery, .rescue: return .infinity
        default: base = 440
        }
        return base + (showHelp ? 120 : 0)
    }

    private var captureInfo: some View {
        VStack(spacing: 0) {
            HStack {
                if !toolPath.isEmpty && toolPath != [.preferences] {
                    Button { toolPath.removeLast() } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("Back")
                }
                Text(toolPath.last?.rawValue ?? "Camera Tools").font(.headline)
                Spacer()
                Button { showHelp.toggle() } label: {
                    Image(systemName: showHelp ? "info.circle.fill" : "info.circle").frame(width: 44, height: 44)
                }.accessibilityLabel(showHelp ? "Hide tool explanations" : "Show tool explanations")
                Button { showsCaptureInfo = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Close camera tools")
            }.padding(.horizontal, 12)
            if let page = toolPath.last {
                toolPage(page)
            } else {
                CompactToolLayout {
                    Picker("Tool complexity", selection: $advancedTools) {
                        Text("Simple").tag(false); Text("Advanced").tag(true)
                    }.pickerStyle(.segmented)
                    if hasAdjustments { Button("Reset to Auto") { useTool(.automatic) }.frame(minHeight: 44) }
                    toolGrid([.shoot, model.mode == .photo ? .timer : .video, .preferences])
                    Toggle("Composition grid", isOn: $showsGrid)
                    if advancedTools {
                        Divider()
                        toolGrid([.exposure, .color, .manualFocus, .focus, .guides, .details, .rescue])
                    }
                }
            }
        }
        .background(menuBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15), lineWidth: 1).allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func toolGrid(_ pages: [CameraToolPage]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: textSize.isAccessibilitySize ? 1 : 3), spacing: 8) {
            ForEach(pages, id: \.self) { page in
                Button { toolPath.append(page) } label: {
                    Label(page.rawValue, systemImage: page.icon)
                        .font(.caption.weight(.semibold)).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(4)

                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func toolPage(_ page: CameraToolPage) -> some View {
        Group {
            switch page {
            case .rescue:
                PhotoRescueView()
            case .gallery: CameraDesignGallery()
            case .advanced:
                CompactToolLayout {
                    toolGrid([.exposure, .color, .manualFocus, .details])
                    Button("Reset to automatic", action: model.resetControls).buttonStyle(.bordered)
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
                        ForEach(0..<2, id: \.self) { index in
                            Text(index == 0 ? "Main brightness" : "Ultra Wide brightness")
                                .foregroundStyle(selectedDualIndex == index ? selection : .white)
                            Slider(value: Binding(get: { model.dualBrightness[index] }, set: { selectedDualIndex = index; model.setDualBrightness($0, index: index) }), in: -2...2, step: 0.1)
                                .accessibilityLabel(index == 0 ? "Main brightness" : "Ultra Wide brightness")
                            Text(String(format: "%+.1f EV", model.dualBrightness[index])).monospacedDigit()
                        }
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
            Picker("Resolution", selection: $model.videoWidth) { Text("1080p").tag(Int32(1920)); Text("4K").tag(Int32(3840)) }.pickerStyle(.segmented)
            Picker("Frame rate", selection: $model.videoFPS) { Text("24 fps").tag(Int32(24)); Text("30 fps").tag(Int32(30)); Text("60 fps").tag(Int32(60)) }.pickerStyle(.segmented)
            Toggle("Steadier video", isOn: $model.stabilization)
            Text("The selected lens determines which formats are available.").font(.footnote)
            Button("Apply video settings") { model.applyVideoSettings(); showsCaptureInfo = false }.buttonStyle(.borderedProminent).foregroundStyle(.black)
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
            Picker("Preferences section", selection: $preferencesSection) {
                Text("Camera").tag(0); Text("Controls").tag(1); Text("App").tag(2)
            }.pickerStyle(.segmented)
            if preferencesSection == 0 {
                Toggle("Show full camera frame", isOn: $fullFrame)
                Text("See the entire photo, or turn off to fill the preview.").font(.caption).foregroundStyle(.secondary)
                Toggle("Rotate camera layout", isOn: $adaptiveLayout)
                Toggle("Composition grid", isOn: $showsGrid)
                Toggle("Low-light suggestions", isOn: $sceneHints)
            } else if preferencesSection == 1 {
                Toggle("Show camera shortcuts", isOn: $showQuickControls)
                Text("Brightness, Night, timer and shot style above the preview. Video shows its own controls.").font(.caption).foregroundStyle(.secondary)
                if showQuickControls {
                    Toggle("Choose my own shortcuts", isOn: $quickAccess)
                    if quickAccess {
                        shortcutPicker("First shortcut", selection: $pin1, excluding: [pin2, pin3])
                        shortcutPicker("Second shortcut", selection: $pin2, excluding: [pin1, pin3])
                        shortcutPicker("Third shortcut", selection: $pin3, excluding: [pin1, pin2])
                    }
                }
                Divider()
                LabeledContent("Small preview position") {
                    Picker("Small preview position", selection: $dualCorner) {
                        Text("Top left").tag(0); Text("Top right").tag(1)
                        Text("Bottom left").tag(2); Text("Bottom right").tag(3)
                    }.labelsHidden().pickerStyle(.menu)
                }
                Text("Where the smaller view sits when one Dual Shot camera is enlarged.").font(.caption).foregroundStyle(.secondary)
                Toggle("Capture vibrations", isOn: $model.haptics)
            } else {
                Toggle("Remember camera settings", isOn: $rememberSetup)
                Text("Turn off to use defaults on relaunch. Recording never restarts automatically.").font(.caption).foregroundStyle(.secondary)
                Toggle("Show saved photo details", isOn: $showCaptureDetails)
                Text("Lens, size and exposure in photo review.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Button { toolPath.append(.checks) } label: {
                    HStack { Label("Device health & testing", systemImage: "heart.text.square"); Spacer(); Image(systemName: "chevron.right").font(.caption) }.frame(minHeight: 44)
                }.buttonStyle(.plain)
                Text("Memory, battery, temperature and optional camera tests. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Clear preview") { Task { await model.clearRecent() } }
                    Spacer()
                    Button("Reset camera") { model.activate(.automatic); showsCaptureInfo = false }
                }.font(.callout).frame(minHeight: 44)
                Text("Clearing the preview keeps Photos and unsaved captures.").font(.caption).foregroundStyle(.secondary)
            }
        case .details:
            Text(fullFrame ? "Full frame shows the camera preview boundaries. Still photos and video can have different aspect ratios." : "Fill screen crops the preview to fit. Tap the framing button at the top to see the full camera frame; saved photos are not cropped by this setting.").font(.caption)
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
        "Stability: take 20 Single photos, 20 Fast pairs and 10 Detail pairs; switch modes between groups. Rotate both ways and review each pair. Check for missed captures, mismatched lenses, freezes and save failures.",
        "Resources: open this panel for a baseline, close it, take repeated captures, then reopen it. Compare memory after processing settles. Repeat unplugged for battery/heat checks. Background the app: the camera indicator should turn off, with no active analysis. Use device profiling for capture-time peaks.",
        "Accessibility: use VoiceOver and the largest text sizes in portrait and both landscapes. Check the Single/Dual switch, shutter, timer, each lens, focus lock, all menus and saved-photo comparison. Check Increase Contrast and Reduce Transparency too.",
        "Night: compare fine text, faces, highlights and moving subjects against Single Auto and Apple Camera. Check the saved reference for each lens. Reject results with blur, ghosting or color shifts.",
        "Night: test Single and Dual, interrupt during capture, deny Photos access, and repeat pairs. Verify originals survive interruption and each saved view is correctly labeled.",
        "Switch Fill / Full Frame in Photo, Video and both Dual Shot layouts. Tap near each visible corner and verify focus follows the tap. Compare the preview with the saved photo.",
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
    case rescue = "Photo Rescue", advanced = "Advanced", preferences = "Preferences"
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

private struct ManualCameraControls: View {
    @ObservedObject var model: CameraViewModel
    let page: CameraToolPage
    private let shutters = [8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4, 2, 1]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if page == .exposure {
                Toggle("Automatic exposure", isOn: $model.controls.automaticExposure)
                    .disabled(!model.camera.customExposureAvailable)
                if !model.controls.automaticExposure && model.camera.customExposureAvailable {
                    LabeledContent("ISO", value: "\(Int(model.controls.iso))")
                    Slider(value: $model.controls.iso, in: model.camera.minISO...max(model.camera.minISO + 1, model.camera.maxISO), step: 1).accessibilityLabel("ISO")
                    Picker("Shutter", selection: $model.controls.shutterSeconds) {
                        ForEach(shutters, id: \.self) { denominator in
                            Text(denominator == 1 ? "1 second" : "1/\(denominator) s").tag(1.0 / Double(denominator))
                        }
                    }
                }
                LabeledContent("Actual exposure", value: model.camera.exposureLabel)
                Text("Available shutter speeds depend on your lens and video frame rate.").font(.footnote)
                if model.controls.automaticExposure {
                    HStack {
                        Text("Brightness")
                        Slider(value: $model.exposureBias, in: -2...2, step: 0.1).accessibilityLabel("Exposure compensation")
                    }
                }
                if model.mode == .photo && model.camera.flashAvailable {
                    Picker("Flash", selection: $model.controls.flash) {
                        Text("Off").tag(AVCaptureDevice.FlashMode.off); Text("Auto").tag(AVCaptureDevice.FlashMode.auto); Text("On").tag(AVCaptureDevice.FlashMode.on)
                    }.pickerStyle(.segmented)
                }
            } else if page == .color {
                Toggle("Automatic color", isOn: $model.controls.automaticWhiteBalance)
                    .disabled(!model.camera.whiteBalanceAvailable)
                if !model.controls.automaticWhiteBalance && model.camera.whiteBalanceAvailable {
                    LabeledContent("Temperature", value: "\(Int(model.controls.temperature)) K")
                    Slider(value: $model.controls.temperature, in: 2500...10000, step: 100).accessibilityLabel("White balance temperature")
                    LabeledContent("Tint", value: "\(Int(model.controls.tint))")
                    Slider(value: $model.controls.tint, in: -100...100, step: 1).accessibilityLabel("White balance tint")
                }
                Text("Automatic color adjusts to the light around you.").font(.footnote)
            } else {
                Toggle("Automatic focus", isOn: $model.controls.automaticFocus)
                    .disabled(!model.camera.manualFocusAvailable)
                if model.controls.automaticFocus {
                    Toggle("Prefer faces", isOn: $model.controls.facePriority)
                } else if model.camera.manualFocusAvailable {
                    HStack {
                        Text("Near")
                        Slider(value: $model.controls.lensPosition, in: 0...1).accessibilityLabel("Focus distance")
                        Text("Far")
                    }
                }
                Text("Automatic focus follows your scene. For manual control, use the Near–Far slider and watch the preview.").font(.footnote)
            }
            Text("Changes appear in the preview.").font(.caption).foregroundStyle(.secondary)
            Button("Reset to automatic", action: model.resetControls).buttonStyle(.bordered)
        }.disabled(!model.canConfigure)
            .onChange(of: model.controls) { _, _ in model.scheduleControls() }
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


private struct RecentCaptureView: View {
    let record: CaptureStore.Record
    let close: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var selection = 0
    @State private var comparing = true
    @State private var comparisonFirst = 0
    @State private var comparisonSecond = 1
    @AppStorage("camera.captureDetails") private var showDetails = false
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(record.isVideo ? "Last video" : record.photos.count > 1 ? "Saved photos" : "Last photo").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close recent capture")
            }
            if record.isVideo, let data = record.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
                Text("Video saved in Photos").font(.caption)
            } else if record.photos.indices.contains(selection) {
                if comparing && record.photos.count >= 2 {
                    HStack(spacing: 6) {
                        ForEach([comparisonFirst, comparisonSecond], id: \.self) { index in
                            VStack {
                                ZoomableCapture(data: record.photos[index].data, maxSize: 1500, label: record.photos[index].label)
                                    .id(index)
                                Button("Enlarge \(record.photos[index].label)") { selection = index; comparing = false }
                                    .font(.caption).frame(minHeight: 44)
                            }
                        }
                    }
                } else { ZoomableCapture(data: record.photos[selection].data, label: record.photos[selection].label).id(selection) }
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
            } else { Text("Open Photos to review this video.") }
            Button("Open Photos") {
                if let url = URL(string: "photos-redirect://") { openURL(url) }
            }.frame(minHeight: 44)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local device check").font(.subheadline.weight(.semibold))
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
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                UIDevice.current.isBatteryMonitoringEnabled = previouslyMonitoring
                return
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            while !Task.isCancelled {
                memory = Self.memoryFootprint()
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

    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
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
        private var previousSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            if previousSize != bounds.size {
                previousSize = bounds.size
                setZoomScale(1, animated: false)
                contentOffset = .zero
            }
            if zoomScale == 1 { picture?.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ZoomView {
        let view = ZoomView()
        view.minimumZoomScale = 1; view.maximumZoomScale = 5
        view.delegate = context.coordinator
        context.coordinator.scrollView = view
        let image = context.coordinator.imageView
        context.coordinator.decodeTask = Task { @MainActor [weak image] in
            let decoded = await CapturePreviewDecoder.image(data, maxSize: maxSize)
            guard !Task.isCancelled else { return }
            image?.image = decoded
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
        return view
    }
    static func dismantleUIView(_ view: ZoomView, coordinator: Coordinator) {
        coordinator.decodeTask?.cancel()
        coordinator.decodeTask = nil
        coordinator.imageView.image = nil
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
    var body: some View {
        CameraPreview(engine: engine, onFocus: onFocus, fillView: fillView, showsFocusFeedback: showsFocusFeedback,
                      focusState: focusState, exposureOnly: exposureOnly, showsGrid: showsGrid,
                      guideImage: hidesGuides ? nil : guides.image)
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
