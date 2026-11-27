import SwiftUI
import AVFoundation
import AppKit

// MARK: - Shared Preview Controller

/// Owns a single `AVCaptureSession` and coordinates sharing it among multiple
/// preview consumers (for example, the main window and a menu popover).
@Observable
@MainActor
final class CameraPreviewController {
    private let engine: CameraPreviewEngine
    private(set) var state: CameraPreviewState = .idle
    var session: AVCaptureSession { engine.session }

    init() {
        engine = CameraPreviewEngine()
        engine.setStateHandler { [weak self] state in
            DispatchQueue.main.async { [weak self] in self?.state = state }
        }
    }

    func retry() { engine.retry() }

    func attach(_ consumerID: UUID, cameraID: String) {
        engine.attach(consumerID, cameraID: cameraID)
    }

    func detach(_ consumerID: UUID, immediately: Bool = false) {
        engine.detach(consumerID, immediately: immediately)
    }
}

enum CameraPreviewState: Equatable, Sendable {
    case idle, starting, running, busy, interrupted, denied
    case failed(String)

    var message: String? {
        switch self {
        case .idle: "Preview is inactive."
        case .starting: "Starting camera preview…"
        case .running: nil
        case .busy: "Camera is in use by another application. Preview will resume when it is available."
        case .interrupted: "Camera preview was interrupted."
        case .denied: "Camera access is not authorized. Allow access in System Settings."
        case .failed(let message): message
        }
    }
}

/// All mutable capture state and session operations are confined to sessionQueue.
/// Only the immutable session reference is shared with main-thread preview layers.
private final class CameraPreviewEngine: @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.macwebcamcontroller.preview")
    private var configuredDeviceID: String?
    private var consumers: [UUID: String] = [:]
    private var pendingStop: DispatchWorkItem?
    private var observedDevice: AVCaptureDevice?
    private var deviceUsageObservation: NSKeyValueObservation?
    private let observerBox = PreviewObserverBox()
    private var stateHandler: (@Sendable (CameraPreviewState) -> Void)?

    func setStateHandler(_ handler: @escaping @Sendable (CameraPreviewState) -> Void) {
        sessionQueue.async { [weak self] in self?.stateHandler = handler }
    }

    func retry() {
        sessionQueue.async { [weak self] in
            guard let self, let cameraID = self.desiredCameraID else { return }
            self.releaseCaptureGraph(clearDeviceObservation: false)
            self.configureAndStart(cameraID: cameraID)
        }
    }

    private func publish(_ state: CameraPreviewState) { stateHandler?(state) }

    init() {
        sessionQueue.async { [weak self] in self?.setupSessionNotifications() }
    }

    private func setupSessionNotifications() {
        observerBox.runtimeError = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            print("[Preview] Capture runtime error: \(error?.localizedDescription ?? "unknown")")
            let message = error?.localizedDescription ?? "Unknown capture error"
            self?.sessionQueue.async { [weak self] in
                guard let self, self.hasConsumers else { return }
                self.releaseCaptureGraph(clearDeviceObservation: false)
                self.publish(.failed(message))
            }
        }

        observerBox.interrupted = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            print("[Preview] Capture interrupted")
            self?.yieldAfterInterruption()
        }
        observerBox.interruptionEnded = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            self?.restartAfterInterruption()
        }
    }

    func attach(_ consumerID: UUID, cameraID: String) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.consumers[consumerID] = cameraID
            self.pendingStop?.cancel()
            self.pendingStop = nil
            self.configureAndStart(cameraID: cameraID)
        }
    }

    func detach(_ consumerID: UUID, immediately: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.consumers.removeValue(forKey: consumerID)
            self.pendingStop?.cancel()
            if let cameraID = self.desiredCameraID {
                self.configureAndStart(cameraID: cameraID)
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.hasConsumers else { return }
                self.releaseCaptureGraph(clearDeviceObservation: true)
                self.publish(.idle)
            }
            self.pendingStop = work
            if immediately {
                work.perform()
            } else {
                self.sessionQueue.asyncAfter(deadline: .now() + 1, execute: work)
            }
        }
    }

    private var hasConsumers: Bool { !consumers.isEmpty }
    private var desiredCameraID: String? { consumers.values.first }

    private func configureAndStart(cameraID: String) {
        guard hasConsumers, consumers.values.contains(cameraID) else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            releaseCaptureGraph(clearDeviceObservation: true)
            publish(.denied)
            return
        }

        guard let device = AVCaptureDevice(uniqueID: cameraID) else {
            releaseCaptureGraph(clearDeviceObservation: true)
            publish(.failed("Camera is no longer connected."))
            return
        }

        observeExternalUse(of: device)

        // The controller preview is deliberately lower priority than Teams,
        // FaceTime, OBS, or any other application using the camera.
        guard !device.isInUseByAnotherApplication else {
            releaseCaptureGraph(clearDeviceObservation: false)
            publish(.busy)
            return
        }

        if configuredDeviceID != cameraID || !session.isRunning { publish(.starting) }
        if configuredDeviceID != cameraID {
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }

            guard let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                configuredDeviceID = nil
                publish(.failed("Could not configure the camera. Try again or reconnect it."))
                return
            }

            session.addInput(input)
            session.commitConfiguration()
            configuredDeviceID = cameraID
        }

        if hasConsumers, !session.isRunning {
            session.startRunning()
        }
        if session.isRunning {
            publish(.running)
        } else {
            // macOS reports interruptions through session notifications;
            // AVCaptureSession.isInterrupted is unavailable on this platform.
            publish(.failed("Camera preview could not start."))
        }
    }

    private func observeExternalUse(of device: AVCaptureDevice) {
        guard observedDevice?.uniqueID != device.uniqueID else { return }

        deviceUsageObservation = nil
        observedDevice = device
        deviceUsageObservation = device.observe(
            \.isInUseByAnotherApplication,
            options: [.new]
        ) { [weak self] device, change in
            let cameraID = device.uniqueID
            let isInUse = change.newValue ?? device.isInUseByAnotherApplication
            self?.sessionQueue.async { [weak self] in
                self?.externalUsageChanged(cameraID: cameraID, isInUse: isInUse)
            }
        }
    }

    private func externalUsageChanged(cameraID: String, isInUse: Bool) {
        guard desiredCameraID == cameraID else { return }

        if isInUse {
            print("[Preview] Camera became busy in another app; stopping preview")
            releaseCaptureGraph(clearDeviceObservation: false)
            publish(.busy)
        } else if hasConsumers {
            print("[Preview] Camera became free; restarting preview")
            configureAndStart(cameraID: cameraID)
        }
    }

    private func restartAfterInterruption() {
        sessionQueue.async { [weak self] in
            guard let self, let cameraID = self.desiredCameraID else { return }
            self.configureAndStart(cameraID: cameraID)
        }
    }

    private func yieldAfterInterruption() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.hasConsumers else { return }
            self.publish(.interrupted)
        }
    }

    private func releaseCaptureGraph(clearDeviceObservation: Bool) {
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.commitConfiguration()
        configuredDeviceID = nil

        if clearDeviceObservation {
            deviceUsageObservation = nil
            observedDevice = nil
        }
    }
}

