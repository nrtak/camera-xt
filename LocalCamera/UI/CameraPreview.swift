import AVFoundation
import SwiftUI
import UIKit
import ImageIO

struct CameraPreview: UIViewRepresentable {
    let engine: CaptureSessionManager
    var onFocus: (CGPoint, Bool) -> Void
    var fillView = false
    var alignsImageLeading = false
    var allowsFocus = true
    var secondary = false
    var showsFocusFeedback = true
    var focusState = "Auto focus"
    var exposureOnly = false
    var showsGrid = false
    var guideImage: UIImage?
    var onImageFrame: ((CGRect) -> Void)?
    var controlStripHeight: CGFloat = 0
    var topControlStripHeight: CGFloat = 0
    var focusExclusionRects: [CGRect] = []

    final class PreviewView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var alignsImageLeading = false
        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        let grid = CAShapeLayer()
        let guide = UIImageView()
        private var gridFrame = CGRect.null
        private var visibleImageFrame = CGRect.zero
        weak var focusMarker: UILabel?
        private var markerBounds = CGRect.null
        var imageFrameChanged: ((CGRect) -> Void)?
        var orientationChanged: ((AVCaptureVideoOrientation) -> Void)?
        private var lastOrientation: UIInterfaceOrientation = .unknown
        override func layoutSubviews() {
            super.layoutSubviews()
            if markerBounds != bounds {
                clearFocusMarker()
                markerBounds = bounds
            }
            if let orientation = window?.windowScene?.interfaceOrientation,
               orientation != .unknown, orientation != lastOrientation {
                clearFocusMarker()
                lastOrientation = orientation
                orientationChanged?(CameraOrientation.capture(orientation))
            }
            updateOverlays()
        }
        // A visual marker belongs to the old preview geometry, not the camera lock.
        func clearFocusMarker() {
            focusMarker?.removeFromSuperview()
            focusMarker = nil
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
            // Move only the letterbox margin. Keep the layer's size and aspect-fit gravity.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let localBounds = CGRect(origin: .zero, size: bounds.size)
            if previewLayer.bounds != localBounds { previewLayer.bounds = localBounds }
            let fitted = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            let offset = alignsImageLeading ? PreviewGeometry.leadingOffset(image: fitted, bounds: localBounds) : 0
            let layerFrame = bounds.offsetBy(dx: offset, dy: 0)
            if previewLayer.frame != layerFrame { previewLayer.frame = layerFrame }
            CATransaction.commit()
            if grid.superlayer == nil { layer.addSublayer(grid) }
            if guide.superview == nil { guide.isUserInteractionEnabled = false; guide.contentMode = .scaleAspectFit; addSubview(guide) }
            let frame = previewLayer.convert(previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)), to: layer)
            guard PreviewGeometry.isValid(frame) else {
                clearFocusMarker()
                grid.path = nil; guide.frame = .zero; gridFrame = .null
                publishImageFrame(.zero)
                return
            }
            publishImageFrame(frame.intersection(bounds))
            guard gridFrame != frame else { return }
            clearFocusMarker()
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
        var allowsFocus = true
        var showsFocusFeedback = true
        var onFocus: (CGPoint, Bool) -> Void
        var exposureOnly = false
        var controlStripHeight: CGFloat = 0
        var topControlStripHeight: CGFloat = 0
        var focusExclusionRects: [CGRect] = []
        weak var marker: UILabel?
        init(engine: CaptureSessionManager, onFocus: @escaping (CGPoint, Bool) -> Void) { self.engine = engine; self.onFocus = onFocus }
        @objc func tap(_ gesture: UITapGestureRecognizer) { focus(gesture, locked: false) }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { focus(gesture, locked: true) }
        }
        @discardableResult
        func requestFocus(at devicePoint: CGPoint, locked: Bool) -> Bool {
            guard allowsFocus, (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else { return false }
            onFocus(devicePoint, locked)
            return true
        }
        private func focus(_ gesture: UIGestureRecognizer, locked: Bool) {
            guard allowsFocus, let view = gesture.view as? PreviewView else { return }
            let point = gesture.location(in: view)
            // Overlay controls own this strip, including gaps and disabled buttons.
            guard PreviewGeometry.acceptsFocus(at: point, bounds: view.bounds, controlStripHeight: controlStripHeight,
                topControlStripHeight: topControlStripHeight, exclusionRects: focusExclusionRects) else { return }
            let videoRect = view.previewLayer.convert(view.previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)), to: view.layer)
            guard PreviewGeometry.isValid(videoRect), point.x.isFinite, point.y.isFinite, videoRect.contains(point) else { return }
            let layerPoint = view.previewLayer.convert(point, from: view.layer)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            guard requestFocus(at: devicePoint, locked: locked) else { return }
            view.clearFocusMarker()
            guard showsFocusFeedback else { return }
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
            view.addSubview(marker); self.marker = marker; view.focusMarker = marker
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak marker] in
                guard let marker, marker.text != "Locked" else { return }
                UIView.animate(withDuration: 0.2) { marker.alpha = 0 } completion: { _ in marker.removeFromSuperview() }
            }

        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, onFocus: onFocus) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PreviewView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        // The preview layer has no intrinsic content size. Always use the space
        // offered by SwiftUI; resizeAspect preserves the complete sensor frame.
        return CGSize(width: width, height: height)
    }
    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.engine.detachPreview(view.previewLayer)
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero)
        view.orientationChanged = { [weak engine, weak view] orientation in
            engine?.setInterfaceOrientation(orientation) { view?.updateOverlays() }
        }
        view.clipsToBounds = true
        view.alignsImageLeading = alignsImageLeading
        view.imageFrameChanged = onImageFrame
        view.previewLayer.videoGravity = fillView ? .resizeAspectFill : .resizeAspect
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap); view.addGestureRecognizer(hold)
        engine.attachPreview(view.previewLayer, secondary: secondary)
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        view.alignsImageLeading = alignsImageLeading
        let gravity: AVLayerVideoGravity = fillView ? .resizeAspectFill : .resizeAspect
        if view.previewLayer.videoGravity != gravity { view.previewLayer.videoGravity = gravity }
        context.coordinator.onFocus = onFocus
        context.coordinator.allowsFocus = allowsFocus
        view.gestureRecognizers?.forEach { $0.isEnabled = allowsFocus }
        view.imageFrameChanged = onImageFrame
        context.coordinator.showsFocusFeedback = showsFocusFeedback
        context.coordinator.exposureOnly = exposureOnly
        context.coordinator.controlStripHeight = controlStripHeight
        context.coordinator.topControlStripHeight = topControlStripHeight
        context.coordinator.focusExclusionRects = focusExclusionRects
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
    static func pictureInPictureFrame(bounds: CGRect, corner: Int, topInset: CGFloat, bottomInset: CGFloat) -> CGRect {
        guard isValid(bounds), topInset.isFinite, bottomInset.isFinite, corner >= 0, corner < 4 else { return .zero }
        let top = min(bounds.maxY, bounds.minY + max(8, topInset))
        let bottom = max(top, bounds.maxY - max(8, bottomInset))
        let width = min(bounds.width * 0.38, max(0, bounds.width - 16))
        let height = min(bounds.height * 0.32, bottom - top)
        guard width > 0, height > 0 else { return .zero }
        return CGRect(x: corner % 2 == 0 ? bounds.minX + 8 : bounds.maxX - width - 8,
                      y: corner < 2 ? top : bottom - height, width: width, height: height)
    }

    /// Keep the main camera's rail clear of the inset camera, in either right corner.
    static func avoidingOverlay(rail: CGRect, overlay: CGRect) -> CGRect {
        guard isValid(rail), isValid(overlay), rail.intersects(overlay) else { return rail }
        let above = max(0, min(rail.maxY, overlay.minY - 6) - rail.minY)
        let belowTop = max(rail.minY, overlay.maxY + 6)
        let below = max(0, rail.maxY - belowTop)
        let height = max(above, below)
        guard height >= 44 else { return .zero }
        return CGRect(x: rail.minX, y: above >= below ? rail.minY : belowTop, width: rail.width, height: height)
    }

    /// Consolidate side letterboxing without scaling or clipping the camera image.
    static func leadingOffset(image: CGRect, bounds: CGRect) -> CGFloat {
        guard isValid(image), isValid(bounds), bounds.contains(image) else { return 0 }
        return bounds.minX - image.minX
    }

    static func sideRailFrame(bounds: CGRect, topInset: CGFloat, bottomInset: CGFloat) -> CGRect {
        guard isValid(bounds), topInset.isFinite, bottomInset.isFinite else { return .zero }
        let top = min(bounds.maxY, bounds.minY + max(0, topInset) + 6)
        let bottom = max(top, bounds.maxY - max(0, bottomInset) - 6)
        let width = min(52, max(0, bounds.width - 12))
        guard bottom > top, width > 0 else { return .zero }
        return CGRect(x: bounds.maxX - width - 6, y: top, width: width, height: bottom - top)
    }

    /// Prefer letterbox space, then move onto the image, clear of global controls.
    static func controlFrame(image: CGRect, bounds: CGRect, topInset: CGFloat, bottomInset: CGFloat,
                             height: CGFloat, atTop: Bool) -> CGRect {
        guard isValid(bounds), topInset.isFinite, bottomInset.isFinite, height.isFinite, height > 0 else { return .zero }
        let top = min(bounds.maxY, bounds.minY + max(0, topInset))
        let bottom = max(top, bounds.maxY - max(0, bottomInset))
        guard bottom > top else { return .zero }
        let visible = image.intersection(bounds)
        let frame = isValid(visible) ? visible : bounds
        let controlHeight = min(height, bottom - top)
        let y: CGFloat
        if atTop {
            y = frame.minY - top >= controlHeight + 6 ? top : max(top, frame.minY + 6)
        } else {
            y = bottom - frame.maxY >= controlHeight + 6 ? frame.maxY + 6 : min(bottom, frame.maxY - 6) - controlHeight
        }
        let sideInset = min(6, bounds.width / 4)
        return CGRect(x: bounds.minX + sideInset, y: min(max(top, y), bottom - controlHeight),
                      width: bounds.width - 2 * sideInset, height: controlHeight)
    }

    static func acceptsFocus(at point: CGPoint, bounds: CGRect, controlStripHeight: CGFloat, topControlStripHeight: CGFloat = 0, exclusionRects: [CGRect] = []) -> Bool {
        guard isValid(bounds), point.x.isFinite, point.y.isFinite,
              controlStripHeight.isFinite, topControlStripHeight.isFinite, bounds.contains(point) else { return false }
        return point.y >= bounds.minY + max(0, topControlStripHeight) && point.y < bounds.maxY - max(0, controlStripHeight) &&
            !exclusionRects.contains(where: { $0.contains(point) })
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

    static func editorFits(bounds: CGRect, topInset: CGFloat, bottomInset: CGFloat, height: CGFloat) -> Bool {
        let available = controlFrame(image: .zero, bounds: bounds, topInset: topInset,
                                     bottomInset: bottomInset, height: height, atTop: true)
        return isValid(available) && available.height + 0.5 >= height && available.width >= 220
    }
}

