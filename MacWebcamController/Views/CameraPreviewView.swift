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
        let device = cameraID.flatMap { AVCaptureDevice(uniqueID: $0) }
        nsView.updateDevice(device)
    }
}

// MARK: - NSView

final class CameraPreviewNSView: NSView, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var currentDeviceID: String?
    private let sessionQueue = DispatchQueue(label: "com.macwebcamcontroller.preview")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func updateDevice(_ device: AVCaptureDevice?) {
        guard device?.uniqueID != currentDeviceID else { return }
        currentDeviceID = device?.uniqueID

        // Capture only the uniqueID string (Sendable) — not AVCaptureDevice itself
        let deviceID = device?.uniqueID
        let session = self.session

        sessionQueue.async {
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }

            if let id = deviceID,
               let dev = AVCaptureDevice(uniqueID: id),
               let input = try? AVCaptureDeviceInput(device: dev),
               session.canAddInput(input) {
                session.addInput(input)
            }

            session.commitConfiguration()

            if deviceID != nil {
                if !session.isRunning { session.startRunning() }
            } else {
                session.stopRunning()
            }
        }
    }
}
