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
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var confirmDiscard = false
    @AppStorage("camera.showsGrid") private var showsGrid = true
    @State private var toolPath: [CameraToolPage] = []
    @State private var showsCaptureInfo = false
    @GestureState private var holdingPeek = false
    @State private var accessiblePeek = false
    @AppStorage("camera.dualLayout") private var dualLayout = -1
    @AppStorage("camera.dualCorner") private var dualCorner = 3
    @AppStorage("camera.lastTool") private var lastTool = ""
    @AppStorage("camera.showHelp") private var showHelp = false
    @State private var showsRecent = false
    @State private var selectedDualIndex = 0
    private var enlargedDualIndex: Int? {
        get { (0...1).contains(dualLayout) ? dualLayout : nil }
        nonmutating set { dualLayout = newValue ?? -1 }
    }
    private var isPeeking: Bool { holdingPeek || accessiblePeek }
    private var hasAdjustments: Bool {
        model.captureStyle != "Auto" || model.timerSeconds > 0 || model.burstEnabled ||
        model.camera.dualEnabled || model.camera.depthEnabled || model.camera.eyeFocusEnabled ||
        model.camera.focusLocked || model.camera.analysisMode != "Off" || !model.controls.automaticExposure || !model.controls.automaticFocus ||
        !model.controls.automaticWhiteBalance || abs(model.exposureBias) > 0.05
    }

    private let ink = Color.white
    private var overlayColor: Color { .black.opacity(reduceTransparency ? 1 : contrast == .increased ? 0.75 : 0.55) }
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
                                    .offset(x: inset ? (dualCorner % 2 == 0 ? 8 : geometry.size.width - width - 8) : 0,
                                            y: enlargedDualIndex == nil ? CGFloat(index) * (height + 4) : inset ? (dualCorner < 2 ? 8 : geometry.size.height - height - 8) : 0)
                                    .zIndex(inset ? 1 : 0)
                            }
                        }
                    }
                } else {
                    GuidedCameraPreview(guides: model.guides, engine: model.engine, onFocus: model.focus, showsFocusFeedback: model.canConfigure, focusState: model.camera.focusStates.first ?? "Auto focus", exposureOnly: model.exposurePointOnly, showsGrid: showsGrid && !isPeeking, hidesGuides: isPeeking)
                        .ignoresSafeArea()
                        .accessibilityLabel("Camera viewfinder")
                }
            }

            VStack(spacing: 12) {
                ZStack(alignment: .trailing) {
                    Color.clear.allowsHitTesting(false)
                    if model.permission != .authorized || model.camera.message != nil {
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
                                .background(overlayColor, in: RoundedRectangle(cornerRadius: 12))
                        } else if model.reviewingBurst {
                            BurstReview(model: model)
                                .background(overlayColor, in: RoundedRectangle(cornerRadius: 12))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else { captureInfo }
                    }
                        .frame(height: min(geometry.size.height * 0.82, toolPanelHeight))
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
        .onChange(of: toolPath) { _, path in lastTool = path.last?.rawValue ?? "" }
        .onChange(of: showsCaptureInfo) { _, _ in accessiblePeek = false }
        .onChange(of: model.reviewingBurst) { _, _ in accessiblePeek = false }
        .foregroundStyle(ink)
        .tint(ink)
        .preferredColorScheme(.dark)
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
        CameraPreview(engine: model.engine, onFocus: { point, locked in
            selectedDualIndex = index
            model.focusDual(at: point, index: index, locked: locked)
        }, secondary: index == 1, showsFocusFeedback: model.canConfigure &&
            model.camera.dualFocusSupported.indices.contains(index) && model.camera.dualFocusSupported[index],
            focusState: model.camera.focusStates.indices.contains(index) ? model.camera.focusStates[index] : "Auto focus",
            exposureOnly: model.exposurePointOnly)
        .background(.black)
        .overlay { Rectangle().strokeBorder(selectedDualIndex == index ? selection.opacity(0.8) : .clear, lineWidth: 1).allowsHitTesting(false) }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Button("Brightness") { selectedDualIndex = index; openTool(.exposure) }
                    .font(.caption2).frame(minHeight: 44).disabled(!model.canConfigure)
                Text(model.camera.focusStates.indices.contains(index) ? model.camera.focusStates[index] : "Tap focus unavailable")
                    .font(.caption2)
                Button {
                    enlargedDualIndex = enlargedDualIndex == index ? nil : index
                } label: {
                    Image(systemName: enlargedDualIndex == index ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(enlargedDualIndex == index ? "Show both cameras equally" : "Enlarge \(title)")
            }
            .padding(6).background(overlayColor, in: RoundedRectangle(cornerRadius: 12)).padding(6)
        }
        .accessibilityLabel("\(title) live viewfinder. Tap to focus this camera.")
    }

    private func openTool(_ page: CameraToolPage? = nil) {
        let selected = page ?? CameraToolPage(rawValue: lastTool)
        toolPath = selected.map { [$0] } ?? []
        showsRecent = false
        showsCaptureInfo = true
    }

    private var captureHUD: some View {
        VStack(spacing: 8) {
            Button { openTool(.details) } label: {
                Text("\(model.mode.rawValue) | \(model.camera.dualEnabled ? "Dual · \(model.camera.dualMode.rawValue)" : model.selectedLens?.name ?? "Camera")")
                    .font(.subheadline.weight(.semibold)).padding(12)
                    .background(overlayColor, in: RoundedRectangle(cornerRadius: 8))
            }
            .disabled(!model.canConfigure)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { activeIndicators }
                VStack(spacing: 6) { activeIndicators }
            }
            LiveHistogram(guides: model.guides, overlayColor: overlayColor)
            if model.lowStorage { Text("Low storage · free space before a long recording").font(.caption).padding(8).background(overlayColor) }
            if model.camera.cooling { Text("iPhone is warm · optional processing is reduced").font(.caption).padding(8).background(overlayColor) }
            if model.countdown > 0 {
                Text("\(model.countdown)").font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).accessibilityLabel("Shutter in \(model.countdown) seconds")
            }
            if let message = model.message {
                Text(message).font(.caption).multilineTextAlignment(.center)
                    .padding(10).background(overlayColor, in: RoundedRectangle(cornerRadius: 12))
            }
            if model.hasPendingCapture && !model.busy {
                ViewThatFits(in: .horizontal) {
                    HStack { saveRecovery }
                    VStack { saveRecovery }
                }.font(.callout).padding(10)
                    .background(overlayColor, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 14).padding(.top, 6)
    }

    @ViewBuilder private var activeIndicators: some View {
        if model.captureStyle != "Auto" { indicator(model.captureStyle, page: .shoot) }
        if model.timerSeconds > 0 { indicator("Timer \(model.timerSeconds)s", page: .timer) }
        if model.camera.focusLocked { indicator("Focus locked", page: .focus) }
        else if model.camera.eyeFocusEnabled { indicator("Eye focus", page: .focus) }
        if model.camera.analysisMode != "Off" { indicator(model.camera.analysisMode, page: .guides) }
        if model.camera.depthEnabled { indicator("Depth", page: .focus) }
        if model.burstEnabled && model.captureStyle == "Auto" { indicator("3-shot burst", page: .shoot) }
        if model.camera.dualEnabled { indicator("Dual · \(model.camera.dualMode.rawValue)", page: .shoot) }
        if !model.controls.automaticExposure && model.captureStyle == "Auto" { indicator("Manual exposure", page: .exposure) }
        if abs(model.exposureBias) > 0.05 { indicator(String(format: "%+.1f EV", model.exposureBias), page: .exposure) }
        if !model.controls.automaticFocus { indicator("Manual focus", page: .manualFocus) }
        if !model.controls.automaticWhiteBalance { indicator("Manual color", page: .color) }
        if model.camera.recording, let started = model.recordingStarted {
            HStack {
                Image(systemName: "record.circle").foregroundStyle(.red)
                Text(started, style: .timer).monospacedDigit()
                Image(systemName: model.camera.audioRecording ? "mic.fill" : "mic.slash.fill")
            }.font(.callout).padding(8).background(overlayColor, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(model.camera.audioRecording ? "Recording with sound" : "Recording without sound")
        }
    }

    private func indicator(_ title: String, page: CameraToolPage) -> some View {
        Button(title) { openTool(page) }.font(.caption.weight(.semibold))
            .padding(8).foregroundStyle(.black).background(selection, in: RoundedRectangle(cornerRadius: 8))
            .disabled(!model.canConfigure)
    }

    private var lensSelector: some View {
        HStack(spacing: 10) {
            ForEach(model.camera.lenses.filter { !$0.isFront && $0.name != "Depth" }.sorted { ($0.zoomFactor ?? 100) < ($1.zoomFactor ?? 100) }) { lens in
                Button { model.select(lens) } label: {
                    Text(lens.zoomLabel).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(lens.id == model.camera.selectedID ? Color.black : .white)
                        .background(lens.id == model.camera.selectedID ? selection : Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(lens.zoomLabel), \(lens.name) camera")
                .accessibilityAddTraits(lens.id == model.camera.selectedID ? .isSelected : [])
            }
        }
        .disabled(!model.canSwitch)
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
        .background(overlayColor, in: RoundedRectangle(cornerRadius: 12))
    }

    private var captureControls: some View {
        VStack(spacing: 6) {
            ZStack {
                lensSelector
                    .opacity(!showsCaptureInfo && !showsRecent && !model.reviewingBurst && model.selectedLens?.isFront == false && !model.camera.dualEnabled ? 1 : 0)
                    .allowsHitTesting(!showsCaptureInfo && !showsRecent && !model.reviewingBurst && model.selectedLens?.isFront == false && !model.camera.dualEnabled)
                    .accessibilityHidden(showsCaptureInfo || showsRecent || model.reviewingBurst || model.selectedLens?.isFront != false || model.camera.dualEnabled)
                if showsCaptureInfo || showsRecent || model.reviewingBurst { HStack { overlayActions } }
            }.frame(height: 44)
            HStack(spacing: 12) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    Button { model.selectMode(mode) } label: {
                        Text(mode.rawValue.uppercased())
                            .font(.caption.weight(.semibold))
                            .frame(minWidth: 80, minHeight: 44)
                            .foregroundStyle(model.mode == mode ? Color.black : .white)
                            .background(model.mode == mode ? selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                }
                Button { openTool() } label: {
                    Label("Tools", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold)).frame(minWidth: 70, minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("Camera Tools")
            }
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
                        Text("Photos").font(.caption2)
                    }
                }
                .accessibilityLabel(model.lastSavedThumbnail == nil ? "Open Photos" : "Review last saved capture")
                .disabled(!model.canConfigure)
                .frame(maxWidth: .infinity)

                Button { showsCaptureInfo = false; showsRecent = false; model.shutter() } label: {
                    ZStack {
                        Circle().fill(model.mode == .video ? Color.red : Color.white)
                        Circle().strokeBorder(Color.black.opacity(0.65), lineWidth: 2).padding(5)
                        if model.camera.recording { RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 28, height: 28) }
                        else if model.busy { ProgressView().tint(.black) }
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
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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
            UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
                .fill(overlayColor).ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder private var overlayActions: some View {
        if showsCaptureInfo || model.reviewingBurst || showsRecent {
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

    private var toolPanelHeight: CGFloat {
        if showsRecent || model.reviewingBurst { return .infinity }
        let base: CGFloat
        switch toolPath.last {
        case nil: base = 270
        case .shoot: base = model.camera.dualEnabled ? 290 : 350
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
                if !toolPath.isEmpty {
                    Button { toolPath = [] } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("All camera tools")
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
                    toolGrid([.shoot, .focus, model.mode == .photo ? .timer : .video, .exposure, .color, .manualFocus, .details, .rescue, .preferences])
                }
            }
        }
        .background(overlayColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15), lineWidth: 1).allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func toolGrid(_ pages: [CameraToolPage]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(pages, id: \.self) { page in
                Button { toolPath.append(page) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Image(systemName: page.icon).font(.title3)
                        Text(page.rawValue).font(.caption.weight(.semibold)).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
                Picker("Dual Shot capture", selection: Binding(get: { model.camera.dualMode }, set: { model.setDualMode($0) })) {
                    ForEach(DualShotMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(!model.canConfigure)
                Text(model.camera.dualMode == .fast ? "Fast · Up to 12 MP per view. Best for movement." : "Detail · Beta. Hold still for both photos. Up to 48 MP where supported; a pause is expected.")
                    .font(.footnote)
                Text(model.camera.resolution).font(.caption).monospacedDigit()
                featureButton("Single Photo", icon: "camera", detail: "Return to one camera") { useTool(.automatic) }
            } else {
            if model.mode == .video {
                Text("Selecting a style switches to its compatible Photo setup.").font(.footnote)
            }
            featureButton("Automatic", icon: "camera", detail: "Everyday photos with automatic settings") { useTool(.automatic) }
            featureButton("Action burst", icon: "figure.run", detail: "Fast shutter and 3 photos. Needs good light.") { useTool(.action) }
            featureButton("Low-light burst · Beta", icon: "moon", detail: "Experimental. Hold still; timer and 3 slow exposures.") { useTool(.night) }
            featureButton("Best Shot", icon: "square.stack", detail: "Take 3 photos, then choose your favorite") { useTool(.burst) }
            if model.camera.dualAvailable {
                featureButton("Dual Shot", icon: "camera.on.rectangle", detail: "Main and ultra-wide photos from one press") { useTool(.dual) }
            }
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
            Text("The timer turns off after use or when you return from the background.").font(.footnote)
            Button("Ready") { showsCaptureInfo = false }.buttonStyle(.borderedProminent).foregroundStyle(.black)
        case .video:
            Picker("Resolution", selection: $model.videoWidth) { Text("1080p").tag(Int32(1920)); Text("4K").tag(Int32(3840)) }.pickerStyle(.segmented)
            Picker("Frame rate", selection: $model.videoFPS) { Text("24 fps").tag(Int32(24)); Text("30 fps").tag(Int32(30)); Text("60 fps").tag(Int32(60)) }.pickerStyle(.segmented)
            Toggle("Steadier video", isOn: $model.stabilization)
            Text("The selected lens determines which formats are available.").font(.footnote)
            Button("Apply video settings") { model.applyVideoSettings(); showsCaptureInfo = false }.buttonStyle(.borderedProminent).foregroundStyle(.black)
        case .preferences:
            Toggle("Composition grid", isOn: $showsGrid)
            Toggle("Capture vibrations", isOn: $model.haptics)
            Picker("Dual Shot inset", selection: $dualCorner) {
                Text("Top left").tag(0); Text("Top right").tag(1)
                Text("Bottom left").tag(2); Text("Bottom right").tag(3)
            }
            if showHelp { Text("Reset to Auto clears capture settings, timer, and locks. Your grid, vibrations, lens, and layout preferences stay unchanged.").font(.footnote) }
            Button("Clear recent preview") { Task { await model.clearRecent() } }.buttonStyle(.bordered)
            if showHelp { Text("Only the latest capture is cached here. Clearing it does not delete anything in Photos.").font(.footnote) }
            Button("Viewfinder guides") { toolPath = [.guides] }.buttonStyle(.bordered)
            Button("Design Preview") { toolPath.append(.gallery) }.buttonStyle(.bordered)
            Button("Reset capture settings") { model.activate(.automatic); showsCaptureInfo = false }.buttonStyle(.bordered)
        case .details:
            LabeledContent("Mode", value: model.mode.rawValue)
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
            }.padding(8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!model.canConfigure).accessibilityHint(detail)
    }

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
    case guides = "Viewfinder guides"
    case shoot = "Shot styles", focus = "Focus & depth", timer = "Timer", video = "Video quality"
    case rescue = "Photo Rescue", advanced = "Advanced", preferences = "Preferences"
    case exposure = "Exposure", color = "Color", manualFocus = "Manual focus", details = "Info", gallery = "Design Preview"
    var icon: String {
        switch self {
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
                .background(Color.yellow.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
                ZoomableCapture(data: record.photos[selection].data).id(selection)
                let photo = record.photos[selection]
                Text("\(photo.label) · \(photo.width) × \(photo.height)").font(.caption)
                if record.photos.count > 1 {
                    HStack {
                        ForEach(record.photos.indices, id: \.self) { index in
                            Button(record.photos[index].label) { selection = index }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(selection == index ? Color.yellow.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityAddTraits(selection == index ? .isSelected : [])
                        }
                    }
                }
                Text("Pinch or double-tap to inspect. Preview is reduced to protect memory.").font(.caption)
            } else { Text("Open Photos to review this video.") }
            Button("Open Photos") {
                if let url = URL(string: "photos-redirect://") { openURL(url) }
            }.frame(minHeight: 44)
        }.padding(12)
    }
}

private struct ZoomableCapture: UIViewRepresentable {
    let data: Data
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
        override func layoutSubviews() {
            super.layoutSubviews()
            if zoomScale == 1 { picture?.frame = bounds; contentSize = bounds.size }
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
            let decoded = await CapturePreviewDecoder.image(data, maxSize: 3000)
            guard !Task.isCancelled else { return }
            image?.image = decoded
        }
        image.contentMode = .scaleAspectFit
        image.isUserInteractionEnabled = true
        image.isAccessibilityElement = true
        image.accessibilityLabel = "Saved photo"
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
    var showsFocusFeedback: Bool
    var focusState: String
    var exposureOnly: Bool
    var showsGrid: Bool
    var hidesGuides: Bool
    var body: some View {
        CameraPreview(engine: engine, onFocus: onFocus, showsFocusFeedback: showsFocusFeedback,
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
