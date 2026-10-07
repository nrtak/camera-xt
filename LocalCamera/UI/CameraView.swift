import SwiftUI
import AVFoundation
import PhotosUI
import CoreImage
import ImageIO

struct CameraView: View {
    @StateObject private var model = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var confirmDiscard = false
    @AppStorage("camera.showsGrid") private var showsGrid = true
    @State private var toolPath: [CameraToolPage] = []
    @State private var showsCaptureInfo = false
    @GestureState private var holdingPeek = false
    @State private var accessiblePeek = false
    @State private var enlargedDualIndex: Int?
    private var isPeeking: Bool { holdingPeek || accessiblePeek }
    private var hasAdjustments: Bool {
        model.captureStyle != "Auto" || model.timerSeconds > 0 || model.burstEnabled ||
        model.camera.dualEnabled || model.camera.depthEnabled || model.camera.eyeFocusEnabled ||
        model.camera.focusLocked || !model.controls.automaticExposure || !model.controls.automaticFocus ||
        !model.controls.automaticWhiteBalance || abs(model.exposureBias) > 0.05
    }

    private let ink = Color(red: 0.10, green: 0.14, blue: 0.22)
    private let selection = Color(red: 1, green: 0.94, blue: 0.36)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.permission == .authorized {
                if model.camera.dualEnabled {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            ForEach(0..<2, id: \.self) { index in
                                let inset = enlargedDualIndex != nil && enlargedDualIndex != index
                                let width = inset ? geometry.size.width * 0.38 : geometry.size.width
                                let height = enlargedDualIndex == nil ? (geometry.size.height - 4) / 2 :
                                    inset ? geometry.size.height * 0.32 : geometry.size.height
                                dualViewfinder(index == 0 ? "Main · 1×" : "Ultra Wide · 0.5×", index: index)
                                    .frame(width: width, height: height)
                                    .clipShape(RoundedRectangle(cornerRadius: inset ? 12 : 0))
                                    .overlay { RoundedRectangle(cornerRadius: inset ? 12 : 0).strokeBorder(.white.opacity(inset ? 0.8 : 0), lineWidth: 2).allowsHitTesting(false) }
                                    .offset(x: inset ? geometry.size.width - width - 8 : 0,
                                            y: enlargedDualIndex == nil ? CGFloat(index) * (height + 4) : inset ? geometry.size.height - height - 8 : 0)
                                    .zIndex(inset ? 1 : 0)
                            }
                        }
                    }
                } else {
                    CameraPreview(engine: model.engine, onFocus: model.focus)
                        .ignoresSafeArea()
                        .accessibilityLabel("Camera viewfinder")
                }
                if showsGrid && model.camera.running && !isPeeking && !model.camera.dualEnabled {
                    compositionGrid.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
                }
            }

            VStack(spacing: 12) {
                ZStack(alignment: .trailing) {
                    Color.clear.allowsHitTesting(false)
                    if model.permission != .authorized || model.camera.message != nil {
                        cameraNotice.padding(.horizontal, 24).frame(maxWidth: .infinity)
                    } else if !showsCaptureInfo && !model.reviewingBurst && !isPeeking && model.selectedLens?.isFront == false && !model.camera.dualEnabled {
                        lensSelector.padding(.trailing, 14)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if showsCaptureInfo || model.reviewingBurst {
                GeometryReader { geometry in
                    Group {
                        if model.reviewingBurst {
                            BurstReview(model: model)
                                .background(Color.white.opacity(reduceTransparency ? 1 : 0.72), in: RoundedRectangle(cornerRadius: 24))
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                        } else { captureInfo }
                    }
                        .frame(height: geometry.size.height * 0.82)
                        .contentShape(Rectangle())
                        .background { Rectangle().fill(Color.clear).contentShape(Rectangle()).onTapGesture {} }
                        .opacity(isPeeking ? 0 : 1)
                        .disabled(isPeeking)
                        .accessibilityHidden(isPeeking)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { captureHUD.opacity(isPeeking ? 0 : 1).disabled(isPeeking).accessibilityHidden(isPeeking) }
        .safeAreaInset(edge: .bottom, spacing: 0) { captureControls }
        .onChange(of: showsCaptureInfo) { _, _ in accessiblePeek = false }
        .onChange(of: model.reviewingBurst) { _, _ in accessiblePeek = false }
        .foregroundStyle(ink)
        .tint(ink)
        .preferredColorScheme(.light)
        .task { model.setActive(scenePhase == .active) }
        .onChange(of: scenePhase) {
            if $0 != .active { accessiblePeek = false }
            if $0 == .background { model.enteredBackground() }
            model.setActive($0 == .active)
        }
        .confirmationDialog("Discard the unsaved capture?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard capture", role: .destructive, action: model.discard)
        }
    }

    private func dualViewfinder(_ title: String, index: Int) -> some View {
        CameraPreview(engine: model.engine, onFocus: { point, _ in
            model.focusDual(at: point, index: index)
        }, secondary: index == 1, showsFocusFeedback: model.canConfigure &&
            model.camera.dualFocusSupported.indices.contains(index) && model.camera.dualFocusSupported[index])
        .background(.black)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(model.camera.dualFocusSupported.indices.contains(index) && model.camera.dualFocusSupported[index] ? "Tap to focus" : "Tap focus unavailable")
                    .font(.caption2)
                Button {
                    enlargedDualIndex = enlargedDualIndex == index ? nil : index
                } label: {
                    Image(systemName: enlargedDualIndex == index ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(enlargedDualIndex == index ? "Show both cameras equally" : "Enlarge \(title)")
            }
            .padding(6).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 12)).padding(6)
        }
        .accessibilityLabel("\(title) live viewfinder. Tap to focus this camera.")
    }

    private func openTool(_ page: CameraToolPage? = nil) {
        toolPath = page.map { [$0] } ?? []
        showsCaptureInfo = true
    }

    private var captureHUD: some View {
        VStack(spacing: 8) {
            Button { openTool(.details) } label: {
                Text("\(model.mode.rawValue) | \(model.camera.dualEnabled ? "Dual Shot" : model.selectedLens?.name ?? "Camera")")
                    .font(.subheadline.weight(.semibold)).padding(12)
                    .background(Color.white.opacity(0.96), in: Capsule())
            }
            .disabled(!model.canConfigure)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { activeIndicators }
                VStack(spacing: 6) { activeIndicators }
            }
            if model.countdown > 0 {
                Text("\(model.countdown)").font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).accessibilityLabel("Shutter in \(model.countdown) seconds")
            }
            if let message = model.message {
                Text(message).font(.caption).multilineTextAlignment(.center)
                    .padding(10).background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
            }
            if model.hasPendingCapture && !model.busy {
                ViewThatFits(in: .horizontal) {
                    HStack { saveRecovery }
                    VStack { saveRecovery }
                }.font(.callout).padding(10)
                    .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 14).padding(.top, 6)
    }

    @ViewBuilder private var activeIndicators: some View {
        if model.captureStyle != "Auto" { indicator(model.captureStyle, page: .shoot) }
        if model.timerSeconds > 0 { indicator("Timer \(model.timerSeconds)s", page: .timer) }
        if model.camera.focusLocked { indicator("Focus locked", page: .focus) }
        else if model.camera.eyeFocusEnabled { indicator("Eye focus", page: .focus) }
        if model.camera.depthEnabled { indicator("Depth", page: .focus) }
        if model.burstEnabled && model.captureStyle == "Auto" { indicator("3-shot burst", page: .shoot) }
        if model.camera.dualEnabled { indicator("Dual Shot", page: .shoot) }
        if !model.controls.automaticExposure && model.captureStyle == "Auto" { indicator("Manual exposure", page: .exposure) }
        if abs(model.exposureBias) > 0.05 { indicator(String(format: "%+.1f EV", model.exposureBias), page: .exposure) }
        if !model.controls.automaticFocus { indicator("Manual focus", page: .manualFocus) }
        if !model.controls.automaticWhiteBalance { indicator("Manual color", page: .color) }
        if model.camera.recording { Text("Recording").foregroundStyle(.red).padding(8).background(Color.white.opacity(0.96), in: Capsule()) }
    }

    private func indicator(_ title: String, page: CameraToolPage) -> some View {
        Button(title) { openTool(page) }.font(.caption.weight(.semibold))
            .padding(10).background(selection, in: Capsule())
            .disabled(!model.canConfigure)
    }

    private var lensSelector: some View {
        VStack(spacing: 4) {
            ForEach(model.camera.lenses.filter { !$0.isFront && $0.name != "Depth" }) { lens in
                Button { model.select(lens) } label: {
                    Text(lens.name).font(.caption.weight(.semibold))
                        .frame(width: 68, height: 44)
                        .background(lens.id == model.camera.selectedID ? selection : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(lens.name) camera")
                .accessibilityAddTraits(lens.id == model.camera.selectedID ? .isSelected : [])
            }
        }
        .padding(5).background(Color.white.opacity(0.96), in: Capsule()).disabled(!model.canSwitch)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var captureControls: some View {
        VStack(spacing: 12) {
            if showsCaptureInfo || model.reviewingBurst || hasAdjustments {
                ViewThatFits(in: .horizontal) {
                    HStack { overlayActions }
                    VStack(spacing: 4) { overlayActions }
                }
            }
            HStack(spacing: 12) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    Button { model.selectMode(mode) } label: {
                        Text(mode.rawValue.uppercased())
                            .font(.caption.weight(.semibold))
                            .frame(minWidth: 80, minHeight: 44)
                            .background(model.mode == mode ? selection : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                }
            }
            .disabled(model.busy || model.configuring || model.hasPendingCapture || model.camera.recording)

            HStack {
                Button { openTool() } label: {
                    VStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                        .background(Color.white.opacity(0.45), in: Circle())
                    Text("Tools").font(.caption2)
                    }
                }
                .accessibilityLabel("Camera Tools")
                .disabled(!model.canConfigure)
                .frame(maxWidth: .infinity)

                Button { showsCaptureInfo = false; model.shutter() } label: {
                    ZStack {
                        Circle().fill(model.mode == .video ? Color.red : Color.white)
                        Circle().strokeBorder(ink.opacity(0.65), lineWidth: 2).padding(5)
                        if model.camera.recording { RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 28, height: 28) }
                        else if model.busy { ProgressView().tint(ink) }
                    }
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                }
                .accessibilityLabel(model.mode == .photo ? "Take photo" : model.camera.recording ? "Stop recording" : "Start recording")
                .disabled(!model.canShutter)
                .opacity(model.canShutter ? 1 : 0.4)

                Button(action: model.flip) {
                    VStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.45), in: Circle())
                    Text("Flip").font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Switch front and rear camera")
                .disabled(!model.canSwitch || !model.camera.lenses.contains { $0.isFront != model.selectedLens?.isFront })
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                .fill(Color.white.opacity(reduceTransparency ? 1 : 0.72)).ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder private var overlayActions: some View {
        if showsCaptureInfo || model.reviewingBurst {
            Label(isPeeking ? "Release to return" : "Peek at scene", systemImage: "eye")
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).updating($holdingPeek) { _, state, _ in state = true })
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(accessiblePeek ? "Restore tools" : "Peek at scene")
                .accessibilityHint("Hold to hide the panel. With VoiceOver, double tap to toggle.")
                .accessibilityAction { accessiblePeek.toggle() }
        }
        Button("Reset to Auto") { accessiblePeek = false; useTool(.automatic) }
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(!model.canConfigure)
    }

    @ViewBuilder private var saveRecovery: some View {
        Button("Retry save") { Task { await model.retrySave() } }
        Button("Settings", action: openSettings)
        Button("Discard", role: .destructive) { confirmDiscard = true }
    }

    private var captureInfo: some View {
        VStack(spacing: 0) {
            HStack {
                if !toolPath.isEmpty {
                    Button { toolPath.removeLast() } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("Back to camera tools")
                }
                Text(toolPath.last?.rawValue ?? "Camera Tools").font(.headline)
                Spacer()
                Button { showsCaptureInfo = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Close camera tools")
            }.padding(.horizontal, 12)
            if let page = toolPath.last {
                toolPage(page)
            } else {
                CompactToolLayout {
                    toolGrid([.shoot, .focus, model.mode == .photo ? .timer : .video, .exposure, .color, .manualFocus, .details, .rescue, .preferences, .gallery])
                    HStack(spacing: 12) {
                        quickPreset("Action", icon: "figure.run", detail: "Fast movement", tool: .action)
                        quickPreset("Night", icon: "moon", detail: "Hold still · Experimental", tool: .night)
                    }
                    Button("Reset to Auto") { useTool(.automatic) }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .background(Color.white.opacity(reduceTransparency ? 1 : 0.72), in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.5), lineWidth: 1).allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func toolGrid(_ pages: [CameraToolPage]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(pages, id: \.self) { page in
                Button { toolPath.append(page) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: page.icon).font(.title2)
                        Text(page.rawValue).font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(10)
                    .background(Color.gray.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
            }
        }
    }

    private func quickPreset(_ title: String, icon: String, detail: String, tool: QuickCaptureTool) -> some View {
        Button { useTool(tool) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: icon).font(.headline)
                Text(detail).font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(10)
                .background(selection, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).disabled(!model.canConfigure || !model.camera.running)
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
            case .exposure, .color, .manualFocus:
                CompactToolLayout {
                    if model.camera.dualEnabled {
                        Text("Manual controls use a single camera.")
                        Button("Switch to single Photo") { model.activate(.automatic) }.buttonStyle(.borderedProminent)
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
            Text("Choose what you want to capture.").foregroundStyle(.secondary)
            if model.camera.dualEnabled || model.mode == .video {
                Text("Selecting a style switches to its compatible Photo setup.").font(.footnote)
            }
            featureButton("Automatic", icon: "camera", detail: "Everyday photos with automatic settings") { useTool(.automatic) }
            featureButton("Action", icon: "figure.run", detail: "Fast shutter and 3 photos. Needs good light.") { useTool(.action) }
            featureButton("Night", icon: "moon", detail: "Experimental. Hold still; timer and 3 slow exposures.") { useTool(.night) }
            featureButton("Best Shot", icon: "square.stack", detail: "Take 3 photos, then choose your favorite") { useTool(.burst) }
            if model.camera.dualAvailable {
                featureButton("Dual Shot", icon: "camera.on.rectangle", detail: "Main and ultra-wide photos from one press") { useTool(.dual) }
            }
        case .focus:
            Text("Tap to focus. Hold to lock. No setup needed.").foregroundStyle(.secondary)
            Button("Reset focus and exposure") { model.focus(at: CGPoint(x: 0.5, y: 0.5), locked: false) }.buttonStyle(.bordered)
            featureButton(model.camera.eyeFocusEnabled ? "Turn off eye focus" : "Eye focus", icon: "eye", detail: "Experimental. Follows an eye on the largest face in rear Photo mode.") {
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
            Text("The timer turns off after use or when you return from the background.").font(.footnote)
            Button("Ready") { showsCaptureInfo = false }.buttonStyle(.borderedProminent)
        case .video:
            Picker("Resolution", selection: $model.videoWidth) { Text("1080p").tag(Int32(1920)); Text("4K").tag(Int32(3840)) }.pickerStyle(.segmented)
            Picker("Frame rate", selection: $model.videoFPS) { Text("24 fps").tag(Int32(24)); Text("30 fps").tag(Int32(30)); Text("60 fps").tag(Int32(60)) }.pickerStyle(.segmented)
            Toggle("Steadier video", isOn: $model.stabilization)
            Text("The selected lens determines which formats are available.").font(.footnote)
            Button("Apply video settings") { model.applyVideoSettings(); showsCaptureInfo = false }.buttonStyle(.borderedProminent)
        case .preferences:
            Toggle("Composition grid", isOn: $showsGrid)
            Text("Grid and your chosen rear lens are remembered. Timers and exposure locks reset; photos stay on your iPhone.").font(.callout).foregroundStyle(.secondary)
            Button("Design Preview") { toolPath.append(.gallery) }.buttonStyle(.bordered)
            Button("Reset capture settings") { model.activate(.automatic); showsCaptureInfo = false }.buttonStyle(.bordered)
        case .details:
            LabeledContent("Mode", value: model.mode.rawValue)
            LabeledContent("Lens", value: model.selectedLens?.name ?? "Unavailable")
            LabeledContent("Resolution", value: model.mode == .photo ? model.camera.resolution : model.camera.videoLabel)
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
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).disabled(!model.canConfigure)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

private enum CameraToolPage: String, Hashable {
    case shoot = "Capture style", focus = "Focus & depth", timer = "Timer", video = "Video quality"
    case rescue = "Photo Rescue", advanced = "Advanced", preferences = "Preferences"
    case exposure = "Exposure", color = "Color", manualFocus = "Manual focus", details = "Capture details", gallery = "Design Preview"
    var icon: String {
        switch self {
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
            .controlSize(.large)
    }
}

// The original reference is bundled locally so design review works offline.
// These images are illustrations, never representations of active camera settings.
private struct PhotoRescueView: View {
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
                HStack {
                    Text("Strength")
                    Slider(value: $model.strength, in: 0...1, step: 0.1, onEditingChanged: { editing in
                        if !editing { Task { await model.apply() } }
                    }).accessibilityLabel("Adjustment strength").disabled(model.busy)
                }
                Button(model.saved ? "Copy saved" : "Save a copy") { Task { await model.save() } }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.saved)
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
                            .background(model.selectedBurstIndex == index ? Color.yellow.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .accessibilityLabel("Frame \(index + 1)\(index == model.recommendedBurstIndex ? ", suggested" : "")")
                    }
                }
                Text("The suggestion uses face quality and image detail on this iPhone. Compare the frames and choose your favorite.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Save selected") { Task { await model.saveBurst(all: false) } }
                    Button("Save all \(model.burstPhotos.count)") { Task { await model.saveBurst(all: true) } }
                }.buttonStyle(.borderedProminent)
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
                .background(Color.yellow.opacity(0.4), in: Capsule())
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
