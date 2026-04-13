import SwiftUI
import AVFoundation

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

final class CameraPreviewNSView: NSView {
    private let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var currentDeviceID: String?

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
        // Avoid restarting if device hasn't changed
        guard device?.uniqueID != currentDeviceID else { return }
        currentDeviceID = device?.uniqueID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }

            if let device,
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }

            self.session.commitConfiguration()

            if device != nil {
                if !self.session.isRunning { self.session.startRunning() }
            } else {
                self.session.stopRunning()
            }
        }
    }

    // Session cleanup happens automatically when the view is released.
}
