import SwiftUI
import AVFoundation

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
                CameraPreview(session: model.engine.session, mirrored: model.selectedLens?.isFront ?? false)
                    .ignoresSafeArea()
                    .accessibilityLabel("Camera viewfinder")
                if showsGrid && model.camera.running {
                    compositionGrid.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
                }
            }

            VStack(spacing: 12) {
                captureHUD
                ZStack(alignment: .trailing) {
                    Color.clear
                    if model.permission != .authorized || model.camera.message != nil {
                        cameraNotice.padding(.horizontal, 24).frame(maxWidth: .infinity)
                    } else if model.selectedLens?.isFront == false {
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
        .confirmationDialog("Discard the unsaved photo?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard photo", role: .destructive, action: model.discard)
        }
    }

    private var captureHUD: some View {
        Button { showsCaptureInfo = true } label: {
            VStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                HStack(spacing: 10) {
                    Text(model.mode.rawValue.uppercased()).fontWeight(.semibold)
                    Divider().frame(height: 16)
                    Text(model.selectedLens?.name ?? "Camera")
                    Divider().frame(height: 16)
                    Text(model.mode == .photo ? model.camera.resolution : "Preview only")
                        .frame(maxWidth: .infinity)
                }
                .font(.caption)
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(.regularMaterial, in: Capsule())
            }
            .padding(.horizontal, 14).padding(.top, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture information")
        .accessibilityValue("\(model.mode.rawValue), \(model.selectedLens?.name ?? "Camera"), \(model.mode == .photo ? model.camera.resolution : "Preview only")")
        .accessibilityHint("Opens current capture details")
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
                    Button { model.mode = mode } label: {
                        Text(mode.rawValue.uppercased())
                            .font(.caption.weight(.semibold))
                            .frame(minWidth: 80, minHeight: 44)
                            .background(model.mode == mode ? selection : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                }
            }
            .disabled(model.busy || model.pendingPhoto != nil)

            if model.mode == .video {
                Text("Preview only · video recording is not available yet")
                    .font(.caption).multilineTextAlignment(.center)
            }
            if let message = model.message {
                Text(message).font(.caption).multilineTextAlignment(.center)

            }
            if model.pendingPhoto != nil && !model.busy {
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

                Button(action: model.capture) {
                    ZStack {
                        Circle().fill(.white)
                        Circle().strokeBorder(ink.opacity(0.65), lineWidth: 2).padding(5)
                        if model.busy { ProgressView().tint(ink) }
                    }
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                }
                .accessibilityLabel("Take photo")
                .disabled(!model.canCapture)
                .opacity(model.canCapture ? 1 : 0.4)

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
                Section("Current capture") {
                    LabeledContent("Mode", value: model.mode.rawValue)
                    LabeledContent("Lens", value: model.selectedLens?.name ?? "Unavailable")
                    if model.mode == .photo {
                        LabeledContent("Photo dimensions", value: model.camera.resolution)
                    } else {
                        Text("Video is preview only. Recording is not available yet.")
                    }
                }
                Section("Viewfinder") {
                    Toggle("Composition grid", isOn: $showsGrid)
                    Text("The preview fills the screen and may crop the edges. Saved photos use the camera’s full capture dimensions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Storage") {
                    Text("Photos are saved on this iPhone. No account or cloud processing is used.")
                }
            }
            .navigationTitle("Capture Info")
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
