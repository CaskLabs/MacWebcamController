import SwiftUI

struct MainWindowView: View {
    @Environment(CameraManager.self) private var cameraManager
    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 16) {
            CameraPickerView()

            Divider()

            if viewModel.selectedCamera != nil {
                Text("Full controls coming soon...")
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "No Camera Selected",
                    systemImage: "camera",
                    description: Text("Connect a USB camera and select it above.")
                )
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 400, minHeight: 500)
    }
}
