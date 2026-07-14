import SwiftUI

struct CameraPickerView: View {
    @Environment(CameraManager.self) private var cameraManager
    @Environment(CameraViewModel.self) private var viewModel
    @State private var isExpanded = false

    var body: some View {
        if cameraManager.cameras.isEmpty {
            HStack {
                Image(systemName: "camera.slash")
                    .foregroundStyle(.secondary)
                Text("No external cameras found")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.selectedCamera?.uvcDevice != nil ? "camera.fill" : "camera")
                        Text(viewModel.selectedCamera?.name ?? "Select a camera…")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(cameraManager.cameras) { camera in
                            Button {
                                viewModel.selectCamera(camera)
                                isExpanded = false
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: camera.uvcDevice != nil ? "camera.fill" : "camera")
                                    Text(camera.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if viewModel.selectedCameraID == camera.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        }
                    }
                    .padding(.vertical, 3)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
                }
            }
        }
    }
}