// MARK: - Observer Box

private final class PreviewObserverBox: @unchecked Sendable {
    var interrupted: NSObjectProtocol?
    var interruptionEnded: NSObjectProtocol?
    var runtimeError: NSObjectProtocol?

    deinit {
        if let interrupted { NotificationCenter.default.removeObserver(interrupted) }
        if let interruptionEnded { NotificationCenter.default.removeObserver(interruptionEnded) }
        if let runtimeError { NotificationCenter.default.removeObserver(runtimeError) }
    }
}

/// Shared session surface with explicit permission, availability and error states.
struct CameraPreviewView: View {
    @Environment(CameraPreviewController.self) private var controller
    let cameraID: String?
    var releaseImmediatelyWhenRemoved: Bool = false

    var body: some View {
        ZStack {
            CameraPreviewSurface(cameraID: cameraID,
                                 releaseImmediatelyWhenRemoved: releaseImmediatelyWhenRemoved)
            if let message = controller.state.message {
                VStack(spacing: 10) {
                    if controller.state == .starting {
                        ProgressView().controlSize(.small)
                    }
                    Text(message).multilineTextAlignment(.center)
                    if controller.state == .denied {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else if controller.state != .starting && controller.state != .idle {
                        Button("Retry Preview") { controller.retry() }
                    }
                }
                .font(.caption)
                .foregroundStyle(.white)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.8))
            }
        }
    }
}