enum CameraChromePolicy {
    static func showsMessage(collapsed: Bool, brief: Bool, busy: Bool, pending: Bool) -> Bool {
        !collapsed || !brief || busy || pending
    }

    static func collapsed(after translation: CGSize, current: Bool, canCollapse: Bool) -> Bool {
        guard translation.width.isFinite, translation.height.isFinite,
              abs(translation.height) >= 28, abs(translation.height) > abs(translation.width) * 1.3 else { return current }
        return translation.height > 0 ? (canCollapse ? true : current) : false
    }
}

/// Logarithmic spacing gives the same gesture distance to 1–2× and 2–4×.
enum ZoomDialScale {
    static func clamped(_ value: Double, minimum: Double, maximum: Double) -> Double {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return 1 }
        guard value.isFinite else { return minimum }
        return min(maximum, max(minimum, value))
    }

    static func value(start: Double, translation: Double, pointsPerOctave: Double,
                      minimum: Double, maximum: Double) -> Double {
        let base = clamped(start, minimum: minimum, maximum: maximum)
        guard translation.isFinite, pointsPerOctave.isFinite, pointsPerOctave > 0,
              minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return base }
        // Clamp in log space before exponentiation, including very long drags.
        let exponent = min(log2(maximum), max(log2(minimum), log2(base) - translation / pointsPerOctave))
        return clamped(pow(2, exponent), minimum: minimum, maximum: maximum)
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
