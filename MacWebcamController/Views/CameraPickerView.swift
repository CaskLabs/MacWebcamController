import SwiftUI

struct CameraPickerView: View {
    @Environment(CameraManager.self) private var cameraManager
    @Environment(CameraViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        Picker("Camera", selection: $vm.selectedCameraID) {
            Text("None").tag(String?.none)
            ForEach(cameraManager.cameras) { camera in
                Text(camera.name).tag(Optional(camera.id))
            }
        }
        .labelsHidden()
        .onChange(of: vm.selectedCameraID) { _, newValue in
            if let id = newValue,
               let camera = cameraManager.cameras.first(where: { $0.id == id }) {
                viewModel.selectCamera(camera)
            } else {
                viewModel.selectCamera(nil)
            }
        }
    }
}
