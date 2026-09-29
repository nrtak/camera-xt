import AVFoundation

struct CameraLens: Identifiable, Equatable {
    let id: String
    let name: String
    let isFront: Bool
}

enum CameraDeviceCatalog {
    static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified
        ).devices
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
        return CameraLens(id: device.uniqueID, name: name, isFront: device.position == .front)
    }
}
