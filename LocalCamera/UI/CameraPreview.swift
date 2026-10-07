import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let engine: CaptureSessionManager
    var onFocus: (CGPoint, Bool) -> Void
    var fillView = false
    var allowsFocus = true

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    final class Coordinator: NSObject {
        let engine: CaptureSessionManager
        var onFocus: (CGPoint, Bool) -> Void
        init(engine: CaptureSessionManager, onFocus: @escaping (CGPoint, Bool) -> Void) { self.engine = engine; self.onFocus = onFocus }
        @objc func tap(_ gesture: UITapGestureRecognizer) { focus(gesture, locked: false) }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { focus(gesture, locked: true) }
        }
        private func focus(_ gesture: UIGestureRecognizer, locked: Bool) {
            guard let view = gesture.view as? PreviewView else { return }
            let point = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else { return }
            onFocus(devicePoint, locked)
            let marker = UIView(frame: CGRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56))
            marker.isUserInteractionEnabled = false
            marker.layer.borderColor = UIColor.systemYellow.cgColor
            marker.layer.borderWidth = 2
            marker.layer.cornerRadius = 6
            view.addSubview(marker)
            UIView.animate(withDuration: 0.3, delay: 1, options: []) { marker.alpha = 0 } completion: { _ in marker.removeFromSuperview() }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, onFocus: onFocus) }
    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.engine.detachPreview(view.previewLayer)
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = fillView ? .resizeAspectFill : .resizeAspect
        if allowsFocus {
            view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
            view.addGestureRecognizer(UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:))))
        }
        engine.attachPreview(view.previewLayer)
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) { context.coordinator.onFocus = onFocus }
}
