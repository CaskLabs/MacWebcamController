import AVFoundation
import Observation

/// Discovers cameras via AVFoundation and matches them to UVC IOKit devices.
@Observable
@MainActor
final class CameraManager {
    private(set) var cameras: [CameraInfo] = []

    private var discoverySession: AVCaptureDevice.DiscoverySession?
    // Observers stored outside @Observable tracking so deinit can release them
    // without hitting actor-isolation restrictions.
    private let observerBox = NotificationObserverBox()

    init() {
        startDiscovery()
    }

    // MARK: - Discovery

    func startDiscovery() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .external,
                .builtInWideAngleCamera,
                .continuityCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        discoverySession = session

        observerBox.connected = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Delay so IOKit finishes enumerating the USB device before we probe it.
                // Without this, GET_MIN requests fail and controls are incorrectly greyed out.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.refreshCameras()
            }
        }

        observerBox.disconnected = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
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

        var uvcDevice: UVCDevice?

        // 1. Try USB location ID matching (most precise).
        // Note: always fall through to subsequent strategies if this yields 0 candidates —
        // the uniqueID prefix may not encode the real location ID (e.g. UUID-format IDs).
        if let locID = locationID {
            let candidates = uvcDevices.filter { $0.locationID == locID }
            if candidates.count == 1 {
                uvcDevice = candidates.first
                print("[CameraManager]   Matched by locationID (unique)")
            } else if candidates.count > 1 {
                // Multiple functions (e.g. IR + RGB) share the same USB location ID.
                // Use name similarity to pick the right one; fall back to the first.
                uvcDevice = candidates.first(where: { nameSimilar($0.name, localizedName) }) ?? candidates.first
                print("[CameraManager]   Matched by locationID (\(candidates.count) candidates, name-tiebreak: \(uvcDevice?.name ?? "first"))")
            } else {
                print("[CameraManager]   locationID 0x\(String(locID, radix: 16)) matched 0 IOKit devices — falling through to VID/PID")
            }
        }

        // 2. Try VID/PID matching if location ID gave no result.
        if uvcDevice == nil, vendorID != 0 || productID != 0 {
            let candidates = uvcDevices.filter { $0.vendorID == vendorID && $0.productID == productID }
            if candidates.count == 1 {
                uvcDevice = candidates.first
            } else if candidates.count > 1 {
                uvcDevice = candidates.first(where: { nameSimilar($0.name, localizedName) }) ?? candidates.first
            }
            print("[CameraManager]   VID/PID match: \(candidates.count) candidate(s), using: \(uvcDevice != nil)")
        }

        // 3. Name similarity as last resort.
        if uvcDevice == nil {
            uvcDevice = uvcDevices.first(where: { nameSimilar($0.name, localizedName) })
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

    /// Returns true when the two names refer to the same physical camera.
    /// Handles cases where IOKit and AVFoundation names differ slightly
    /// (e.g. "Dell Webcam WB7022" vs "Dell Webcam WB7022 - RGB").
    nonisolated static func nameSimilar(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased(), lb = b.lowercased()
        return la == lb || la.contains(lb) || lb.contains(la)
    }

    nonisolated static func extractLocationID(from uniqueID: String) -> UInt32? {
        let hex = uniqueID
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        let prefix = String(hex.prefix(8))
        if let value = UInt32(prefix, radix: 16), value != 0 {
            return value
        }
        return nil
    }

    nonisolated static func extractVendorProduct(from modelID: String) -> (UInt16, UInt16) {
        // Format: "UVC Camera VendorID_21325 ProductID_8457" (decimal)
        if let vidRange = modelID.range(of: "VendorID_"),
           let pidRange = modelID.range(of: "ProductID_") {
            let vidStr = String(modelID[vidRange.upperBound...].prefix(while: \.isNumber))
            let pidStr = String(modelID[pidRange.upperBound...].prefix(while: \.isNumber))
            if let vid = UInt16(vidStr), let pid = UInt16(pidStr) {
                return (vid, pid)
            }
        }
        // Format: "VID_XXXX&PID_XXXX" (hex)
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

// MARK: - Observer Storage

/// Holds NotificationCenter observer tokens outside @Observable/@MainActor
/// so they can be released from the nonisolated deinit context.
private final class NotificationObserverBox: @unchecked Sendable {
    var connected: Any?
    var disconnected: Any?

    deinit {
        if let obs = connected    { NotificationCenter.default.removeObserver(obs) }
        if let obs = disconnected { NotificationCenter.default.removeObserver(obs) }
    }
}
