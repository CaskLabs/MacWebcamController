@preconcurrency import AVFoundation
import SwiftUI

/// Live video preview for a selected camera using AVCaptureSession.
/// Wraps AVCaptureVideoPreviewLayer in an NSView.
struct CameraPreviewView: NSViewRepresentable {
    let cameraID: String?

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView()
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.updateDevice(cameraID)
    }
}

// MARK: - NSView

final class CameraPreviewNSView: NSView, @unchecked Sendable {
    // nonisolated(unsafe): these are accessed only from sessionQueue, which we manage manually.
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated(unsafe) private var currentDeviceID: String?
    private let sessionQueue = DispatchQueue(label: "com.macwebcamcontroller.preview")

    // The preview layer IS the view's backing layer — makeBackingLayer() returns it directly.
    // This avoids the init-time nil-layer problem with addSublayer.
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        previewLayer
    }

    func updateDevice(_ deviceID: String?) {
        guard deviceID != currentDeviceID else { return }
        currentDeviceID = deviceID

        sessionQueue.async { [session] in
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }

            if let id = deviceID,
               let device = AVCaptureDevice(uniqueID: id),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }

            session.commitConfiguration()

            if deviceID != nil {
                if !session.isRunning { session.startRunning() }
            } else {
                if session.isRunning { session.stopRunning() }
            }
        }
    }
}
