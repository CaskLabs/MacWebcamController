import SwiftUI

private class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let raw = UserDefaults.standard.string(forKey: "appearanceMode") ?? ""
        let mode = AppearanceMode(rawValue: raw) ?? .system
        mode.apply()
    }
}

@main
struct MacWebcamControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

        Settings {
            SettingsView()
        }
    }

    /// Deselects the current camera if it was disconnected.
    @MainActor
    private func handleCameraListChange(_ cameras: [CameraInfo]) {
        guard let selected = viewModel.selectedCamera else { return }
        if !cameras.contains(where: { $0.id == selected.id }) {
            viewModel.selectCamera(nil)
            viewModel.errorMessage = "Camera \"\(selected.name)\" was disconnected."
        }
    }
}
