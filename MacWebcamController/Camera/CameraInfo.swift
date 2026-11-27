import Foundation

/// Information about a detected camera, combining AVFoundation metadata with the UVC device.
struct CameraInfo: Identifiable, Sendable, Equatable {
    static func == (lhs: CameraInfo, rhs: CameraInfo) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name &&
        lhs.uvcDevice?.identity == rhs.uvcDevice?.identity
    }

    func withUVCDevice(_ device: (any CameraControlling)?) -> CameraInfo {
        CameraInfo(id: id, name: name, modelID: modelID, locationID: locationID,
                   vendorID: vendorID, productID: productID, uvcDevice: device)
    }
    let id: String          // AVCaptureDevice.uniqueID (persistent key for UserDefaults)
    let name: String        // User-facing device name
    let modelID: String     // Model identifier (may contain vendor:product)
    let locationID: UInt32  // USB location ID for IOKit matching
    let vendorID: UInt16
    let productID: UInt16
    /// The associated UVC device, nil if no IOKit match was found.
    let uvcDevice: (any CameraControlling)?
}
