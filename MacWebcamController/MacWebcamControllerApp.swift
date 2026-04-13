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
        }
        .menuBarExtraStyle(.window)

        Window("Camera Controls", id: "main") {
            MainWindowView()
                .environment(cameraManager)
                .environment(viewModel)
        }
        .defaultSize(width: 420, height: 600)
    }
}
