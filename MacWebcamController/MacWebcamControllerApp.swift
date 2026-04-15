import SwiftUI

@MainActor
private class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the SwiftUI App to open a window by ID.
    var openWindowHandler: ((String) -> Void)?

    private weak var statusBarButton: NSStatusBarButton?
    private var originalTarget: AnyObject?
    private var originalAction: Selector?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let raw = UserDefaults.standard.string(forKey: "appearanceMode") ?? ""
        let mode = AppearanceMode(rawValue: raw) ?? .system
        mode.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowCountChanged),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowCountChanged),
            name: NSWindow.willCloseNotification, object: nil)

        // Wait for SwiftUI to create the MenuBarExtra status item, then hook right-click.
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            setupStatusBarRightClick()
        }
    }

    private func setupStatusBarRightClick() {
        guard let button = findStatusBarButton() else {
            print("[AppDelegate] Status bar button not found — right-click menu unavailable")
            return
        }
        statusBarButton = button
        originalTarget = button.target as AnyObject?
        originalAction = button.action
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp]
        button.sendAction(on: mask)
        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
    }

    /// Scans NSApp.windows for the status-bar-level window and returns its NSStatusBarButton.
    private func findStatusBarButton() -> NSStatusBarButton? {
        for window in NSApp.windows where window.level == .statusBar {
            if let button = firstSubview(ofType: NSStatusBarButton.self, in: window.contentView) {
                return button
            }
        }
        return nil
    }

    private func firstSubview<T: NSView>(ofType type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let match = firstSubview(ofType: type, in: sub) { return match }
        }
        return nil
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu(for: sender)
        } else if let action = originalAction {
            NSApp.sendAction(action, to: originalTarget, from: sender)
        }
    }

    private func showContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open Full Controls", action: #selector(openFullControls), keyEquivalent: "")
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MacWebcamController", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 2), in: button)
    }

    @objc private func openFullControls() {
        openWindowHandler?("main")
    }

    @objc private func openSettings() {
        openWindowHandler?("main")
    }

    @objc private func windowCountChanged(_ notification: Notification) {
        // Defer one run-loop cycle so SwiftUI can update the window list after a close.
        DispatchQueue.main.async {
            let hasWindow = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled)
            }
            NSApp.setActivationPolicy(hasWindow ? .regular : .accessory)
        }
    }
}

@main
struct MacWebcamControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var cameraManager = CameraManager()
    @State private var viewModel = CameraViewModel()

    var body: some Scene {
        MenuBarExtra("MacWebcamController", systemImage: "camera") {
            MenuBarView()
                .environment(cameraManager)
                .environment(viewModel)
                .onChange(of: cameraManager.cameras) { _, cameras in
                    handleCameraListChange(cameras)
                }
                .onAppear {
                    appDelegate.openWindowHandler = { id in
                        openWindow(id: id)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Window("Camera Controls", id: "main") {
            MainWindowView()
                .environment(cameraManager)
                .environment(viewModel)
                .onChange(of: cameraManager.cameras) { _, cameras in
                    handleCameraListChange(cameras)
                }
        }
        .defaultSize(width: 420, height: 600)
    }

    @MainActor
    private func handleCameraListChange(_ cameras: [CameraInfo]) {
        guard let selected = viewModel.selectedCamera else { return }
        if !cameras.contains(where: { $0.id == selected.id }) {
            viewModel.selectCamera(nil)
            viewModel.errorMessage = "Camera \"\(selected.name)\" was disconnected."
        }
    }
}