/// Live video preview for a selected camera using the shared capture session.
private struct CameraPreviewSurface: NSViewRepresentable {
    @Environment(CameraPreviewController.self) private var previewController
    let cameraID: String?
    let releaseImmediatelyWhenRemoved: Bool

    init(cameraID: String?, releaseImmediatelyWhenRemoved: Bool = false) {
        self.cameraID = cameraID
        self.releaseImmediatelyWhenRemoved = releaseImmediatelyWhenRemoved
    }

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(
            controller: previewController,
            releaseImmediatelyWhenRemoved: releaseImmediatelyWhenRemoved
        )
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.updateDevice(cameraID)
    }

    static func dismantleNSView(_ nsView: CameraPreviewNSView, coordinator: ()) {
        nsView.detach()
    }
}

// MARK: - NSView

@MainActor
final class CameraPreviewNSView: NSView {
    private let consumerID = UUID()
    private let controller: CameraPreviewController
    private let releaseImmediatelyWhenRemoved: Bool
    private var currentDeviceID: String?
    private var isAttached = false
    private var isObservingApplication = false
    private weak var observedWindow: NSWindow?
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(controller: CameraPreviewController, releaseImmediatelyWhenRemoved: Bool) {
        self.controller = controller
        self.releaseImmediatelyWhenRemoved = releaseImmediatelyWhenRemoved
        self.previewLayer = AVCaptureVideoPreviewLayer()
        super.init(frame: .zero)

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow(window)
        updatePresentationState()
    }

    func updateDevice(_ deviceID: String?) {
        if deviceID != currentDeviceID {
            detachFromSession(immediately: false)
            currentDeviceID = deviceID
        }

        updatePresentationState()
    }

    func detach() {
        observeWindow(nil)
        detachFromSession(immediately: releaseImmediatelyWhenRemoved)
        currentDeviceID = nil
    }

    private func observeWindow(_ newWindow: NSWindow?) {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didMiniaturizeNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didDeminiaturizeNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: observedWindow
            )
        }

        observedWindow = newWindow
        guard let newWindow else {
            stopObservingApplication()
            return
        }

        startObservingApplication()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMiniaturize),
            name: NSWindow.didMiniaturizeNotification,
            object: newWindow
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidDeminiaturize),
            name: NSWindow.didDeminiaturizeNotification,
            object: newWindow
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: newWindow
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeOcclusionState),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: newWindow
        )
    }

    private func startObservingApplication() {
        guard !isObservingApplication else { return }
        isObservingApplication = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidUnhide),
            name: NSApplication.didUnhideNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidHide),
            name: NSApplication.didHideNotification,
            object: NSApp
        )
    }

    private func stopObservingApplication() {
        guard isObservingApplication else { return }
        isObservingApplication = false
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didUnhideNotification,
            object: NSApp
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didHideNotification,
            object: NSApp
        )
    }

    private func updatePresentationState() {
        guard let deviceID = currentDeviceID,
              let window,
              !window.isMiniaturized,
              window.isVisible,
              window.occlusionState.contains(.visible),
              !NSApp.isHidden else {
            let shouldReleaseImmediately = window?.isMiniaturized == true ||
                window?.isVisible == false || NSApp.isHidden
            detachFromSession(immediately: shouldReleaseImmediately)
            return
        }

        guard !isAttached else { return }
        isAttached = true
        previewLayer.session = controller.session
        controller.attach(consumerID, cameraID: deviceID)
    }

    private func detachFromSession(immediately: Bool) {
        // Clear the layer even if this view never finished attaching (for
        // example, when it was created while its window was minimized).
        previewLayer.session = nil
        guard isAttached else { return }
        isAttached = false
        controller.detach(consumerID, immediately: immediately)
    }

    @objc private func windowDidMiniaturize(_ notification: Notification) {
        detachFromSession(immediately: true)
    }

    @objc private func windowDidDeminiaturize(_ notification: Notification) {
        updatePresentationState()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        detachFromSession(immediately: true)
    }

    @objc private func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = observedWindow else { return }
        if window.occlusionState.contains(.visible) {
            updatePresentationState()
        } else {
            detachFromSession(immediately: releaseImmediatelyWhenRemoved || !window.isVisible)
        }
    }

    @objc private func applicationDidUnhide(_ notification: Notification) {
        updatePresentationState()
    }

    @objc private func applicationDidHide(_ notification: Notification) {
        detachFromSession(immediately: true)
    }
}
