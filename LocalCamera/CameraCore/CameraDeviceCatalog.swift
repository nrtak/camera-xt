import AVFoundation

struct CameraLens: Identifiable, Equatable {
    let id: String
    let name: String
    let isFront: Bool
    var zoomFactor: Double? = nil
    var maximumZoom: Double = 1
    var secondaryZooms: [Double] = []
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
        return CameraLens(id: device.uniqueID, name: name, isFront: device.position == .front, zoomFactor: displayZoom(for: device), maximumZoom: Double(device.maxAvailableVideoZoomFactor),
                          secondaryZooms: device.position == .back && device.deviceType != .builtInUltraWideCamera
                            ? Array(Set(device.formats.flatMap { $0.secondaryNativeResolutionZoomFactors.map { Double($0) } })).sorted() : [])
    }
}
struct ZoomShortcut: Identifiable {
    let lens: CameraLens
    let multiplier: Double
    var value: Double { (lens.zoomFactor ?? 1) * multiplier }
    var id: String { "\(lens.id)-\(multiplier)" }
}

enum ZoomShortcuts {
    static func make(_ lenses: [CameraLens]) -> [ZoomShortcut] {
        var choices: [ZoomShortcut] = []
        for lens in lenses where !lens.isFront && lens.name != "Depth" {
            guard let base = lens.zoomFactor, base.isFinite, base > 0 else { continue }
            choices.append(ZoomShortcut(lens: lens, multiplier: 1))
            for factor in lens.secondaryZooms where factor.isFinite && factor > 1 && factor <= lens.maximumZoom {
                choices.append(ZoomShortcut(lens: lens, multiplier: factor))
            }
        }
        choices.sort {
            if abs($0.value - $1.value) < 0.01 { return $0.multiplier < $1.multiplier }
            return $0.value < $1.value
        }
        var unique: [ZoomShortcut] = []
        for choice in choices where !unique.contains(where: { abs($0.value - choice.value) < 0.01 }) { unique.append(choice) }
        return unique
    }
}
