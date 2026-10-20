import AVFoundation
import SwiftUI
import UIKit
import ImageIO

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
    var onImageFrame: ((CGRect) -> Void)?
    var controlStripHeight: CGFloat = 0

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        let grid = CAShapeLayer()
        let guide = UIImageView()
        private var gridFrame = CGRect.null
        private var visibleImageFrame = CGRect.zero
        var imageFrameChanged: ((CGRect) -> Void)?
        var orientationChanged: ((AVCaptureVideoOrientation) -> Void)?
        private var lastOrientation: UIInterfaceOrientation = .unknown
        override func layoutSubviews() {
            super.layoutSubviews()
            if let orientation = window?.windowScene?.interfaceOrientation,
               orientation != .unknown, orientation != lastOrientation {
                lastOrientation = orientation
                orientationChanged?(CameraOrientation.capture(orientation))
            }
            updateOverlays()
        }
        private func publishImageFrame(_ frame: CGRect) {
            let valid = PreviewGeometry.isValid(frame) ? frame : .zero
            guard visibleImageFrame != valid else { return }
            visibleImageFrame = valid
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.imageFrameChanged?(self.visibleImageFrame)
            }
        }
        func updateOverlays() {
            if grid.superlayer == nil { layer.addSublayer(grid) }
            if guide.superview == nil { guide.isUserInteractionEnabled = false; guide.contentMode = .scaleAspectFit; addSubview(guide) }
            let frame = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard PreviewGeometry.isValid(frame) else {
                grid.path = nil; guide.frame = .zero; gridFrame = .null
                publishImageFrame(.zero)
                return
            }
            publishImageFrame(frame.intersection(bounds))
            guard gridFrame != frame else { return }
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
        var controlStripHeight: CGFloat = 0
        weak var marker: UILabel?
        init(engine: CaptureSessionManager, onFocus: @escaping (CGPoint, Bool) -> Void) { self.engine = engine; self.onFocus = onFocus }
        @objc func tap(_ gesture: UITapGestureRecognizer) { focus(gesture, locked: false) }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { focus(gesture, locked: true) }
        }
        private func focus(_ gesture: UIGestureRecognizer, locked: Bool) {
            guard let view = gesture.view as? PreviewView else { return }
            let point = gesture.location(in: view)
            // Overlay controls own this strip, including gaps and disabled buttons.
            guard PreviewGeometry.acceptsFocus(at: point, bounds: view.bounds, controlStripHeight: controlStripHeight) else { return }
            let videoRect = view.previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard PreviewGeometry.isValid(videoRect), point.x.isFinite, point.y.isFinite, videoRect.contains(point) else { return }
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else { return }
            guard showsFocusFeedback else { return }
            onFocus(devicePoint, locked)
            marker?.removeFromSuperview()
            let visibleFrame = videoRect.intersection(view.bounds)
            guard let markerFrame = PreviewGeometry.focusRect(at: point, in: visibleFrame) else { return }
            let marker = UILabel(frame: markerFrame)
            marker.text = exposureOnly ? "EV" : nil
            marker.font = .preferredFont(forTextStyle: .caption2)
            marker.textAlignment = .center; marker.textColor = .white
            marker.backgroundColor = .clear
            marker.isUserInteractionEnabled = false
            marker.layer.borderColor = exposureOnly ? UIColor.white.cgColor : UIColor(CameraAppearance.selection).cgColor
            marker.layer.borderWidth = 1
            view.addSubview(marker); self.marker = marker
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak marker] in
                guard let marker, marker.text != "Locked" else { return }
                UIView.animate(withDuration: 0.2) { marker.alpha = 0 } completion: { _ in marker.removeFromSuperview() }
            }

        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, onFocus: onFocus) }
    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.engine.detachPreview(view.previewLayer)
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.orientationChanged = { [weak engine, weak view] orientation in
            engine?.setInterfaceOrientation(orientation) { view?.updateOverlays() }
        }
        view.clipsToBounds = true
        view.imageFrameChanged = onImageFrame
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
        let gravity: AVLayerVideoGravity = fillView ? .resizeAspectFill : .resizeAspect
        if view.previewLayer.videoGravity != gravity { view.previewLayer.videoGravity = gravity }
        context.coordinator.onFocus = onFocus
        view.imageFrameChanged = onImageFrame
        context.coordinator.showsFocusFeedback = showsFocusFeedback
        context.coordinator.exposureOnly = exposureOnly
        context.coordinator.controlStripHeight = controlStripHeight
        context.coordinator.marker?.isHidden = !showsFocusFeedback
        if focusState == "Focus locked" { context.coordinator.marker?.text = "Locked" }
        else if focusState == "Auto focus", context.coordinator.marker?.text == "Locked" { context.coordinator.marker?.removeFromSuperview() }
        if view.guide.image !== guideImage { view.guide.image = guideImage }
        view.grid.isHidden = !showsGrid
        view.updateOverlays()
    }
}

/// Reject transient invalid camera geometry before assigning CALayer/UIView frames.
enum PreviewGeometry {
    static func acceptsFocus(at point: CGPoint, bounds: CGRect, controlStripHeight: CGFloat) -> Bool {
        guard isValid(bounds), point.x.isFinite, point.y.isFinite,
              controlStripHeight.isFinite, bounds.contains(point) else { return false }
        return point.y < bounds.maxY - max(0, controlStripHeight)
    }

    static func panelRect(image: CGRect, bounds: CGRect, preferredHeight: CGFloat, sidePanel: Bool = false) -> CGRect {
        guard isValid(bounds) else { return .zero }
        let intersection = image.intersection(bounds)
        let visible = isValid(intersection) ? intersection : bounds
        let inset = visible.insetBy(dx: min(10, visible.width / 4), dy: min(10, visible.height / 4))
        let height = min(inset.height, max(0, preferredHeight))
        let width = sidePanel ? min(340, inset.width * 0.48) : inset.width
        return CGRect(x: sidePanel ? inset.maxX - width : inset.minX, y: inset.maxY - height, width: width, height: height)
    }

    static func focusRect(at point: CGPoint, in frame: CGRect) -> CGRect? {
        guard isValid(frame), point.x.isFinite, point.y.isFinite, frame.contains(point) else { return nil }
        let width = min(64, frame.width), height = min(64, frame.height)
        return CGRect(x: min(max(frame.minX, point.x - width / 2), frame.maxX - width),
                      y: min(max(frame.minY, point.y - height / 2), frame.maxY - height),
                      width: width, height: height)
    }

    static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty &&
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
        rect.width > 0 && rect.height > 0
    }
}

enum CameraOrientation {
    static func capture(_ orientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    static func vision(_ orientation: AVCaptureVideoOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .landscapeRight: return .up
        case .landscapeLeft: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }

    static func sensorPoint(x: CGFloat, y: CGFloat, orientation: AVCaptureVideoOrientation) -> CGPoint {
        switch orientation {
        case .landscapeRight: return CGPoint(x: x, y: 1 - y)
        case .landscapeLeft: return CGPoint(x: 1 - x, y: y)
        case .portraitUpsideDown: return CGPoint(x: y, y: x)
        default: return CGPoint(x: 1 - y, y: 1 - x)
        }
    }
}
