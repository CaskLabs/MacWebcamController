import AVFoundation
import Observation

/// Discovers cameras via AVFoundation and matches them to UVC IOKit devices.
@Observable
@MainActor
final class CameraManager {
    private(set) var cameras: [CameraInfo] = []

    private var discoverySession: AVCaptureDevice.DiscoverySession?
    // nonisolated(unsafe) so deinit (which is nonisolated) can release them
    nonisolated(unsafe) private var connectedObserver: Any?
    nonisolated(unsafe) private var disconnectedObserver: Any?

    init() {
        startDiscovery()
    }

    // MARK: - Discovery

    func startDiscovery() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        discoverySession = session

        connectedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCameras() }
        }

        disconnectedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCameras() }
        }

        refreshCameras()
    }

    // MARK: - Disconnect Notification

    /// Called when the camera list changes; observers can watch `cameras` for changes.
    func refreshCameras() {
        guard let session = discoverySession else { return }
        let avDevices = session.devices

        // Capture avDevices as Sendable array values before launching detached task
        let deviceNames = avDevices.map { ($0.uniqueID, $0.localizedName, $0.modelID) }

        Task.detached {
            let uvcDevices = UVCDeviceDiscovery.discoverDevices()
            let infos = deviceNames.map { (uniqueID, localizedName, modelID) in
                CameraManager.matchCameraFrom(
                    uniqueID: uniqueID, localizedName: localizedName, modelID: modelID,
                    uvcDevices: uvcDevices
                )
            }
            await MainActor.run { [weak self] in
                self?.cameras = infos
            }
        }
    }

    // MARK: - AVFoundation <-> IOKit Matching

    nonisolated private static func matchCameraFrom(
        uniqueID: String, localizedName: String, modelID: String, uvcDevices: [UVCDevice]
    ) -> CameraInfo {
        let locationID = extractLocationID(from: uniqueID)
        let (vendorID, productID) = extractVendorProduct(from: modelID)

        print("[CameraManager] Matching '\(localizedName)' uniqueID=\(uniqueID) modelID=\(modelID)")
        print("[CameraManager]   Extracted locationID=\(locationID.map { String(format: "0x%08X", $0) } ?? "nil") VID:0x\(String(vendorID, radix: 16)) PID:0x\(String(productID, radix: 16))")
        print("[CameraManager]   Available UVC devices: \(uvcDevices.map { "\($0.name) loc:0x\(String($0.locationID, radix: 16)) vid:0x\(String($0.vendorID, radix: 16)) pid:0x\(String($0.productID, radix: 16))" })")

        let uvcDevice: UVCDevice?
        if let locID = locationID, let match = uvcDevices.first(where: { $0.locationID == locID }) {
            uvcDevice = match
            print("[CameraManager]   Matched by locationID")
        } else if vendorID != 0 || productID != 0 {
            let candidates = uvcDevices.filter { $0.vendorID == vendorID && $0.productID == productID }
            uvcDevice = candidates.count == 1 ? candidates.first : nil
            print("[CameraManager]   VID/PID match: \(candidates.count) candidate(s), using: \(uvcDevice != nil)")
        } else {
            uvcDevice = uvcDevices.first(where: { $0.name == localizedName })
            print("[CameraManager]   Name match: \(uvcDevice != nil)")
        }

        if uvcDevice == nil {
            print("[CameraManager]   WARNING: No UVC device matched for '\(localizedName)'")
        }

        return CameraInfo(
            id: uniqueID,
            name: localizedName,
            modelID: modelID,
            locationID: locationID ?? 0,
            vendorID: vendorID,
            productID: productID,
            uvcDevice: uvcDevice
        )
    }

    nonisolated private static func extractLocationID(from uniqueID: String) -> UInt32? {
        let hex = uniqueID
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        let prefix = String(hex.prefix(8))
        if let value = UInt32(prefix, radix: 16), value != 0 {
            return value
        }
        return nil
    }

    nonisolated private static func extractVendorProduct(from modelID: String) -> (UInt16, UInt16) {
        // "VID_XXXX&PID_XXXX" format
        if let vidRange = modelID.range(of: "VID_", options: .caseInsensitive),
           let pidRange = modelID.range(of: "PID_", options: .caseInsensitive) {
            let vidStr = String(modelID[vidRange.upperBound...].prefix(4))
            let pidStr = String(modelID[pidRange.upperBound...].prefix(4))
            if let vid = UInt16(vidStr, radix: 16), let pid = UInt16(pidStr, radix: 16) {
                return (vid, pid)
            }
        }
        // Plain hex: "0xVVVVPPPP..."
        let hex = modelID.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        if hex.count >= 8 {
            let vidStr = String(hex.prefix(4))
            let pidStr = String(hex.dropFirst(4).prefix(4))
            if let vid = UInt16(vidStr, radix: 16), let pid = UInt16(pidStr, radix: 16) {
                return (vid, pid)
            }
        }
        return (0, 0)
    }
}
