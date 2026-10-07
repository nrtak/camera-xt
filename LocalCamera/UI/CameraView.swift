import SwiftUI
import AVFoundation
import PhotosUI
import CoreImage
import ImageIO

struct CameraView: View {
    @StateObject private var model = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var confirmDiscard = false
    @State private var showsGrid = true
    @State private var showsCaptureInfo = false

    private let ink = Color(red: 0.10, green: 0.14, blue: 0.22)
    private let selection = Color(red: 1, green: 0.94, blue: 0.36)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.permission == .authorized {
                CameraPreview(engine: model.engine, onFocus: model.focus)
                    .ignoresSafeArea()
                    .accessibilityLabel("Camera viewfinder")
                if showsGrid && model.camera.running {
                    compositionGrid.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
                }
            }

            VStack(spacing: 12) {
                captureHUD
                ZStack(alignment: .trailing) {
                    Color.clear.allowsHitTesting(false)
                    if model.permission != .authorized || model.camera.message != nil {
                        cameraNotice.padding(.horizontal, 24).frame(maxWidth: .infinity)
                    } else if model.selectedLens?.isFront == false && !model.camera.dualEnabled {
                        lensSelector.padding(.trailing, 14)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { captureControls }
        .foregroundStyle(ink)
        .tint(ink)
        .preferredColorScheme(.light)
        .task { model.setActive(scenePhase == .active) }
        .onChange(of: scenePhase) { model.setActive($0 == .active) }
        .sheet(isPresented: $showsCaptureInfo) { captureInfo }
        .sheet(isPresented: $model.reviewingBurst) { BurstReview(model: model).interactiveDismissDisabled() }
        .confirmationDialog("Discard the unsaved capture?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard capture", role: .destructive, action: model.discard)
        }
    }

    private var captureHUD: some View {
        Button { showsCaptureInfo = true } label: {
            VStack(spacing: 7) {
                Label("Tools", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                HStack(spacing: 10) {
                    Text(model.mode.rawValue.uppercased()).fontWeight(.semibold)
                    Divider().frame(height: 16)
                    Text(model.camera.dualEnabled ? "Main + Ultra Wide" : model.selectedLens?.name ?? "Camera")
                    Divider().frame(height: 16)
                    Text(model.mode == .photo ? model.camera.resolution : model.camera.videoLabel)
                        .frame(maxWidth: .infinity)
                }
                .font(.caption)
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(.regularMaterial, in: Capsule())
                Text([model.camera.exposureLabel, model.camera.focusLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(.horizontal, 14).padding(.top, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera Tools and capture information")
        .accessibilityValue("\(model.mode.rawValue), \(model.selectedLens?.name ?? "Camera"), \(model.mode == .photo ? model.camera.resolution : model.camera.videoLabel)")
        .accessibilityHint("Opens camera features, controls, and current capture details")
        .disabled(model.busy || model.hasPendingCapture)
    }

    private var lensSelector: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(model.camera.lenses.filter { !$0.isFront }) { lens in
                    Button { model.select(lens) } label: {
                        Text(lens.name)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .frame(width: 64).frame(minHeight: 44)
                            .background(lens.id == model.camera.selectedID ? selection : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(lens.name) camera")
                    .accessibilityAddTraits(lens.id == model.camera.selectedID ? .isSelected : [])
                }
            }
            .padding(5)
        }
        .frame(width: 74)
        .frame(maxHeight: 170)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 37))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var captureControls: some View {
        VStack(spacing: 12) {
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
            .disabled(model.busy || model.configuring || model.hasPendingCapture || model.camera.dualEnabled || model.camera.recording)

            if model.mode == .photo && model.camera.dualAvailable {
                Toggle("Dual Shot · Main + Ultra Wide", isOn: Binding(get: { model.camera.dualEnabled }, set: model.setDualEnabled))
                    .font(.caption).tint(.orange)
                    .disabled(model.busy || model.configuring || model.hasPendingCapture)
            }
            if model.camera.focusLocked {
                Button("AE/AF locked · Tap to reset") { model.focus(at: CGPoint(x: 0.5, y: 0.5), locked: false) }
                    .font(.caption)
            }
            if model.mode == .photo && !model.camera.dualEnabled {
                Toggle("3-shot burst · Best Shot review", isOn: $model.burstEnabled)
                    .font(.caption).tint(.orange)
                    .disabled(model.busy || model.configuring || model.hasPendingCapture)
            }
            if model.mode == .video {
                Text(model.camera.recording ? "● Recording" : model.camera.videoLabel)
                    .font(.caption).multilineTextAlignment(.center)
            }
            if model.countdown > 0 { Text("\(model.countdown)").font(.largeTitle.monospacedDigit()) }
            if let message = model.message {
                Text(message).font(.caption).multilineTextAlignment(.center)

            }
            if model.hasPendingCapture && !model.busy {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { saveRecovery }
                    VStack(spacing: 12) { saveRecovery }
                }
                .font(.callout)
            }
            HStack {
                Button { showsGrid.toggle() } label: {
                    Image(systemName: "grid")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                        .background(showsGrid ? selection.opacity(0.7) : Color.white.opacity(0.45), in: Circle())
                }
                .accessibilityLabel("Composition grid")
                .accessibilityValue(showsGrid ? "On" : "Off")
                .frame(maxWidth: .infinity)

                Button(action: model.shutter) {
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
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.45), in: Circle())
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
                .fill(.regularMaterial).ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder private var saveRecovery: some View {
        Button("Retry save") { Task { await model.retrySave() } }
        Button("Settings", action: openSettings)
        Button("Discard", role: .destructive) { confirmDiscard = true }
    }

    private var captureInfo: some View {
        NavigationStack {
            Form {
                Section("Camera Tools") {
                    NavigationLink {
                        PhotoRescueView()
                            .onAppear { model.setPhotoEditorActive(true) }
                            .onDisappear { model.setPhotoEditorActive(false) }
                    } label: {
                        Label("Photo Rescue", systemImage: "wand.and.stars")
                    }
                    .disabled(model.busy || model.configuring || model.camera.recording || model.hasPendingCapture)
                    Button(action: model.nightPreset) {
                        Label("Night · steady scene", systemImage: "moon.stars")
                    }
                    .disabled(model.mode != .photo || !model.camera.customExposureAvailable || model.camera.dualEnabled || model.busy || model.configuring || model.hasPendingCapture)
                    Text("Night uses a 3-second timer and three separate 1/4-second exposures. Support the phone and review the originals. This experimental preset does not merge frames; moving subjects may blur.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(action: model.actionPreset) {
                        Label("Action · 3-shot burst", systemImage: "figure.run")
                    }
                    .disabled(model.mode != .photo || !model.camera.customExposureAvailable || model.camera.dualEnabled || model.busy || model.configuring || model.hasPendingCapture)
                    Toggle("Embed depth in photos", isOn: Binding(get: { model.camera.depthEnabled }, set: model.engine.setDepthEnabled))
                        .disabled(!model.camera.depthAvailable || model.busy || model.configuring || model.hasPendingCapture)
                    Text(model.camera.depthAvailable ? "Saves a depth map alongside the photo when the camera provides one. No artificial blur is applied." : "Select the Depth rear camera or Front Depth camera in Photo mode to capture depth where supported. Unavailable with Dual Shot or video.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Eye-priority focus · experimental", isOn: Binding(get: { model.camera.eyeFocusEnabled }, set: model.setEyeFocus))
                        .disabled(!model.camera.eyeFocusAvailable || model.busy || model.configuring || model.hasPendingCapture)
                    Text("In rear Photo mode, focuses near an eye of the largest visible face. Tap focus, manual focus, or changing cameras turns it off. Processing pauses when the phone gets hot.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Current capture") {
                    LabeledContent("Mode", value: model.mode.rawValue)
                    LabeledContent("Lens", value: model.selectedLens?.name ?? "Unavailable")
                    if model.mode == .photo {
                        LabeledContent("Photo dimensions", value: model.camera.resolution)
                    } else {
                        LabeledContent("Video format", value: model.camera.videoLabel)
                        LabeledContent("Stabilization", value: model.camera.stabilized ? "Auto" : "Off")
                    }
                }
                Section("Capture settings") {
                    if model.mode == .photo {
                        Picker("Timer", selection: $model.timerSeconds) {
                            Text("Off").tag(0); Text("3 seconds").tag(3); Text("10 seconds").tag(10)
                        }
                    } else {
                        Picker("Resolution", selection: $model.videoWidth) {
                            Text("1080p").tag(Int32(1920)); Text("4K").tag(Int32(3840))
                        }
                        Picker("Frame rate", selection: $model.videoFPS) {
                            Text("24 fps").tag(Int32(24)); Text("30 fps").tag(Int32(30)); Text("60 fps").tag(Int32(60))
                        }
                        Toggle("Video stabilization", isOn: $model.stabilization)
                        Button("Apply video settings", action: model.applyVideoSettings)
                    }
                }
                .disabled(model.busy || model.configuring || model.camera.recording || model.hasPendingCapture)
                ManualCameraControls(model: model)
                    .disabled(model.busy || model.configuring || model.hasPendingCapture || model.camera.dualEnabled || model.camera.recording)
                Section("Focus and exposure") {
                    Text("Tap the viewfinder to focus and meter. Hold to lock focus and exposure after adjustment.")
                    HStack {
                        Text("Exposure")
                        Slider(value: $model.exposureBias, in: -2...2, step: 0.1)
                            .accessibilityLabel("Exposure compensation")
                        Text(String(format: "%+.1f EV", model.exposureBias)).monospacedDigit()
                    }
                    .disabled(model.busy || model.configuring)
                    Button("Reset camera controls", action: model.resetControls)
                }
                if model.camera.dualAvailable {
                    Section("Dual Shot") {
                        Text("One shutter press saves separate main and ultra-wide photos. Both cameras stay active while enabled. Resolution and processing can differ from a single-camera photo; exposure timing can differ between lenses.")
                    }
                }
                Section("Viewfinder") {
                    Toggle("Composition grid", isOn: $showsGrid)
                    Text("The viewfinder preserves the camera aspect ratio. Saved photos use the camera’s full capture dimensions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Design") {
                    NavigationLink("Design Preview") { CameraDesignGallery() }
                    Text("Browse the original mockups. Preview screens do not change camera settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Storage") {
                    Text("Photos are saved on this iPhone. No account or cloud processing is used.")
                }
            }
            .navigationTitle("Camera Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsCaptureInfo = false } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

// The original reference is bundled locally so design review works offline.
// These images are illustrations, never representations of active camera settings.
private struct PhotoRescueView: View {
    @StateObject private var model = PhotoRescueModel()
    @State private var selection: PhotosPickerItem?
    @State private var showsOriginal = false
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Improve light, color, and noise on this iPhone. Preview the change before saving a separate copy.")
                PhotosPicker(selection: $selection, matching: .images) {
                    Label("Choose a photo", systemImage: "photo")
                }
                .buttonStyle(.borderedProminent).disabled(model.busy)
                if let result = model.result {
                    Image(uiImage: showsOriginal ? result.before : result.after)
                        .resizable().scaledToFit().frame(maxHeight: 400)
                        .accessibilityLabel(showsOriginal ? "Original photo" : "Adjusted preview")
                    Toggle("Show original", isOn: $showsOriginal)
                    HStack {
                        Text("Strength")
                        Slider(value: $model.strength, in: 0...1, step: 0.1)
                            .accessibilityLabel("Adjustment strength")
                    }
                    .disabled(model.busy)
                    Button("Apply strength") { Task { await model.apply() } }
                        .disabled(model.busy)
                    Button(model.saved ? "Copy saved" : "Save preview as a copy") { Task { await model.save() } }
                        .buttonStyle(.borderedProminent).disabled(model.busy || model.saved)
                    Text("\(result.photo.dimensions.width) × \(result.photo.dimensions.height) · JPEG")
                        .font(.caption)
                }
                if model.busy { ProgressView() }
                if let message = model.message { Text(message).font(.callout) }
                Text("Exports a standard-color JPEG up to 12 MP without location metadata. Original RAW, HDR, Live Photo, and depth data stay in the original. This tool makes tonal adjustments; it cannot reconstruct missed focus or motion detail.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
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
    private let shutters = [8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4, 2, 1]
    var body: some View {
        Section("Manual controls") {
            Toggle("Automatic exposure", isOn: $model.controls.automaticExposure)
                .disabled(!model.camera.customExposureAvailable)
            if !model.controls.automaticExposure {
                LabeledContent("ISO", value: "\(Int(model.controls.iso))")
                Slider(value: $model.controls.iso, in: model.camera.minISO...max(model.camera.minISO + 1, model.camera.maxISO), step: 1)
                    .accessibilityLabel("ISO")
                Picker("Shutter", selection: $model.controls.shutterSeconds) {
                    ForEach(shutters, id: \.self) { denominator in
                        Text(denominator == 1 ? "1 second" : "1/\(denominator) s").tag(1.0 / Double(denominator))
                    }
                }
                Text("The live HUD shows the actual exposure. Each lens and video frame rate limits the available shutter duration.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("Automatic white balance", isOn: $model.controls.automaticWhiteBalance)
                .disabled(!model.camera.whiteBalanceAvailable)
            if !model.controls.automaticWhiteBalance {
                LabeledContent("Temperature", value: "\(Int(model.controls.temperature)) K")
                Slider(value: $model.controls.temperature, in: 2500...10000, step: 100)
                    .accessibilityLabel("White balance temperature")
                LabeledContent("Tint", value: "\(Int(model.controls.tint))")
                Slider(value: $model.controls.tint, in: -100...100, step: 1).accessibilityLabel("White balance tint")
            }
            Toggle("Automatic focus", isOn: $model.controls.automaticFocus)
                .disabled(!model.camera.manualFocusAvailable)
            if model.controls.automaticFocus {
                Toggle("Prefer faces", isOn: $model.controls.facePriority)
            } else {
                HStack {
                    Text("Near")
                    Slider(value: $model.controls.lensPosition, in: 0...1).accessibilityLabel("Focus distance")
                    Text("Far")
                }
            }
            if model.mode == .photo && model.camera.flashAvailable {
                Picker("Flash", selection: $model.controls.flash) {
                    Text("Off").tag(AVCaptureDevice.FlashMode.off)
                    Text("Auto").tag(AVCaptureDevice.FlashMode.auto)
                    Text("On").tag(AVCaptureDevice.FlashMode.on)
                }
            }
            Button("Apply manual controls", action: model.applyControls)
            Button("Reset to automatic", action: model.resetControls)
            if model.mode == .photo && model.camera.customExposureAvailable {
                Button("Action preset · 1/500 s burst", action: model.actionPreset)
                Text("Freezes faster motion with a short shutter and three separate frames. Needs adequate light; ISO is estimated once from the current exposure.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BurstReview: View {
    @ObservedObject var model: CameraViewModel
    @State private var confirmDiscard = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if model.burstPreviews.indices.contains(model.selectedBurstIndex) {
                    Image(uiImage: model.burstPreviews[model.selectedBurstIndex])
                        .resizable().scaledToFit().frame(maxHeight: .infinity)
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Discard", role: .destructive) { confirmDiscard = true } } }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Original design mockups")
                    .font(.title2.bold())
                Text("Review the visual direction alongside the working app. These are static design previews; values and controls shown in the images are illustrative.")
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 20) {
                    ForEach(CameraDesignScreen.all) { screen in
                        NavigationLink {
                            CameraDesignDetail(initialSelection: screen.id)
                        } label: {
                            VStack(spacing: 8) {
                                CameraDesignImage(screen: screen)
                                    .frame(height: 230)
                                Text(screen.title).font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(screen.title) design preview")
                    }
                }
                NavigationLink("View complete reference sheet") {
                    ScrollView {
                        Image("DesignReference")
                            .resizable().scaledToFit()
                            .accessibilityLabel("Original Camera XT mockup sheet with ten proposed screens")
                        Text("Design reference only · not a screenshot of the current app")
                            .font(.footnote).padding()
                    }
                    .navigationTitle("Original Mockups")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Design Preview")
        .navigationBarTitleDisplayMode(.inline)
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
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(CameraDesignScreen.all[selection].title)
        .navigationBarTitleDisplayMode(.inline)
    }
}