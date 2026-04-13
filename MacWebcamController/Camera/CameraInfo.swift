import Foundation

/// Information about a detected camera.
struct CameraInfo: Identifiable, Sendable {
    let id: String          // AVCaptureDevice.uniqueID
    let name: String        // User-facing device name
    let modelID: String     // Model identifier (often contains vendor:product)
    let vendorID: Int?
    let productID: Int?
}
