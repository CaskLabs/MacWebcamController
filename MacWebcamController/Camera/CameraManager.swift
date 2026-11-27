import AVFoundation
import Observation

/// Discovers cameras via AVFoundation and matches them to UVC IOKit devices.
@Observable
@MainActor
final class CameraManager {
    private(set) var cameras: [CameraInfo] = []
    private(set) var authorizationStatus: AVAuthorizationStatus = .notDetermined

    private var discoverySession: AVCaptureDevice.DiscoverySession?
    private var refreshInProgress = false
    private var refreshPending = false
    // Observers stored outside @Observable tracking so deinit can release them
    // without hitting actor-isolation restrictions.
    private let observerBox = NotificationObserverBox()

    init() {
        startDiscovery()
    }

    // MARK: - Discovery

    func startDiscovery() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        authorizationStatus = status

        switch status {
        case .authorized:
            setupDiscoverySession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.authorizationStatus = granted ? .authorized : .denied
                    if granted {
                        self.setupDiscoverySession()
                    }
                }
            }
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func checkPermissionState() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        authorizationStatus = status
        if status == .authorized && discoverySession == nil {
            setupDiscoverySession()
        }
    }

    private func setupDiscoverySession() {
        guard discoverySession == nil else {
            refreshCameras()
            return
        }

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
        if refreshInProgress {
            refreshPending = true
            return
        }

        guard let session = discoverySession else { return }
        refreshInProgress = true
        let avDevices = session.devices

        // Capture avDevices as Sendable array values before launching detached task
        let deviceNames = avDevices.map { ($0.uniqueID, $0.localizedName, $0.modelID) }

        Task.detached {
            let uvcDevices = UVCDeviceDiscovery.discoverDevices()
            var infos = deviceNames.map { (uniqueID, localizedName, modelID) in
                CameraManager.matchCameraFrom(
                    uniqueID: uniqueID, localizedName: localizedName, modelID: modelID,
                    uvcDevices: uvcDevices
                )
            }
            // Reject all collisions rather than arbitrarily assigning one physical
            // control interface to several AVFoundation cameras.
            let counts = infos.compactMap { $0.uvcDevice }.reduce(into: [ObjectIdentifier: Int]()) {
                $0[ObjectIdentifier($1), default: 0] += 1
            }
            infos = infos.map { info in
                guard let device = info.uvcDevice, counts[ObjectIdentifier(device)] != 1 else { return info }
                return info.withUVCDevice(nil)
            }
            let refreshedCameras = infos
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cameras = refreshedCameras
                self.refreshInProgress = false

                if self.refreshPending {
                    self.refreshPending = false
                    self.refreshCameras()
                }
            }
        }
    }

    // MARK: - AVFoundation <-> IOKit Matching

    nonisolated private static func matchCameraFrom(
        uniqueID: String, localizedName: String, modelID: String, uvcDevices: [UVCDevice]
    ) -> CameraInfo {
        let locationID = extractLocationID(from: uniqueID)
        let (vendorID, productID) = extractVendorProduct(from: modelID)

        let candidates = uvcDevices.map {
            CameraMatchCandidate(name: $0.name, locationID: $0.locationID,
                                 vendorID: $0.vendorID, productID: $0.productID)
        }
        let index = uniqueCandidateIndex(locationID: locationID, vendorID: vendorID,
                                         productID: productID, name: localizedName,
                                         candidates: candidates)
        let uvcDevice = index.map { uvcDevices[$0] }

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

    /// An ambiguous match must never grant hardware write access.
    nonisolated static func uniqueCandidateIndex(
        locationID: UInt32?, vendorID: UInt16, productID: UInt16,
        name: String, candidates: [CameraMatchCandidate]
    ) -> Int? {
        func resolve(_ indices: [Int]) -> Int? {
            if indices.count == 1 { return indices.first }
            let names = indices.filter { nameSimilar(candidates[$0].name, name) }
            return names.count == 1 ? names.first : nil
        }
        if let locationID {
            let matches = candidates.indices.filter { candidates[$0].locationID == locationID }
            if !matches.isEmpty { return resolve(matches) }
        }
        if vendorID != 0 && productID != 0 {
            let matches = candidates.indices.filter {
                candidates[$0].vendorID == vendorID && candidates[$0].productID == productID
            }
            if !matches.isEmpty { return resolve(matches) }
        }
        let matches = candidates.indices.filter { nameSimilar(candidates[$0].name, name) }
        return matches.count == 1 ? matches.first : nil
    }

    /// Returns true when the two names refer to the same physical camera.
    /// Handles cases where IOKit and AVFoundation names differ slightly
    /// (e.g. "Dell Webcam WB7022" vs "Dell Webcam WB7022 - RGB").
    nonisolated static func nameSimilar(_ a: String, _ b: String) -> Bool {
        let la = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lb = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !la.isEmpty, !lb.isEmpty else { return false }
        return la == lb || la.contains(lb) || lb.contains(la)
    }

    nonisolated static func extractLocationID(from uniqueID: String) -> UInt32? {
        guard UUID(uuidString: uniqueID) == nil else { return nil }
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

struct CameraMatchCandidate: Sendable {
    let name: String
    let locationID: UInt32
    let vendorID: UInt16
    let productID: UInt16
}
