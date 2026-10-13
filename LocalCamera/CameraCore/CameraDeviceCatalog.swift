import AVFoundation

struct CameraLens: Identifiable, Equatable {
    let id: String
    let name: String
    let isFront: Bool
    var zoomFactor: Double? = nil
    var maximumZoom: Double = 1
    var zoomLabel: String {
        guard let zoomFactor else { return name }
        return zoomFactor.rounded() == zoomFactor ? String(format: "%.0f×", zoomFactor) : String(format: "%.1f×", zoomFactor)
    }
}

enum CameraDeviceCatalog {
    static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    // Normalize the hardware's constituent-camera zoom factors to the main lens (1×).
    private static func displayZoom(for device: AVCaptureDevice) -> Double? {
        guard device.position == .back else { return nil }
        for type in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera] {
            guard let virtual = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
            let devices = virtual.constituentDevices
            let factors = [1.0] + virtual.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
            guard factors.count == devices.count,
                  let main = devices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
                  let selected = devices.firstIndex(where: { $0.uniqueID == device.uniqueID }),
                  factors[main] > 0 else { continue }
            return (factors[selected] / factors[main] * 10).rounded() / 10
        }
        return device.deviceType == .builtInWideAngleCamera ? 1 : nil
    }

    static func lens(for device: AVCaptureDevice) -> CameraLens {
        let name: String
        if device.position == .front {
            name = "Front"
        } else {
            switch device.deviceType {
            case .builtInUltraWideCamera: name = "Ultra Wide"
            case .builtInTelephotoCamera: name = "Telephoto"
            default: name = "Wide"
            }
        }
        return CameraLens(id: device.uniqueID, name: name, isFront: device.position == .front, zoomFactor: displayZoom(for: device), maximumZoom: Double(device.maxAvailableVideoZoomFactor))
    }
}
