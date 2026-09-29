import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var model = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("\(model.mode.rawValue) · \(model.selectedLens?.name ?? "Camera")")
                    .font(.headline)
                Text(model.mode == .photo ? model.camera.resolution : "Preview only · recording not available")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top)

            ZStack {
                Color.black
                if model.permission == .authorized {
                    CameraPreview(session: model.engine.session, mirrored: model.selectedLens?.isFront ?? false)
                    if let message = model.camera.message {
                        VStack(spacing: 16) {
                            Text(message)
                            Button("Retry camera") { model.engine.start() }
                                .disabled(model.busy)
                        }
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding()
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "camera").font(.largeTitle)
                        Text("Camera access lets you preview and take photos on this iPhone.")
                        if model.permission == .notDetermined {
                            Button("Enable camera") { Task { await model.requestCamera() } }
                        } else if model.permission == .restricted {
                            Text("Camera access is restricted on this device.")
                        } else {
                            Button("Open Settings", action: openSettings)
                        }
                    }
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .accessibilityLabel("Camera viewfinder")

            if model.selectedLens?.isFront == false {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(model.camera.lenses.filter { !$0.isFront }) { lens in
                            Button(lens.name) { model.select(lens) }
                                .buttonStyle(.bordered)
                                .tint(lens.id == model.camera.selectedID ? .blue : .secondary)
                                .accessibilityAddTraits(lens.id == model.camera.selectedID ? .isSelected : [])
                        }
                    }
                }.disabled(!model.canSwitch)
            }

            Picker("Capture mode", selection: $model.mode) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).disabled(model.busy || model.pendingPhoto != nil)

            if let message = model.message {
                Text(message).font(.caption).multilineTextAlignment(.center)
            }
            if model.pendingPhoto != nil && !model.busy {
                HStack {
                    Button("Retry save") { Task { await model.retrySave() } }
                    Button("Settings", action: openSettings)
                    Button("Discard", role: .destructive) { confirmDiscard = true }
                }.font(.callout)
            }
            HStack {
                Text("On device").font(.caption).frame(maxWidth: .infinity)
                Button(action: model.capture) {
                    ZStack {
                        Circle().strokeBorder(.blue, lineWidth: 4).frame(width: 72, height: 72)
                        Circle().fill(.blue).frame(width: 58, height: 58)
                        if model.busy { ProgressView().tint(.white) }
                    }
                }
                .accessibilityLabel("Take photo")
                .disabled(!model.canCapture).opacity(model.canCapture ? 1 : 0.4)
                Button(action: model.flip) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2)
                }
                .frame(maxWidth: .infinity).accessibilityLabel("Switch front and rear camera")
                .disabled(!model.canSwitch || !model.camera.lenses.contains { $0.isFront != model.selectedLens?.isFront })
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal)
        .background(Color(uiColor: .systemGroupedBackground))
        .task { model.setActive(scenePhase == .active) }
        .onChange(of: scenePhase) { model.setActive($0 == .active) }
        .confirmationDialog("Discard the unsaved photo?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard photo", role: .destructive, action: model.discard)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
