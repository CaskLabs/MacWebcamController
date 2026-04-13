import SwiftUI

@main
struct MacWebcamControllerApp: App {
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
