import SwiftUI

struct CameraPickerView: View {
    @Environment(CameraManager.self) private var cameraManager
    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        if cameraManager.cameras.isEmpty {
            HStack {
                Image(systemName: "camera.slash")
                    .foregroundStyle(.secondary)
                Text("No external cameras found")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        } else {
            Picker("Camera", selection: $vm.selectedCameraID) {
                Text("Select a camera…").tag(String?.none)
                ForEach(cameraManager.cameras) { camera in
                    HStack {
                        Image(systemName: camera.uvcDevice != nil ? "camera.fill" : "camera")
                        Text(camera.name)
                    }
                    .tag(Optional(camera.id))
                }
            }
            .labelsHidden()
            .onChange(of: vm.selectedCameraID) { _, newValue in
                let camera = cameraManager.cameras.first { $0.id == newValue }
                viewModel.selectCamera(camera)
            }
        }
    }
}
