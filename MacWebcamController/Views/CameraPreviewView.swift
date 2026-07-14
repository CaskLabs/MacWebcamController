@preconcurrency import AVFoundation
import Observation
import SwiftUI

/// Owns the single capture session shared by every preview surface.
///
/// MenuBarExtra content can be dismantled and recreated frequently. Keeping the
/// session here prevents overlapping `startRunning`/`stopRunning` calls from
/// short-lived NSViews and allows the main-window and menu-bar layers to share
/// one camera stream.
@Observable
final class CameraPreviewController: @unchecked Sendable {
    @ObservationIgnored let session = AVCaptureSession()

    @ObservationIgnored private let sessionQueue = DispatchQueue(
        label: "com.macwebcamcontroller.preview.session",
        qos: .userInitiated
    )
    @ObservationIgnored private let stateLock = NSLock()
    @ObservationIgnored private var consumers: [UUID: String] = [:]
    @ObservationIgnored private var pendingStop: DispatchWorkItem?
    @ObservationIgnored private var configuredDeviceID: String?
    @ObservationIgnored private var observedDevice: AVCaptureDevice?
    @ObservationIgnored private var deviceUsageObservation: NSKeyValueObservation?
    @ObservationIgnored private let observerBox = PreviewNotificationObserverBox()

    init() {
        session.beginConfiguration()
        if session.canSetSessionPreset(.medium) {
            // The menu-bar preview is small. Avoid running a 4K/4MP camera and
            // the macOS video-effects pipeline at full resolution for it.
            session.sessionPreset = .medium
        }
        session.commitConfiguration()

        observerBox.interruptionEnded = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.restartAfterInterruption()
        }

        observerBox.runtimeError = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            print("[Preview] Capture runtime error: \(error?.localizedDescription ?? "unknown")")
            self?.restartAfterInterruption()
        }

        observerBox.interrupted = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            print("[Preview] Capture interrupted")
            self?.yieldAfterInterruption()
        }
    }

    /// Registers or updates one visible preview surface.
    func attach(_ consumerID: UUID, cameraID: String) {
        stateLock.lock()
        consumers[consumerID] = cameraID
        pendingStop?.cancel()
        pendingStop = nil
        stateLock.unlock()

        sessionQueue.async { [weak self] in
            self?.configureAndStart(cameraID: cameraID)
        }
    }

    /// Detaches a surface. The delayed stop absorbs rapid menu-popover
    /// close/reopen cycles without tearing down the camera graph each time.
    func detach(_ consumerID: UUID, immediately: Bool = false) {
        stateLock.lock()
        consumers.removeValue(forKey: consumerID)
        let remainingCameraID = consumers.values.first

        if let remainingCameraID {
            stateLock.unlock()
            sessionQueue.async { [weak self] in
                self?.configureAndStart(cameraID: remainingCameraID)
            }
            return
        }

        pendingStop?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.hasConsumers else { return }
            self.releaseCaptureGraph(clearDeviceObservation: true)
        }
        pendingStop = workItem
        stateLock.unlock()

        if immediately {
            sessionQueue.async(execute: workItem)
        } else {
            sessionQueue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
    }

    private var hasConsumers: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !consumers.isEmpty
    }

    private var desiredCameraID: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return consumers.values.first
    }

    private func configureAndStart(cameraID: String) {
        guard let device = AVCaptureDevice(uniqueID: cameraID) else {
            releaseCaptureGraph(clearDeviceObservation: true)
            print("[Preview] Could not find camera \(cameraID)")
            return
        }

        observeExternalUse(of: device)

        // The controller preview is deliberately lower priority than Teams,
        // FaceTime, OBS, or any other application using the camera.
        guard !device.isInUseByAnotherApplication else {
            releaseCaptureGraph(clearDeviceObservation: false)
            print("[Preview] Camera is in use by another application; yielding preview")
            return
        }

        if configuredDeviceID != cameraID {
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }

            guard let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                configuredDeviceID = nil
                print("[Preview] Could not configure camera \(cameraID)")
                return
            }

            session.addInput(input)
            session.commitConfiguration()
            configuredDeviceID = cameraID
        }

        if hasConsumers, !session.isRunning {
            session.startRunning()
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
        guard observedDevice?.uniqueID == cameraID else { return }

        if isInUse {
            releaseCaptureGraph(clearDeviceObservation: false)
        } else if let desiredCameraID {
            configureAndStart(cameraID: desiredCameraID)
        }
    }

    private func releaseCaptureGraph(clearDeviceObservation: Bool) {
        if session.isRunning {
            session.stopRunning()
        }

        // stopRunning() alone keeps the AVCaptureDeviceInput (and therefore
        // the UVC device) retained. Removing every input releases the camera
        // for the higher-priority conferencing application.
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.commitConfiguration()
        configuredDeviceID = nil

        if clearDeviceObservation {
            deviceUsageObservation = nil
            observedDevice = nil
        }
    }

    private func restartAfterInterruption() {
        sessionQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let cameraID = self.desiredCameraID else { return }
            self.configureAndStart(cameraID: cameraID)
        }
    }

    private func yieldAfterInterruption() {
        sessionQueue.async { [weak self] in
            self?.releaseCaptureGraph(clearDeviceObservation: false)
        }
    }
}

private final class PreviewNotificationObserverBox: @unchecked Sendable {
    var interrupted: NSObjectProtocol?
    var interruptionEnded: NSObjectProtocol?
    var runtimeError: NSObjectProtocol?

    deinit {
        if let interrupted { NotificationCenter.default.removeObserver(interrupted) }
        if let interruptionEnded { NotificationCenter.default.removeObserver(interruptionEnded) }
        if let runtimeError { NotificationCenter.default.removeObserver(runtimeError) }
    }
}

/// Live video preview for a selected camera using the shared capture session.
struct CameraPreviewView: NSViewRepresentable {
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
                name: NSWindow.didBecomeKeyNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
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
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: newWindow
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: newWindow
        )
    }

    private func startObservingApplication() {
        guard !isObservingApplication else { return }
        isObservingApplication = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didUnhideNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didHideNotification,
            object: NSApp
        )
    }

    private func stopObservingApplication() {
        guard isObservingApplication else { return }
        isObservingApplication = false
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
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
              window.isKeyWindow,
              !NSApp.isHidden,
              NSApp.isActive else {
            let shouldReleaseImmediately = window?.isMiniaturized == true ||
                window?.isKeyWindow == false || NSApp.isHidden || !NSApp.isActive
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

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        updatePresentationState()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        detachFromSession(immediately: true)
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        updatePresentationState()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        detachFromSession(immediately: true)
    }
}
