import SwiftUI

struct MenuBarView: View {
    @Environment(CameraManager.self) private var cameraManager
    @Environment(CameraViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            CameraPickerView()

            Divider()

            if viewModel.selectedCamera != nil {
                Text("Controls coming soon...")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Text("No camera selected")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Open Full Controls") {
                openWindow(id: "main")
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
