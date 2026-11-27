import AppKit
import SwiftUI
import Observation

/// Owns the public AppKit status item; SwiftUI owns the content of both surfaces.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let cameraManager = CameraManager()
    private let viewModel = CameraViewModel()
    private let previewController = CameraPreviewController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let raw = UserDefaults.standard.string(forKey: "appearanceMode") ?? ""
        (AppearanceMode(rawValue: raw) ?? .system).apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Camera Controls")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            MenuBarView(
                openFullControls: { [weak self] in self?.showMainWindow(settings: false) },
                openSettings: { [weak self] in self?.showMainWindow(settings: true) }
            )
            .environment(cameraManager)
            .environment(viewModel)
            .environment(previewController)
        )
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        observeCameras()
    }

    private func observeCameras() {
        let cameras = withObservationTracking {
            cameraManager.cameras
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeCameras() }
        }
        handleCameraListChange(cameras)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        cameraManager.checkPermissionState()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        cameraManager.checkPermissionState()
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            let controls = menu.addItem(withTitle: "Open Full Controls", action: #selector(openFullControls), keyEquivalent: "o")
            controls.target = self
            let settings = menu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit MacWebcamController", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    @objc private func openFullControls() { showMainWindow(settings: false) }
    @objc fileprivate func openSettings() { showMainWindow(settings: true) }

    private func showMainWindow(settings: Bool) {
        popover.performClose(nil)
        viewModel.showingSettings = settings
        cameraManager.checkPermissionState()
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Camera Controls"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 400, height: 500)
            window.contentViewController = NSHostingController(rootView:
                MainWindowView()
                    .environment(cameraManager)
                    .environment(viewModel)
                    .environment(previewController)
            )
            window.center()
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.deminiaturize(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func windowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleCameraListChange(_ cameras: [CameraInfo]) {
        if let selected = viewModel.selectedCamera {
            if let refreshed = cameras.first(where: { $0.id == selected.id }) {
                if refreshed != selected { viewModel.selectCamera(refreshed) }
                return
            }
            viewModel.selectCamera(nil)
            viewModel.errorMessage = "Camera \"\(selected.name)\" was disconnected."
        }

        // Only a serial-backed identity can authorize migration across ports.
        let physicalMatches = cameras.filter {
            guard let identity = viewModel.lastSelectedPhysicalCameraID else { return false }
            return $0.uvcDevice?.persistentIdentity == identity
        }
        if physicalMatches.count > 1 {
            viewModel.errorMessage = "Multiple cameras report the same serial identity. Select a camera explicitly."
            return
        }
        if let sameCamera = physicalMatches.first {
            if let oldCameraID = viewModel.lastSelectedCameraID {
                SettingsPersistence().migrateCameraData(from: oldCameraID, to: sameCamera.id)
            }
            viewModel.selectCamera(sameCamera)
        } else if let sameCamera = cameras.first(where: { $0.id == viewModel.lastSelectedCameraID }),
                  viewModel.lastSelectedPhysicalCameraID == nil ||
                    sameCamera.uvcDevice?.persistentIdentity == viewModel.lastSelectedPhysicalCameraID {
            viewModel.selectCamera(sameCamera)
        } else if cameras.count == 1 {
            viewModel.selectCamera(cameras.first)
        } else if cameras.filter({ $0.uvcDevice != nil }).count == 1,
                  let singleUVC = cameras.first(where: { $0.uvcDevice != nil }) {
            viewModel.selectCamera(singleUVC)
        }
    }

}

@main
struct MacWebcamControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { SettingsView().frame(width: 420, height: 260) }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
