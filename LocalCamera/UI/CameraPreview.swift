import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let engine: CaptureSessionManager
    var onFocus: (CGPoint, Bool) -> Void
    var fillView = false
    var allowsFocus = true
    var secondary = false
    var showsFocusFeedback = true
    var focusState = "Auto focus"
    var exposureOnly = false
    var showsGrid = false
    var guideImage: UIImage?

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        let grid = CAShapeLayer()
        let guide = UIImageView()
        private var gridFrame = CGRect.null
        override func layoutSubviews() {
            super.layoutSubviews()
            updateOverlays()
        }
        func updateOverlays() {
            if grid.superlayer == nil { layer.addSublayer(grid) }
            if guide.superview == nil { guide.isUserInteractionEnabled = false; guide.contentMode = .scaleAspectFit; addSubview(guide) }
            let frame = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard PreviewGeometry.isValid(frame), gridFrame != frame else { return }
            gridFrame = frame
            guide.frame = frame
            let path = UIBezierPath()
            for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                let x = frame.minX + frame.width * fraction, y = frame.minY + frame.height * fraction
                path.move(to: CGPoint(x: x, y: frame.minY)); path.addLine(to: CGPoint(x: x, y: frame.maxY))
                path.move(to: CGPoint(x: frame.minX, y: y)); path.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            grid.path = path.cgPath; grid.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
            grid.lineWidth = 0.5
        }
    }
    final class Coordinator: NSObject {
        let engine: CaptureSessionManager
        var showsFocusFeedback = true
        var onFocus: (CGPoint, Bool) -> Void
        var exposureOnly = false
        weak var marker: UILabel?
        init(engine: CaptureSessionManager, onFocus: @escaping (CGPoint, Bool) -> Void) { self.engine = engine; self.onFocus = onFocus }
        @objc func tap(_ gesture: UITapGestureRecognizer) { focus(gesture, locked: false) }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { focus(gesture, locked: true) }
        }
        private func focus(_ gesture: UIGestureRecognizer, locked: Bool) {
            guard let view = gesture.view as? PreviewView else { return }
            let point = gesture.location(in: view)
            let videoRect = view.previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard PreviewGeometry.isValid(videoRect), point.x.isFinite, point.y.isFinite, videoRect.contains(point) else { return }
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else { return }
            guard showsFocusFeedback else { return }
            onFocus(devicePoint, locked)
            marker?.removeFromSuperview()
            let marker = UILabel(frame: CGRect(x: min(max(0, point.x - 46), max(0, view.bounds.width - 92)), y: min(max(0, point.y - 30), max(0, view.bounds.height - 60)), width: 92, height: 60))
            marker.text = exposureOnly ? "Brightness" : locked ? "Lock requested" : "Focus requested"
            marker.font = .preferredFont(forTextStyle: .caption2)
            marker.textAlignment = .center; marker.textColor = .white
            marker.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            marker.isUserInteractionEnabled = false
            marker.layer.borderColor = exposureOnly ? UIColor.white.cgColor : UIColor.systemYellow.cgColor
            marker.layer.borderWidth = 1
            view.addSubview(marker); self.marker = marker
            if !locked || exposureOnly {
                UIView.animate(withDuration: 0.2, delay: 1.5, options: []) { marker.alpha = 0 } completion: { _ in marker.removeFromSuperview() }
            }

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
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
            let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
            tap.require(toFail: hold)
            view.addGestureRecognizer(tap); view.addGestureRecognizer(hold)
        }
        engine.attachPreview(view.previewLayer, secondary: secondary)
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onFocus = onFocus
        context.coordinator.showsFocusFeedback = showsFocusFeedback
        context.coordinator.exposureOnly = exposureOnly
        if focusState == "Focus locked" { context.coordinator.marker?.text = "Focus locked" }
        else if focusState == "Auto focus", context.coordinator.marker?.text == "Focus locked" { context.coordinator.marker?.removeFromSuperview() }
        if view.guide.image !== guideImage { view.guide.image = guideImage }
        view.grid.isHidden = !showsGrid
        view.updateOverlays()
    }
}

/// Reject transient invalid camera geometry before assigning CALayer/UIView frames.
enum PreviewGeometry {
    static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty &&
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
        rect.width > 0 && rect.height > 0
    }
}
