import AVFoundation
import Observation

/// Discovers and tracks connected cameras via AVFoundation.
@Observable
@MainActor
final class CameraManager {
    private(set) var cameras: [CameraInfo] = []

    private var discoverySession: AVCaptureDevice.DiscoverySession?

    init() {
        startDiscovery()
    }

    func startDiscovery() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        discoverySession = session
        refreshCameras()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCameras() }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCameras() }
        }
    }

    private func refreshCameras() {
        guard let session = discoverySession else { return }
        cameras = session.devices.map { device in
            CameraInfo(
                id: device.uniqueID,
                name: device.localizedName,
                modelID: device.modelID,
                vendorID: nil,
                productID: nil
            )
        }
    }
}
